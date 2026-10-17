import '../l10n/messages.dart';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'models.dart';
import 'transfer_protocol.dart';

class SharedRead {
  SharedRead(this.size, this.stream, this.close, {this.version});
  final int size;
  final String? version;
  final Stream<List<int>> stream;
  final Future<void> Function() close;
}

abstract class FolderProvider {
  Future<void> validate(String location);
  Future<SharedPage> list(String location, String id, String path, int offset);
  Future<SharedRead> open(String location, String path, {int offset = 0, int? length});
  Future<Map<String, dynamic>> statDocument(String location) async => throw const FileSystemException('Document provider unavailable');
  Future<SharedRead> openDocument(String location, {int offset = 0, int? length}) async => throw const FileSystemException('Document provider unavailable');
  Future<void> retain(String location) async {}
  Future<void> revoke(String location);
}

class SharedFolders {
  SharedFolders(this.directory, {this.documents, this.stateFilename = 'shared-folders.json'});
  final String stateFilename;
  final Directory directory;
  final FolderProvider? documents;
  final Map<String, Map<String, String>> _roots = {};
  Future<void> _saveQueue = Future.value();
  File get _state => File(p.join(directory.path, stateFilename));

  Future<void> load() async {
    if (!await _state.exists()) return;
    final data = jsonDecode(await _state.readAsString()) as Map<String, dynamic>;
    for (final entry in data.entries) {
      final value = entry.value;
      if (RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(entry.key) &&
          value is Map && value['location'] is String && value['name'] is String) {
        _roots[entry.key] = {'location': value['location'] as String,
          'name': value['name'] as String};
        if (_document(value['location'] as String)) await documents?.retain(value['location'] as String);
      }
    }
  }

  Future<void> _save() {
    final content = jsonEncode(_roots);
    _saveQueue = _saveQueue.catchError((Object _) {}).then((_) async {
      final temporary = File('${_state.path}.new');
      await temporary.writeAsString(content, flush: true);
      await temporary.rename(_state.path);
    });
    return _saveQueue;
  }

  bool _document(String location) => location.startsWith('content://');

  Future<String> _localTarget(String root, String path) async {
    if (!isSharedPath(path)) throw const FormatException('Invalid shared path');
    final private = await directory.resolveSymbolicLinks();
    final canonicalRoot = await Directory(root).resolveSymbolicLinks();
    if (!p.equals(canonicalRoot, root) ||
        await FileSystemEntity.type(root, followLinks: false) != FileSystemEntityType.directory) {
      throw const FileSystemException('Shared folder unavailable');
    }
    final target = p.joinAll([root, ...path.split('/').where((e) => e.isNotEmpty)]);
    final canonical = await File(target).resolveSymbolicLinks();
    if (!p.equals(canonical, target) ||
        (!p.equals(root, canonical) && !p.isWithin(root, canonical)) ||
        p.equals(private, canonical) || p.isWithin(private, canonical)) {
      throw const FileSystemException('Path is outside the shared folder');
    }
    return canonical;
  }

  Future<void> add(String location, {String? name}) async {
    if (_roots.values.any((r) => r['location'] == location)) return;
    if (_roots.length >= 50) throw StateError(localizeMessage("Можно открыть доступ к 50 папкам"));
    if (_document(location)) {
      if (documents == null) throw StateError(localizeMessage("Документы Android недоступны"));
      await documents!.validate(location);
    } else {
      location = p.normalize(p.absolute(location));
      await _localTarget(location, '');
    }
    if (_roots.values.any((r) => r['location'] == location)) return;
    _roots[randomToken(16)] = {'location': location,
      'name': safeFilename(name ?? p.basename(location))};
    if (_document(location)) await documents?.retain(location);
    await _save();
  }

  Future<void> remove(String id) async {
    final root = _roots.remove(id);
    await _save();
    if (root != null && _document(root['location']!)) {
      await documents?.revoke(root['location']!);
    }
  }

  List<SharedFile> roots() => _roots.entries.map((entry) => SharedFile(
    id: entry.key, name: entry.value['name']!, size: 0, isDirectory: true,
    folderId: entry.key, relativePath: '', rootName: entry.value['name'])).toList();

  Future<SharedPage> list(String id, String path, {int offset = 0}) async {
    if (!isSharedPath(path) || offset < 0 || offset > 100000) {
      throw const FormatException('Invalid directory request');
    }
    final root = _roots[id];
    if (root == null) throw const FileSystemException('Folder not shared');
    final location = root['location']!;
    if (_document(location)) {
      if (documents == null) throw const FileSystemException('Document provider unavailable');
      final page = await documents!.list(location, id, path, offset);
      return SharedPage(page.entries.map((entry) => SharedFile.fromJson({...entry.toJson(), 'rootName': root['name']})).toList(), nextOffset: page.nextOffset);
    }
    final target = await _localTarget(location, path);
    final entries = <SharedFile>[];
    var skipped = 0;
    await for (final child in Directory(target).list(followLinks: false)) {
      final name = p.basename(child.path);
      final relative = path.isEmpty ? name : '$path/$name';
      if (!isSharedPath(relative) || child is Link) continue;
      try {
        final resolved = await _localTarget(location, relative);
        final stat = await FileStat.stat(resolved);
        final isDirectory = stat.type == FileSystemEntityType.directory;
        if (!isDirectory && (stat.type != FileSystemEntityType.file || stat.size > maxFileBytes)) continue;
        if (skipped++ < offset) continue;
        if (entries.length == 200) return SharedPage(entries, nextOffset: offset + 200);
        entries.add(SharedFile(id: id, folderId: id, relativePath: relative,
          name: safeFilename(name), size: isDirectory ? 0 : stat.size, isDirectory: isDirectory,
          version: contentVersion(stat.size, stat.modified), modifiedAt: stat.modified, rootName: root['name']));
      } on FileSystemException {
      }
    }
    return SharedPage(entries);
  }

  Future<SharedRead> open(String id, String path, {int offset = 0, int? length}) async {
    if (offset < 0 || (length != null && length < 0) || !isSharedPath(path) || path.isEmpty) throw const FormatException('Invalid file path');
    final root = _roots[id];
    if (root == null) throw const FileSystemException('Folder not shared');
    final location = root['location']!;
    if (_document(location)) {
      if (documents == null) throw const FileSystemException('Document provider unavailable');
      return documents!.open(location, path, offset: offset, length: length);
    }
    final target = await _localTarget(location, path);
    final stat = await FileStat.stat(target);
    if (stat.type != FileSystemEntityType.file || stat.size > maxFileBytes) {
      throw const FileSystemException('File unavailable');
    }
    if (offset > stat.size) throw const FileSystemException('Source changed');
    final end = length == null ? stat.size : (offset + length < stat.size ? offset + length : stat.size);
    return SharedRead(stat.size, File(target).openRead(offset, end), () async {},
      version: contentVersion(stat.size, stat.modified));
  }
}
