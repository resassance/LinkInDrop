import 'package:flutter/material.dart';
import '../l10n/app_strings.dart';

Color successColor(BuildContext context) => Theme.of(context).brightness == Brightness.dark ? const Color(0xff50d890) : const Color(0xff168451);
Color warningColor(BuildContext context) => Theme.of(context).brightness == Brightness.dark ? const Color(0xffffce73) : const Color(0xff946000);

class HelpButton extends StatelessWidget {
  const HelpButton({super.key, required this.title, required this.message});
  final String title;
  final String message;
  @override
  Widget build(BuildContext context) => IconButton(tooltip: tr(context, 'Подробнее'), icon: const Icon(Icons.help_outline_rounded, size: 20),
    onPressed: () => showDialog<void>(context: context, builder: (context) => AlertDialog(title: Text(title),
      content: SingleChildScrollView(child: Text(message)), actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(tr(context, 'Закрыть')))])));
}

class SectionHeading extends StatelessWidget {
  const SectionHeading(this.title, {super.key, this.help});
  final String title;
  final String? help;
  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.only(bottom: 12), child: Row(children: [
    Expanded(child: Text(title, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: 20, fontWeight: FontWeight.w700))),
    if (help != null) HelpButton(title: title, message: help!),
  ]));
}

class ActionRow extends StatelessWidget {
  const ActionRow({super.key, required this.children, this.flexes});
  final List<Widget> children;
  final List<int>? flexes;
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, constraints) {
    if (constraints.maxWidth < 340 || MediaQuery.textScalerOf(context).scale(16) > 21) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (var i = 0; i < children.length; i++) ...[
        if (i > 0) const SizedBox(height: 8), children[i],
      ]]);
    }
    return IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (var i = 0; i < children.length; i++) ...[
      if (i > 0) const SizedBox(width: 8), Expanded(flex: flexes?[i] ?? 1, child: children[i]),
    ]]));
  });
}

class ChoiceField<T> extends StatelessWidget {
  const ChoiceField({super.key, required this.label, required this.value, required this.options, required this.onChanged, this.icon, this.selectedChild, this.showLabel = true});
  final String label;
  final T? value;
  final Map<T, String> options;
  final ValueChanged<T>? onChanged;
  final IconData? icon;
  final Widget? selectedChild;
  final bool showLabel;
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    if (showLabel) ...[Text(label, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)), const SizedBox(height: 8)],
    PopupMenuButton<T>(enabled: onChanged != null, tooltip: label, initialValue: value, position: PopupMenuPosition.under,
      onSelected: onChanged, itemBuilder: (context) => options.entries.map((option) => PopupMenuItem<T>(value: option.key,
        child: Container(padding: const EdgeInsets.symmetric(vertical: 6), decoration: BoxDecoration(
          color: option.key == value ? Theme.of(context).colorScheme.primary.withValues(alpha: .10) : null, borderRadius: BorderRadius.circular(8)),
          child: Row(children: [const SizedBox(width: 8), Expanded(child: Text(option.value)), const SizedBox(width: 12),
            if (option.key == value) Icon(Icons.check_rounded, color: Theme.of(context).colorScheme.primary), const SizedBox(width: 8)])))).toList(),
      child: InputDecorator(decoration: InputDecoration(enabled: onChanged != null), child: Row(children: [
        if (icon != null) ...[Icon(icon, size: 22), const SizedBox(width: 10)],
        Expanded(child: selectedChild ?? Text(options[value] ?? label)), const SizedBox(width: 8), const Icon(Icons.expand_more_rounded),
      ]))),
  ]);
}
