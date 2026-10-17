import 'dart:io';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import '../core/controller.dart';
import '../l10n/app_strings.dart';
import 'design_system.dart';
import 'media_thumbnail.dart';

class MediaComposer extends StatefulWidget {
  const MediaComposer({super.key, required this.controller, required this.addFiles});
  final BridgeController controller;
  final Future<void> Function() addFiles;
  @override
  State<MediaComposer> createState() => _MediaComposerState();
}

class _MediaComposerState extends State<MediaComposer> {
  int _index = 0;
  BridgeController get c => widget.controller;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(animation: c, builder: (context, _) {
    final items = c.selection.items;
    if (_index >= items.length) _index = 0;
    final current = items.isEmpty ? null : items[_index];
    return SafeArea(top: false, child: Padding(padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [Expanded(child: Text(tr(context, 'К отправке'), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700))),
          IconButton(tooltip: tr(context, 'Закрыть'), onPressed: c.selection.sending ? null : () => Navigator.pop(context), icon: const Icon(Icons.close_rounded))]),
        Flexible(child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (current != null) ...[
            if (!current.directory && (current.image || current.video)) InkWell(onTap: current.video ? () => c.run(() async {
              final result = await OpenFilex.open(current.path);
              if (result.type != ResultType.done) throw FileSystemException(result.message);
            }) : null, child: AspectRatio(aspectRatio: 4 / 3, child: MediaThumbnail(path: current.path, name: current.name, size: 480, fit: BoxFit.contain)))
            else Padding(padding: const EdgeInsets.all(24), child: Icon(current.directory ? Icons.folder_outlined : Icons.description_outlined, size: 64)),
            const SizedBox(height: 8), Text(current.name, maxLines: 2, overflow: TextOverflow.ellipsis), const SizedBox(height: 12),
          ],
          SizedBox(height: 96, child: ListView.separated(scrollDirection: Axis.horizontal, itemCount: items.length, separatorBuilder: (_, i) => const SizedBox(width: 8),
            itemBuilder: (context, index) { final source = items[index]; return SizedBox(width: 88, child: Stack(children: [
              Positioned.fill(child: InkWell(onTap: () => setState(() => _index = index), child: Container(padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: index == _index ? Theme.of(context).colorScheme.primary : Colors.transparent, width: 2)),
                child: source.directory ? const Icon(Icons.folder_outlined) : MediaThumbnail(path: source.path, name: source.name, size: 80)))),
              Positioned(top: 0, right: 0, child: IconButton.filledTonal(tooltip: tr(context, 'Убрать файл'), icon: const Icon(Icons.close_rounded, size: 18),
                onPressed: c.busy ? null : () => c.run(() => c.removeSelected(source)))),
            ])); })),
          const SizedBox(height: 12), OutlinedButton.icon(onPressed: c.busy ? null : widget.addFiles, icon: const Icon(Icons.add_rounded), label: Text(tr(context, 'Добавить файлы'))),
          const SizedBox(height: 16), ChoiceField<String>(label: tr(context, 'Получатель'), value: c.selectedPeer?.id,
            options: {for (final peer in c.peers) peer.id: '${peer.name} · ${peer.online ? tr(context, 'В сети') : tr(context, 'Не в сети')}'},
            onChanged: c.busy ? null : c.selectPeer, icon: Icons.devices_outlined),
          const SizedBox(height: 12), Row(children: [Expanded(child: Text('${items.length} · ${stringsOf(context).size(c.selection.totalBytes)}')),
            Text(tr(context, 'Без сжатия')), HelpButton(title: tr(context, 'Без сжатия'), message: tr(context, 'Файлы передаются в исходном качестве. Оригиналы на устройстве сохраняются.'))]),
          if (items.isEmpty) Text(tr(context, 'Файлы и папки пока не выбраны')),
          const SizedBox(height: 12),
        ]))),
        FilledButton(key: const ValueKey('composer-send'), onPressed: c.busy || items.isEmpty || c.selectedPeer == null || c.selection.sending ? null : () async {
          await c.run(c.sendSelection);
          if (context.mounted && c.selection.items.isEmpty) Navigator.pop(context);
        }, child: Text(c.selection.sending ? tr(context, 'Добавляем в очередь…') : c.selection.hasDirectories ? tr(context, 'Передать выбранное') : trFiles(context, items.length))),
      ])));
  });
}
