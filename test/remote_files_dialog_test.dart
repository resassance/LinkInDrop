import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearbridge/core/models.dart';
import 'package:nearbridge/ui/remote_files_dialog.dart';

void main() {
  testWidgets('folder navigation, back, pagination and file selection', (tester) async {
    final id = randomToken(16);
    final folder = SharedFile(id: id, folderId: id, relativePath: '', name: 'Documents',
      size: 0, isDirectory: true);
    final file = SharedFile(id: id, folderId: id, relativePath: 'hello.txt', name: 'hello.txt', size: 5);
    final calls = <String>[];
    SharedFile? chosen;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => TextButton(
      onPressed: () async {
        chosen = await showDialog<SharedFile>(context: context, builder: (_) => RemoteFilesDialog(
          deviceName: 'PC', canDownload: true, load: (directory, offset) async {
            calls.add('${directory?.name}:$offset');
            if (directory == null) return SharedPage([folder]);
            return offset == 0 ? const SharedPage([], nextOffset: 200) : SharedPage([file]);
          }));
      }, child: const Text('Open')))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Documents'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Назад'), findsOneWidget);
    await tester.tap(find.text('Показать ещё'));
    await tester.pumpAndSettle();
    expect(find.text('hello.txt'), findsOneWidget);
    await tester.tap(find.byTooltip('Назад'));
    await tester.pumpAndSettle();
    expect(find.text('Documents'), findsOneWidget);
    await tester.tap(find.text('Documents'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Показать ещё'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Скачать'));
    await tester.pumpAndSettle();
    expect(chosen?.relativePath, 'hello.txt');
    expect(calls, contains('Documents:200'));
  });
}
