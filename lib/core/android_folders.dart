import 'dart:typed_data';
import 'dart:io';

import 'package:flutter/services.dart';

import 'models.dart';
import 'shared_folders.dart';

class AndroidFolders implements FolderProvider {
  const AndroidFolders();
  static final Map<String, int> _references = {};
  static const channel = MethodChannel('nearbridge/system');

  Future<T> _translate<T>(Future<T> Function() operation) async {
    try { return await operation(); } on PlatformException catch (error) {
      throw FileSystemException(error.message ?? 'Папка недоступна');
    }
  }

  Future<Map<String, dynamic>?> pick() => channel.invokeMapMethod<String, dynamic>('pickFolder');

  Future<List<String>> pickFiles() async =>
    (await channel.invokeListMethod<String>('pickSharedFiles')) ?? [];

  @override
  Future<Map<String, dynamic>> statDocument(String location) async {
    final value = await _translate<Map<String, dynamic>?>(() => channel.invokeMapMethod<String, dynamic>('statSharedDocument', {'uri': location}));
    if (value == null) throw const FileSystemException('Файл недоступен');
    return value;
  }

  @override
  Future<SharedRead> openDocument(String location, {int offset = 0, int? length}) =>
    _open('openSharedDocument', {'uri': location, 'offset': offset, 'length': length});

  @override
  Future<void> validate(String location) => _translate(() => channel.invokeMethod<void>('checkFolder', {'uri': location}));

  @override
  Future<void> retain(String location) async { _references[location] = (_references[location] ?? 0) + 1; }

  @override
  Future<void> revoke(String location) async {
    final remaining = (_references[location] ?? 1) - 1;
    if (remaining > 0) { _references[location] = remaining; return; }
    _references.remove(location);
    await _translate(() => channel.invokeMethod<void>('revokeFolder', {'uri': location}));
  }

  @override
  Future<SharedPage> list(String location, String id, String path, int offset) async {
    final value = await _translate(() => channel.invokeMapMethod<String, dynamic>('listFolder',
      {'uri': location, 'path': path, 'offset': offset}));
    if (value == null) throw StateError('Папка недоступна');
    final items = (value['files'] as List).map((raw) {
      final entry = Map<String, dynamic>.from(raw as Map);
      return SharedFile.fromJson({...entry, 'id': id, 'folderId': id});
    }).toList();
    return SharedPage(items, nextOffset: value['nextOffset'] as int?);
  }

  @override
  Future<SharedRead> open(String location, String path, {int offset = 0, int? length}) async {
    return _open('openFolderFile', {'uri': location, 'path': path, 'offset': offset, 'length': length});
  }

  Future<SharedRead> _open(String method, Map<String, dynamic> arguments) async {
    final value = await _translate(() => channel.invokeMapMethod<String, dynamic>(method, arguments));
    if (value == null) throw StateError('Файл недоступен');
    final reader = value['reader'] as String;
    var closed = false;
    Future<void> close() async {
      if (closed) return;
      closed = true;
      await channel.invokeMethod<void>('closeFolderFile', {'reader': reader});
    }
    Stream<List<int>> stream() async* {
      try {
        while (!closed) {
          final bytes = await channel.invokeMethod<Uint8List>('readFolderFile', {'reader': reader});
          if (bytes == null || bytes.isEmpty) break;
          yield bytes;
        }
      } finally {
        await close();
      }
    }
    return SharedRead(value['size'] as int, stream(), close, version: value['version'] as String?);
  }
}
