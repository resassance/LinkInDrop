import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/models.dart';

class RemoteFilesDialog extends StatefulWidget {
  const RemoteFilesDialog({super.key, required this.deviceName, required this.load,
    required this.canDownload, this.search, this.preview, this.initialFolder, this.isFavorite, this.toggleFavorite});
  final String deviceName;
  final Future<SharedPage> Function(SharedFile? folder, int offset) load;
  final bool canDownload;
  final SharedFile? initialFolder;
  final bool Function(SharedFile)? isFavorite;
  final Future<void> Function(SharedFile)? toggleFavorite;
  final Future<SharedPage> Function(SharedFile?, String, String?)? search;
  final Future<Map<String, dynamic>> Function(SharedFile)? preview;

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
  final _query = TextEditingController();
  Timer? _debounce;
  String? _cursor;
  final Map<String, Future<Map<String, dynamic>>> _previews = {};
  Future<void> _previewQueue = Future.value();

  @override
  void dispose() { _debounce?.cancel(); _query.dispose(); super.dispose(); }

  Future<Map<String, dynamic>> _preview(SharedFile entry) {
    return _previews.putIfAbsent(jsonEncode(entry.toJson()), () {
      final result = Completer<Map<String, dynamic>>();
      _previewQueue = _previewQueue.catchError((Object _) {}).then((_) async {
        if (!mounted) { result.complete({'type': 'metadata'}); return; }
        try { result.complete(await widget.preview!(entry)); }
        catch (error, stack) { result.completeError(error, stack); }
      });
      return result.future;
    });
  }

  void _enter(SharedFile entry) {
    final path = entry.relativePath ?? '';
    final root = entry.rootName ?? (path.isEmpty ? entry.name : _folders.isNotEmpty ? _folders.first.name : 'Общая папка');
    _folders.clear();
    _folders.add(SharedFile(id: entry.id, folderId: entry.folderId, relativePath: '', name: root, size: 0, isDirectory: true, rootName: root));
    var relative = '';
    for (final part in path.split('/').where((p) => p.isNotEmpty)) {
      relative = relative.isEmpty ? part : '$relative/$part';
      _folders.add(SharedFile(id: entry.id, folderId: entry.folderId, relativePath: relative,
        name: safeFilename(part), size: 0, isDirectory: true, rootName: root));
    }
    _query.clear();
    unawaited(_load(reset: true));
  }

