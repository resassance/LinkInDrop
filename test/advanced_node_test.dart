import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearbridge/core/access_rules.dart';
import 'package:nearbridge/core/connection_error.dart';
import 'package:nearbridge/core/models.dart';
import 'package:nearbridge/core/node.dart';
import 'package:nearbridge/core/shared_folders.dart';
import 'package:nearbridge/core/transfer_protocol.dart';

void main() {
  test('downloads and uploads retain checked blocks across pause and resume', () async {
    final root = await Directory.systemTemp.createTemp('nearbridge-resume-');
    var pause = false;
    late BridgeNode receiver;
    final activities = <Activity>[];
    BridgeNode make(String name) => BridgeNode(directory: Directory('${root.path}/$name'),
      name: name, preferredPort: 0, discoveryEnabled: false, onPairRequest: (_) async => true,
      onClipboard: (_) async {}, onActivity: activities.add, onChanged: () {
        if (name == 'receiver' && pause && (receiver.transferProgress ?? 0) > 0.3) {
          pause = false;
          receiver.cancelTransfer();
        }
      });
    final source = make('source');
    receiver = make('receiver');
    try {
      await source.start(); await receiver.start();
      await receiver.pair(source.invite('127.0.0.1'));
      source.fileSharingEnabled = true;
      final bytes = Uint8List.fromList(List.generate(9 * 1024 * 1024, (i) => i % 251));
      final file = await File('${root.path}/large.bin').writeAsBytes(bytes);
      await source.sharedFiles.add(file.path);
      final peer = receiver.peers.values.single;
      final entry = (await receiver.listFiles(peer)).single;
      final id = randomToken(16);
      pause = true;
      await expectLater(receiver.downloadFile(peer, entry, transferId: id), throwsA(isA<TransferStopped>()));
      final meta = jsonDecode(await File('${receiver.directory.path}/partial/$id.json').readAsString()) as Map;
      expect(meta['offset'], transferBlockBytes);
      await receiver.downloadFile(peer, entry, transferId: id);
      final accepted = activities.lastWhere((a) => a.path != null);
      expect(await File(accepted.path!).readAsBytes(), bytes);
      final uploadId = randomToken(16);
      Future<SharedRead> open(int offset, int? length) async {
        final stat = await file.stat();
        final end = length == null ? stat.size : (offset + length < stat.size ? offset + length : stat.size);
        return SharedRead(stat.size, file.openRead(offset, end), () async {}, version: contentVersion(stat.size, stat.modified));
      }
      pause = true;
      await expectLater(receiver.uploadSource(peer, uploadId, 'large.bin', open), throwsA(isA<TransferStopped>()));
      await receiver.uploadSource(peer, uploadId, 'large.bin', open);
      final uploaded = activities.lastWhere((a) => a.path != null);
      expect(await File(uploaded.path!).readAsBytes(), bytes);
    } finally { await receiver.stop(); await source.stop(); await root.delete(recursive: true); }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('per-device access, expiry, recursive search and text preview', () async {
    final root = await Directory.systemTemp.createTemp('nearbridge-tools-');
    BridgeNode make(String name) => BridgeNode(directory: Directory('${root.path}/$name'),
      name: name, preferredPort: 0, discoveryEnabled: false, onPairRequest: (_) async => true,
      onClipboard: (_) async {}, onActivity: (_) {}, onChanged: () {});
    final source = make('source'); final client = make('client');
    try {
      await source.start(); await client.start(); await client.pair(source.invite('127.0.0.1'));
      final folder = await Directory('${root.path}/Docs/Nested').create(recursive: true);
      await File('${folder.path}/unique-name.txt').writeAsString('preview text');
      await source.sharedFolders.add('${root.path}/Docs');
      source.fileSharingEnabled = true;
      final peer = client.peers.values.single;
      final grant = (await client.browseFiles(peer)).entries.single;
      final result = await client.searchFiles(peer, 'unique');
      expect(result.entries.single.relativePath, 'Nested/unique-name.txt');
      expect((await client.previewFile(peer, result.entries.single))['text'], 'preview text');
      await source.access.set(grant.id, ShareAccess(peerIds: {}));
      expect((await client.browseFiles(peer)).entries, isEmpty);
      await expectLater(client.browseFiles(peer, folder: grant), throwsA(isA<RemoteFailure>().having((e) => e.status, 'status', 403)));
      await source.access.set(grant.id, ShareAccess(peerIds: {client.identity.id}, expiresAt: DateTime.now().subtract(const Duration(seconds: 1))));
      expect((await client.browseFiles(peer)).entries, isEmpty);
      await source.access.set(grant.id, ShareAccess(peerIds: {client.identity.id}));
      expect((await client.browseFiles(peer)).entries.single.id, grant.id);
    } finally { await client.stop(); await source.stop(); await root.delete(recursive: true); }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
