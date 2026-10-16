import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearbridge/core/models.dart';
import 'package:nearbridge/core/shared_folders.dart';

void main() {
  test('folder grants persist, include new children and revoke the whole tree', () async {
    final root = await Directory.systemTemp.createTemp('nearbridge-folders-');
    try {
      final private = await Directory('${root.path}/private').create();
      final shared = await Directory('${root.path}/shared').create();
      await Directory('${shared.path}/nested').create();
      await File('${shared.path}/nested/hello.txt').writeAsString('hello');
      final folders = SharedFolders(private);
      await folders.add(shared.path);
      final grant = folders.roots().single;
      expect(grant.isDirectory, isTrue);
      final page = await folders.list(grant.id, '');
      expect(page.entries.single.relativePath, 'nested');
      expect(page.entries.single.isDirectory, isTrue);
      await File('${shared.path}/new.txt').writeAsString('new');
      expect((await folders.list(grant.id, '')).entries.map((e) => e.name), contains('new.txt'));
      final loaded = SharedFolders(private);
      await loaded.load();
      expect(loaded.roots().single.id, grant.id);
      final source = await loaded.open(grant.id, 'nested/hello.txt');
      expect(source.size, 5);
      expect(await source.stream.expand((bytes) => bytes).toList(), 'hello'.codeUnits);
      await source.close();
      await loaded.remove(grant.id);
      await expectLater(loaded.list(grant.id, ''), throwsA(isA<FileSystemException>()));
      await expectLater(loaded.open(grant.id, 'nested/hello.txt'), throwsA(isA<FileSystemException>()));
      final reloaded = SharedFolders(private);
      await reloaded.load();
      expect(reloaded.roots(), isEmpty);
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('paths, symbolic links and application-private descendants cannot escape grants', () async {
    final root = await Directory.systemTemp.createTemp('nearbridge-boundary-');
    try {
      final private = await Directory('${root.path}/private').create();
      await File('${private.path}/identity.json').writeAsString('secret');
      final folders = SharedFolders(private);
      await expectLater(folders.add(private.path), throwsA(isA<FileSystemException>()));
      await folders.add(root.path);
      final id = folders.roots().single.id;
      expect((await folders.list(id, '')).entries.map((e) => e.name), isNot(contains('private')));
      await expectLater(folders.open(id, 'private/identity.json'), throwsA(isA<FileSystemException>()));
      for (final path in ['../outside', '/etc/passwd', 'a/../../b', r'C:\Windows',
        r'a\..\b', 'a//b', './a', 'a\u0000b']) {
        await expectLater(folders.list(id, path), throwsFormatException);
        await expectLater(folders.open(id, path), throwsFormatException);
      }
      if (!Platform.isWindows) {
        await Link('${root.path}/shortcut').create(private.path);
        expect((await folders.list(id, '')).entries.map((e) => e.name), isNot(contains('shortcut')));
        await expectLater(folders.open(id, 'shortcut/identity.json'), throwsA(isA<FileSystemException>()));
        await expectLater(folders.add('${root.path}/shortcut'), throwsA(isA<FileSystemException>()));
        final selected = await Directory('${root.path}/selected').create();
        await folders.add(selected.path);
        final selectedId = folders.roots().last.id;
        await selected.delete();
        await Link(selected.path).create(private.path);
        await expectLater(folders.list(selectedId, ''), throwsA(isA<FileSystemException>()));
      }
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('large directories are paged without silently omitting children', () async {
    final root = await Directory.systemTemp.createTemp('nearbridge-pages-');
    try {
      final private = await Directory('${root.path}/private').create();
      final shared = await Directory('${root.path}/shared').create();
      for (var index = 0; index < 205; index++) {
        await File('${shared.path}/file-$index.txt').writeAsString('$index');
      }
      final folders = SharedFolders(private);
      await folders.add(shared.path);
      final id = folders.roots().single.id;
      final first = await folders.list(id, '');
      expect(first.entries.length, 200);
      expect(first.nextOffset, 200);
      final second = await folders.list(id, '', offset: first.nextOffset!);
      expect(second.entries.length, 5);
      expect(second.nextOffset, isNull);
      expect([...first.entries, ...second.entries].map((e) => e.relativePath).toSet().length, 205);
      await expectLater(folders.list(id, '', offset: -1), throwsFormatException);
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('folder wire entries reject invalid paths and remain compatible with individual files', () {
    final id = randomToken(16);
    final folder = SharedFile(id: id, folderId: id, relativePath: '',
      name: 'Documents', size: 0, isDirectory: true);
    expect(SharedFile.fromJson(folder.toJson()).isDirectory, isTrue);
    expect(() => SharedFile.fromJson({...folder.toJson(), 'relativePath': '../secret'}), throwsFormatException);
    expect(() => SharedFile.fromJson({...folder.toJson(), 'directory': false}), throwsFormatException);
    expect(SharedFile.fromJson({'id': id, 'name': 'legacy.txt', 'size': 5}).folderId, isNull);
    expect(() => SharedPage.fromJson({'files': [], 'nextOffset': -1}), throwsFormatException);
  });
}
