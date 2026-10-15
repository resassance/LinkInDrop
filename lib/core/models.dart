import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const protocolVersion = 1;
const maxClipboardBytes = 8 * 1024 * 1024;
const maxTextBytes = 256 * 1024;
const maxFileBytes = 2 * 1024 * 1024 * 1024;

String randomToken([int bytes = 32]) {
  final random = Random.secure();
  return base64Url.encode(List.generate(bytes, (_) => random.nextInt(256)))
      .replaceAll('=', '');
}

bool secureEquals(String a, String b) {
  final left = utf8.encode(a);
  final right = utf8.encode(b);
  var difference = left.length ^ right.length;
  for (var i = 0; i < left.length; i++) {
    difference |= left[i] ^ (i < right.length ? right[i] : 0);
  }
  return difference == 0;
}

String certificateFingerprint(String pem) {
  final body = pem.replaceAll(RegExp(r'-----[^-]+-----|\s'), '');
  return sha256.convert(base64.decode(body)).toString();
}

String safeFilename(String name) {
  var result = name.split(RegExp(r'[/\\]')).last
      .replaceAll(RegExp(r'[\x00-\x1f<>:"/\\|?*]'), '_')
      .replaceAll(RegExp(r'[. ]+$'), '');
  if (result.isEmpty || result == '.' || result == '..') result = 'file';
  if (RegExp(r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])($|\.)',
      caseSensitive: false).hasMatch(result)) result = '_$result';
  if (result.length > 120) result = result.substring(result.length - 120);
  return result;
}

bool isLocalAddress(String host) {
  final address = InternetAddress.tryParse(host);
  if (address == null || address.type != InternetAddressType.IPv4) return false;
  final b = address.rawAddress;
  return b[0] == 10 || b[0] == 127 ||
      (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
      (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254);
}

// VPNs such as Tailscale use 100.64.0.0/10. Keep discovery LAN-only,
// but allow a user-provided VPN/public IPv4 address or DNS endpoint.
bool isConnectionHost(String host) {
  if (host.isEmpty || host.length > 253 || host != host.trim()) return false;
  final address = InternetAddress.tryParse(host);
  if (address != null) {
    if (address.type != InternetAddressType.IPv4) return false;
    final b = address.rawAddress;
    return b[0] != 0 && b[0] < 224 && host != '255.255.255.255';
  }
  if (RegExp(r'^[0-9.]+$').hasMatch(host)) return false;
  return host.split('.').every((label) => label.length <= 63 &&
    RegExp(r'^[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?$').hasMatch(label));
}

class PairInvite {
  PairInvite({required this.id, required this.name, required this.host,
    required this.port, required this.fingerprint, required this.secret,
    required this.expiresAt, this.hosts = const []});

  final String id;
  final String name;
  final String host;
  final int port;
  final String fingerprint;
  final String secret;
  final DateTime expiresAt;
  final List<String> hosts;

  String encode() => 'nearbridge://pair/${base64Url.encode(utf8.encode(jsonEncode({
    'v': protocolVersion, 'id': id, 'name': name, 'host': host, 'port': port,
    'fingerprint': fingerprint, 'secret': secret,
    'expires': expiresAt.millisecondsSinceEpoch,
    'hosts': hosts,
  }))).replaceAll('=', '')}';

  static PairInvite parse(String value) {
    final text = value.trim();
    if (text.length > 4096 || !text.startsWith('nearbridge://pair/')) {
      throw const FormatException('Неверный код подключения');
    }
    final data = jsonDecode(utf8.decode(base64Url.decode(
      base64Url.normalize(text.substring('nearbridge://pair/'.length)))));
    if (data is! Map<String, dynamic> || data['v'] != protocolVersion ||
        data['host'] is! String || !isConnectionHost(data['host'] as String) ||
        data['port'] is! int || (data['port'] as int) < 1 ||
        (data['port'] as int) > 65535 || data['expires'] is! int ||
        data['id'] is! String || data['name'] is! String ||
        data['fingerprint'] is! String || data['secret'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(data['fingerprint'] as String) ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(data['secret'] as String)) {
      throw const FormatException('Неверный код подключения');
    }
    final expires = DateTime.fromMillisecondsSinceEpoch(data['expires'] as int);
    if (!expires.isAfter(DateTime.now())) {
      throw const FormatException('Код истёк. Создайте новый');
    }
    return PairInvite(id: data['id'] as String, name: data['name'] as String,
      host: data['host'] as String, port: data['port'] as int,
      fingerprint: data['fingerprint'] as String, secret: data['secret'] as String,
      expiresAt: expires,
      hosts: connectionHosts(data['hosts']));
  }
}

