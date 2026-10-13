import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearbridge/core/controller.dart';
import 'package:nearbridge/core/models.dart';
import 'package:nearbridge/ui/app.dart';

void main() {
  testWidgets('desktop and compact layouts show pairing and clipboard controls', (tester) async {
    final controller = BridgeController()..loading = false;
    await tester.binding.setSurfaceSize(const Size(1100, 1100));
    await tester.pumpWidget(NearbridgeApp(controller: controller, start: false));
    expect(find.text('nearbridge'), findsOneWidget);
    expect(find.text('Добавить'), findsOneWidget);
    expect(find.text('Общий буфер'), findsOneWidget);
    expect(find.text('Выбрать файлы'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('failed connections show readable messages and complete details', (tester) async {
    final controller = BridgeController()..loading = false;
    controller.record(Activity('Не получилось',
      'Нет соединения с 192.168.31.45:45831. Проверьте VPN и Windows Firewall.\n\nПодробности: SocketException: timeout', error: true));
    await tester.binding.setSurfaceSize(const Size(1100, 1600));
    await tester.pumpWidget(NearbridgeApp(controller: controller, start: false));
    await tester.scrollUntilVisible(find.text('Не получилось'), 300,
      scrollable: find.byType(Scrollable).first);
    expect(find.textContaining('Нет соединения с 192.168.31.45:45831'), findsOneWidget);
    await tester.tap(find.text('Не получилось'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Подробности: SocketException: timeout'), findsOneWidget);
    expect(find.text('Проверить сеть'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await tester.binding.setSurfaceSize(null);
  });
}
