import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'identity.dart';
import 'models.dart';

class BridgeNode {
  BridgeNode({required this.directory, required this.name,
    required this.onPairRequest, required this.onClipboard, required this.onActivity,
    required this.onChanged, this.preferredPort = 45831,
    this.discoveryEnabled = true});

  final Directory directory;
  String name;
  final int preferredPort;
  final bool discoveryEnabled;
  final Future<bool> Function(String name) onPairRequest;
  final Future<void> Function(ClipboardPayload payload) onClipboard;
  final void Function(Activity activity) onActivity;
  final void Function() onChanged;
  final Map<String, Peer> peers = {};
  final Map<String, Map<String, dynamic>> nearby = {};
  final Set<String> _receivedIds = {};
  final Set<String> _activeTransfers = {};
  final Map<String, DateTime> _pairAttempts = {};
  late Identity identity;
  HttpServer? _server;
  RawDatagramSocket? _discovery;
  Timer? _discoveryTimer;
  Timer? _healthTimer;
  String? _inviteSecret;
  DateTime? _inviteExpiry;
  bool _pairing = false;
  bool _checking = false;
  bool receivingEnabled = true;
  bool clipboardReceivingEnabled = true;
  double? transferProgress;
  String? transferName;
  final Set<HttpClient> _clients = {};
  HttpClient? _outgoingTransfer;
  Future<void> _saveQueue = Future.value();
  int get port => _server?.port ?? preferredPort;
  bool get running => _server != null;
  Directory get inbox => Directory(p.join(directory.path, 'inbox'));

  Future<void> start() async {
    identity = await Identity.load(directory);
    await inbox.create(recursive: true);
    final state = File(p.join(directory.path, 'peers.json'));
    if (await state.exists()) {
      final data = jsonDecode(await state.readAsString()) as List<dynamic>;
      for (final item in data) {
        final peer = Peer.fromJson(item as Map<String, dynamic>);
        peers[peer.id] = peer;
      }
    }
    try {
      _server = await HttpServer.bindSecure(InternetAddress.anyIPv4,
        preferredPort, identity.context);
    } on SocketException {
      _server = await HttpServer.bindSecure(InternetAddress.anyIPv4, 0, identity.context);
    }
    _server!.idleTimeout = const Duration(seconds: 30);
    _server!.listen((request) => unawaited(_handle(request)), onError: (Object error) {
      onActivity(Activity('Ошибка соединения', '$error', error: true));
    });
    if (discoveryEnabled) await _startDiscovery();
    _healthTimer = Timer.periodic(const Duration(seconds: 5), (_) => unawaited(checkPeers()));
    onChanged();
  }

