import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearbridge/core/models.dart';
import 'package:nearbridge/core/transfer_protocol.dart';

void main() {
  test('upload blocks resume, reject corruption and complete idempotently', () async {
    final root = await Directory.systemTemp.createTemp('nearbridge-blocks-');
    try {
      final inbox = await Directory('${root.path}/inbox').create();
      final store = UploadStore(root, inbox);
      final id = randomToken(16);
      final bytes = Uint8List.fromList(utf8.encode('first second'));
      final digest = sha256.convert(bytes).toString();
      final meta = {'id': id, 'name': 'file.txt', 'size': bytes.length, 'sha256': digest,
        'relative': 'Folder/Nested/file.txt'};
      expect((await store.start('peer', meta))['offset'], 0);
      final first = bytes.sublist(0, 5);
      await expectLater(store.block('peer', id, 0, first, '0' * 64), throwsFormatException);
      await store.block('peer', id, 0, first, sha256.convert(first).toString());
      expect((await store.start('peer', meta))['offset'], 5);
      expect((await store.block('peer', id, 0, first, sha256.convert(first).toString()))['offset'], 5);
      final rest = bytes.sublist(5);
      await store.block('peer', id, 5, rest, sha256.convert(rest).toString());
      final done = await store.complete('peer', id);
      expect(done['sha256'], digest);
      expect(await File(done['path'] as String).readAsBytes(), bytes);
      expect((await store.complete('peer', id))['done'], isTrue);
      expect((await inbox.list(recursive: true).where((e) => e is File).toList()).length, 1);
      await expectLater(store.start('peer', {...meta, 'sha256': 'a' * 64}), throwsFormatException);
      await expectLater(store.start('peer', {...meta, 'id': randomToken(16), 'relative': '../secret'}), throwsFormatException);
    } finally { await root.delete(recursive: true); }
  });
}
