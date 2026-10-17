import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearbridge/core/app_directory.dart';
import 'package:nearbridge/core/controller.dart';
import 'package:nearbridge/core/send_selection.dart';

void main() {
  test('selection deduplicates and preserves files on queue failure', () async {
    final root = await Directory.systemTemp.createTemp('linkindrop-selection-');
    final selection = SendSelection();
    try {
      final file = await File('${root.path}/notes.txt').writeAsString('hello');
      await selection.add([file.path, file.path], names: {file.path: 'Заметки.txt'});
      expect(selection.items.single.name, 'Заметки.txt');
      expect(selection.totalBytes, 5);
      await expectLater(selection.send((items) async => throw StateError('queue unavailable')), throwsStateError);
      expect(selection.items.length, 1);
      expect(selection.sending, isFalse);
      final barrier = Completer<void>();
      final pending = selection.send((items) => barrier.future);
      selection.remove(selection.items.single);
      expect(selection.items.length, 1);
      await selection.send((items) async => fail('Must not enqueue twice'));
      barrier.complete();
      await pending;
      expect(selection.items, isEmpty);
    } finally { selection.dispose(); await root.delete(recursive: true); }
  });

  test('failed additions leave the existing selection intact', () async {
    final root = await Directory.systemTemp.createTemp('linkindrop-selection-');
    final selection = SendSelection();
    try {
      final first = await File('${root.path}/one.txt').writeAsString('one');
      final second = await File('${root.path}/two.txt').writeAsString('two');
      await selection.add([first.path]);
      await expectLater(selection.add([second.path, '${root.path}/missing']), throwsA(isA<FileSystemException>()));
      expect(selection.items.single.path, first.path);
      expect(selection.loading, isFalse);
      await selection.add([root.path]);
      expect(selection.hasDirectories, isTrue);
    } finally { selection.dispose(); await root.delete(recursive: true); }
  });

  test('concurrent additions are retained while an earlier batch is being queued', () async {
    final root = await Directory.systemTemp.createTemp('linkindrop-concurrent-');
    final selection = SendSelection();
    try {
      final first = await File('${root.path}/one.txt').writeAsString('one');
      final second = await File('${root.path}/two.txt').writeAsString('two');
      final third = await File('${root.path}/three.txt').writeAsString('three');
      await selection.add([first.path]);
      final barrier = Completer<void>();
      final sending = selection.send((items) => barrier.future);
      await Future.wait([selection.add([second.path]), selection.add([third.path])]);
      barrier.complete();
      await sending;
      expect(selection.items.map((item) => item.path), [second.path, third.path]);
    } finally { selection.dispose(); await root.delete(recursive: true); }
  });

  test('removing a preview deletes only app-owned share copies', () async {
    final root = await Directory.systemTemp.createTemp('linkindrop-staged-cleanup-');
    final controller = BridgeController()..directory = root;
    try {
      final shared = await Directory('${root.path}/shared/batch').create(recursive: true);
      final owned = await File('${shared.path}/photo.jpg').writeAsString('copy');
      final original = await File('${root.path}/original.jpg').writeAsString('original');
      controller.pendingFiles.add(owned.path);
      await controller.stageFiles([owned.path, original.path]);
      await controller.removeSelected(controller.selection.items.first);
      expect(await owned.exists(), isFalse);
      expect(controller.pendingFiles, isEmpty);
      await controller.removeSelected(controller.selection.items.single);
      expect(await original.readAsString(), 'original');
    } finally { controller.dispose(); await root.delete(recursive: true); }
  });

  test('rebrand reuses legacy identity without copying or replacing it', () async {
    final root = await Directory.systemTemp.createTemp('linkindrop-profile-');
    try {
      final legacy = await Directory('${root.path}/nearbridge').create();
      await File('${legacy.path}/identity.json').writeAsString('old-identity');
      final proposed = Directory('${root.path}/LinkInDrop');
      expect((await resolveAppDirectory(proposed)).path, legacy.path);
      await proposed.create();
      await File('${proposed.path}/identity.json').writeAsString('existing-new-identity');
      expect((await resolveAppDirectory(proposed)).path, proposed.path);
      expect(await File('${legacy.path}/identity.json').readAsString(), 'old-identity');
    } finally { await root.delete(recursive: true); }
  });
}
