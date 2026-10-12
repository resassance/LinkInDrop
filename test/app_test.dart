import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearbridge/core/controller.dart';
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
}
