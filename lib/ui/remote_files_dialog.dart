import '../l10n/app_strings.dart';
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
    final root = entry.rootName ?? (path.isEmpty ? entry.name : _folders.isNotEmpty ? _folders.first.name : tr(context, "Общая папка"));
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
          if (snapshot.connectionState != ConnectionState.done) return Center(child: CircularProgressIndicator());
          if (snapshot.hasError) return SelectableText('${snapshot.error}');
          final data = snapshot.data!;
          if (data['type'] == 'image') return Image.memory(base64.decode(data['data'] as String), fit: BoxFit.contain, cacheWidth: 400);
          if (data['type'] == 'text') return SingleChildScrollView(child: SelectableText(
            '${data['text']}${data['truncated'] == true ? tr(context, "\n… показано начало файла") : ''}', style: TextStyle(fontFamily: 'monospace')));
          return Text(data['reason'] is String ? tr(context, data['reason'] as String) : tr(context, "Предпросмотр этого формата недоступен. Размер: {0}", [_size(entry.size)]));
        })),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr(context, "Закрыть"))),
        FilledButton(onPressed: !widget.canDownload ? null : () => Navigator.pop(context, true), child: Text(tr(context, "Скачать")))]));
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

  String _size(int bytes) => stringsOf(context).size(bytes);

  Widget _entry(SharedFile entry) => InkWell(
    onTap: _loading ? null : entry.isDirectory ? () => _enter(entry) : () => _showPreview(entry),
    child: Padding(padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6), child: Row(children: [
      SizedBox(width: 28, height: 32, child: !entry.isDirectory && widget.preview != null && RegExp(r'\.(png|jpe?g|webp|gif)$', caseSensitive: false).hasMatch(entry.name)
        ? _Thumbnail(load: () => _preview(entry)) : Icon(entry.isDirectory ? Icons.folder_outlined : Icons.insert_drive_file_outlined)),
      SizedBox(width: 10),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(entry.name, key: ValueKey('remote-name:${entry.relativePath ?? entry.id}'), maxLines: 2, overflow: TextOverflow.ellipsis),
        Text(entry.isDirectory ? tr(context, "Папка") : _size(entry.size), style: Theme.of(context).textTheme.bodySmall),
      ])),
      SizedBox(width: 40, child: PopupMenuButton<String>(tooltip: tr(context, "Действия: {0}", [entry.name]),
        onSelected: (action) async {
          if (action == 'download') Navigator.pop(context, entry);
          if (action == 'favorite') { await widget.toggleFavorite!(entry); if (mounted) setState(() {}); }
        }, itemBuilder: (_) => [
          PopupMenuItem(value: 'download', enabled: !_loading && widget.canDownload,
            child: Text(entry.isDirectory ? tr(context, "Скачать папку") : tr(context, "Скачать"))),
          if (entry.isDirectory && widget.toggleFavorite != null) PopupMenuItem(value: 'favorite',
            child: Text(widget.isFavorite?.call(entry) == true ? tr(context, "Убрать из избранного") : tr(context, "В избранное"))),
        ])),
    ])));

  Widget _browser() => Scaffold(
    appBar: AppBar(automaticallyImplyLeading: false, titleSpacing: 12,
      title: Text(widget.deviceName, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 18)),
      actions: [IconButton(tooltip: tr(context, "Обновить"), onPressed: _loading ? null : () => _load(reset: true), icon: Icon(Icons.refresh)),
        IconButton(tooltip: tr(context, "Закрыть"), onPressed: () => Navigator.pop(context), icon: Icon(Icons.close))]),
    body: Column(children: [
      Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Row(children: [
        if (_folders.isNotEmpty) IconButton(tooltip: tr(context, "Назад"), onPressed: _back, icon: Icon(Icons.arrow_back))
        else Padding(padding: EdgeInsets.all(12), child: Icon(Icons.folder_shared_outlined)),
        Expanded(child: Text(_folders.isEmpty ? tr(context, "Общие файлы и папки") : _folders.last.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
        if (_folders.isNotEmpty) IconButton(tooltip: tr(context, "К общему списку"), icon: Icon(Icons.home_outlined), onPressed: () {
          _folders.clear(); _query.clear(); unawaited(_load(reset: true));
        }),
      ])),
      if (!widget.canDownload) Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: Text(tr(context, "Включите приём файлов, чтобы скачивать их."))),
      if (widget.search != null) Padding(padding: EdgeInsets.fromLTRB(12, 0, 12, 8), child: TextField(
        controller: _query, decoration: InputDecoration(isDense: true, prefixIcon: Icon(Icons.search), hintText: tr(context, "Поиск файлов")),
        onChanged: (_) { _debounce?.cancel(); _debounce = Timer(Duration(milliseconds: 400), () => unawaited(_load(reset: true))); })),
      Divider(height: 1),
      Expanded(child: _loading && _entries.isEmpty ? Center(child: CircularProgressIndicator()) : ListView(children: [
        if (_error != null) Padding(padding: EdgeInsets.all(12), child: SelectableText(tr(context, "{0}\n\nПроверьте доступ к папке на другом устройстве.", [_error]))),
        if (_entries.isEmpty && _error == null) Padding(padding: EdgeInsets.all(12), child: Text(_folders.isEmpty
          ? tr(context, "Общих файлов и папок пока нет. Выберите их на другом устройстве.") : tr(context, "Папка пуста или в ней нет доступных файлов."))),
        for (final entry in _entries) _entry(entry),
        if (_loading) Center(child: CircularProgressIndicator()),
        if ((_nextOffset != null || _cursor != null) && !_loading) TextButton(onPressed: () => _load(reset: false),
          child: Text(_cursor != null ? tr(context, "Продолжить поиск") : tr(context, "Показать ещё"))),
      ])),
    ]));

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, constraints) {
    if (constraints.maxWidth < 600) return Dialog.fullscreen(child: _browser());
    return Dialog(clipBehavior: Clip.antiAlias, child: SizedBox(width: 720, height: constraints.maxHeight * 0.85, child: _browser()));
  });
}

class _Thumbnail extends StatefulWidget {
  _Thumbnail({required this.load});
  final Future<Map<String, dynamic>> Function() load;
  @override
  State<_Thumbnail> createState() => _ThumbnailState();
}

class _ThumbnailState extends State<_Thumbnail> {
  late final Future<Map<String, dynamic>> pending = widget.load();
  @override
  Widget build(BuildContext context) => SizedBox(width: 40, height: 40,
    child: FutureBuilder<Map<String, dynamic>>(future: pending, builder: (context, snapshot) {
      if (snapshot.data?['type'] != 'image') return Icon(Icons.image_outlined);
      return ClipRRect(borderRadius: BorderRadius.circular(6), child: Image.memory(
        base64.decode(snapshot.data!['data'] as String), fit: BoxFit.cover, cacheWidth: 80));
    }));
}
