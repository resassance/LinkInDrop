import 'dart:collection';

import 'models.dart';

class SearchService {
  final Map<String, _Search> _searches = {};

  Future<SharedPage> search({required String peer, required String query,
    required Future<List<SharedFile>> Function() roots,
    required Future<SharedPage> Function(SharedFile folder, int offset) list,
    SharedFile? folder, String? cursor}) async {
    final now = DateTime.now();
    _searches.removeWhere((_, value) => now.difference(value.updated) > const Duration(minutes: 2));
    if (query.trim().length < 2 || query.length > 120) throw const FormatException('Введите от 2 до 120 символов');
    late _Search state;
    final key = cursor ?? randomToken(16);
    if (cursor != null) {
      final old = _searches[key];
      if (old == null || old.peer != peer || old.query != query.toLowerCase() || old.busy) {
        throw const FormatException('Поиск истёк. Повторите запрос.');
      }
      state = old;
    } else {
      if (_searches.length >= 128) throw StateError('Слишком много поисковых запросов');
      state = _Search(peer, query.toLowerCase());
      if (folder != null) state.pending.add((folder, 0));
      else {
        for (final root in await roots()) {
          if (root.name.toLowerCase().contains(state.query)) state.ready.add(root);
          if (root.isDirectory) state.pending.add((root, 0));
        }
      }
      _searches[key] = state;
    }
    state.busy = true;
    final found = <SharedFile>[];
    final deadline = DateTime.now().add(const Duration(seconds: 1));
    try {
      while (found.length < 100) {
        if (state.ready.isNotEmpty) { found.add(state.ready.removeFirst()); continue; }
        if (state.pending.isEmpty || DateTime.now().isAfter(deadline)) break;
        final next = state.pending.removeFirst();
        try {
          final page = await list(next.$1, next.$2);
          for (final entry in page.entries) {
            if (entry.name.toLowerCase().contains(state.query)) state.ready.add(entry);
            if (entry.isDirectory && (entry.relativePath?.split('/').length ?? 0) < 64) {
              if (state.pending.length >= 100000) throw StateError('Слишком много вложенных папок');
              state.pending.add((entry, 0));
            }
          }
          if (page.nextOffset != null) state.pending.addFirst((next.$1, page.nextOffset!));
        } on SearchAccessDenied {
        }
      }
      state.updated = DateTime.now();
      final more = state.ready.isNotEmpty || state.pending.isNotEmpty;
      if (!more) _searches.remove(key);
      return SharedPage(found, cursor: more ? key : null);
    } finally { state.busy = false; }
  }
}

class SearchAccessDenied implements Exception {}

class _Search {
  _Search(this.peer, this.query);
  final String peer;
  final String query;
  final Queue<(SharedFile, int)> pending = Queue();
  final Queue<SharedFile> ready = Queue();
  DateTime updated = DateTime.now();
  bool busy = false;
}
