import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linkindrop/core/shared_files.dart';

void main() {
  test('explicit grants survive restart, revoke, and exclude private files', () async {
    final root = await Directory.systemTemp.createTemp('linkindrop-shares-');
    try {
      final private = await Directory('${root.path}/private').create();
      final library = SharedFiles(private);
      await library.load();
      final file = await File('${root.path}/document.txt').writeAsString('hello');
      await library.add(file.path);
      await library.add(file.path);
      final entry = (await library.list()).single;
      expect(entry.name, 'document.txt');
      expect(entry.size, 5);
      expect(await library.resolve('../../document.txt'), isNull);
      final keys = await File('${private.path}/identity.json').writeAsString('secret');
      await expectLater(library.add(keys.path), throwsStateError);
      final loaded = SharedFiles(private);
      await loaded.load();
      expect((await loaded.list()).single.id, entry.id);
      await loaded.remove(entry.id);
      expect(await loaded.resolve(entry.id), isNull);
      final reloaded = SharedFiles(private);
      await reloaded.load();
      expect(await reloaded.list(), isEmpty);
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('deleted files and replacements by symlinks are not served', () async {
    final root = await Directory.systemTemp.createTemp('linkindrop-links-');
    try {
      final private = await Directory('${root.path}/private').create();
      final library = SharedFiles(private);
      final file = await File('${root.path}/shared.txt').writeAsString('public');
      await library.add(file.path);
      final entry = (await library.list()).single;
      await file.delete();
      expect(await library.resolve(entry.id), isNull);
      if (!Platform.isWindows) {
        final secret = await File('${private.path}/identity.json').writeAsString('secret');
        await Link(file.path).create(secret.path);
        expect(await library.resolve(entry.id), isNull);
        await expectLater(library.add(file.path), throwsStateError);
      }
    } finally {
      await root.delete(recursive: true);
    }
  });
}
