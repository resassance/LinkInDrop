import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:linkindrop/core/controller.dart';
import 'package:linkindrop/core/media_library.dart';
import 'package:linkindrop/core/models.dart';
import 'package:linkindrop/core/node.dart';
import 'package:linkindrop/ui/app.dart';
import 'package:linkindrop/ui/attachment_sheet.dart';
import 'package:linkindrop/ui/app_theme.dart';
import 'package:linkindrop/ui/media_composer.dart';

class _MobileController extends BridgeController {
  int sent = 0;
  @override
  bool get isAndroid => true;
  @override
  Future<void> pushClipboard() async { sent++; record(Activity('Буфер отправлен', 'CRNEBRIS', kind: 'clipboard')); }
}

class _Library extends MediaLibrary {
  _Library(this.path, {this.permission = 'full'});
  final String path;
  final String permission;
  @override
  Future<String> access({bool request = false}) async => permission;
  @override
  Future<List<Map<String, String>>> albums() async => [];
  @override
  Future<List<LibraryItem>> page({String? album, int offset = 0}) async => offset == 0 ? [
    const LibraryItem(uri: 'content://test/1', name: 'lake.jpg', size: 100),
    const LibraryItem(uri: 'content://test/2', name: 'walk.mp4', size: 200, video: true, duration: 28000),
    for (var index = 3; index <= 18; index++) LibraryItem(uri: 'content://test/$index', name: 'photo-$index.jpg', size: 300),
  ] : [];
  @override
  Future<List<String>> importItems(List<String> uris) async => [path];
}

