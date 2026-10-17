import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearbridge/core/controller.dart';
import 'package:nearbridge/core/models.dart';
import 'package:nearbridge/core/node.dart';
import 'package:nearbridge/l10n/messages.dart';
import 'package:nearbridge/ui/app.dart';

class _MobileController extends BridgeController {
  @override
  bool get isAndroid => true;
}

class _SendController extends BridgeController {
  final sent = <String>[];
  @override
  Future<void> enqueuePaths(Peer peer, List<String> paths, {Map<String, String>? names}) async { sent.addAll(paths); }
}

void main() {
  test('plural forms, sizes and user content are localized without modifying arguments', () {
    const ru = AppStrings('ru'), en = AppStrings('en');
    expect([1, 2, 5, 11, 21, 22].map(ru.files), [
      'Передать 1 файл', 'Передать 2 файла', 'Передать 5 файлов', 'Передать 11 файлов', 'Передать 21 файл', 'Передать 22 файла']);
    expect(en.files(1), 'Transfer 1 file');
    expect(en.files(2), 'Transfer 2 files');
    expect(ru.size(1536), '1,5 КБ');
    expect(en.size(1536), '1.5 KB');
    expect(en.text('Адрес: {0}', ['Телефон {1}']), 'Address: Телефон {1}');
  });

  testWidgets('theme and language changes persist and do not discard the selected files', (tester) async {
    final root = await Directory.systemTemp.createTemp('linkindrop-settings-');
    final controller = BridgeController()..loading = false..directory = root..languagePreference = 'en';
    final file = await File('${root.path}/Заметки.txt').writeAsString('hello');
    await controller.stageFiles([file.path]);
    await tester.binding.setSurfaceSize(const Size(1440, 1024));
    await tester.pumpWidget(NearbridgeApp(controller: controller, start: false));
    await tester.tap(find.byKey(const ValueKey('theme-dark')));
    await tester.pumpAndSettle();
    expect(Theme.of(tester.element(find.byType(Scaffold).first)).brightness, Brightness.dark);
    await controller.setAppearance(language: 'ru');
    await tester.pumpAndSettle();
    expect(find.text('К отправке'), findsOneWidget);
    expect(find.text('Заметки.txt'), findsOneWidget);
    final saved = jsonDecode(await File('${root.path}/settings.json').readAsString()) as Map;
    expect(saved['theme'], 'dark');
    expect(saved['language'], 'ru');
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await root.delete(recursive: true);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('selection requires the explicit transfer action', (tester) async {
    final root = await Directory.systemTemp.createTemp('linkindrop-confirm-');
    final controller = _SendController()..loading = false..languagePreference = 'en';
    final file = await File('${root.path}/notes.txt').writeAsString('hello');
    controller.node = BridgeNode(directory: root, name: 'test', onPairRequest: (_) async => false,
      onClipboard: (_) async {}, onActivity: (_) {}, onChanged: () {});
    controller.node!.peers['phone'] = Peer(id: 'phone', name: 'Телефон', host: '127.0.0.1', port: 1,
      fingerprint: '', incomingToken: '', outgoingToken: '')..online = true;
    await controller.stageFiles([file.path]);
    expect(controller.sent, isEmpty);
    await tester.binding.setSurfaceSize(const Size(1100, 900));
    await tester.pumpWidget(NearbridgeApp(controller: controller, start: false));
    expect(find.text('notes.txt'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('send-selection')));
    await tester.pumpAndSettle();
    expect(controller.sent, [file.path]);
    expect(controller.selection.items, isEmpty);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await root.delete(recursive: true);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('mobile header actions share a row in both languages and themes', (tester) async {
    final controller = _MobileController()..loading = false;
    for (final language in ['ru', 'en']) {
      for (final theme in ['light', 'dark']) {
        for (final width in [320.0, 390.0]) {
          controller.languagePreference = language;
          controller.themePreference = theme;
          await tester.binding.setSurfaceSize(Size(width, 844));
          await tester.pumpWidget(NearbridgeApp(controller: controller, start: false));
          await tester.pumpAndSettle();
          final title = find.text(language == 'ru' ? 'Передача' : 'Transfer').first;
          final shortcut = find.byKey(const ValueKey('received-shortcut'));
          expect((tester.getCenter(title).dy - tester.getCenter(shortcut).dy).abs(), lessThan(2));
          expect(find.byType(NavigationBar), findsOneWidget);
          expect(tester.takeException(), isNull, reason: '$width $language $theme');
        }
      }
    }
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('system locale selects Russian or falls back to English', (tester) async {
    final controller = BridgeController()..loading = false;
    for (final entry in {'ru': 'К отправке', 'en': 'Ready to send', 'fr': 'Ready to send'}.entries) {
      tester.binding.platformDispatcher.localesTestValue = [Locale(entry.key)];
      await tester.pumpWidget(NearbridgeApp(controller: controller, start: false));
      await tester.pumpAndSettle();
      expect(find.text(entry.key == 'ru' ? 'Выбрать файлы' : 'Choose files'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    tester.binding.platformDispatcher.clearLocalesTestValue();
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
