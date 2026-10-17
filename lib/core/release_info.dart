import '../l10n/messages.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';

const appVersion = '0.3.0-alpha.4';

final _versionPattern = RegExp(r'^v?([0-9]{1,9})\.([0-9]{1,9})\.([0-9]{1,9})(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$');

int compareVersions(String a, String b) {
  final x = _versionPattern.firstMatch(a), y = _versionPattern.firstMatch(b);
  if (x == null || y == null) return x == null ? (y == null ? 0 : -1) : 1;
  for (var i = 1; i <= 3; i++) {
    final d = int.parse(x[i]!).compareTo(int.parse(y[i]!));
    if (d != 0) return d;
  }
  final preX = x[4], preY = y[4];
  if (preX == null || preY == null) return preX == null ? (preY == null ? 0 : 1) : -1;
  final left = preX.split('.'), right = preY.split('.');
  for (var i = 0; i < left.length && i < right.length; i++) {
    final l = int.tryParse(left[i]), r = int.tryParse(right[i]);
    final d = l != null && r != null ? l.compareTo(r) : l != null ? -1 : r != null ? 1 : left[i].compareTo(right[i]);
    if (d != 0) return d;
  }
  return left.length.compareTo(right.length);
}

Future<Map<String, String>?> checkRelease() async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    return await (() async {
      final request = await client.getUrl(Uri.parse('https://api.github.com/repos/resassance/LinkInDrop/releases?per_page=30'));
      request.headers.set(HttpHeaders.userAgentHeader, 'LinkInDrop/$appVersion');
      request.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final response = await request.close();
      if (response.statusCode != 200) throw HttpException(localizeMessage("Не удалось проверить обновления: {0}", [response.statusCode]));
      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
        if (bytes.length > 2 * 1024 * 1024) throw FormatException(localizeMessage("Ответ сервера слишком большой"));
      }
      final releases = (jsonDecode(utf8.decode(bytes)) as List).whereType<Map>().where((r) => r['draft'] != true && r['tag_name'] is String && _versionPattern.hasMatch(r['tag_name'] as String)).toList();
      releases.sort((a, b) => compareVersions(b['tag_name'] as String, a['tag_name'] as String));
      if (releases.isEmpty || compareVersions(releases.first['tag_name'] as String, appVersion) <= 0) return null;
      final tag = releases.first['tag_name'] as String;
      if (!RegExp(r'^v[0-9A-Za-z.+-]+$').hasMatch(tag)) throw const FormatException('Invalid release tag');
      return {'version': tag, 'url': 'https://github.com/resassance/LinkInDrop/releases/tag/$tag'};
    })().timeout(const Duration(seconds: 20));
  } finally { client.close(force: true); }
}

Future<void> openRelease(String url) async {
  final uri = Uri.parse(url);
  if (uri.scheme != 'https' || uri.host != 'github.com' || !uri.path.startsWith('/resassance/LinkInDrop/releases/')) throw const FormatException('Invalid release URL');
  if (Platform.isAndroid) {
    await const MethodChannel('linkindrop/system').invokeMethod<void>('openRelease', {'url': url});
  } else {
    final result = Platform.isWindows
      ? await Process.run('rundll32.exe', ['url.dll,FileProtocolHandler', url])
      : await Process.run('xdg-open', [url]);
    if (result.exitCode != 0) throw StateError(localizeMessage("Откройте {0} в браузере", [url]));
  }
}