Future<void> capture(WidgetTester tester, GlobalKey key, String name) async {
  final directory = Platform.environment['LINKINDROP_CAPTURE_DIR'];
  if (directory == null) return;
  final shadows = debugDisableShadows;
  debugDisableShadows = false;
  try {
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
  }
  await tester.pumpAndSettle();
  await tester.runAsync(() async {
    final image = await (key.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage(pixelRatio: 1);
    final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    await Directory(directory).create(recursive: true);
    await File('$directory/$name.png').writeAsBytes(data.buffer.asUint8List());
    image.dispose();
  });
  } finally { debugDisableShadows = shadows; }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('linkindrop/system');
  late Uint8List photo;
  setUpAll(() async {
    final fonts = Platform.environment['LINKINDROP_TEST_FONTS'];
    if (fonts != null) {
      final loader = FontLoader('Roboto')..addFont(File('$fonts/Roboto-Regular.ttf').readAsBytes().then((bytes) => ByteData.sublistView(bytes)));
      await loader.load();
      final icons = FontLoader('MaterialIcons')..addFont(File('$fonts/MaterialIcons-Regular.otf').readAsBytes().then((bytes) => ByteData.sublistView(bytes)));
      await icons.load();
    }
  });
  setUp(() async {
    photo = await File('test/fixtures/coast.jpg').readAsBytes();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'mediaThumbnail') return photo;
      if (call.method == 'mediaAccess') return 'full';
      if (call.method == 'mediaAlbums') return <dynamic>[];
      if (call.method == 'mediaPage') return [for (var index = 0; index < 18; index++) {'uri': 'content://test/$index', 'name': index == 0 ? 'lake.jpg' : index == 1 ? 'walk.mp4' : 'photo-$index.jpg', 'size': 100, 'video': index == 1, 'duration': 28000}];
      if (call.method == 'importMedia') return [File('test/fixtures/coast.jpg').absolute.path];
      if (call.method == 'backgroundStatus') return <String, dynamic>{};
      return null;
    });
  });
  tearDown(() { TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null); });

  testWidgets('manual clipboard sends immediately while Text opens the editor', (tester) async {
    final c = _MobileController()..loading = false..languagePreference = 'ru'..themePreference = 'dark';
    c.node = BridgeNode(directory: Directory('/tmp/unused'), name: 'A34', onPairRequest: (_) async => false,
      onClipboard: (_) async {}, onActivity: (_) {}, onChanged: () {});
    c.node!.peers['pc'] = Peer(id: 'pc', name: 'CRNEBRIS', host: '127.0.0.1', port: 1, fingerprint: '', incomingToken: '', outgoingToken: '')..online = true;
    await tester.binding.setSurfaceSize(const Size(390, 844));
    final key = GlobalKey();
    c.record(Activity('Отправлено', 'На CRNEBRIS · 8,2 МБ', name: 'lake.jpg', thumbnailPath: File('test/fixtures/coast.jpg').absolute.path, kind: 'upload'));
    c.record(Activity('Не отправлено', 'На CRNEBRIS · 12,9 МБ', name: 'walk.mp4', thumbnailPath: File('test/fixtures/coast.jpg').absolute.path, kind: 'upload', error: true));
    await tester.pumpWidget(RepaintBoundary(key: key, child: LinkInDropApp(controller: c, start: false)));
    await tester.pumpAndSettle();
    await capture(tester, key, 'android-transfer');
    await tester.tap(find.byKey(const ValueKey('send-clipboard')));
    await tester.pumpAndSettle();
    expect(c.sent, 1);
    expect(find.byType(AlertDialog), findsNothing);
    await tester.tap(find.byKey(const ValueKey('compose-text')));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    await capture(tester, key, 'android-text');
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    c.themePreference = 'light';
    c.record(Activity('Файл получен', 'CRNEBRIS · 8,2 МБ', name: 'lake.jpg', path: File('test/fixtures/coast.jpg').absolute.path, kind: 'download'));
    await tester.pump();
    await tester.tap(find.byType(NavigationDestination).at(1));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('Полученные').first).dy, lessThan(145));
    await capture(tester, key, 'android-received');
    await tester.tap(find.byType(NavigationDestination).at(3));
    await tester.pumpAndSettle();
    expect(find.byType(ExpansionTile), findsNothing);
    expect(find.byKey(const ValueKey('send-clipboard')), findsNothing);
    await capture(tester, key, 'android-settings');
    c.record(Activity('Не получилось', 'Выберите другую папку', error: true));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(SnackBar, 'Выберите другую папку'), findsOneWidget);
    await tester.pumpWidget(const SizedBox()); c.dispose(); await tester.binding.setSurfaceSize(null);
  });

  testWidgets('attachment selection survives source changes and closing before confirmation', (tester) async {
    final c = _MobileController()..loading = false..languagePreference = 'ru'..themePreference = 'dark';
    c.node = BridgeNode(directory: Directory('/tmp/unused'), name: 'A34', onPairRequest: (_) async => false,
      onClipboard: (_) async {}, onActivity: (_) {}, onChanged: () {});
    c.node!.peers['pc'] = Peer(id: 'pc', name: 'CRNEBRIS', host: '127.0.0.1', port: 1, fingerprint: '', incomingToken: '', outgoingToken: '')..online = true;
    final key = GlobalKey();
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpWidget(RepaintBoundary(key: key, child: LinkInDropApp(controller: c, start: false)));
    await tester.tap(find.byKey(const ValueKey('attach'))); await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('lake.jpg'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('lake.jpg'));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(c.selection.items.length, 1);
    await capture(tester, key, 'android-gallery');
    c.themePreference = 'light'; c.changed(); await tester.pumpAndSettle();
    await tester.tap(find.text('Файлы')); await tester.pumpAndSettle();
    expect(find.descendant(of: find.byType(AttachmentSheet), matching: find.text('coast.jpg')), findsOneWidget);
    await capture(tester, key, 'android-attachment-files');
    await tester.tap(find.byTooltip('Закрыть')); await tester.pumpAndSettle();
    expect(c.selection.items.length, 1);
    await tester.tap(find.byKey(const ValueKey('attach'))); await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('attachments-next')), findsOneWidget);
    await tester.tap(find.byTooltip('Закрыть')); await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox()); c.dispose(); await tester.binding.setSurfaceSize(null);
  });

  testWidgets('permission denial keeps the system picker available', (tester) async {
    final c = BridgeController()..loading = false;
    await tester.pumpWidget(MaterialApp(locale: const Locale('ru'), supportedLocales: const [Locale('ru'), Locale('en')], localizationsDelegates: GlobalMaterialLocalizations.delegates, home: Scaffold(body: AttachmentSheet(controller: c,
      library: _Library('', permission: 'denied'), pickFiles: () async {}, pickFolder: () async {}))));
    await tester.pumpAndSettle();
    expect(find.text('Выбрать через системное окно'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); c.dispose();
  });

  testWidgets('desktop navigation and mobile large text remain usable', (tester) async {
    for (final width in [320.0, 1440.0]) {
      final c = BridgeController()..loading = false..languagePreference = 'ru';
      final key = GlobalKey();
      if (width > 700) {
        c.deviceName = 'CRNEBRIS';
        c.node = BridgeNode(directory: Directory('/tmp/unused'), name: 'CRNEBRIS', onPairRequest: (_) async => false, onClipboard: (_) async {}, onActivity: (_) {}, onChanged: () {});
        c.node!.peers['phone'] = Peer(id: 'phone', name: 'A34', host: '127.0.0.1', port: 1, fingerprint: '', incomingToken: '', outgoingToken: '')..online = true;
        await tester.runAsync(() => c.stageFiles([File('test/fixtures/coast.jpg').absolute.path]));
      }
      await tester.binding.setSurfaceSize(Size(width, 1024));
      await tester.pumpWidget(RepaintBoundary(key: key, child: MediaQuery(data: MediaQueryData(textScaler: TextScaler.linear(width == 320 ? 1.6 : 1)),
        child: LinkInDropApp(controller: c, start: false))));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      if (width > 700) {
        await capture(tester, key, 'desktop-transfer');
        await tester.tap(find.byKey(const ValueKey('theme-menu'))); await tester.pumpAndSettle();
        await capture(tester, key, 'desktop-theme-menu');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape); await tester.pumpAndSettle();
      }
      await tester.pumpWidget(const SizedBox()); c.dispose();
    }
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('media composer keeps the staged selection when closed', (tester) async {
    final c = BridgeController()..loading = false;
    await tester.runAsync(() => c.stageFiles([File('test/fixtures/coast.jpg').absolute.path]));
    await tester.binding.setSurfaceSize(const Size(390, 844));
    final key = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(key: key, child: MaterialApp(locale: const Locale('ru'), supportedLocales: const [Locale('ru'), Locale('en')], localizationsDelegates: GlobalMaterialLocalizations.delegates, theme: linkInDropTheme(Brightness.dark), home: Builder(builder: (context) => Scaffold(
      body: Center(child: FilledButton(onPressed: () => showModalBottomSheet<void>(context: context, isScrollControlled: true,
        builder: (_) => SizedBox(height: 720, child: MediaComposer(controller: c, addFiles: () async {}))), child: const Text('Open'))))))));
    await tester.tap(find.text('Open')); await tester.pumpAndSettle();
    await capture(tester, key, 'android-media-preview');
    await tester.tap(find.byTooltip('Закрыть')); await tester.pumpAndSettle();
    expect(c.selection.items.length, 1);
    await tester.pumpWidget(const SizedBox()); c.dispose(); await tester.binding.setSurfaceSize(null);
  });
}
