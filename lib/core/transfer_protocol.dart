import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'models.dart';

const transferBlockBytes = 4 * 1024 * 1024;

String contentVersion(int size, DateTime modified) =>
  sha256.convert(utf8.encode('$size:${modified.microsecondsSinceEpoch}')).toString();

String portablePath(String relative) {
  if (!isSharedPath(relative) || relative.isEmpty) throw const FormatException('Invalid destination');
  return relative.split('/').map((part) {
    final safe = safeFilename(part);
    return safe == part ? safe : '${safe.substring(0, min(safe.length, 100))}_${sha256.convert(utf8.encode(part)).toString().substring(0, 8)}';
  }).join('/');
}

Future<File> inboxDestination(Directory inbox, String relative) async {
  final clean = portablePath(relative);
  final path = p.joinAll([inbox.path, ...clean.split('/')]);
  final root = await inbox.resolveSymbolicLinks();
  var current = inbox.path;
  for (final part in clean.split('/').take(clean.split('/').length - 1)) {
    current = p.join(current, part);
    final type = await FileSystemEntity.type(current, followLinks: false);
    if (type == FileSystemEntityType.notFound) await Directory(current).create();
    final resolved = await Directory(current).resolveSymbolicLinks();
    if (!p.equals(resolved, current) || !p.isWithin(root, resolved)) {
      throw const FileSystemException('Unsafe destination');
    }
  }
  if (await FileSystemEntity.type(path, followLinks: false) != FileSystemEntityType.notFound) {
    throw const FileSystemException('Destination already exists');
  }
  return File(path);
}

Future<void> inboxDirectory(Directory inbox, String relative) async {
  final clean = portablePath(relative);
  final root = await inbox.resolveSymbolicLinks();
  var current = inbox.path;
  for (final part in clean.split('/')) {
    current = p.join(current, part);
    final type = await FileSystemEntity.type(current, followLinks: false);
    if (type == FileSystemEntityType.notFound) await Directory(current).create();
    final resolved = await Directory(current).resolveSymbolicLinks();
    if (!p.equals(resolved, current) || !p.isWithin(root, resolved)) throw const FileSystemException('Unsafe destination');
  }
}

class TransferStopped implements Exception {
  const TransferStopped();
  @override
  String toString() => 'Передача приостановлена';
}

class UploadStore {
  UploadStore(this.directory, this.inbox);
  final Directory directory;
  final Directory inbox;
  final Set<String> _busy = {};
  Directory get state => Directory(p.join(directory.path, 'uploads'));
  String _key(String peer, String id) => sha256.convert(utf8.encode('$peer:$id')).toString();
  File _meta(String key) => File(p.join(state.path, '$key.json'));
  File _part(String key) => File(p.join(state.path, '$key.part'));

  Future<T> _locked<T>(String key, Future<T> Function() action) async {
    if (!_busy.add(key)) throw StateError('Передача занята');
    try { return await action(); } finally { _busy.remove(key); }
  }

  void _validateId(String id) {
    if (!RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(id)) throw const FormatException('Invalid transfer ID');
  }

  Future<Map<String, dynamic>> _load(String key) async {
    final file = _meta(key);
    if (!await file.exists()) throw const FileSystemException('Upload not found');
    final value = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    if (value['finalizing'] == true && value['output'] is String) {
      final output = File(p.joinAll([inbox.path, ...portablePath(value['output'] as String).split('/')]));
      if (await output.exists() && (await sha256.bind(output.openRead()).first).toString() == value['sha256']) {
        value['done'] = true;
        value.remove('finalizing');
        await _save(key, value);
      }
    }
    return value;
  }

  Future<void> _save(String key, Map<String, dynamic> data) async {
    final file = File('${_meta(key).path}.new');
    await file.writeAsString(jsonEncode(data), flush: true);
    await file.rename(_meta(key).path);
  }