  Future<void> _showPreview(SharedFile entry) async {
    if (widget.preview == null) { if (widget.canDownload) Navigator.pop(context, entry); return; }
    final pending = _preview(entry);
    final download = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: Text(entry.name),
      content: SizedBox(width: 480, height: 360, child: FutureBuilder<Map<String, dynamic>>(
        future: pending, builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
          if (snapshot.hasError) return SelectableText('${snapshot.error}');
          final data = snapshot.data!;
          if (data['type'] == 'image') return Image.memory(base64.decode(data['data'] as String), fit: BoxFit.contain, cacheWidth: 400);
          if (data['type'] == 'text') return SingleChildScrollView(child: SelectableText(
            '${data['text']}${data['truncated'] == true ? '\n… показано начало файла' : ''}', style: const TextStyle(fontFamily: 'monospace')));
          return Text(data['reason'] as String? ?? 'Предпросмотр этого формата недоступен. Размер: ${_size(entry.size)}');
        })),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Закрыть')),
        FilledButton(onPressed: !widget.canDownload ? null : () => Navigator.pop(context, true), child: const Text('Скачать'))]));
    if (download == true && mounted) Navigator.pop(context, entry);
  }

  @override
  void initState() {
    super.initState();
    if (widget.initialFolder != null) _folders.add(widget.initialFolder!);
    unawaited(_load(reset: true));
  }

  Future<void> _load({required bool reset}) async {
    final generation = ++_generation;
    final offset = reset ? 0 : (_cursor != null ? 0 : _nextOffset);
    if (offset == null) return;
    setState(() {
      _loading = true;
      _error = null;
      if (reset) { _entries = []; _nextOffset = null; _cursor = null; }
    });
    try {
      final text = _query.text.trim();
      final page = text.length >= 2 && widget.search != null
        ? await widget.search!(_folders.isEmpty ? null : _folders.last, text, reset ? null : _cursor)
        : await widget.load(_folders.isEmpty ? null : _folders.last, offset);
      if (!mounted || generation != _generation) return;
      setState(() {
        _entries = reset ? page.entries : [..._entries, ...page.entries];
        _nextOffset = page.nextOffset;
        _cursor = page.cursor;
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
    _query.clear();
    unawaited(_load(reset: true));
  }

  String _size(int bytes) => bytes < 1024 ? '$bytes Б'
    : bytes < 1024 * 1024 ? '${(bytes / 1024).toStringAsFixed(1)} КБ'
    : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} МБ';

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Файлы: ${widget.deviceName}'),
    insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
    content: SizedBox(width: 520, height: MediaQuery.sizeOf(context).height < 600 ? 260 : 400, child: Column(children: [
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
          _query.clear();
          unawaited(_load(reset: true));
        }, child: const Text('К общему списку'))),
      if (!widget.canDownload) const Text('Включите приём файлов, чтобы скачивать их.'),
      if (widget.search != null) Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: TextField(
        controller: _query, decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Поиск в папке и подпапках'),
        onChanged: (_) { _debounce?.cancel(); _debounce = Timer(const Duration(milliseconds: 400), () => unawaited(_load(reset: true))); })),
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
            leading: !entry.isDirectory && widget.preview != null && RegExp(r'\.(png|jpe?g|webp|gif)$', caseSensitive: false).hasMatch(entry.name)
              ? _Thumbnail(load: () => _preview(entry)) : Icon(entry.isDirectory ? Icons.folder_outlined : Icons.insert_drive_file_outlined),
            title: Text(entry.name, maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(entry.isDirectory ? 'Папка' : _size(entry.size)),
              if (entry.isDirectory) Wrap(children: [
                if (widget.toggleFavorite != null) IconButton(tooltip: 'Избранная папка',
                  icon: Icon(widget.isFavorite?.call(entry) == true ? Icons.star : Icons.star_outline), onPressed: () async {
                    await widget.toggleFavorite!(entry); if (mounted) setState(() {});
                  }),
                IconButton(tooltip: 'Скачать папку', icon: const Icon(Icons.download_rounded),
                  onPressed: _loading || !widget.canDownload ? null : () => Navigator.pop(context, entry)),
              ])
              else IconButton(tooltip: 'Скачать', icon: const Icon(Icons.download_rounded),
                onPressed: _loading || !widget.canDownload ? null : () => Navigator.pop(context, entry)),
            ]),
            onTap: _loading ? null : entry.isDirectory ? () {
              _enter(entry);
            } : () => _showPreview(entry)),
          if (_loading) const Center(child: CircularProgressIndicator()),
          if ((_nextOffset != null || _cursor != null) && !_loading) TextButton(
            onPressed: () => _load(reset: false), child: Text(_cursor != null ? 'Продолжить поиск' : 'Показать ещё')),
        ])),
    ])),
    actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Закрыть'))]);
}

class _Thumbnail extends StatefulWidget {
  const _Thumbnail({required this.load});
  final Future<Map<String, dynamic>> Function() load;
  @override
  State<_Thumbnail> createState() => _ThumbnailState();
}

class _ThumbnailState extends State<_Thumbnail> {
  late final Future<Map<String, dynamic>> pending = widget.load();
  @override
  Widget build(BuildContext context) => SizedBox(width: 40, height: 40,
    child: FutureBuilder<Map<String, dynamic>>(future: pending, builder: (context, snapshot) {
      if (snapshot.data?['type'] != 'image') return const Icon(Icons.image_outlined);
      return ClipRRect(borderRadius: BorderRadius.circular(6), child: Image.memory(
        base64.decode(snapshot.data!['data'] as String), fit: BoxFit.cover, cacheWidth: 80));
    }));
}
