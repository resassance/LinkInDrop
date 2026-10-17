import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linkindrop/core/connection_error.dart';
import 'package:linkindrop/core/models.dart';
import 'package:linkindrop/core/node.dart';

void main() {
  test('TLS folder browsing, nested download, disabled sharing and grant revocation', () async {
    final root = await Directory.systemTemp.createTemp('linkindrop-folder-transfer-');
    final activities = <Activity>[];
    BridgeNode make(String name) => BridgeNode(
      directory: Directory('${root.path}/$name'), name: name, preferredPort: 0,
      discoveryEnabled: false, onPairRequest: (_) async => true,
      onClipboard: (_) async {}, onActivity: activities.add, onChanged: () {});
    final first = make('first');
    final second = make('second');
    try {
      await first.start();
      await second.start();
      await second.pair(first.invite('127.0.0.1'));
      final peer = second.peers[first.identity.id]!;
      final shared = await Directory('${root.path}/Documents').create();
      await Directory('${shared.path}/Nested').create();
      final original = await File('${shared.path}/Nested/Привет #1.txt').writeAsString('Привет');
      await first.sharedFolders.add(shared.path);
      await expectLater(second.browseFiles(peer), throwsA(isA<RemoteFailure>()
        .having((e) => e.status, 'status', 403)));
      first.fileSharingEnabled = true;
      final folder = (await second.browseFiles(peer)).entries.single;
      expect(folder.name, 'Documents');
      expect(jsonEncode(folder.toJson()), isNot(contains(root.path)));
      final client = HttpClient(context: SecurityContext(withTrustedRoots: false));
      client.badCertificateCallback = (certificate, _, _) =>
        certificateFingerprint(certificate.pem) == first.identity.fingerprint;
      try {
        for (final path in ['../private/identity.json', '/etc/passwd', r'Nested\..\private']) {
          final request = await client.getUrl(Uri(scheme: 'https', host: '127.0.0.1',
            port: first.port, path: '/browse/file', queryParameters: {'folder': folder.id, 'path': path}));
          request.headers.set('X-LinkInDrop-Id', second.identity.id);
          request.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${peer.outgoingToken}');
          final response = await request.close();
          expect(response.statusCode, 400);
          await response.drain<void>();
        }
      } finally {
        client.close(force: true);
      }
      final nested = (await second.browseFiles(peer, folder: folder)).entries.single;
      expect(nested.name, 'Nested');
      final entry = (await second.browseFiles(peer, folder: nested)).entries.single;
      expect(entry.relativePath, 'Nested/Привет #1.txt');
      await second.downloadFile(peer, entry);
      final received = activities.singleWhere((e) => e.path != null);
      expect(await File(received.path!).readAsBytes(), await original.readAsBytes());
      expect(await second.listFiles(peer), isEmpty);
      first.fileSharingEnabled = false;
      await expectLater(second.downloadFile(peer, entry), throwsA(isA<RemoteFailure>()
        .having((e) => e.status, 'status', 403)));
      first.fileSharingEnabled = true;
      await first.sharedFolders.remove(folder.id);
      await expectLater(second.browseFiles(peer, folder: nested), throwsA(isA<RemoteFailure>()
        .having((e) => e.status, 'status', 404)));
      await expectLater(second.downloadFile(peer, entry), throwsA(isA<RemoteFailure>()
        .having((e) => e.status, 'status', 404)));
      expect(await second.inbox.list().where((e) => e.path.endsWith('.part')).isEmpty, isTrue);
    } finally {
      await first.stop();
      await second.stop();
      await root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
