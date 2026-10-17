import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import '../core/controller.dart';
import '../l10n/app_strings.dart';
import 'design_system.dart';

Future<void> chooseReceiveDestination(BuildContext context, BridgeController c) => c.run(() async {
  String? selected;
  final confirm = tr(context, 'Получать сюда');
  if (c.isAndroid) {
    final result = await c.platformChannel.invokeMapMethod<String, dynamic>('pickFolder', {'write': true});
    selected = result?['uri'] as String?;
  } else { selected = await getDirectoryPath(confirmButtonText: confirm); }
  if (selected != null) await c.setReceiveStorage(selected, c.conflictPolicy);
});

class ReceiveDestination extends StatelessWidget {
  const ReceiveDestination({super.key, required this.controller});
  final BridgeController controller;
  @override
  Widget build(BuildContext context) {
    final c = controller;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionHeading(tr(context, 'Папка получения'), help: tr(context, 'Новые файлы будут сохраняться сюда. Уже полученные файлы останутся на прежнем месте.')),
      Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface,
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant), borderRadius: BorderRadius.circular(12)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [const Icon(Icons.folder_outlined), const SizedBox(width: 12), Expanded(child: Text(c.receiveDestination == null ? tr(context, 'Встроенная папка LinkInDrop')
            : c.receiveDestination!.startsWith('content://') ? Uri.decodeComponent(c.receiveDestination!.split('/').last).replaceFirst('primary:', '') : c.receiveDestination!))]),
          const SizedBox(height: 12), ActionRow(children: [
            OutlinedButton.icon(onPressed: c.busy || c.node == null ? null : () => chooseReceiveDestination(context, c), icon: const Icon(Icons.edit_outlined), label: Text(tr(context, 'Изменить'))),
            OutlinedButton.icon(key: const ValueKey('received-shortcut'), onPressed: c.node == null ? null : c.revealReceivedFolder, icon: const Icon(Icons.folder_open_outlined), label: Text(tr(context, 'Открыть'))),
          ]),
          if (c.receiveDestination != null) TextButton(onPressed: c.busy ? null : () => c.run(() => c.setReceiveStorage(null, c.conflictPolicy)), child: Text(tr(context, 'Встроенная папка'))),
        ])),
    ]);
  }
}
