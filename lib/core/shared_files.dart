import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'models.dart';

class SharedFiles {
  SharedFiles(this.directory);
  final Directory directory;
  final Map<String, String> _paths = {};
  Future<void> _saveQueue = Future.value();
  File get _state => File(p.join(directory.path, 'shared-files.json'));

  Future<void> load() async {
    if (await _state.exists()) {
      final data = jsonDecode(await _state.readAsString()) as Map<String, dynamic>;
      for (final entry in data.entries) {
        if (RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(entry.key) && entry.value is String) {
          _paths[entry.key] = entry.value as String;
        }
      }
    }
  }

  Future<void> _save() {
    final content = jsonEncode(_paths);
    _saveQueue = _saveQueue.catchError((Object _) {}).then((_) async {
      final temporary = File('${_state.path}.new');
      await temporary.writeAsString(content, flush: true);
      await temporary.rename(_state.path);
    });
    return _saveQueue;
  }

  Future<void> add(String path) async {
    if (_paths.length >= 200) throw StateError('Можно открыть доступ к 200 файлам');
    final file = File(path);
    final canonical = await file.resolveSymbolicLinks();
    final privateRoot = await directory.resolveSymbolicLinks();
    if (!p.equals(p.normalize(p.absolute(path)), canonical) ||
        p.equals(canonical, privateRoot) || p.isWithin(privateRoot, canonical) ||
        await FileSystemEntity.type(canonical, followLinks: false) != FileSystemEntityType.file) {
      throw StateError('Этот файл нельзя открыть для удалённого доступа');
    }
    if (await file.length() > maxFileBytes) throw StateError('Лимит файла — 8 ТБ');
    if (_paths.containsValue(canonical)) return;
    _paths[randomToken(16)] = canonical;
    await _save();
  }

  Future<void> remove(String id) async {
    _paths.remove(id);
    await _save();
  }

  Future<File?> resolve(String id) async {
    final path = _paths[id];
    if (path == null) return null;
    try {
      final canonical = await File(path).resolveSymbolicLinks();
      if (!p.equals(canonical, path) ||
          await FileSystemEntity.type(path, followLinks: false) != FileSystemEntityType.file ||
          await File(path).length() > maxFileBytes) return null;
      return File(path);
    } on FileSystemException {
      return null;
    }
  }

  Future<List<SharedFile>> list() async {
    final result = <SharedFile>[];
    for (final id in _paths.keys.toList()) {
      final file = await resolve(id);
      if (file == null) continue;
      try {
        result.add(SharedFile(id: id, name: safeFilename(p.basename(file.path)),
          size: await file.length()));
      } on FileSystemException {
      }
    }
    return result;
  }
}
