import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'models.dart';
import 'shared_folders.dart';
import 'transfer_protocol.dart';

class SharedFiles {
  SharedFiles(this.directory, {this.documents});
  final FolderProvider? documents;
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
          if ((entry.value as String).startsWith('content://')) await documents?.retain(entry.value as String);
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
    if (path.startsWith('content://')) {
      if (documents == null) throw StateError('Документы Android недоступны');
      final info = await documents!.statDocument(path);
      if (info['size'] is! int || (info['size'] as int) < 0 || (info['size'] as int) > maxFileBytes) throw StateError('Недопустимый размер файла');
      if (_paths.containsValue(path)) return;
      _paths[randomToken(16)] = path;
      await documents!.retain(path);
      await _save();
      return;
    }
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
    final location = _paths.remove(id);
    await _save();
    if (location?.startsWith('content://') == true) await documents?.revoke(location!);
  }

  Future<File?> resolve(String id) async {
    final path = _paths[id];
    if (path == null || path.startsWith('content://')) return null;
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

  Future<SharedFile?> metadata(String id) async {
    final location = _paths[id];
    if (location == null) return null;
    if (location.startsWith('content://')) {
      if (documents == null) return null;
      try {
        final info = await documents!.statDocument(location);
        return SharedFile.fromJson({...info, 'id': id, 'name': safeFilename(info['name'] as String)});
      } on FileSystemException { return null; }
    }
    final file = await resolve(id);
    if (file == null) return null;
    final stat = await file.stat();
    return SharedFile(id: id, name: safeFilename(p.basename(file.path)), size: stat.size,
      modifiedAt: stat.modified, version: contentVersion(stat.size, stat.modified));
  }

  Future<SharedRead> open(String id, {int offset = 0, int? length}) async {
    final location = _paths[id];
    if (location == null || offset < 0 || (length != null && length < 0)) throw const FileSystemException('File unavailable');
    if (location.startsWith('content://')) {
      if (documents == null) throw const FileSystemException('Document provider unavailable');
      return documents!.openDocument(location, offset: offset, length: length);
    }
    final file = await resolve(id);
    if (file == null) throw const FileSystemException('File unavailable');
    final stat = await file.stat();
    if (offset > stat.size) throw const FileSystemException('Source changed');
    final end = length == null ? stat.size : (offset + length < stat.size ? offset + length : stat.size);
    return SharedRead(stat.size, file.openRead(offset, end), () async {}, version: contentVersion(stat.size, stat.modified));
  }

  Future<List<SharedFile>> list() async {
    final result = <SharedFile>[];
    for (final id in _paths.keys.toList()) {
      try {
        final entry = await metadata(id);
        if (entry != null) result.add(entry);
      } on FileSystemException {
      }
    }
    return result;
  }
}