  Future<Map<String, dynamic>> start(String peer, Map<String, dynamic> value) async {
    final id = value['id'];
    if (id is! String) throw const FormatException('Missing transfer ID');
    _validateId(id);
    final size = value['size'];
    final digest = value['sha256'];
    final name = value['name'];
    final relative = value['relative'];
    if (size is! int || size < 0 || size > maxFileBytes || digest is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest) || name is! String || name.length > 255 ||
        (relative != null && (relative is! String || !isSharedPath(relative) || relative.isEmpty))) {
      throw const FormatException('Invalid upload metadata');
    }
    final key = _key(peer, id);
    return _locked(key, () async {
      await state.create(recursive: true);
      if (await _meta(key).exists()) {
        final old = await _load(key);
        if (old['size'] != size || old['sha256'] != digest || old['relative'] != relative || old['name'] != name) {
          throw const FormatException('Transfer source changed. Create a new transfer.');
        }
        if (old['done'] == true) return {'offset': size, 'done': true, 'sha256': digest};
        return {'offset': await _part(key).exists() ? await _part(key).length() : 0, 'done': false};
      }
      await _save(key, {'id': id, 'size': size, 'name': name, 'relative': relative,
        'sha256': digest, 'created': DateTime.now().millisecondsSinceEpoch, 'done': false});
      await _part(key).writeAsBytes([]);
      return {'offset': 0, 'done': false};
    });
  }

  Future<Map<String, dynamic>> block(String peer, String id, int offset, Uint8List bytes, String digest) async {
    _validateId(id);
    if (bytes.isEmpty || bytes.length > transferBlockBytes || offset < 0 ||
        !secureEquals(sha256.convert(bytes).toString(), digest)) throw const FormatException('Invalid block');
    final key = _key(peer, id);
    return _locked(key, () async {
      final meta = await _load(key);
      if (meta['done'] == true) return {'offset': meta['size'], 'done': true};
      final file = _part(key);
      final length = await file.length();
      if (offset + bytes.length > (meta['size'] as int)) throw const FormatException('Invalid block length');
      if (offset < length && offset + bytes.length <= length) {
        final existing = await file.openRead(offset, offset + bytes.length).fold(BytesBuilder(), (b, c) => b..add(c));
        if (secureEquals(sha256.convert(existing.takeBytes()).toString(), digest)) return {'offset': length};
      }
      if (offset != length) throw const FormatException('Invalid block offset');
      final output = await file.open(mode: FileMode.append);
      try { await output.writeFrom(bytes); await output.flush(); } finally { await output.close(); }
      return {'offset': length + bytes.length};
    });
  }

  Future<Map<String, dynamic>> complete(String peer, String id) async {
    _validateId(id);
    final key = _key(peer, id);
    return _locked(key, () async {
      final meta = await _load(key);
      if (meta['done'] == true) return {'done': true, 'sha256': meta['sha256']};
      final file = _part(key);
      if (await file.length() != meta['size']) throw const FormatException('Incomplete upload');
      final digest = (await sha256.bind(file.openRead()).first).toString();
      if (!secureEquals(digest, meta['sha256'] as String)) {
        await file.writeAsBytes([]);
        throw const FormatException('File checksum mismatch');
      }
      final relative = meta['relative'] as String? ?? '${randomToken(8)}_${safeFilename(meta['name'] as String)}';
      var target = await inboxDestination(inbox, relative);
      if (await target.exists()) throw const FileSystemException('Destination already exists');
      meta['output'] = p.relative(target.path, from: inbox.path);
      meta['finalizing'] = true;
      await _save(key, meta);
      await file.rename(target.path);
      meta['done'] = true;
      meta.remove('finalizing');
      await _save(key, meta);
      return {'done': true, 'sha256': digest, 'path': target.path};
    });
  }

  Future<void> cancel(String peer, String id) async {
    _validateId(id);
    final key = _key(peer, id);
    await _locked(key, () async {
      if (await _part(key).exists()) await _part(key).delete();
      if (await _meta(key).exists()) await _meta(key).delete();
    });
  }
}