  Future<List<String>> addresses() async {
    final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4,
      includeLoopback: false);
    return interfaces.expand((i) => i.addresses).map((a) => a.address)
      .where(isLocalAddress).toList();
  }

  PairInvite invite(String host) {
    _inviteSecret ??= randomToken();
    if (_inviteExpiry == null || !_inviteExpiry!.isAfter(DateTime.now())) {
      _inviteSecret = randomToken();
      _inviteExpiry = DateTime.now().add(const Duration(minutes: 5));
    }
    return PairInvite(id: identity.id, name: name, host: host, port: port,
      fingerprint: identity.fingerprint, secret: _inviteSecret!, expiresAt: _inviteExpiry!);
  }

  void cancelInvite() {
    _inviteSecret = null;
    _inviteExpiry = null;
  }

  Future<void> savePeers() {
    final content = jsonEncode(peers.values.map((peer) => peer.toJson()).toList());
    _saveQueue = _saveQueue.catchError((Object _) {}).then((_) async {
      final temporary = File(p.join(directory.path, 'peers.json.new'));
      await temporary.writeAsString(content, flush: true);
      await temporary.rename(p.join(directory.path, 'peers.json'));
    });
    return _saveQueue;
  }

  Future<void> forget(String id) async {
    peers.remove(id);
    await savePeers();
    onChanged();
  }

  HttpClient _client(String fingerprint) {
    final client = HttpClient(context: SecurityContext(withTrustedRoots: false));
    client.connectionTimeout = const Duration(seconds: 5);
    client.badCertificateCallback = (certificate, host, port) =>
      secureEquals(certificateFingerprint(certificate.pem), fingerprint);
    _clients.add(client);
    return client;
  }

  Future<Map<String, dynamic>> _jsonRequest({required String host,
    required int port, required String fingerprint, required String endpoint,
    String? token, Map<String, dynamic>? body,
    Duration timeout = const Duration(seconds: 15)}) async {
    final client = _client(fingerprint);
    try {
      return await (() async {
        final request = await client.openUrl(body == null ? 'GET' : 'POST',
          Uri(scheme: 'https', host: host, port: port, path: endpoint));
        request.followRedirects = false;
        request.headers.set('X-Nearbridge-Id', identity.id);
        if (token != null) request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        if (body != null) {
          request.headers.contentType = ContentType.json;
          request.add(utf8.encode(jsonEncode(body)));
        }
        final response = await request.close();
        final raw = await _readBounded(response, 65536);
        if (response.statusCode != 200) {
          throw HttpException('Запрос отклонён (${response.statusCode})');
        }
        return jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
      })().timeout(timeout);
    } finally {
      client.close(force: true);
      _clients.remove(client);
    }
  }

  Future<void> pair(PairInvite invite) async {
    if (invite.id == identity.id) throw StateError('Это ваше устройство');
    final localToken = randomToken();
    final response = await _jsonRequest(host: invite.host, port: invite.port,
      fingerprint: invite.fingerprint, endpoint: '/pair',
      timeout: const Duration(minutes: 2), body: {
        'v': protocolVersion, 'secret': invite.secret, 'id': identity.id,
        'name': name, 'port': port, 'fingerprint': identity.fingerprint,
        'token': localToken,
      });
    if (response['id'] != invite.id || response['token'] is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(response['token'] as String)) {
      throw const FormatException('Invalid pairing response');
    }
    peers[invite.id] = Peer(id: invite.id, name: invite.name, host: invite.host,
      port: invite.port, fingerprint: invite.fingerprint,
      incomingToken: localToken, outgoingToken: response['token'] as String)..online = true;
    await savePeers();
    onActivity(Activity('Устройство подключено', invite.name));
    onChanged();
  }

  Future<void> checkPeers() async {
    if (_checking || !running) return;
    _checking = true;
    try {
      await Future.wait(peers.values.toList().map((peer) async {
        try {
          await _jsonRequest(host: peer.host, port: peer.port,
            fingerprint: peer.fingerprint, endpoint: '/ping', token: peer.outgoingToken);
          peer.online = true;
        } catch (_) {
          peer.online = false;
        }
      }));
      onChanged();
    } finally {
      _checking = false;
    }
  }

  Future<void> sendClipboard(ClipboardPayload payload) async {
    final targets = peers.values.where((p) => p.online && p.clipboardEnabled).toList();
    if (targets.isEmpty) throw StateError('Нет подключённых устройств');
    var delivered = 0;
    await Future.wait(targets.map((peer) async {
      try {
        await _jsonRequest(host: peer.host, port: peer.port,
          fingerprint: peer.fingerprint, endpoint: '/clipboard',
          token: peer.outgoingToken, body: payload.toJson());
        delivered++;
      } catch (_) {
        peer.online = false;
      }
    }));
    onChanged();
    if (delivered == 0) throw StateError('Не удалось передать буфер');
    onActivity(Activity('Буфер отправлен',
      '${payload.type == 'png' ? 'Изображение' : 'Текст'} · устройств: $delivered'));
  }

  Future<void> sendFile(Peer peer, String path, {String? filename}) async {
    if (transferName != null) throw StateError('Дождитесь текущей передачи');
    final file = File(path);
    final length = await file.length();
    if (length > maxFileBytes) throw StateError('Лимит файла — 2 ГБ');
    final name = safeFilename(filename ?? p.basename(path));
    final client = _client(peer.fingerprint);
    _outgoingTransfer = client;
    transferName = name;
    transferProgress = 0;
    onChanged();
    try {
      final request = await client.postUrl(Uri(scheme: 'https', host: peer.host,
        port: peer.port, path: '/file'));
      request.followRedirects = false;
      request.headers.set('X-Nearbridge-Id', identity.id);
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${peer.outgoingToken}');
      request.headers.set('X-Nearbridge-Filename', base64Url.encode(utf8.encode(name)));
      request.contentLength = length;
      request.headers.contentType = ContentType.binary;
      var sent = 0;
      await request.addStream(file.openRead().map((chunk) {
        sent += chunk.length;
        transferProgress = length == 0 ? 1 : sent / length;
        onChanged();
        return chunk;
      }));
      final response = await request.close().timeout(const Duration(minutes: 2));
      await _readBounded(response, 65536);
      if (response.statusCode != 200) throw HttpException('Передача отклонена (${response.statusCode})');
      onActivity(Activity('Файл отправлен', '$name → ${peer.name}'));
    } finally {
      client.close(force: true);
      _clients.remove(client);
      _outgoingTransfer = null;
      transferName = null;
      transferProgress = null;
      onChanged();
    }
  }

  void cancelTransfer() {
    _outgoingTransfer?.close(force: true);
  }

  static Future<Uint8List> _readBounded(Stream<List<int>> stream, int limit) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream.timeout(const Duration(seconds: 30))) {
      if (builder.length + chunk.length > limit) throw const FormatException('Payload is too large');
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  void _respond(HttpRequest request, int status, Map<String, dynamic> body) {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body));
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      if (request.uri.path == '/pair' && request.method == 'POST') {
        await _acceptPair(request);
        return;
      }
      final peer = peers[request.headers.value('X-Nearbridge-Id')];
      if (peer == null || !secureEquals(
          request.headers.value(HttpHeaders.authorizationHeader) ?? '',
          'Bearer ${peer.incomingToken}')) {
        _respond(request, 401, {'error': 'Unauthorized'});
        return;
      }
      peer.online = true;
      switch ((request.method, request.uri.path)) {
        case ('GET', '/ping'):
          _respond(request, 200, {'v': protocolVersion, 'id': identity.id});
        case ('POST', '/clipboard'):
          if (!clipboardReceivingEnabled || !peer.clipboardEnabled) {
            _respond(request, 403, {'error': 'Clipboard disabled'});
            return;
          }
          final bytes = await _readBounded(request, 12 * 1024 * 1024);
          final payload = ClipboardPayload.fromJson(jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>);
          if (_receivedIds.contains(payload.id)) {
            _respond(request, 200, {'duplicate': true});
            return;
          }
          await onClipboard(payload);
          _receivedIds.add(payload.id);
          if (_receivedIds.length > 256) _receivedIds.remove(_receivedIds.first);
          onActivity(Activity('Буфер получен',
            '${payload.type == 'png' ? 'Изображение' : 'Текст'} · ${peer.name}'));
          _respond(request, 200, {'ok': true});
        case ('POST', '/file'):
          if (!receivingEnabled) {
            _respond(request, 403, {'error': 'Receiving disabled'});
            return;
          }
          await _acceptFile(request, peer);
        default:
          _respond(request, 404, {'error': 'Not found'});
      }
    } on FormatException {
      _respond(request, 400, {'error': 'Invalid payload'});
    } on TimeoutException {
      _respond(request, 408, {'error': 'Timeout'});
    } catch (error) {
      _respond(request, 500, {'error': 'Request failed'});
      onActivity(Activity('Ошибка передачи', '$error', error: true));
    } finally {
      try {
        await request.response.close();
      } catch (_) {}
      onChanged();
    }
  }

  Future<void> _acceptPair(HttpRequest request) async {
    final remote = request.connectionInfo?.remoteAddress.address ?? '';
    final now = DateTime.now();
    _pairAttempts.removeWhere((_, date) => now.difference(date) > const Duration(minutes: 1));
    if (_pairing || _pairAttempts.containsKey(remote) || _pairAttempts.length > 64) {
      _respond(request, 429, {'error': 'Try again later'});
      return;
    }
    _pairAttempts[remote] = now;
    final body = jsonDecode(utf8.decode(await _readBounded(request, 8192))) as Map<String, dynamic>;
    if (_inviteSecret == null || _inviteExpiry == null ||
        !_inviteExpiry!.isAfter(now) || body['secret'] is! String ||
        !secureEquals(body['secret'] as String, _inviteSecret!) ||
        body['v'] != protocolVersion || body['id'] is! String ||
        body['id'] == identity.id || (body['id'] as String).length > 100 ||
        body['name'] is! String || (body['name'] as String).length > 80 ||
        body['port'] is! int || (body['port'] as int) < 1 || (body['port'] as int) > 65535 ||
        body['fingerprint'] is! String || body['token'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(body['fingerprint'] as String) ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(body['token'] as String)) {
      _respond(request, 403, {'error': 'Pairing code invalid or expired'});
      return;
    }
    _pairing = true;
    try {
      final accepted = await onPairRequest(body['name'] as String)
        .timeout(const Duration(seconds: 90), onTimeout: () => false);
      if (!accepted || _inviteSecret == null || !_inviteExpiry!.isAfter(DateTime.now())) {
        _respond(request, 403, {'error': 'Pairing rejected'});
        return;
      }
      final token = randomToken();
      final peer = Peer(id: body['id'] as String, name: body['name'] as String,
        host: remote, port: body['port'] as int,
        fingerprint: body['fingerprint'] as String,
        incomingToken: token, outgoingToken: body['token'] as String)..online = true;
      peers[peer.id] = peer;
      await savePeers();
      cancelInvite();
      _respond(request, 200, {'id': identity.id, 'token': token});
      onActivity(Activity('Устройство подключено', peer.name));
    } finally {
      _pairing = false;
    }
  }

  Future<void> _acceptFile(HttpRequest request, Peer peer) async {
    final size = request.contentLength;
    if (size < 0 || size > maxFileBytes || _activeTransfers.length >= 2) {
      _respond(request, 413, {'error': 'File too large or receiver busy'});
      return;
    }
    final encoded = request.headers.value('X-Nearbridge-Filename');
    if (encoded == null || encoded.length > 2048) throw const FormatException('Missing filename');
    final name = safeFilename(utf8.decode(base64Url.decode(encoded)));
    final id = randomToken(8);
    final temporary = File(p.join(inbox.path, '.$id.part'));
    final output = File(p.join(inbox.path, '${id}_$name'));
    _activeTransfers.add(id);
    final sink = temporary.openWrite();
    var received = 0;
    try {
      await sink.addStream(request.timeout(const Duration(seconds: 30)).map((chunk) {
        received += chunk.length;
        if (received > size || received > maxFileBytes) throw const FormatException('File length mismatch');
        return chunk;
      }));
      await sink.flush();
      await sink.close();
      if (received != size) throw const FormatException('Incomplete file');
      await temporary.rename(output.path);
      onActivity(Activity('Файл получен', '$name · ${peer.name}', path: output.path));
      _respond(request, 200, {'ok': true, 'bytes': received});
    } catch (_) {
      try { await sink.close(); } catch (_) {}
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    } finally {
      _activeTransfers.remove(id);
    }
  }

  Future<void> _startDiscovery() async {
    try {
      _discovery = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 45832,
        reuseAddress: true, reusePort: !Platform.isWindows);
      _discovery!.broadcastEnabled = true;
      _discovery!.listen((event) {
        if (event != RawSocketEvent.read) return;
        Datagram? packet;
        while ((packet = _discovery?.receive()) != null) {
          final current = packet!;
          if (current.data.length > 2048) continue;
          try {
            final data = jsonDecode(utf8.decode(current.data)) as Map<String, dynamic>;
            if (data['app'] != 'nearbridge' || data['v'] != protocolVersion ||
                data['id'] == identity.id || data['id'] is! String || data['name'] is! String ||
                data['port'] is! int || !isLocalAddress(current.address.address)) continue;
            data['host'] = current.address.address;
            data['seen'] = DateTime.now().millisecondsSinceEpoch;
            if (nearby.length < 64 || nearby.containsKey(data['id'])) nearby[data['id'] as String] = data;
            final peer = peers[data['id']];
            if (peer != null && (peer.host != data['host'] || peer.port != data['port'])) {
              unawaited(_verifyAddress(peer, data['host'] as String, data['port'] as int));
            }
            onChanged();
          } catch (_) {}
        }
      }, onError: (Object _) {});
      _discoveryTimer = Timer.periodic(const Duration(seconds: 4), (_) => _announce());
      _announce();
    } catch (_) {
      onActivity(Activity('Поиск устройств недоступен', 'Подключение через QR-код работает'));
    }
  }

  Future<void> _verifyAddress(Peer peer, String host, int port) async {
    if (port < 1 || port > 65535) return;
    try {
      final result = await _jsonRequest(host: host, port: port, fingerprint: peer.fingerprint,
        endpoint: '/ping', token: peer.outgoingToken);
      if (result['id'] != peer.id || !peers.containsKey(peer.id)) return;
      peer.host = host;
      peer.port = port;
      peer.online = true;
      await savePeers();
      onChanged();
    } catch (_) {}
  }

  void _announce() {
    nearby.removeWhere((_, data) => DateTime.now().millisecondsSinceEpoch - (data['seen'] as int) > 15000);
    final data = utf8.encode(jsonEncode({'app': 'nearbridge', 'v': protocolVersion,
      'id': identity.id, 'name': name, 'port': port}));
    try { _discovery?.send(data, InternetAddress('255.255.255.255'), 45832); } catch (_) {}
    onChanged();
  }

  Future<void> stop() async {
    _healthTimer?.cancel();
    _discoveryTimer?.cancel();
    _discovery?.close();
    for (final client in _clients.toList()) { client.close(force: true); }
    _clients.clear();
    await _server?.close(force: true);
    _server = null;
  }
}
