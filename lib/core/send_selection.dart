import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../l10n/messages.dart';

class SelectedSource {
  const SelectedSource({required this.path, required this.name, required this.size, required this.directory});
  final String path;
  final String name;
  final int size;
  final bool directory;
  bool get image => !directory && RegExp(r'\.(png|jpe?g|webp|gif)$', caseSensitive: false).hasMatch(name);
}

class SendSelection extends ChangeNotifier {
  final List<SelectedSource> _items = [];
  List<SelectedSource> get items => List.unmodifiable(_items);
  int get totalBytes => _items.fold(0, (total, item) => total + item.size);
  bool get hasDirectories => _items.any((item) => item.directory);
  bool sending = false;
  bool loading = false;
  Future<void> _adding = Future.value();

  Future<void> add(Iterable<String> paths, {Map<String, String> names = const {}}) {
    final requested = paths.toList();
    final result = _adding.catchError((Object _) {}).then((_) => _add(requested, names));
    _adding = result.catchError((Object _) {});
    return result;
  }

  Future<void> _add(List<String> paths, Map<String, String> names) async {
    loading = true;
    notifyListeners();
    try {
      final additions = <SelectedSource>[];
      for (final path in paths) {
        if (_items.any((item) => item.path == path) || additions.any((item) => item.path == path)) continue;
        final stat = await FileStat.stat(path);
        if (stat.type != FileSystemEntityType.file && stat.type != FileSystemEntityType.directory) {
          throw FileSystemException(localizeMessage('Файл недоступен'), path);
        }
        additions.add(SelectedSource(path: path, name: names[path] ?? p.basename(path),
          size: stat.type == FileSystemEntityType.file ? stat.size : 0,
          directory: stat.type == FileSystemEntityType.directory));
      }
      _items.addAll(additions);
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  void remove(SelectedSource item) {
    if (sending) return;
    _items.remove(item);
    notifyListeners();
  }

  Future<void> send(Future<void> Function(List<SelectedSource>) enqueue) async {
    if (sending || loading || _items.isEmpty) return;
    sending = true;
    notifyListeners();
    final batch = List<SelectedSource>.of(_items);
    try {
      await enqueue(batch);
      _items.removeWhere(batch.contains);
    } finally {
      sending = false;
      notifyListeners();
    }
  }
}
