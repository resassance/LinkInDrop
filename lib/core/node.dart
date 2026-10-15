import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'identity.dart';
import 'connection_error.dart';
import 'models.dart';
import 'shared_files.dart';

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
  List<String> _localAddresses = [];
  final Map<String, Future<void>> _routeChecks = {};
  late Identity identity;
  late SharedFiles sharedFiles;
  bool fileSharingEnabled = false;
  int _downloads = 0;
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
  bool _transferCancelled = false;
  Future<void> _saveQueue = Future.value();
  int get port => _server?.port ?? preferredPort;
  bool get running => _server != null;
  Directory get inbox => Directory(p.join(directory.path, 'inbox'));

  Future<void> start() async {
    identity = await Identity.load(directory);
    await inbox.create(recursive: true);
    sharedFiles = SharedFiles(directory);
    await sharedFiles.load();
    _localAddresses = await addresses();
    final state = File(p.join(directory.path, 'peers.json'));
    if (await state.exists()) {
      final data = jsonDecode(await state.readAsString()) as List<dynamic>;
      for (final item in data) {
        final peer = Peer.fromJson(item as Map<String, dynamic>);
        peers[peer.id] = peer;
      }
    }
    final portFile = File(p.join(directory.path, 'listen-port'));
    final savedPort = await portFile.exists()
      ? int.tryParse(await portFile.readAsString()) : null;
    final listenPort = preferredPort != 0 && savedPort != null &&
      savedPort >= 1 && savedPort <= 65535 ? savedPort : preferredPort;
    try {
      _server = await HttpServer.bindSecure(InternetAddress.anyIPv4,
        listenPort, identity.context);
    } on SocketException {
      _server = await HttpServer.bindSecure(InternetAddress.anyIPv4, 0, identity.context);
      onActivity(Activity('Порт подключения изменён',
        'Порт $listenPort занят. Используется $port. Создайте новый QR и обновите правило Windows Firewall.', error: true));
    }
    if (preferredPort != 0) await portFile.writeAsString('$port', flush: true);
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
      .where(isConnectionHost).toSet().toList();
  }

  PairInvite invite(String host) {
    _inviteSecret ??= randomToken();
    if (_inviteExpiry == null || !_inviteExpiry!.isAfter(DateTime.now())) {
      _inviteSecret = randomToken();
      _inviteExpiry = DateTime.now().add(const Duration(minutes: 5));
    }
    return PairInvite(id: identity.id, name: name, host: host, port: port,
      fingerprint: identity.fingerprint, secret: _inviteSecret!, expiresAt: _inviteExpiry!,
      hosts: _localAddresses.take(8).toList());
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
    client.connectionTimeout = const Duration(seconds: 8);
    client.findProxy = (_) => 'DIRECT';
    client.badCertificateCallback = (certificate, host, port) =>
      secureEquals(certificateFingerprint(certificate.pem), fingerprint);
    _clients.add(client);
    return client;
  }

  Future<Map<String, dynamic>> _jsonRequest({required String host,
    required int port, required String fingerprint, required String endpoint,
    String? token, Map<String, dynamic>? body,
    Set<int> acceptedStatuses = const {200},
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
        final raw = await _readBounded(response, 256 * 1024);
        final decoded = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
        if (!acceptedStatuses.contains(response.statusCode)) {
          throw RemoteFailure(response.statusCode, decoded['error'] as String? ?? 'Request rejected');
        }
        return decoded;
      })().timeout(timeout);
    } finally {
      client.close(force: true);
      _clients.remove(client);
    }
  }

  Future<T> _firstSuccess<T>(Iterable<Future<T> Function()> attempts) async {
    final tasks = attempts.toList();
    if (tasks.isEmpty) throw const SocketException('No connection addresses');
    final result = Completer<T>();
    var remaining = tasks.length;
    for (final attempt in tasks) {
      unawaited(() async {
        try {
          final value = await attempt();
          if (!result.isCompleted) result.complete(value);
        } catch (error, stack) {
          remaining--;
          if (remaining == 0 && !result.isCompleted) result.completeError(error, stack);
        }
      }());
    }
    return result.future;
  }

  Future<void> probeInvite(PairInvite invite) async { await _probeInviteRoute(invite); }

  Future<String> _probeInviteRoute(PairInvite invite) async {
    try {
      return await _firstSuccess({invite.host, ...invite.hosts}.take(8).map((host) => () async {
        await _jsonRequest(host: host, port: invite.port,
          fingerprint: invite.fingerprint, endpoint: '/ping',
          timeout: const Duration(seconds: 5), acceptedStatuses: const {200, 401});
        return host;
      }));
    } on SocketException catch (error) {
      throw describePairingFailure(error, '${invite.host}:${invite.port}', waitingForApproval: false);
    } on HandshakeException catch (error) {
      throw describePairingFailure(error, '${invite.host}:${invite.port}', waitingForApproval: false);
    } on TimeoutException catch (error) {
      throw describePairingFailure(error, '${invite.host}:${invite.port}', waitingForApproval: false);
    }
  }

  Future<void> pair(PairInvite invite, {void Function(String)? onStage}) async {
    if (invite.id == identity.id) throw StateError('Это ваше устройство');
    final target = '${invite.host}:${invite.port}';
    onStage?.call('Проверка соединения с $target');
    final host = await _probeInviteRoute(invite);
    onStage?.call('Подтвердите подключение на ${invite.name}');
    try {
      await _completePair(PairInvite(id: invite.id, name: invite.name, host: host,
        port: invite.port, fingerprint: invite.fingerprint, secret: invite.secret,
        expiresAt: invite.expiresAt, hosts: invite.hosts));
    } on SocketException catch (error) {
      throw describePairingFailure(error, target, waitingForApproval: false);
    } on HandshakeException catch (error) {
      throw describePairingFailure(error, target, waitingForApproval: false);
    } on TimeoutException catch (error) {
      throw describePairingFailure(error, target, waitingForApproval: true);
    } on RemoteFailure catch (error) {
      throw describePairingFailure(error, target, waitingForApproval: true);
    }
  }

  Future<void> _completePair(PairInvite invite) async {
    final localToken = randomToken();
    final response = await _jsonRequest(host: invite.host, port: invite.port,
      fingerprint: invite.fingerprint, endpoint: '/pair',
      timeout: const Duration(minutes: 2), body: {
        'v': protocolVersion, 'secret': invite.secret, 'id': identity.id,
        'name': name, 'port': port, 'fingerprint': identity.fingerprint,
        'token': localToken,
        'hosts': _localAddresses,
      });
    if (response['id'] != invite.id || response['token'] is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(response['token'] as String)) {
      throw const FormatException('Invalid pairing response');
    }
    peers[invite.id] = Peer(id: invite.id, name: invite.name, host: invite.host,
      port: invite.port, fingerprint: invite.fingerprint,
      incomingToken: localToken, outgoingToken: response['token'] as String,
      additionalHosts: connectionHosts(response['hosts']))..online = true;
    await savePeers();
    onActivity(Activity('Устройство подключено', invite.name));
    onChanged();
  }

  Future<void> checkPeers() async {
    if (_checking || !running) return;
    _checking = true;
    try {
      try { _localAddresses = await addresses(); } catch (_) {}
      await Future.wait(peers.values.toList().map((peer) async {
        try {
          await _connectPeer(peer);
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

  Future<void> _connectPeer(Peer peer) {
    return _routeChecks.putIfAbsent(peer.id, () => _findRoute(peer).whenComplete(
      () { _routeChecks.remove(peer.id); }));
  }

  Future<void> _findRoute(Peer peer) async {
    // Race independently pinned endpoints so a VPN blackhole cannot hold a
    // healthy LAN route hostage. Never retry a file upload after sending bytes.
    final candidates = <(String, int)>{
      if (peer.remoteHost != null) (peer.remoteHost!, peer.remotePort ?? peer.port),
      (peer.host, peer.port),
      for (final host in peer.additionalHosts) (host, peer.port),
    }.take(10).toList();
    for (var round = 0; round < 2; round++) {
      if (!running || peers[peer.id] != peer) throw StateError('Устройство отключено');
      try {
        final route = await _firstSuccess(candidates.map((route) => () async {
          final result = await _jsonRequest(host: route.$1, port: route.$2,
            fingerprint: peer.fingerprint, endpoint: '/ping', token: peer.outgoingToken,
            timeout: const Duration(seconds: 4));
          if (result['id'] != peer.id) throw const FormatException('Device identity mismatch');
          return (route, connectionHosts(result['hosts']));
        }));
        if (peers[peer.id] != peer || !running) throw StateError('Устройство отключено');
        peer.activeHost = route.$1.$1;
        peer.activePort = route.$1.$2;
        final hosts = route.$2;
        if (hosts.isNotEmpty && jsonEncode(hosts) != jsonEncode(peer.additionalHosts)) {
          peer.additionalHosts = hosts;
          await savePeers();
        }
        return;
      } on SocketException {
        if (round == 1) rethrow;
      } on TimeoutException {
        if (round == 1) rethrow;
      }
      await Future<void>.delayed(const Duration(milliseconds: 350));
    }
  }

  Future<Map<String, dynamic>> _pairedRequest(Peer peer, String endpoint,
      {Map<String, dynamic>? body}) async {
    for (var attempt = 0; ; attempt++) {
      await _connectPeer(peer);
      try {
        return await _jsonRequest(host: peer.connectionHost, port: peer.connectionPort,
          fingerprint: peer.fingerprint, endpoint: endpoint,
          token: peer.outgoingToken, body: body);
      } on SocketException {
        if (attempt != 0) rethrow;
      } on TimeoutException {
        if (attempt != 0) rethrow;
      }
      // Only reads and clipboard messages (deduplicated by payload ID) use this
      // helper. Repeating a pairing request or upload could produce duplicates.
    }
  }

  Future<void> sendClipboard(ClipboardPayload payload) async {
    final targets = peers.values.where((p) => p.clipboardEnabled).toList();
    if (targets.isEmpty) throw StateError('Нет подключённых устройств');
    var delivered = 0;
    await Future.wait(targets.map((peer) async {
      try {
        await _pairedRequest(peer, '/clipboard', body: payload.toJson());
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
      await _connectPeer(peer);
      final request = await client.postUrl(Uri(scheme: 'https', host: peer.connectionHost,
        port: peer.connectionPort, path: '/file')).timeout(const Duration(seconds: 15));
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
      })).timeout(const Duration(minutes: 30));
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
    _transferCancelled = true;
    _outgoingTransfer?.close(force: true);
  }

  Future<void> setRemoteAddress(Peer peer, String? host, int? port) async {
    if (host != null) {
      if (!isConnectionHost(host) || port == null || port < 1 || port > 65535) {
        throw const FormatException('Введите IPv4/DNS-адрес и порт 1–65535');
      }
      // Verify TLS, token and device identity before persisting the endpoint.
      final result = await _jsonRequest(host: host, port: port,
        fingerprint: peer.fingerprint, endpoint: '/ping', token: peer.outgoingToken);
      if (result['id'] != peer.id) throw StateError('Адрес принадлежит другому устройству');
    }
    if (peers[peer.id] != peer) throw StateError('Устройство уже отключено');
    peer.remoteHost = host;
    peer.remotePort = host == null ? null : port;
    peer.activeHost = host;
    peer.activePort = host == null ? null : port;
    peer.online = host != null;
    await savePeers();
    onChanged();
    if (host == null) await checkPeers();
  }

  Future<List<SharedFile>> listFiles(Peer peer) async {
    final result = await _pairedRequest(peer, '/files');
    final entries = result['files'];
    if (entries is! List || entries.length > 200) {
      throw const FormatException('Invalid file list');
    }
    return entries.map((entry) => SharedFile.fromJson(entry as Map<String, dynamic>)).toList();
  }

  Future<void> downloadFile(Peer peer, SharedFile entry) async {
    _transferCancelled = false;
    for (var attempt = 0; ; attempt++) {
      try {
        await _downloadFile(peer, entry);
        return;
      } on SocketException {
        if (attempt != 0 || _transferCancelled) rethrow;
      } on TimeoutException {
        if (attempt != 0 || _transferCancelled) rethrow;
      } on HttpException {
        if (attempt != 0 || _transferCancelled) rethrow;
      }
      onActivity(Activity('Восстановление соединения',
        'Получение ${entry.name} будет повторено через доступный адрес устройства.'));
      await Future<void>.delayed(const Duration(milliseconds: 350));
      if (_transferCancelled) throw StateError('Передача отменена');
    }
  }

  Future<void> _downloadFile(Peer peer, SharedFile entry) async {
    if (!receivingEnabled) throw StateError('Включите приём файлов');
    if (transferName != null) throw StateError('Дождитесь текущей передачи');
    // Validate even entries constructed by callers; the ID is a single segment.
    SharedFile.fromJson(entry.toJson());
    final client = _client(peer.fingerprint);
    _outgoingTransfer = client;
    transferName = entry.name;
    transferProgress = 0;
    final id = randomToken(8);
    final temporary = File(p.join(inbox.path, '.$id.part'));
    final output = File(p.join(inbox.path, '${id}_${safeFilename(entry.name)}'));
    IOSink? sink;
    onChanged();
    try {
      await _connectPeer(peer);
      final request = await client.getUrl(Uri(scheme: 'https', host: peer.connectionHost,
        port: peer.connectionPort, path: '/files/${entry.id}'))
        .timeout(const Duration(seconds: 15));
      request.followRedirects = false;
      request.headers.set('X-Nearbridge-Id', identity.id);
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${peer.outgoingToken}');
      final response = await request.close().timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        throw RemoteFailure(response.statusCode, 'Не удалось получить файл. Обновите список.');
      }
      final size = response.contentLength;
      if (size < 0 || size > maxFileBytes) throw const FormatException('Invalid file length');
      // The file may have changed since listing; use the length of this response.
      var received = 0;
      sink = temporary.openWrite();
      await sink.addStream(response.timeout(const Duration(seconds: 30)).map((chunk) {
        received += chunk.length;
        if (received > size) throw const FormatException('File length mismatch');
        transferProgress = size == 0 ? 1 : received / size;
        onChanged();
        return chunk;
      }));
      await sink.flush();
      await sink.close();
      sink = null;
      if (received != size) throw const FormatException('Incomplete file');
      await temporary.rename(output.path);
      onActivity(Activity('Файл получен', '${entry.name} · ${peer.name}', path: output.path));
    } finally {
      client.close(force: true);
      _clients.remove(client);
      try { await sink?.close(); } catch (_) {}
      if (await temporary.exists()) await temporary.delete();
      _outgoingTransfer = null;
      transferName = null;
      transferProgress = null;
      onChanged();
    }
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
      if (request.method == 'GET' &&
          (request.uri.path == '/files' || request.uri.path.startsWith('/files/'))) {
        await _serveSharedFiles(request, peer);
        return;
      }
      switch ((request.method, request.uri.path)) {
        case ('GET', '/ping'):
          _respond(request, 200, {'v': protocolVersion, 'id': identity.id, 'hosts': _localAddresses});
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
        incomingToken: token, outgoingToken: body['token'] as String,
        additionalHosts: connectionHosts(body['hosts']))..online = true;
      peers[peer.id] = peer;
      await savePeers();
      cancelInvite();
      _respond(request, 200, {'id': identity.id, 'token': token, 'hosts': _localAddresses});
      onActivity(Activity('Устройство подключено', peer.name));
    } finally {
      _pairing = false;
    }
  }

  Future<void> _serveSharedFiles(HttpRequest request, Peer peer) async {
    if (!fileSharingEnabled) {
      _respond(request, 403, {'error': 'Владелец не включил доступ к файлам'});
      return;
    }
    if (request.uri.path == '/files') {
      _respond(request, 200, {'files': (await sharedFiles.list()).map((e) => e.toJson()).toList()});
      return;
    }
    final parts = request.uri.pathSegments;
    if (parts.length != 2 || !RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(parts[1])) {
      _respond(request, 404, {'error': 'File not shared'});
      return;
    }
    if (_downloads >= 2) {
      _respond(request, 429, {'error': 'Receiver busy'});
      return;
    }
    _downloads++;
    try {
      final file = await sharedFiles.resolve(parts[1]);
      if (file == null) {
        _respond(request, 404, {'error': 'File not shared'});
        return;
      }
      final size = await file.length();
      if (size > maxFileBytes) {
        _respond(request, 413, {'error': 'File too large'});
        return;
      }
      request.response.headers.contentType = ContentType.binary;
      request.response.contentLength = size;
      request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      try {
        await request.response.addStream(file.openRead(0, size))
          .timeout(const Duration(minutes: 30));
        onActivity(Activity('Файл скачан устройством', '${p.basename(file.path)} · ${peer.name}'));
      } catch (error) {
        // Headers may already be on the wire; do not append JSON to a file.
        onActivity(Activity('Скачивание прервано', '$error', error: true));
        try { await request.response.close(); } catch (_) {}
      }
    } finally {
      _downloads--;
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

