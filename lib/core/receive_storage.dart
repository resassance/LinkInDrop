import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'transfer_protocol.dart';
import 'shared_folders.dart';

class InsufficientSpace implements Exception {
  const InsufficientSpace();
  @override
  String toString() => 'Недостаточно свободного места для получения файла';
}

Future<int?> freeBytes(String path) async {
  if (Platform.isAndroid) return const MethodChannel('nearbridge/system').invokeMethod<int>('freeBytes', {'path': path});
  final result = Platform.isWindows
    ? await Process.run('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', r'(Get-Item -LiteralPath $env:NB_STORAGE_PATH).PSDrive.Free'], environment: {'NB_STORAGE_PATH': path})
    : await Process.run('df', ['-Pk', path]);
  if (result.exitCode != 0) return null;
  if (Platform.isWindows) return int.tryParse('${result.stdout}'.trim());
  final lines = '${result.stdout}'.trim().split('\n');
  final fields = lines.last.trim().split(RegExp(r'\s+'));
  return fields.length >= 4 ? (int.tryParse(fields[3]) ?? 0) * 1024 : null;
}

Future<void> requireSpace(String path, int bytes) async {
  final free = await freeBytes(path);
  if (free != null && free < bytes + 16 * 1024 * 1024) throw const InsufficientSpace();
}

class ReceiveStorage {
  ReceiveStorage(this.directory, this.inbox);
  final Directory directory;
  final Directory inbox;
  String? destination;
  String conflict = 'rename';
  final Map<String, Map<String, dynamic>> receipts = {};
  final Map<String, String> _verifiedVersions = {};
  Future<void> _saving = Future.value();
  Future<void> _delivering = Future.value();
  final channel = const MethodChannel('nearbridge/system');

  Future<void> _protectDestination(String root, String relative) async {
    if (await Directory(root).resolveSymbolicLinks() != root) throw const FileSystemException('Unsafe destination');
    final private = await directory.resolveSymbolicLinks();
    final target = p.joinAll([root, ...portablePath(relative).split('/')]);
    if (p.equals(private, target) || p.isWithin(private, target)) throw const FileSystemException('Нельзя получать файлы в служебные данные Nearbridge');
  }

  Future<void> createDirectory(String relative) async {
    if (destination != null && !destination!.startsWith('content://')) await _protectDestination(destination!, relative);
    await inboxDirectory(inbox, relative);
    if (destination == null) return;
    if (destination!.startsWith('content://')) {
      await channel.invokeMethod<void>('createReceivedDirectory', {'tree': destination, 'relative': portablePath(relative)});
    } else { await inboxDirectory(Directory(destination!), relative); }
  }

  Future<SharedRead> open(String peer, String token, int offset, int? length) async {
    final item = receipts[token];
    if (item == null || item['peer'] != peer || item['skipped'] == true) throw const FileSystemException('Copy unavailable');
    final location = item['location'] as String;
    if (!location.startsWith('content://')) {
      final file = await readable(peer, token);
      final stat = await file.stat();
      if (offset > stat.size) throw const FileSystemException('Source changed');
      final version = contentVersion(stat.size, stat.modified);
      if (_verifiedVersions[token] != version) {
        if ((await sha256.bind(file.openRead()).first).toString() != item['sha256']) throw const FileSystemException('Backup copy was changed');
        _verifiedVersions[token] = version;
      }
      final end = length == null || offset + length > stat.size ? stat.size : offset + length;
      return SharedRead(stat.size, file.openRead(offset, end), () async {}, version: contentVersion(stat.size, stat.modified));
    }
    final value = await channel.invokeMapMethod<String, dynamic>('openReceived', {'location': location, 'offset': offset, 'length': length});
    final reader = value!['reader'] as String;
    final version = value['version'] as String?;
    var closed = false;
    Future<void> close() async { if (!closed) { closed = true; await channel.invokeMethod<void>('closeFolderFile', {'reader': reader}); } }
    if (version == null || version.startsWith('0:') || _verifiedVersions[token] != version) {
      if (!await verify(peer, token, item['sha256'] as String)) { await close(); throw const FileSystemException('Backup copy was changed'); }
      if (version != null) _verifiedVersions[token] = version;
    }
    Stream<List<int>> stream() async* {
      try {
        while (!closed) {
          final chunk = await channel.invokeMethod<List<dynamic>>('readFolderFile', {'reader': reader});
          if (chunk == null || chunk.isEmpty) break;
          yield chunk.cast<int>();
        }
      } finally { await close(); }
    }
    return SharedRead(value['size'] as int, stream(), close, version: value['version'] as String?);
  }

  Future<void> load() async {
    final file = File(p.join(directory.path, 'receipts.json'));
    if (await file.exists()) {
      final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      for (final entry in data.entries) { receipts[entry.key] = (entry.value as Map).cast<String, dynamic>(); }
    }
  }
  Future<void> _save() {
    final content = jsonEncode(receipts);
    return _saving = _saving.catchError((Object _) {}).then((_) async {
      final file = File(p.join(directory.path, 'receipts.json.new'));
      await file.writeAsString(content, flush: true);
      await file.rename(p.join(directory.path, 'receipts.json'));
    });
  }
  String key(String peer, String id) => sha256.convert(utf8.encode('$peer:$id')).toString();

