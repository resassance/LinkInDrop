import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../l10n/app_strings.dart';

class TextComposeDialog extends StatefulWidget {
  const TextComposeDialog({super.key, this.recipient});
  final String? recipient;
  @override
  State<TextComposeDialog> createState() => _TextComposeDialogState();
}

class _TextComposeDialogState extends State<TextComposeDialog> {
  final _text = TextEditingController();
  @override
  void dispose() { _text.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => AlertDialog(scrollable: true, title: Text(tr(context, 'Отправить текст')),
    content: SizedBox(width: 480, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Text(widget.recipient == null ? tr(context, 'Выберите устройство') : tr(context, 'На {0}', [widget.recipient!])), const SizedBox(height: 16),
      TextField(controller: _text, minLines: 3, maxLines: 8, autofocus: true, onChanged: (_) => setState(() {}), decoration: InputDecoration(hintText: tr(context, 'Текст или ссылка'))),
      Align(alignment: Alignment.centerLeft, child: TextButton.icon(onPressed: () async {
        final value = await Clipboard.getData(Clipboard.kTextPlain);
        if (mounted && value?.text != null) setState(() => _text.text = value!.text!);
      }, icon: const Icon(Icons.content_paste_rounded), label: Text(tr(context, 'Вставить')))),
    ])),
    actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(tr(context, 'Отмена'))),
      FilledButton(onPressed: widget.recipient == null || _text.text.trim().isEmpty ? null : () => Navigator.pop(context, _text.text), child: Text(tr(context, 'Отправить')))]);
}
