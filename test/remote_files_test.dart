import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linkindrop/core/connection_error.dart';
import 'package:linkindrop/core/models.dart';
import 'package:linkindrop/core/node.dart';

void main() {
  test('paired browsing, pull download, route failover and revocation', () async {
    final root = await Directory.systemTemp.createTemp('linkindrop-remote-');
    final received = <Activity>[];
    BridgeNode make(String name) => BridgeNode(
      directory: Directory('${root.path}/$name'), name: name, preferredPort: 0,
      discoveryEnabled: false, onPairRequest: (_) async => true,
      onClipboard: (_) async {}, onActivity: received.add, onChanged: () {});
    final first = make('first');
    final second = make('second');
    try {
      await first.start();
      await second.start();
      await second.pair(first.invite('127.0.0.1'));
      final peer = second.peers[first.identity.id]!;
      await expectLater(second.listFiles(peer), throwsA(isA<RemoteFailure>()
        .having((e) => e.status, 'status', 403)));
      final file = await File('${root.path}/sample.bin')
        .writeAsBytes(List.generate(250000, (i) => i % 251));
      await first.sharedFiles.add(file.path);
      first.fileSharingEnabled = true;
      final entry = (await second.listFiles(peer)).single;
      expect(entry.name, 'sample.bin');
      peer.remoteHost = '127.0.0.2';
      peer.remotePort = 1;
      await second.downloadFile(peer, entry);
      final output = received.where((a) => a.path != null).single.path!;
      expect(await File(output).readAsBytes(), await file.readAsBytes());
      expect(second.transferName, isNull);
      expect(await second.inbox.list().where((e) => e.path.endsWith('.part')).isEmpty, isTrue);
      second.receivingEnabled = false;
      await expectLater(second.downloadFile(peer, entry), throwsStateError);
      second.receivingEnabled = true;
      await first.sharedFiles.remove(entry.id);
      await expectLater(second.downloadFile(peer, entry), throwsA(isA<RemoteFailure>()
        .having((e) => e.status, 'status', 404)));
      expect(await second.inbox.list().where((e) => e.path.endsWith('.part')).isEmpty, isTrue);
      await first.forget(second.identity.id);
      await expectLater(second.listFiles(peer), throwsA(isA<RemoteFailure>()
        .having((e) => e.status, 'status', 401)));
    } finally {
      await first.stop();
      await second.stop();
      await root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('pairing can use an alternative adapter from a new QR code', () async {
    final root = await Directory.systemTemp.createTemp('linkindrop-adapter-');
    BridgeNode make(String name) => BridgeNode(
      directory: Directory('${root.path}/$name'), name: name, preferredPort: 0,
      discoveryEnabled: false, onPairRequest: (_) async => true,
      onClipboard: (_) async {}, onActivity: (_) {}, onChanged: () {});
    final first = make('first');
    final second = make('second');
    try {
      await first.start();
      await second.start();
      final original = first.invite('127.0.0.1');
      final invite = PairInvite(id: original.id, name: original.name,
        host: '0.0.0.0', port: original.port, fingerprint: original.fingerprint,
        secret: original.secret, expiresAt: original.expiresAt, hosts: ['127.0.0.1']);
      await second.pair(invite);
      expect(second.peers[first.identity.id]!.online, isTrue);
    } finally {
      await first.stop();
      await second.stop();
      await root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 1)));
}