  Future<Map<String, dynamic>> deliver(String peer, String id, File source, String relative, String digest) {
    final result = _delivering.catchError((Object _) {}).then((_) => _deliver(peer, id, source, relative, digest));
    _delivering = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }
  Future<Map<String, dynamic>> _deliver(String peer, String id, File source, String relative, String digest) async {
    final token = key(peer, id);
    if (receipts.containsKey(token)) return receipts[token]!;
    if (await FileSystemEntity.type(source.path, followLinks: false) != FileSystemEntityType.file || await source.resolveSymbolicLinks() != source.path) throw const FileSystemException('Unsafe source');
    final size = await source.length();
    var location = source.path;
    var skipped = false;
    final root = destination ?? inbox.path;
    if (root.startsWith('content://')) {
      final result = await channel.invokeMapMethod<String, dynamic>('exportReceived', {
        'tree': root, 'source': source.path, 'relative': portablePath(relative), 'policy': conflict, 'digest': digest});
      location = result!['location'] as String;
      skipped = result['skipped'] == true;
    } else {
      final folder = Directory(root);
      final canonical = await folder.resolveSymbolicLinks();
      if (canonical != root || (destination != null && (p.equals(canonical, directory.path) || p.isWithin(directory.path, canonical)))) throw const FileSystemException('Выберите папку вне данных Nearbridge');
      if (destination != null) await _protectDestination(root, relative);
      await requireSpace(root, size);
      var relativeName = portablePath(relative);
      var target = File(p.joinAll([root, ...relativeName.split('/')]));
      if (target.path != source.path && await FileSystemEntity.type(target.path, followLinks: false) != FileSystemEntityType.notFound) {
        if (conflict == 'skip') {
          skipped = true;
          location = target.path;
        } else if (conflict == 'rename') {
          final base = p.posix.withoutExtension(relativeName), ext = p.posix.extension(relativeName);
          var n = 1;
          do { relativeName = '$base ($n)$ext'; n++; target = File(p.joinAll([root, ...relativeName.split('/')])); }
          while (await FileSystemEntity.type(target.path, followLinks: false) != FileSystemEntityType.notFound);
        }
      }
      if (!skipped && target.path != source.path) {
        if (p.posix.dirname(relativeName) != '.') await inboxDirectory(folder, p.posix.dirname(relativeName));
        final type = await FileSystemEntity.type(target.path, followLinks: false);
        if (type != FileSystemEntityType.notFound && type != FileSystemEntityType.file) throw const FileSystemException('Unsafe destination');
        if (type == FileSystemEntityType.file && await target.resolveSymbolicLinks() != target.path) throw const FileSystemException('Unsafe destination');
        final temporary = File('${target.path}.$token.tmp');
        try {
          await source.copy(temporary.path);
          if ((await sha256.bind(temporary.openRead()).first).toString() != digest) throw const FileSystemException('Checksum mismatch');
          await temporary.rename(target.path);
        } finally { if (await temporary.exists()) await temporary.delete(); }
        location = target.path;
      }
    }
    final receipt = <String, dynamic>{'peer': peer, 'id': id, 'name': p.basename(relative), 'relative': relative,
      'size': size, 'sha256': digest, 'location': location, 'skipped': skipped};
    receipts[token] = receipt;
    try { await _save(); } catch (_) { receipts.remove(token); rethrow; }
    if (location != source.path && await source.exists()) await source.delete();
    return receipt;
  }

  Future<bool> verify(String peer, String token, String digest) async {
    final item = receipts[token];
    if (item == null || item['peer'] != peer || item['sha256'] != digest || item['skipped'] == true) return false;
    final location = item['location'] as String;
    try {
      if (location.startsWith('content://')) return await channel.invokeMethod<bool>('verifyReceived', {'location': location, 'digest': digest}) == true;
      final file = File(location);
      if (await FileSystemEntity.type(location, followLinks: false) != FileSystemEntityType.file || await file.resolveSymbolicLinks() != location || await file.length() != item['size']) return false;
      return (await sha256.bind(file.openRead()).first).toString() == digest;
    } on FileSystemException { return false; }
  }

  Future<File> readable(String peer, String token) async {
    final item = receipts[token];
    if (item == null || item['peer'] != peer || item['skipped'] == true) throw const FileSystemException('Copy unavailable');
    final location = item['location'] as String;
    if (location.startsWith('content://')) throw const FileSystemException('Восстановление этой копии выполняется через папку Android');
    if (await FileSystemEntity.type(location, followLinks: false) != FileSystemEntityType.file || await File(location).resolveSymbolicLinks() != location) throw const FileSystemException('Copy unavailable');
    return File(location);
  }
}
