import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';

const appVersion = '0.3.0-alpha.1';

int compareVersions(String a, String b) {
  List<int> parts(String v) => RegExp(r'\d+').allMatches(v.replaceFirst(RegExp(r'^v'), '')).map((m) => int.parse(m[0]!)).toList();
  final x = parts(a), y = parts(b);
  for (var i = 0; i < 3; i++) {
    final d = (i < x.length ? x[i] : 0).compareTo(i < y.length ? y[i] : 0);
    if (d != 0) return d;
  }
  if (a.contains('-') != b.contains('-')) return a.contains('-') ? -1 : 1;
  for (var i = 3; i < x.length || i < y.length; i++) {
    final d = (i < x.length ? x[i] : 0).compareTo(i < y.length ? y[i] : 0);
    if (d != 0) return d;
  }
  return 0;
}

Future<Map<String, String>?> checkRelease() async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    return await (() async {
      final request = await client.getUrl(Uri.parse('https://api.github.com/repos/resassance/nearbridge/releases?per_page=30'));
      request.headers.set(HttpHeaders.userAgentHeader, 'Nearbridge/$appVersion');
      request.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final response = await request.close();
      if (response.statusCode != 200) throw HttpException('Не удалось проверить обновления: ${response.statusCode}');
      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
        if (bytes.length > 2 * 1024 * 1024) throw const FormatException('Ответ сервера слишком большой');
      }
      final releases = (jsonDecode(utf8.decode(bytes)) as List).whereType<Map>().where((r) => r['draft'] != true && r['tag_name'] is String).toList();
      releases.sort((a, b) => compareVersions(b['tag_name'] as String, a['tag_name'] as String));
      if (releases.isEmpty || compareVersions(releases.first['tag_name'] as String, appVersion) <= 0) return null;
      final tag = releases.first['tag_name'] as String;
      if (!RegExp(r'^v[0-9A-Za-z.+-]+$').hasMatch(tag)) throw const FormatException('Invalid release tag');
      return {'version': tag, 'url': 'https://github.com/resassance/nearbridge/releases/tag/$tag'};
    })().timeout(const Duration(seconds: 20));
  } finally { client.close(force: true); }
}

Future<void> openRelease(String url) async {
  final uri = Uri.parse(url);
  if (uri.scheme != 'https' || uri.host != 'github.com' || !uri.path.startsWith('/resassance/nearbridge/releases/')) throw const FormatException('Invalid release URL');
  if (Platform.isAndroid) {
    await const MethodChannel('nearbridge/system').invokeMethod<void>('openRelease', {'url': url});
  } else {
    final result = Platform.isWindows
      ? await Process.run('rundll32.exe', ['url.dll,FileProtocolHandler', url])
      : await Process.run('xdg-open', [url]);
    if (result.exitCode != 0) throw StateError('Откройте $url в браузере');
  }
}
