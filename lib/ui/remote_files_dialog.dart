import 'dart:async';

import 'package:flutter/material.dart';

import '../core/models.dart';

class RemoteFilesDialog extends StatefulWidget {
  const RemoteFilesDialog({super.key, required this.deviceName, required this.load,
    required this.canDownload});
  final String deviceName;
  final Future<SharedPage> Function(SharedFile? folder, int offset) load;
  final bool canDownload;

  @override
  State<RemoteFilesDialog> createState() => _RemoteFilesDialogState();
}

class _RemoteFilesDialogState extends State<RemoteFilesDialog> {
  final List<SharedFile> _folders = [];
  List<SharedFile> _entries = [];
  int? _nextOffset;
  bool _loading = true;
  String? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load(reset: true));
  }

  Future<void> _load({required bool reset}) async {
    final generation = ++_generation;
    final offset = reset ? 0 : _nextOffset;
    if (offset == null) return;
    setState(() {
      _loading = true;
      _error = null;
      if (reset) { _entries = []; _nextOffset = null; }
    });
    try {
      final page = await widget.load(_folders.isEmpty ? null : _folders.last, offset);
      if (!mounted || generation != _generation) return;
      setState(() {
        _entries = reset ? page.entries : [..._entries, ...page.entries];
        _nextOffset = page.nextOffset;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() => _error = '$error');
    } finally {
      if (mounted && generation == _generation) setState(() => _loading = false);
    }
  }

  void _back() {
    _folders.removeLast();
    unawaited(_load(reset: true));
  }

  String _size(int bytes) => bytes < 1024 ? '$bytes Б'
    : bytes < 1024 * 1024 ? '${(bytes / 1024).toStringAsFixed(1)} КБ'
    : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} МБ';

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Файлы: ${widget.deviceName}'),
    content: SizedBox(width: 520, height: 400, child: Column(children: [
      Row(children: [
        if (_folders.isNotEmpty) IconButton(tooltip: 'Назад', onPressed: _back,
          icon: const Icon(Icons.arrow_back_rounded)),
        Expanded(child: Text(_folders.isEmpty ? 'Общие файлы и папки' : _folders.last.name,
          maxLines: 2, overflow: TextOverflow.ellipsis)),
        IconButton(tooltip: 'Обновить', onPressed: _loading ? null : () => _load(reset: true),
          icon: const Icon(Icons.refresh_rounded)),
      ]),
      if (_folders.isNotEmpty) Align(alignment: Alignment.centerLeft,
        child: TextButton(onPressed: () {
          _folders.clear();
          unawaited(_load(reset: true));
        }, child: const Text('К общему списку'))),
      if (!widget.canDownload) const Text('Включите приём файлов, чтобы скачивать их.'),
      const SizedBox(height: 8),
      Expanded(child: _loading && _entries.isEmpty
        ? const Center(child: CircularProgressIndicator())
        : ListView(children: [
          if (_error != null) Padding(padding: const EdgeInsets.all(8),
            child: SelectableText('$_error\n\nПроверьте доступ к папке на другом устройстве.')),
          if (_entries.isEmpty && _error == null) Padding(padding: const EdgeInsets.all(8),
            child: Text(_folders.isEmpty
              ? 'Общих файлов и папок пока нет. Выберите их на другом устройстве.'
              : 'Папка пуста или в ней нет доступных файлов.')),
          for (final entry in _entries) ListTile(
            leading: Icon(entry.isDirectory ? Icons.folder_outlined : Icons.insert_drive_file_outlined),
            title: Text(entry.name), subtitle: Text(entry.isDirectory ? 'Папка' : _size(entry.size)),
            onTap: _loading ? null : entry.isDirectory ? () {
              _folders.add(entry);
              unawaited(_load(reset: true));
            } : widget.canDownload ? () => Navigator.pop(context, entry) : null,
            trailing: entry.isDirectory ? const Icon(Icons.chevron_right_rounded)
              : IconButton(tooltip: 'Скачать', icon: const Icon(Icons.download_rounded),
                  onPressed: _loading || !widget.canDownload ? null : () => Navigator.pop(context, entry))),
          if (_loading) const Center(child: CircularProgressIndicator()),
          if (_nextOffset != null && !_loading) TextButton(
            onPressed: () => _load(reset: false), child: const Text('Показать ещё')),
        ])),
    ])),
    actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Закрыть'))]);
}
