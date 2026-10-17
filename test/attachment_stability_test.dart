import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkindrop/core/controller.dart';
import 'package:linkindrop/core/media_library.dart';
import 'package:linkindrop/ui/attachment_sheet.dart';

class _Library extends MediaLibrary {
  _Library({this.permission = 'full'});
  final String permission;
  final importing = Completer<List<String>>();
  int pages = 0;
  Completer<void>? nextPage;
  @override
  Future<String> access({bool request = false}) async => permission;
  @override
  Future<List<Map<String, String>>> albums() async => [{'id': 'camera', 'name': 'Camera'}];
  @override
  Future<List<LibraryItem>> page({String? album, int offset = 0}) async {
    pages++;
    final pending = nextPage;
    nextPage = null;
    if (pending != null) await pending.future;
    return [for (var i = offset; i < offset + 60; i++) LibraryItem(uri: 'content://$album/$i', name: 'photo-$i.jpg', size: 100)];
  }
  @override
  Future<List<String>> importItems(List<String> uris) => importing.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('linkindrop/system');
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async => null);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  Future<void> open(WidgetTester tester, BridgeController c, _Library library) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpWidget(MaterialApp(locale: const Locale('ru'), supportedLocales: const [Locale('ru')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: Scaffold(body: AttachmentSheet(controller: c, library: library, pickFiles: () async {}, pickFolder: () async {}))));
    await tester.pumpAndSettle();
  }

  testWidgets('selecting a photo preserves the mounted gallery and scroll position', (tester) async {
    final c = BridgeController()..loading = false;
    final library = _Library();
    await open(tester, c, library);
    final scroll = tester.state<ScrollableState>(find.descendant(of: find.byType(CustomScrollView), matching: find.byType(Scrollable)));
    scroll.position.jumpTo(900);
    await tester.pumpAndSettle();
    final position = scroll.position.pixels;
    final tile = find.bySemanticsLabel('photo-24.jpg');
    await tester.ensureVisible(tile);
    final before = scroll.position.pixels;
    await tester.tap(tile);
    await tester.pump();
    expect(scroll.mounted, isTrue);
    expect(scroll.position.pixels, before);
    expect(position, greaterThan(0));
    library.importing.complete([File('test/fixtures/coast.jpg').absolute.path]);
    await tester.runAsync(() async { await Future<void>.delayed(const Duration(milliseconds: 100)); });
    await tester.pumpAndSettle();
    expect(scroll.mounted, isTrue);
    expect(scroll.position.pixels, before);
    expect(c.selection.items, hasLength(1));
    expect(find.text('Далее · 1'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('returning focus keeps the current album and loaded gallery', (tester) async {
    final c = BridgeController()..loading = false;
    final library = _Library();
    await open(tester, c, library);
    await tester.tap(find.byTooltip('Альбом'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Camera'));
    await tester.pumpAndSettle();
    expect(find.text('Camera'), findsOneWidget);
    final pages = library.pages;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('Camera'), findsOneWidget);
    expect(library.pages, pages);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('returning from Android settings refreshes limited grants without losing the album or scroll', (tester) async {
    final c = BridgeController()..loading = false;
    final library = _Library(permission: 'limited');
    await open(tester, c, library);
    await tester.tap(find.byTooltip('Альбом'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Camera'));
    await tester.pumpAndSettle();
    final scroll = tester.state<ScrollableState>(find.descendant(of: find.byType(CustomScrollView), matching: find.byType(Scrollable)));
    scroll.position.jumpTo(900);
    await tester.pumpAndSettle();
    final before = scroll.position.pixels;
    final pages = library.pages;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(library.pages, greaterThan(pages));
    expect(scroll.mounted, isTrue);
    expect(scroll.position.pixels, before);
    scroll.position.jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.text('Camera'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('returning during pagination refreshes media after the pending page finishes', (tester) async {
    final c = BridgeController()..loading = false;
    final library = _Library(permission: 'limited');
    await open(tester, c, library);
    final pending = Completer<void>();
    library.nextPage = pending;
    final scroll = tester.state<ScrollableState>(find.descendant(of: find.byType(CustomScrollView), matching: find.byType(Scrollable)));
    scroll.position.jumpTo(scroll.position.maxScrollExtent);
    await tester.pump();
    final pages = library.pages;
    expect(library.nextPage, isNull);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    pending.complete();
    await tester.pumpAndSettle();
    expect(library.pages, greaterThan(pages));
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    await tester.binding.setSurfaceSize(null);
  });
}
