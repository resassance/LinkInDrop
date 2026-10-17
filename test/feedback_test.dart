import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkindrop/core/android_folders.dart';
import 'package:linkindrop/core/controller.dart';
import 'package:linkindrop/core/models.dart';
import 'package:linkindrop/core/node.dart';
import 'package:linkindrop/core/photo_backup.dart';
import 'package:linkindrop/core/shared_folders.dart';
import 'package:linkindrop/core/shared_files.dart';
import 'package:linkindrop/core/transfer_queue.dart';
import 'package:linkindrop/ui/app.dart';

class _RealHttp extends HttpOverrides {}

class _Controller extends BridgeController {
  @override
  bool get isAndroid => true;
  @override
  Future<int?> receiveFreeSpace() async => null;
}

class _SlowFolders extends FolderProvider {
  final entered = Completer<void>();
  final listed = Completer<SharedPage>();
  @override
  Future<void> validate(String location) async {}
  @override
  Future<void> revoke(String location) async {}
  @override
  Future<SharedRead> open(String location, String path, {int offset = 0, int? length}) async =>
    SharedRead(5, Stream.value([1, 2, 3, 4, 5]), () async {});
  @override
  Future<SharedPage> list(String location, String id, String path, int offset) {
    entered.complete();
    return listed.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('disabling photos interrupts active backups, preserves manual pauses and normal transfers', () async {
    final root = await Directory.systemTemp.createTemp('linkindrop-backup-toggle-');
    final blocked = Completer<void>();
    final started = Completer<void>();
    final normalDone = Completer<void>();
    var interrupted = 0;
    final executed = <String>[];
    final queue = TransferQueue(directory: root, execute: (job, progress) async {
      executed.add(job.id);
      if (job.id == 'active' && !started.isCompleted) { started.complete(); await blocked.future; }
      if (job.id == 'normal') normalDone.complete();
    }, interrupt: () { interrupted++; if (!blocked.isCompleted) blocked.completeError(StateError('paused')); },
      completed: (_) async {}, discard: (_) async {});
    final active = TransferJob(id: 'active', peerId: 'peer', kind: 'backup', name: 'one.jpg');
    final pending = TransferJob(id: 'pending', peerId: 'peer', kind: 'backup', name: 'two.jpg');
    final manual = TransferJob(id: 'manual', peerId: 'peer', kind: 'backup', name: 'three.jpg', state: 'paused');
    try {
      queue.jobs.addAll([active, pending, manual, TransferJob(id: 'normal', peerId: 'peer', kind: 'upload', name: 'note.txt')]);
      queue.start();
      await started.future;
      await queue.setBackupEnabled(false);
      await normalDone.future;
      expect(interrupted, 1);
      expect(active.state, 'paused');
      expect(pending.state, 'paused');
      expect(TransferJob.fromJson(pending.toJson()).backupPaused, isTrue);
      expect(manual.backupPaused, isFalse);
      await queue.resume(pending);
      expect(pending.state, 'paused');
      final completed = Completer<void>();
      queue.addListener(() { if (pending.state == 'completed' && !completed.isCompleted) completed.complete(); });
      await queue.setBackupEnabled(true);
      await completed.future;
      expect(manual.state, 'paused');
      expect(executed.where((id) => id == 'active').length, 2);
      expect(executed, contains('normal'));
    } finally { await queue.close(); await root.delete(recursive: true); }
  });

  test('disabling backup during an awaited directory listing cannot enqueue photos', () async {
    final root = await Directory.systemTemp.createTemp('linkindrop-scan-toggle-');
    final provider = _SlowFolders();
    final sources = SharedFolders(root, documents: provider);
    final queued = <TransferJob>[];
    final backup = PhotoBackup(directory: root, sources: sources, enqueue: (jobs) async { queued.addAll(jobs); },
      available: (_) => true, changed: () {});
    try {
      await sources.add('content://photos/tree/camera');
      backup.peerId = 'peer';
      await backup.setEnabled(true);
      final scan = backup.scan();
      await provider.entered.future;
      await backup.setEnabled(false);
      final id = sources.roots().single.id;
      provider.listed.complete(SharedPage([SharedFile(id: id, folderId: id, relativePath: 'one.jpg', name: 'one.jpg', size: 5)]));
      await scan;
      expect(queued, isEmpty);
      expect(backup.scanning, isFalse);
      final controller = BridgeController()..directory = root..backup = backup;
      backup.peerId = null;
      backup.enabled = true;
      await controller.setPhotoBackup(false);
      expect(backup.enabled, isFalse);
      controller.dispose();
    } finally { await backup.close(); await root.delete(recursive: true); }
  });

  test('desktop browses Android document trees and persistent individual document grants over TLS', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
    final root = await Directory.systemTemp.createTemp('linkindrop-android-browse-');
    const channel = MethodChannel('linkindrop/system');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var reads = 0;
    var revoked = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'checkFolder': return null;
        case 'listFolder': return {'files': [{'name': 'phone.txt', 'relativePath': 'phone.txt', 'directory': false, 'size': 5, 'version': '1:5'}]};
        case 'statSharedDocument': if (revoked) throw PlatformException(code: 'folder', message: 'Permission revoked'); return {'name': 'single.txt', 'size': 5, 'version': '1:5'};
        case 'openFolderFile':
        case 'openSharedDocument': reads = 0; return {'reader': 'reader', 'size': 5, 'version': '1:5'};
        case 'readFolderFile': return reads++ == 0 ? Uint8List.fromList([104, 101, 108, 108, 111]) : null;
        case 'closeFolderFile': return null;
        case 'revokeFolder': revoked = true; return null;
        default: throw StateError('Unexpected ${call.method}');
      }
    });
    BridgeNode make(String name, {FolderProvider? provider}) => BridgeNode(directory: Directory('${root.path}/$name'), name: name,
      folderProvider: provider, preferredPort: 0, discoveryEnabled: false, onPairRequest: (_) async => true,
      onClipboard: (_) async {}, onActivity: (_) {}, onChanged: () {});
    final phone = make('phone', provider: const AndroidFolders());
    final desktop = make('desktop');
    try {
      await phone.start(); await desktop.start();
      await desktop.pair(phone.invite('127.0.0.1'));
      final peer = desktop.peers[phone.identity.id]!;
      await phone.sharedFolders.add('content://test/tree/photos', name: 'Phone');
      await phone.sharedFiles.add('content://test/document/single');
      phone.fileSharingEnabled = true;
      final entries = (await desktop.browseFiles(peer)).entries;
      final folder = entries.singleWhere((entry) => entry.isDirectory);
      final child = (await desktop.browseFiles(peer, folder: folder)).entries.single;
      expect(child.relativePath, 'phone.txt');
      await desktop.downloadFile(peer, child);
      final single = entries.singleWhere((entry) => !entry.isDirectory);
      await desktop.downloadFile(peer, single);
      expect(await (await phone.sharedFiles.open(single.id)).stream.expand((chunk) => chunk).toList(), [104, 101, 108, 108, 111]);
      final restored = BridgeNode(directory: phone.directory, name: 'phone', folderProvider: const AndroidFolders(), preferredPort: 0,
        discoveryEnabled: false, onPairRequest: (_) async => true, onClipboard: (_) async {}, onActivity: (_) {}, onChanged: () {});
      await restored.start();
      expect((await restored.sharedFiles.list()).single.name, 'single.txt');
      await restored.sharedFiles.remove(single.id);
      await restored.stop();
      await phone.sharedFiles.remove(single.id);
      expect(revoked, isTrue);
      expect(await phone.sharedFiles.list(), isEmpty);
    } finally { await phone.stop(); await desktop.stop(); messenger.setMockMethodCallHandler(channel, null); await root.delete(recursive: true); }
    }, _RealHttp());
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('scroll extent stays stable and compact layouts fit populated controls', (tester) async {
    final controller = _Controller()..loading = false..languagePreference = 'ru';
    final node = BridgeNode(directory: Directory('/tmp/unused'), name: 'Test', onPairRequest: (_) async => false,
      onClipboard: (_) async {}, onActivity: (_) {}, onChanged: () {});
    node.sharedFiles = SharedFiles(node.directory);
    node.sharedFolders = SharedFolders(node.directory);
    controller.node = node;
    node.peers['peer'] = Peer(id: 'peer', name: 'Очень длинное имя телефона и компьютера', host: '127.0.0.1', port: 1,
      fingerprint: '', incomingToken: '', outgoingToken: '')..online = true;
    expect(controller.selectedPeer?.id, 'peer');
    controller.selectedPeerId = 'deleted-device';
    expect(controller.selectedPeer?.id, 'peer');
    controller.queue = TransferQueue(directory: Directory('/tmp/unused'), execute: (_, __) async {}, interrupt: () {}, completed: (_) async {}, discard: (_) async {});
    controller.queue!.jobs.addAll(List.generate(3, (index) => TransferJob(id: '$index', peerId: 'peer', kind: 'upload',
      name: 'Очень длинное имя файла номер $index.jpg', state: index == 0 ? 'running' : 'waiting', totalBytes: 1000000)));
    controller.backup = PhotoBackup(directory: Directory('/tmp/unused'), sources: SharedFolders(Directory('/tmp/unused')),
      enqueue: (_) async {}, available: (_) => false, changed: () {});
    for (final width in [320.0, 390.0, 800.0, 1100.0]) {
      await tester.binding.setSurfaceSize(Size(width, 844));
      await tester.pumpWidget(LinkInDropApp(key: ValueKey(width), controller: controller, start: false));
      await tester.pumpAndSettle();
      final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first).position;
      final extent = scroll.maxScrollExtent;
      scroll.jumpTo(extent * 0.65);
      await tester.pumpAndSettle();
      expect(scroll.maxScrollExtent, closeTo(extent, 0.1));
      final offset = scroll.pixels;
      controller.busy = true; controller.changed();
      await tester.pump();
      expect(scroll.pixels, closeTo(offset, 0.1));
      expect(scroll.maxScrollExtent, closeTo(extent, 0.1));
      expect(tester.widget<ButtonStyleButton>(find.ancestor(of: find.text('Файлы устройства'), matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton))).onPressed, isNotNull);
      controller.busy = false; controller.changed();
      await tester.pump();
      if (width < 700) {
        await tester.tap(find.byType(NavigationDestination).at(3));
      } else {
        await tester.tap(find.byKey(const ValueKey('nav-3')));
      }
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Фоновая работа и фотобэкап'));
      await tester.tap(find.text('Фоновая работа и фотобэкап'));
      await tester.pumpAndSettle();
      controller.backup!.enabled = true; controller.changed();
      await tester.pump();
      final toggle = tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, 'Автоматически копировать новые фото'));
      expect(toggle.onChanged, isNotNull);
      controller.backup!.enabled = false;
      await tester.ensureVisible(find.text('Фоновая работа и фотобэкап'));
      await tester.tap(find.text('Фоновая работа и фотобэкап'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'width $width');
      controller.busy = false;
      if (width == 320) {
        await tester.tap(find.byType(NavigationDestination).at(2));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Мои файлы и папки'));
        await tester.tap(find.text('Мои файлы и папки'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Выбрать файлы и папки'));
        await tester.tap(find.text('Выбрать файлы и папки'));
        await tester.pumpAndSettle();
        expect(find.text('Включить доступ'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Закрыть'));
        await tester.pumpAndSettle();
      }
    }
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await tester.binding.setSurfaceSize(null);
  });
}
