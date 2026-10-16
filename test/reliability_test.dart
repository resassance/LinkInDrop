import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearbridge/core/models.dart';
import 'package:nearbridge/core/node.dart';
import 'package:nearbridge/core/receive_storage.dart';
import 'package:nearbridge/core/release_info.dart';
import 'package:nearbridge/core/shared_folders.dart';
import 'package:nearbridge/core/transfer_queue.dart';
import 'package:nearbridge/core/photo_backup.dart';

void main() {
  test('release ordering distinguishes stable versions, alpha versions and numbers', () {
    expect(compareVersions('v0.3.0-alpha.2', '0.3.0-alpha.1'), greaterThan(0));
    expect(compareVersions('v0.3.0', '0.3.0-alpha.9'), greaterThan(0));
    expect(compareVersions('v0.10.0', '0.9.99'), greaterThan(0));
    expect(compareVersions('v0.2.0', '0.3.0-alpha.1'), lessThan(0));
  });

  test('receive policies preserve, rename or replace files and verify actual contents', () async {
    final root = await Directory.systemTemp.createTemp('nearbridge-storage-');
    try {
      final private = await Directory('${root.path}/private').create();
      final inbox = await Directory('${private.path}/inbox').create();
      final target = await Directory('${root.path}/received').create();
      final storage = ReceiveStorage(private, inbox)..destination = target.path;
      await storage.load();
      await File('${target.path}/photo.jpg').writeAsString('old');
      final digest = sha256.convert(utf8.encode('new')).toString();
      Future<File> source(String id) => File('${inbox.path}/$id').writeAsString('new');
      final renamed = await storage.deliver('peer', 'rename', await source('rename'), 'photo.jpg', digest);
      expect(await File('${target.path}/photo.jpg').readAsString(), 'old');
      expect(await File(renamed['location'] as String).readAsString(), 'new');
      expect(await storage.verify('peer', storage.key('peer', 'rename'), digest), isTrue);
      expect(await storage.verify('other-peer', storage.key('peer', 'rename'), digest), isFalse);
      await File(renamed['location'] as String).writeAsString('corrupt');
      expect(await storage.verify('peer', storage.key('peer', 'rename'), digest), isFalse);
      await expectLater(storage.open('peer', storage.key('peer', 'rename'), 0, 4), throwsA(isA<FileSystemException>()));
      storage.conflict = 'skip';
      final skipped = await storage.deliver('peer', 'skip', await source('skip'), 'photo.jpg', digest);
      expect(skipped['skipped'], isTrue);
      expect(await File('${target.path}/photo.jpg').readAsString(), 'old');
      storage.conflict = 'replace';
      await storage.deliver('peer', 'replace', await source('replace'), 'photo.jpg', digest);
      expect(await File('${target.path}/photo.jpg').readAsString(), 'new');
      final restored = ReceiveStorage(private, inbox)..destination = target.path;
      await restored.load();
      expect(await restored.verify('peer', storage.key('peer', 'replace'), digest), isTrue);
      await storage.createDirectory('Empty/Nested');
      expect(await Directory('${target.path}/Empty/Nested').exists(), isTrue);
    } finally { await root.delete(recursive: true); }
  });

  test('receive destination rejects a symlinked parent', () async {
    final root = await Directory.systemTemp.createTemp('nearbridge-storage-link-');
    try {
      final private = await Directory('${root.path}/private').create();
      final inbox = await Directory('${private.path}/inbox').create();
      final target = await Directory('${root.path}/received').create();
      final outside = await Directory('${root.path}/outside').create();
      await Link('${target.path}/Nested').create(outside.path);
      final source = await File('${inbox.path}/source').writeAsString('new');
      final storage = ReceiveStorage(private, inbox)..destination = target.path;
      await expectLater(storage.deliver('peer', 'id', source, 'Nested/file.txt', sha256.convert(utf8.encode('new')).toString()), throwsA(isA<FileSystemException>()));
      expect(await source.exists(), isTrue);
      expect(await File('${outside.path}/file.txt').exists(), isFalse);
    } finally { await root.delete(recursive: true); }
  });

  test('queue priorities apply to folder groups and survive serialization', () async {
    final root = await Directory.systemTemp.createTemp('nearbridge-priority-');
    final executions = <String>[];
    final done = Completer<void>();
    final queue = TransferQueue(directory: root, execute: (job, progress) async { executions.add(job.name); progress(1); },
      interrupt: () {}, completed: (_) async {}, discard: (_) async {});
    try {
      final low = TransferJob(id: randomToken(16), peerId: 'peer', kind: 'upload', name: 'low', state: 'paused', totalBytes: 100, batchId: 'folder');
      final high = TransferJob(id: randomToken(16), peerId: 'peer', kind: 'upload', name: 'high', state: 'paused', totalBytes: 200);
      await queue.addAll([low, high]);
      await queue.setPriority(high, 1);
      final decoded = TransferJob.fromJson(high.toJson());
      expect(decoded.priority, 1); expect(decoded.totalBytes, 200);
      low.state = 'waiting'; high.state = 'waiting';
      queue.addListener(() { if (queue.jobs.every((j) => j.state == 'completed') && !done.isCompleted) done.complete(); });
      queue.start(); await done.future;
      expect(executions, ['high', 'low']);
      expect(queue.batchProgress('folder'), 1);
    } finally { await queue.close(); await root.delete(recursive: true); }
  });

  test('backup receipts verify remote copies, restore files and redact diagnostics', () async {
    final root = await Directory.systemTemp.createTemp('nearbridge-receipts-');
    BridgeNode make(String name) => BridgeNode(directory: Directory('${root.path}/$name'), name: name,
      preferredPort: 0, discoveryEnabled: false, onPairRequest: (_) async => true,
      onClipboard: (_) async {}, onActivity: (_) {}, onChanged: () {});
    final receiver = make('receiver'), sender = make('sender');
    try {
      await receiver.start(); await sender.start(); await sender.pair(receiver.invite('127.0.0.1'));
      final destination = await Directory('${root.path}/Photos').create();
      receiver.received.destination = destination.path;
      final file = await File('${root.path}/photo.jpg').writeAsString('photo-data');
      final peer = sender.peers.values.single;
      final id = randomToken(16);
      Future<SharedRead> open(int offset, int? length) async => SharedRead(10,
        file.openRead(offset, length == null ? null : (offset + length > 10 ? 10 : offset + length)), () async {}, version: 'photo');
      final digest = await sender.uploadSource(peer, id, 'photo.jpg', open);
      final token = sender.lastUploadReceipt!['receipt'] as String;
      expect(await sender.verifyReceipt(peer, token, digest), isTrue);
      await sender.downloadFile(peer, SharedFile(id: 'receipt:$token', name: 'photo.jpg', size: 10), expectedDigest: digest);
      final restored = sender.received.receipts.values.single;
      expect(await File(restored['location'] as String).readAsString(), 'photo-data');
      await File('${destination.path}/photo.jpg').delete();
      expect(await sender.verifyReceipt(peer, token, digest), isFalse);
      final report = sender.diagnosticReport();
      for (final private in [peer.id, peer.fingerprint, peer.incomingToken, peer.outgoingToken, peer.host, root.path]) { expect(report.contains(private), isFalse); }
      expect(peer.latencyMs, isNotNull);
    } finally { await sender.stop(); await receiver.stop(); await root.delete(recursive: true); }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('photo verification makes a lost copy eligible for repair without changing originals', () async {
    final root = await Directory.systemTemp.createTemp('nearbridge-backup-verify-');
    final private = await Directory('${root.path}/private').create();
    final photos = await Directory('${root.path}/Camera').create();
    final original = await File('${photos.path}/photo.jpg').writeAsString('original-photo');
    final jobs = <TransferJob>[];
    var remoteValid = true;
    final backup = PhotoBackup(directory: private, sources: SharedFolders(private, stateFilename: 'backup-folders.json'),
      enqueue: (batch) async => jobs.addAll(batch), available: (_) => true, changed: () {},
      verifyCopy: (_, __, ___) async => remoteValid);
    try {
      await backup.load([]); await backup.sources.add(photos.path);
      backup.peerId = 'peer'; backup.enabled = true;
      await backup.scan(); expect(jobs.length, 1);
      jobs.single.receipt = 'receipt'; await backup.completed(jobs.single);
      await backup.verify(); expect(backup.verified, 1); expect(backup.missing, 0);
      remoteValid = false;
      await backup.verify(); expect(backup.missing, 1);
      await backup.scan(); expect(jobs.length, 2);
      expect(await original.readAsString(), 'original-photo');
    } finally { await backup.close(); await root.delete(recursive: true); }
  });

  test('free space preflight rejects an impossible reservation before writing data', () async {
    final root = await Directory.systemTemp.createTemp('nearbridge-space-');
    try {
      final available = await freeBytes(root.path);
      expect(available, isNotNull);
      await expectLater(requireSpace(root.path, available! + 1), throwsA(isA<InsufficientSpace>()));
      expect(await root.list().isEmpty, isTrue);
    } finally { await root.delete(); }
  });

  test('shared files larger than 2 GiB support 64 bit ranged offsets', () async {
    final root = await Directory.systemTemp.createTemp('nearbridge-large-range-');
    final node = BridgeNode(directory: Directory('${root.path}/node'), name: 'large', preferredPort: 0,
      discoveryEnabled: false, onPairRequest: (_) async => true, onClipboard: (_) async {}, onActivity: (_) {}, onChanged: () {});
    final client = HttpClient(context: SecurityContext(withTrustedRoots: false))..badCertificateCallback = (_, __, ___) => true;
    try {
      await node.start();
      final size = 3 * 1024 * 1024 * 1024;
      final file = File('${root.path}/large.bin');
      final handle = await file.open(mode: FileMode.write);
      await handle.truncate(size); await handle.setPosition(size - 1); await handle.writeByte(123); await handle.close();
      await node.sharedFiles.add(file.path); node.fileSharingEnabled = true;
      final entry = (await node.sharedFiles.list()).single;
      expect(entry.size, size); expect(SharedFile.fromJson(entry.toJson()).size, size);
      final peer = Peer(id: 'test-peer', name: 'peer', host: '127.0.0.1', port: 1, fingerprint: '0' * 64,
        incomingToken: randomToken(), outgoingToken: randomToken());
      node.peers[peer.id] = peer;
      final request = await client.getUrl(Uri.parse('https://127.0.0.1:${node.port}/files/${entry.id}'));
      request.headers.set('X-Nearbridge-Id', peer.id);
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${peer.incomingToken}');
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=${size - 16}-${size - 1}');
      final response = await request.close();
      expect(response.statusCode, 206);
      final bytes = await response.expand((chunk) => chunk).toList();
      expect(bytes.length, 16); expect(bytes.last, 123);
      expect(response.headers.value(HttpHeaders.contentRangeHeader), 'bytes ${size - 16}-${size - 1}/$size');
    } finally { client.close(force: true); await node.stop(); await root.delete(recursive: true); }
  });
}
