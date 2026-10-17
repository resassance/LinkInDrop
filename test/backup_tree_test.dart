import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkindrop/core/photo_backup.dart';
import 'package:linkindrop/core/shared_folders.dart';
import 'package:linkindrop/core/transfer_queue.dart';

void main() {
  test('same-named backup roots stay separate and retain their destination names after restart', () async {
    final root = await Directory.systemTemp.createTemp('linkindrop-backup-roots-');
    final private = await Directory('${root.path}/private').create();
    final queued = <TransferJob>[];
    PhotoBackup create() => PhotoBackup(directory: private, sources: SharedFolders(private, stateFilename: 'backup-folders.json'),
      enqueue: (batch) async => queued.addAll(batch), available: (_) => true, changed: () {});
    var backup = create();
    try {
      await backup.load([]);
      for (final disk in ['internal', 'sd-card']) {
        final file = File('${root.path}/$disk/DCIM/Camera/photo.jpg');
        await file.parent.create(recursive: true);
        await file.writeAsString('same-photo');
        await backup.sources.add(file.parent.parent.path);
      }
      backup.peerId = 'peer';
      await backup.setEnabled(true);
      await backup.scan();
      expect(queued.map((job) => job.relative), unorderedEquals(['DCIM/Camera/photo.jpg', 'DCIM (2)/Camera/photo.jpg']));
      for (final job in queued) {
        job.state = 'completed';
        await backup.completed(job);
      }
      await backup.sources.remove(backup.sources.roots().first.id);
      await backup.close();
      backup = create();
      await backup.load(queued);
      await File('${root.path}/sd-card/DCIM/Camera/new.jpg').writeAsString('new-photo');
      await backup.scan();
      expect(queued.last.relative, 'DCIM (2)/Camera/new.jpg');
      final other = File('${root.path}/replacement/DCIM/Camera/photo.jpg');
      await other.parent.create(recursive: true);
      await other.writeAsString('same-photo');
      await backup.sources.add(other.parent.parent.path);
      await backup.scan();
      expect(queued.last.relative, 'DCIM (3)/Camera/photo.jpg');
    } finally {
      await backup.close();
      await root.delete(recursive: true);
    }
  });

  test('photo backup keeps selected root, nested folders, names and duplicate paths across restarts', () async {
    final root = await Directory.systemTemp.createTemp('linkindrop-backup-tree-');
    final private = await Directory('${root.path}/private').create();
    final photos = await Directory('${root.path}/DCIM').create();
    final queued = <TransferJob>[];
    PhotoBackup create() => PhotoBackup(directory: private, sources: SharedFolders(private, stateFilename: 'backup-folders.json'),
      enqueue: (batch) async => queued.addAll(batch), available: (_) => true, changed: () {});
    var backup = create();
    try {
      for (final path in ['Camera/photo.jpg', 'Screenshots/photo.jpg', 'Camera/Trip/nested.png']) {
        final file = File('${photos.path}/$path');
        await file.parent.create(recursive: true);
        await file.writeAsString(path.endsWith('photo.jpg') ? 'same-photo' : 'another-photo');
      }
      await backup.load([]);
      await backup.sources.add(photos.path);
      backup.peerId = 'peer';
      await backup.setEnabled(true);
      await backup.scan();
      expect(queued.map((job) => job.relative), unorderedEquals(['DCIM/Camera/photo.jpg', 'DCIM/Screenshots/photo.jpg', 'DCIM/Camera/Trip/nested.png']));
      for (final job in queued) {
        job.receipt = job.id;
        job.state = 'completed';
        await backup.completed(job);
      }
      await backup.close();
      backup = create();
      await backup.load(queued);
      await backup.scan();
      expect(queued, hasLength(3));
      final added = File('${photos.path}/Camera/new.jpg');
      await added.writeAsString('new-photo');
      await backup.scan();
      expect(queued.last.relative, 'DCIM/Camera/new.jpg');
      expect(await added.readAsString(), 'new-photo');
    } finally {
      await backup.close();
      await root.delete(recursive: true);
    }
  });
}