class Peer {
  Peer({required this.id, required this.name, required this.host,
    required this.port, required this.fingerprint, required this.incomingToken,
    required this.outgoingToken, this.clipboardEnabled = true,
    this.remoteHost, this.remotePort, List<String>? additionalHosts})
    : additionalHosts = additionalHosts ?? [];

  final String id;
  String name;
  String host;
  int port;
  final String fingerprint;
  final String incomingToken;
  final String outgoingToken;
  bool clipboardEnabled;
  String? remoteHost;
  int? remotePort;
  List<String> additionalHosts;
  String? activeHost;
  int? activePort;
  String get connectionHost => activeHost ?? remoteHost ?? host;
  int get connectionPort => activePort ?? remotePort ?? port;
  bool online = false;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'host': host,
    'port': port, 'fingerprint': fingerprint, 'incomingToken': incomingToken,
    'outgoingToken': outgoingToken, 'clipboardEnabled': clipboardEnabled,
    'remoteHost': remoteHost, 'remotePort': remotePort,
    'additionalHosts': additionalHosts};

  factory Peer.fromJson(Map<String, dynamic> data) => Peer(
    id: data['id'] as String, name: data['name'] as String,
    host: data['host'] as String, port: data['port'] as int,
    fingerprint: data['fingerprint'] as String,
    incomingToken: data['incomingToken'] as String,
    outgoingToken: data['outgoingToken'] as String,
    clipboardEnabled: data['clipboardEnabled'] as bool? ?? true,
    remoteHost: data['remoteHost'] as String?, remotePort: data['remotePort'] as int?,
    additionalHosts: connectionHosts(data['additionalHosts']));
}

List<String> connectionHosts(dynamic value) => value is List
  ? value.whereType<String>().where(isConnectionHost).toSet().take(8).toList() : [];

class SharedFile {
  const SharedFile({required this.id, required this.name, required this.size});
  final String id;
  final String name;
  final int size;
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'size': size};
  factory SharedFile.fromJson(Map<String, dynamic> value) {
    if (value['id'] is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(value['id'] as String) ||
        value['name'] is! String || (value['name'] as String).length > 120 ||
        value['size'] is! int || (value['size'] as int) < 0 ||
        (value['size'] as int) > maxFileBytes) {
      throw const FormatException('Invalid shared file');
    }
    return SharedFile(id: value['id'] as String,
      name: safeFilename(value['name'] as String), size: value['size'] as int);
  }
}

class ClipboardPayload {
  ClipboardPayload({required this.id, required this.type, required this.data,
    required this.createdAt});
  final String id;
  final String type;
  final Uint8List data;
  final DateTime createdAt;
  String get digest => sha256.convert([...utf8.encode(type), ...data]).toString();
  String get text => utf8.decode(data);

  Map<String, dynamic> toJson() => {'id': id, 'type': type,
    'data': base64.encode(data), 'created': createdAt.millisecondsSinceEpoch};

  factory ClipboardPayload.fromJson(Map<String, dynamic> value) {
    if (value['id'] is! String || (value['id'] as String).length > 100 ||
        value['data'] is! String || value['created'] is! int ||
        !['text', 'png'].contains(value['type'])) {
      throw const FormatException('Invalid clipboard payload');
    }
    final type = value['type'] as String;
    final encoded = value['data'] as String;
    final limit = type == 'text' ? maxTextBytes : maxClipboardBytes;
    if (encoded.length > ((limit + 2) ~/ 3) * 4) {
      throw const FormatException('Clipboard is too large');
    }
    final data = base64.decode(encoded);
    if (data.length > limit) throw const FormatException('Clipboard is too large');
    if (type == 'text') utf8.decode(data);
    if (type == 'png' && (data.length < 8 ||
        !secureEquals(base64.encode(data.sublist(0, 8)), 'iVBORw0KGgo='))) {
      throw const FormatException('Invalid PNG');
    }
    final created = DateTime.fromMillisecondsSinceEpoch(value['created'] as int);
    final age = DateTime.now().difference(created);
    if (age > const Duration(minutes: 2) || age < const Duration(minutes: -2)) {
      throw const FormatException('Stale clipboard');
    }
    return ClipboardPayload(id: value['id'] as String, type: type,
      data: data, createdAt: created);
  }
}

class Activity {
  Activity(this.title, this.detail, {this.path, this.error = false})
      : time = DateTime.now();
  final String title;
  final String detail;
  final String? path;
  final bool error;
  final DateTime time;
}

