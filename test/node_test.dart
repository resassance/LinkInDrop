import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearbridge/core/models.dart';
import 'package:nearbridge/core/node.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('TLS pairing, clipboard, file transfer, replay protection and revocation', () async {
    final root = await Directory.systemTemp.createTemp('nearbridge-test-');
    final received = <ClipboardPayload>[];
    final activities = <Activity>[];
    BridgeNode make(String name) => BridgeNode(
      directory: Directory('${root.path}/$name'), name: name, preferredPort: 0,
      discoveryEnabled: false, onPairRequest: (_) async => true,
      onClipboard: (payload) async => received.add(payload),
      onActivity: activities.add, onChanged: () {});
    final first = make('first');
    final second = make('second');
    try {
      await first.start();
      await second.start();
      final invite = first.invite('127.0.0.1');
      final bad = PairInvite(id: invite.id, name: invite.name, host: invite.host,
        port: invite.port, fingerprint: '0' * 64, secret: invite.secret,
        expiresAt: invite.expiresAt);
      await expectLater(second.pair(bad), throwsA(anything));
      await second.pair(invite);
      expect(first.peers.length, 1);
      expect(second.peers.length, 1);
      final payload = ClipboardPayload(id: 'message', type: 'text',
        data: Uint8List.fromList(utf8.encode('hello')), createdAt: DateTime.now());
      await second.sendClipboard(payload);
      await second.sendClipboard(payload);
      expect(received.length, 1);
      expect(received.single.text, 'hello');
      final file = File('${root.path}/sample.bin');
      final bytes = List.generate(512000, (i) => i % 256);
      await file.writeAsBytes(bytes);
      await second.sendFile(second.peers.values.single, file.path,
        filename: '../../sample.bin');
      final accepted = activities.where((a) => a.path != null).single;
      expect(accepted.path!.startsWith(first.inbox.path), isTrue);
      expect(await File(accepted.path!).readAsBytes(), bytes);
      first.clipboardReceivingEnabled = false;
      await expectLater(second.sendClipboard(ClipboardPayload(id: 'next', type: 'text',
        data: payload.data, createdAt: DateTime.now())), throwsStateError);
      await first.forget(second.identity.id);
      await second.checkPeers();
      expect(second.peers.values.single.online, isFalse);
      await expectLater(second.pair(invite), throwsA(anything));
    } finally {
      await first.stop();
      await second.stop();
      await root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
