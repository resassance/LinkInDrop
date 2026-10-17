import 'dart:async';
import 'package:flutter/material.dart';
import '../core/controller.dart';
import '../core/media_library.dart';
import '../l10n/app_strings.dart';
import 'design_system.dart';
import 'media_thumbnail.dart';

class AttachmentSheet extends StatefulWidget {
  const AttachmentSheet({super.key, required this.controller, required this.pickFiles, required this.pickFolder, this.library = const MediaLibrary()});
  final BridgeController controller;
  final Future<void> Function() pickFiles;
  final Future<void> Function() pickFolder;
  final MediaLibrary library;
  @override
  State<AttachmentSheet> createState() => _AttachmentSheetState();
}

class _AttachmentSheetState extends State<AttachmentSheet> with WidgetsBindingObserver {
  int _tab = 0;
  String _access = 'loading';
  String? _album;
  List<Map<String, String>> _albums = [];
  final List<LibraryItem> _items = [];
  bool _loading = false;
  bool _more = true;
  bool _working = false;
  String? _error;
  int _generation = 0;
  bool _checkingAccess = false;
  bool _backgrounded = false;
  BridgeController get c => widget.controller;
  @override
  void initState() { super.initState(); WidgetsBinding.instance.addObserver(this); unawaited(_initialize(request: true)); }
  @override
  void dispose() { WidgetsBinding.instance.removeObserver(this); _generation++; super.dispose(); }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) _backgrounded = true;
    if (state == AppLifecycleState.resumed && !_working && !_loading) unawaited(_refreshAccess());
  }
  Future<void> _refreshAccess() async {
    if (_checkingAccess || _working || _loading || _access == 'loading' || WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) return;
    _checkingAccess = true;
    var checked = false;
    try {
      final access = await widget.library.access();
      if (!mounted || WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) return;
      checked = true;
      if (mounted && (access != _access || _backgrounded)) {
        _backgrounded = false;
        await _initialize(preservePosition: true);
      }
    } catch (_) {
    } finally { _checkingAccess = false; if (checked) _refreshWhenReady(); }
  }
  void _refreshWhenReady() {
    if (mounted && _backgrounded && !_working && !_loading && WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) unawaited(_refreshAccess());
  }
  Future<void> _initialize({bool request = false, bool preservePosition = false}) async {
    final generation = ++_generation;
    final count = _items.length;
    if (preservePosition) setState(() => _loading = true);
    try {
      final access = await widget.library.access(request: request);
      final albums = access == 'denied' ? <Map<String, String>>[] : await widget.library.albums();
      if (!mounted || generation != _generation) return;
      if (preservePosition && access != 'denied') {
        final album = albums.any((entry) => entry['id'] == _album) ? _album : null;
        final items = <LibraryItem>[];
        var more = true;
        while (more && (items.isEmpty || items.length < count)) {
          final page = await widget.library.page(album: album, offset: items.length);
          if (!mounted || generation != _generation) return;
          items.addAll(page);
          more = page.length == 60;
        }
        setState(() { _access = access; _albums = albums; _album = album; _items..clear()..addAll(items); _more = more; _loading = false; _error = null; });
        return;
      }
      setState(() { _access = access; _albums = albums; _items.clear(); if (!albums.any((album) => album['id'] == _album)) _album = null; _more = true; _loading = false; _error = null; });
      if (access != 'denied') await _load();
    } catch (error) { if (mounted && generation == _generation) setState(() { if (!preservePosition) _access = 'denied'; _loading = false; _error = '$error'; }); }
    finally { if (mounted && generation == _generation) { setState(() => _loading = false); _refreshWhenReady(); } }
  }
  Future<void> _load() async {
    if (_loading || !_more) return;
    final generation = _generation;
    setState(() => _loading = true);
    try {
      final page = await widget.library.page(album: _album, offset: _items.length);
      if (mounted && generation == _generation) setState(() { _items.addAll(page); _more = page.length == 60; _error = null; });
    } catch (error) { if (mounted && generation == _generation) setState(() => _error = '$error'); }
    finally { if (mounted && generation == _generation) { setState(() => _loading = false); _refreshWhenReady(); } }
  }
  Future<void> _operation(Future<void> Function() action) async {
    if (_working || c.busy) return;
    setState(() { _working = true; _error = null; });
    try { await action(); }
    catch (error) { if (mounted) setState(() => _error = '$error'); }
    finally {
      if (mounted) {
        setState(() => _working = false);
        _refreshWhenReady();
      }
    }
  }
  Future<void> _select(LibraryItem item) => _operation(() async {
    final existing = c.gallerySources[item.uri];
    if (existing != null) {
      final sources = c.selection.items.where((source) => source.path == existing);
      if (sources.isNotEmpty) await c.removeSelected(sources.first);
    } else {
      if (c.selection.items.length >= 100) throw StateError(tr(context, 'Не больше 100 файлов за раз'));
      final paths = await widget.library.importItems([item.uri]);
      await c.stageFiles(paths);
      if (paths.isNotEmpty) c.gallerySources[item.uri] = paths.first;
    }
  });
  Widget _gallery(ScrollController scroll) {
    if (_access == 'loading') return const Center(child: CircularProgressIndicator());
    if (_access == 'denied') return ListView(controller: scroll, padding: const EdgeInsets.all(20), children: [
      const Icon(Icons.photo_library_outlined, size: 48), const SizedBox(height: 16),
      Text(tr(context, 'Разрешите доступ к фото и видео или выберите их через системное окно.')),
      const SizedBox(height: 16), OutlinedButton(onPressed: () => _initialize(request: true), child: Text(tr(context, 'Разрешить доступ'))),
      const SizedBox(height: 8), FilledButton(onPressed: _working ? null : () => _operation(() async {
        final uris = await widget.library.pickMedia();
        final paths = await widget.library.importItems(uris);
        await c.stageFiles(paths);
      }), child: Text(tr(context, 'Выбрать через системное окно'))),
    ]);
    return NotificationListener<ScrollNotification>(onNotification: (notice) {
      if (notice.metrics.extentAfter < 500 && _more && !_loading && _error == null) unawaited(_load());
      return false;
    }, child: CustomScrollView(key: const PageStorageKey('attachment-gallery'), controller: scroll, slivers: [
      SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 12), child: Column(children: [
        Row(children: [Expanded(child: ChoiceField<String>(showLabel: false, label: tr(context, 'Альбом'), value: _album ?? '', options: {'': tr(context, 'Недавние'), for (final album in _albums) album['id']!: album['name']!},
          onChanged: _loading || _working ? null : (value) { if (value == (_album ?? '')) return; _generation++; setState(() { _album = value.isEmpty ? null : value; _items.clear(); _more = true; _loading = false; _error = null; }); if (scroll.hasClients) scroll.jumpTo(0); unawaited(_load()); })), const SizedBox(width: 12), Text(tr(context, 'Выбрано: {0}', [c.selection.items.length]), style: TextStyle(color: Theme.of(context).colorScheme.primary))]),
        if (_access == 'limited') Padding(padding: const EdgeInsets.only(top: 8), child: TextButton(onPressed: () => _initialize(request: true), child: Text(tr(context, 'Доступ только к выбранным фото · Изменить')))),
      ]))),
      if (_items.isEmpty && !_loading) SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.all(24), child: Text(tr(context, 'В этом альбоме нет доступных фото и видео')))),
      SliverPadding(padding: const EdgeInsets.symmetric(horizontal: 4), sliver: SliverGrid(delegate: SliverChildBuilderDelegate((context, index) {
        final item = _items[index];
        final path = c.gallerySources[item.uri];
        final selectedIndex = path == null ? -1 : c.selection.items.indexWhere((source) => source.path == path);
        return Semantics(label: item.name, selected: selectedIndex >= 0, button: true, child: InkWell(onTap: _working ? null : () => _select(item),
          child: Stack(fit: StackFit.expand, children: [MediaThumbnail(path: item.uri, name: item.name, size: 160, radius: 2),
            Positioned(top: 4, right: 4, child: Container(width: 28, height: 28, alignment: Alignment.center,
              decoration: BoxDecoration(shape: BoxShape.circle, color: selectedIndex < 0 ? Colors.black38 : Theme.of(context).colorScheme.primary, border: Border.all(color: Colors.white, width: 2)),
              child: selectedIndex < 0 ? null : Text('${selectedIndex + 1}', style: TextStyle(color: Theme.of(context).colorScheme.onPrimary, fontWeight: FontWeight.bold)))),
            if (item.video) Positioned(bottom: 6, left: 6, child: Container(color: Colors.black54, padding: const EdgeInsets.all(3),
              child: Text('${item.duration ~/ 60000}:${((item.duration ~/ 1000) % 60).toString().padLeft(2, '0')}', style: const TextStyle(color: Colors.white, fontSize: 12)))),
          ])));
      }, childCount: _items.length), gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, crossAxisSpacing: 3, mainAxisSpacing: 3))),
      if (_loading) const SliverToBoxAdapter(child: Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))),
    ]));
  }
  Widget _files(ScrollController scroll) => ListView(controller: scroll, padding: const EdgeInsets.symmetric(horizontal: 16), children: [
    OutlinedButton.icon(onPressed: _working ? null : () => _operation(_tab == 1 ? widget.pickFiles : widget.pickFolder),
      icon: Icon(_tab == 1 ? Icons.description_outlined : Icons.create_new_folder_outlined),
      label: Text(tr(context, _tab == 1 ? 'Выбрать файлы на устройстве' : 'Добавить папку'))),
    const SizedBox(height: 12), Text(tr(context, 'Из памяти телефона и доступных хранилищ'), style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
    const Divider(height: 32), SectionHeading(tr(context, 'К отправке')),
    if (c.selection.items.isEmpty) Text(tr(context, 'Файлы и папки пока не выбраны')),
    for (final source in c.selection.items) ListTile(contentPadding: EdgeInsets.zero,
      leading: source.directory ? const Icon(Icons.folder_outlined) : MediaThumbnail(path: source.path, name: source.name),
      title: Text(source.name, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(source.directory ? tr(context, 'Папка со всем содержимым') : stringsOf(context).size(source.size)),
      trailing: IconButton(tooltip: tr(context, 'Убрать файл'), onPressed: _working ? null : () => _operation(() => c.removeSelected(source)), icon: const Icon(Icons.close_rounded))),
  ]);
  @override
  Widget build(BuildContext context) => AnimatedBuilder(animation: c.selection, builder: (context, _) => PopScope(canPop: !_working, child: DraggableScrollableSheet(
    expand: false, initialChildSize: .77, minChildSize: .55, maxChildSize: .98, builder: (context, scroll) => Column(children: [
      Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Theme.of(context).colorScheme.onSurfaceVariant, borderRadius: BorderRadius.circular(8))))),
      Padding(padding: const EdgeInsets.fromLTRB(16, 0, 8, 12), child: Row(children: [Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(tr(context, 'Прикрепить'), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
        if (c.selectedPeer != null) Text(tr(context, 'На {0}', [c.selectedPeer!.name]), style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ])), IconButton(tooltip: tr(context, 'Закрыть'), onPressed: _working ? null : () => Navigator.pop(context, false), icon: const Icon(Icons.close_rounded))])),
      if (_working) Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Column(children: [const LinearProgressIndicator(), const SizedBox(height: 8), Text(tr(context, 'Подготавливаем файлы…'))])),
      if (_error != null) Padding(padding: const EdgeInsets.all(16), child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
      Expanded(key: const ValueKey('attachment-content'), child: _tab == 0 ? _gallery(scroll) : _files(scroll)),
      if (c.selection.items.isNotEmpty) Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 8), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('${c.selection.items.length} · ${stringsOf(context).size(c.selection.totalBytes)}${c.selection.hasDirectories ? tr(context, ' + папки') : ''}'), const SizedBox(height: 8),
        FilledButton(key: const ValueKey('attachments-next'), onPressed: _working ? null : () => Navigator.pop(context, true), child: Text(tr(context, 'Далее · {0}', [c.selection.items.length]))),
      ])),
      SafeArea(top: false, child: NavigationBar(selectedIndex: _tab, onDestinationSelected: _working ? null : (value) => setState(() => _tab = value), destinations: [
        NavigationDestination(icon: const Icon(Icons.photo_library_outlined), label: tr(context, 'Галерея')),
        NavigationDestination(icon: const Icon(Icons.description_outlined), label: tr(context, 'Файлы')),
        NavigationDestination(icon: const Icon(Icons.folder_outlined), label: tr(context, 'Папки')),
      ])),
    ]))));
}
