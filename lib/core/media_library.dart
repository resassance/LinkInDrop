import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'dart:async';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart';

class LibraryItem {
  const LibraryItem({required this.uri, required this.name, required this.size, this.video = false, this.duration = 0});
  factory LibraryItem.fromMap(Map value) => LibraryItem(uri: value['uri'] as String, name: value['name'] as String,
    size: (value['size'] as num).toInt(), video: value['video'] == true, duration: (value['duration'] as num? ?? 0).toInt());
  final String uri;
  final String name;
  final int size;
  final bool video;
  final int duration;
}

class MediaLibrary {
  const MediaLibrary();
  static const channel = MethodChannel('linkindrop/system');
  Future<String> access({bool request = false}) async => await channel.invokeMethod<String>('mediaAccess', {'request': request}) ?? 'denied';
  Future<List<Map<String, String>>> albums() async => ((await channel.invokeListMethod<dynamic>('mediaAlbums')) ?? [])
    .map((value) => Map<String, String>.from(value as Map)).toList();
  Future<List<LibraryItem>> page({String? album, int offset = 0}) async => ((await channel.invokeListMethod<dynamic>('mediaPage', {'album': album, 'offset': offset})) ?? [])
    .map((value) => LibraryItem.fromMap(value as Map)).toList();
  Future<List<String>> importItems(List<String> uris) async => await channel.invokeListMethod<String>('importMedia', {'uris': uris}) ?? [];
  Future<List<String>> pickMedia() async => await channel.invokeListMethod<String>('pickMedia') ?? [];
  Future<String?> exportFolder(String uri) => channel.invokeMethod<String>('importFolder', {'uri': uri});
  static Future<Uint8List?> thumbnail(String location, {bool video = false}) async {
    if (defaultTargetPlatform != TargetPlatform.android && !location.startsWith('content://')) {
      if (!video) return null;
      try {
        final stat = await File(location).stat();
        final directory = Directory('${(await getTemporaryDirectory()).path}/linkindrop-thumbnails');
        await directory.create(recursive: true);
        final key = sha256.convert(utf8.encode('$location:${stat.size}:${stat.modified}'));
        final target = File('${directory.path}/$key.jpg');
        if (await target.exists()) return target.readAsBytes();
        late Process process;
        if (Platform.isWindows) {
          final script = File('${directory.path}/media-thumbnail.ps1');
          if (!await script.exists()) await script.writeAsString(await rootBundle.loadString('assets/windows/media-thumbnail.ps1'));
          process = await Process.start('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', script.path, '-Path', location, '-Output', target.path]);
        } else {
          process = await Process.start('ffmpeg', ['-v', 'error', '-i', location, '-frames:v', '1', '-vf', 'scale=640:480:force_original_aspect_ratio=decrease', '-y', target.path]);
        }
        final output = process.stdout.drain<void>();
        final errors = process.stderr.drain<void>();
        final timer = Timer(const Duration(seconds: 15), () => process.kill());
        final code = await process.exitCode;
        timer.cancel();
        await Future.wait([output, errors]);
        if (code != 0 || !await target.exists()) return null;
        return target.readAsBytes();
      } catch (_) { return null; }
    }
    try { return await channel.invokeMethod<Uint8List>('mediaThumbnail', {'uri': location, 'video': video}); }
    on PlatformException { return null; } on MissingPluginException { return null; }
  }
}
