import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:linkindrop/core/models.dart';
import 'package:linkindrop/core/connection_error.dart';
import 'package:linkindrop/core/node.dart';

import 'support/relay_server.dart';

void main() {
  test('pinned TLS pairing and clipboard travel through the internet relay', () async {
    final root = await Directory.systemTemp.createTemp('linkindrop-relay-');
    RelayServer? fixture;
    Process? process;
    final received = <ClipboardPayload>[];
    final activities = <Activity>[];
    BridgeNode make(String name) => BridgeNode(directory: Directory('${root.path}/$name'),
      name: name, preferredPort: 0, discoveryEnabled: false, onPairRequest: (_) async => true,
      onClipboard: (payload) async => received.add(payload), onActivity: activities.add, onChanged: () {});
    final source = make('source'); final client = make('client');
    try {
      late int port;
      if (await File('relay_server/node_modules/ws/package.json').exists()) {
        process = await Process.start('node', ['relay_server/server.mjs'], environment: {'PORT': '0'});
        final line = await process.stdout.transform(utf8.decoder).transform(const LineSplitter()).first;
        port = int.parse(line.split(' ').last);
      } else { fixture = RelayServer(); await fixture.start(port: 0); port = fixture.port; }
      final url = 'ws://127.0.0.1:$port';
      await source.start(); await client.start();
      await source.configureRelay(url); await client.configureRelay(url);
      final original = source.invite('127.0.0.1');
      final invite = PairInvite(id: original.id, name: original.name, host: '127.0.0.1', port: 1,
        fingerprint: original.fingerprint, secret: original.secret, expiresAt: original.expiresAt,
        relayUrl: original.relayUrl, relayRoom: original.relayRoom);
      expect(PairInvite.parse(invite.encode()).relayUrl, url);
      await client.pair(invite);
      final peer = client.peers.values.single;
      peer.host = '127.0.0.1'; peer.port = 1; peer.additionalHosts = [];
      await client.sendClipboard(ClipboardPayload(id: randomToken(16), type: 'text',
        data: Uint8List.fromList(utf8.encode('relayed')), createdAt: DateTime.now()));
      expect(peer.activeRelay, isTrue);
      expect(received.single.text, 'relayed');
      final bytes = Uint8List.fromList(List.generate(5 * 1024 * 1024, (i) => i % 251));
      final file = await File('${root.path}/relayed.bin').writeAsBytes(bytes);
      await source.sharedFiles.add(file.path);
      source.fileSharingEnabled = true;
      final entry = (await client.listFiles(peer)).single;
      await client.downloadFile(peer, entry);
      expect(await File(activities.singleWhere((a) => a.path != null).path!).readAsBytes(), bytes);
      final bad = PairInvite(id: invite.id, name: invite.name, host: invite.host, port: invite.port,
        fingerprint: '0' * 64, secret: invite.secret, expiresAt: invite.expiresAt,
        relayUrl: invite.relayUrl, relayRoom: invite.relayRoom);
      await expectLater(client.probeInvite(bad), throwsA(isA<ConnectionFailure>()
        .having((e) => e.kind, 'kind', ConnectionFailureKind.certificate)));
    } finally {
      await client.stop(); await source.stop(); await fixture?.close();
      if (process != null) { process.kill(); await process.exitCode; }
      await root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
