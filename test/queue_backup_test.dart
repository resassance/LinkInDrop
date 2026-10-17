import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linkindrop/core/models.dart';
import 'package:linkindrop/core/photo_backup.dart';
import 'package:linkindrop/core/shared_folders.dart';
import 'package:linkindrop/core/transfer_queue.dart';

void main() {
  test('queue pause is durable and can resume after application restart', () async {
    final root = await Directory.systemTemp.createTemp('linkindrop-queue-');
    final blocked = Completer<void>();
    final started = Completer<void>();
    var executions = 0;
    final first = TransferQueue(directory: root, execute: (job, progress) async {
      executions++; started.complete(); await blocked.future;
    }, interrupt: () { if (!blocked.isCompleted) blocked.completeError(StateError('paused')); },
      completed: (_) async {}, discard: (_) async {});
    TransferQueue? second;
    try {
      await first.load();
      final job = TransferJob(id: randomToken(16), peerId: 'peer', kind: 'upload', name: 'file.txt', source: '/file.txt');
      await first.addAll([job]);
      await started.future;
      await first.pause(job);
      await first.close();
      second = TransferQueue(directory: root, execute: (job, progress) async { executions++; progress(1); },
        interrupt: () {}, completed: (_) async {}, discard: (_) async {});
      await second.load();
      expect(second.jobs.single.state, 'paused');
      final done = Completer<void>();
      second.addListener(() { if (second!.jobs.single.state == 'completed' && !done.isCompleted) done.complete(); });
      await second.resume(second.jobs.single);
      await done.future;
      expect(executions, 2);
      expect(second.jobs.single.progress, 1);
    } finally { await second?.close(); await root.delete(recursive: true); }
  });

  test('photo backup deduplicates content and records only acknowledged copies', () async {
    final root = await Directory.systemTemp.createTemp('linkindrop-backup-');
    final queued = <TransferJob>[];
    final private = await Directory('${root.path}/private').create();
    final photos = await Directory('${root.path}/Camera').create();
    final sources = SharedFolders(private, stateFilename: 'backup-folders.json');
    final backup = PhotoBackup(directory: private, sources: sources,
      enqueue: (jobs) async => queued.addAll(jobs), available: (_) => true, changed: () {});
    try {
      await backup.load([]);
      await sources.add(photos.path);
      await File('${photos.path}/one.jpg').writeAsString('same-photo');
      await File('${photos.path}/copy.jpg').writeAsString('same-photo');
      await File('${photos.path}/two.png').writeAsString('other-photo');
      await File('${photos.path}/notes.txt').writeAsString('not-photo');
      backup.peerId = 'peer'; backup.enabled = true;
      await backup.scan();
      expect(queued.length, 2);
      expect(backup.copied, 0);
      await backup.completed(queued.first);
      expect(backup.copied, 1);
      await backup.scan();
      expect(queued.length, 2);
      expect(await File('${photos.path}/one.jpg').exists(), isTrue);
      expect(await File('${photos.path}/copy.jpg').exists(), isTrue);
      final unavailable = await Directory('${root.path}/Unavailable').create();
      await sources.add(unavailable.path);
      await unavailable.delete();
      await File('${photos.path}/late.jpg').writeAsString('new-photo');
      await backup.scan();
      expect(backup.lastError, isNotNull);
      expect(queued.length, 2);
      await unavailable.create();
      await backup.scan();
      expect(backup.lastError, isNull);
      expect(queued.length, 3);
    } finally { await backup.close(); await root.delete(recursive: true); }
  });
}
