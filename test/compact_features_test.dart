import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearbridge/core/controller.dart';
import 'package:nearbridge/core/node.dart';
import 'package:nearbridge/core/receive_storage.dart';
import 'package:nearbridge/core/received_categories.dart';
import 'package:nearbridge/ui/app.dart';

class _AndroidController extends BridgeController {
  @override
  bool get isAndroid => true;
}

class _FolderController extends BridgeController {
  int opened = 0;
  @override
  Future<void> openReceivedFolder() async { opened++; }
  @override
  Future<int?> receiveFreeSpace() async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('received categories handle case, unknown extensions and preserve folder trees', () {
    for (final pair in {'PIC.HEIC': 'Фото', 'clip.mp4': 'Видео', 'song.FLAC': 'Музыка', 'notes.pdf': 'Документы',
      'backup.tar.gz': 'Архивы', 'app.apk': 'Приложения', 'blob': 'Другое', 'unknown.zzz': 'Другое'}.entries) {
      expect(organizedReceivedPath(pair.key, enabled: true), '${pair.value}/${pair.key}');
      expect(organizedReceivedPath(pair.key, enabled: false), pair.key);
    }
    for (final path in ['Holiday/one.jpg', 'Photos/2026/10/one.jpg', 'RestoredPhotos/one.jpg']) {
      expect(organizedReceivedPath(path, enabled: true), path);
    }
  });

  test('organized receive storage keeps receipts idempotent and conflict policies working', () async {
    final root = await Directory.systemTemp.createTemp('nearbridge-organize-');
    try {
      final private = await Directory('${root.path}/private').create();
      final inbox = await Directory('${private.path}/inbox').create();
      final destination = await Directory('${root.path}/received').create();
      final storage = ReceiveStorage(private, inbox)..sortByType = true..destination = destination.path;
      final digest = sha256.convert(utf8.encode('photo')).toString();
      Future<File> source(String id) => File('${inbox.path}/$id').writeAsString('photo');
      final first = await storage.deliver('peer', 'one', await source('one'), 'one.jpg', digest);
      expect(first['relative'], 'Фото/one.jpg');
      expect(await File('${destination.path}/Фото/one.jpg').readAsString(), 'photo');
      expect(await storage.verify('peer', storage.key('peer', 'one'), digest), isTrue);
      final second = await storage.deliver('peer', 'two', await source('two'), 'one.jpg', digest);
      expect(second['location'], '${destination.path}/Фото/one (1).jpg');
      storage.conflict = 'skip';
      expect((await storage.deliver('peer', 'three', await source('three'), 'one.jpg', digest))['skipped'], isTrue);
      final nested = await storage.deliver('peer', 'folder', await source('folder'), 'Holiday/one.jpg', digest);
      expect(nested['relative'], 'Holiday/one.jpg');
      storage.sortByType = false;
      expect((await storage.deliver('peer', 'one', File('missing-source'), 'one.jpg', digest))['location'], first['location']);
      final plain = await storage.deliver('peer', 'plain', await source('plain'), 'two.jpg', digest);
      expect(plain['location'], '${destination.path}/two.jpg');
      final loaded = ReceiveStorage(private, inbox);
      await loaded.load();
      expect(await loaded.verify('peer', storage.key('peer', 'one'), digest), isTrue);
    } finally { await root.delete(recursive: true); }
  });

  test('Android folder opener and explicit direct Wi-Fi preference use the platform bridge', () async {
    final root = await Directory.systemTemp.createTemp('nearbridge-android-network-');
    const channel = MethodChannel('nearbridge/system');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'setDirectWifi') return {'direct': true, 'wifi': true, 'vpn': true, 'addresses': ['192.168.1.10']};
      return null;
    });
    final controller = _AndroidController()..directory = root;
    controller.node = BridgeNode(directory: root, name: 'test', onPairRequest: (_) async => false, onClipboard: (_) async {}, onActivity: (_) {}, onChanged: () {});
    try {
      expect(controller.androidDirectWifi, isFalse);
      controller.node = null;
      await controller.setDirectWifi(true);
      expect(controller.localNetwork['direct'], isTrue);
      final settings = jsonDecode(await File('${root.path}/settings.json').readAsString()) as Map;
      expect(settings['androidDirectWifi'], isTrue);
      controller.node = BridgeNode(directory: root, name: 'test', onPairRequest: (_) async => false, onClipboard: (_) async {}, onActivity: (_) {}, onChanged: () {});
      await controller.openReceivedFolder();
      expect(calls.last.method, 'openReceivedFolder');
      expect((calls.last.arguments as Map)['tree'], isNull);
      controller.receiveDestination = 'content://test/tree/received';
      await controller.openReceivedFolder();
      expect((calls.last.arguments as Map)['tree'], controller.receiveDestination);
    } finally { controller.dispose(); messenger.setMockMethodCallHandler(channel, null); await root.delete(recursive: true); }
  });

  testWidgets('compact desktop has a marked drop zone and a working received-folder shortcut', (tester) async {
    final controller = _FolderController()..loading = false..languagePreference = 'ru';
    controller.node = BridgeNode(directory: Directory('/tmp/unused'), name: 'test', onPairRequest: (_) async => false,
      onClipboard: (_) async {}, onActivity: (_) {}, onChanged: () {});
    await tester.binding.setSurfaceSize(const Size(1100, 900));
    await tester.pumpWidget(NearbridgeApp(controller: controller, start: false));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('file-drop-zone')), findsOneWidget);
    expect(find.text('Перетащите сюда файлы или папки'), findsOneWidget);
    expect(find.text('Ваши устройства.\nОдин буфер.'), findsNothing);
    expect(find.text('Автоматически копировать новые фото'), findsNothing);
    await tester.tap(find.text('Полученные файлы'));
    await tester.pumpAndSettle();
    expect(controller.opened, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await tester.binding.setSurfaceSize(null);
  });
}
