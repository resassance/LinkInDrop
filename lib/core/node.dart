import '../l10n/messages.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'identity.dart';
import 'connection_error.dart';
import 'models.dart';
import 'shared_files.dart';
import 'shared_folders.dart';
import 'access_rules.dart';
import 'transfer_protocol.dart';
import 'relay_transport.dart';
import 'search_service.dart';
import 'file_preview.dart';
import 'receive_storage.dart';
import 'release_info.dart';
import 'package:crypto/crypto.dart';

class BridgeNode {
  BridgeNode({required Directory directory, required this.name,
    required this.onPairRequest, required this.onClipboard, required this.onActivity,
    required this.onChanged, this.preferredPort = 45831,
    this.discoveryEnabled = true, this.folderProvider}) : _directory = directory;

  Directory _directory;
  Directory get directory => _directory;
  String name;
  final int preferredPort;
  final bool discoveryEnabled;
  final FolderProvider? folderProvider;
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
  late SharedFolders sharedFolders;
  late AccessRules access;
  late UploadStore uploads;
  late ReceiveStorage received;
  int transferBytes = 0;
  int sessionBytes = 0;
  int transferTotal = 0;
  int bytesPerSecond = 0;
  Stopwatch _rateClock = Stopwatch();
  int _pacedBytes = 0;
  Map<String, dynamic>? lastUploadReceipt;
  final SearchService searchService = SearchService();
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
  bool _stopping = false;
  bool receivingEnabled = true;
  bool clipboardReceivingEnabled = true;
  double? transferProgress;
  String? transferName;
  final Set<HttpClient> _clients = {};
  final Map<HttpClient, RelayDialer> _dialers = {};
  RelayHost? relayHost;
  String? relayUrl;
  String? relayRoom;
  HttpClient? _outgoingTransfer;
  bool _transferCancelled = false;
  Future<void> _saveQueue = Future.value();
  int get port => _server?.port ?? preferredPort;
  bool get running => _server != null;
  Directory get inbox => Directory(p.join(directory.path, 'inbox'));

  Future<void> start({String? destination, String conflictPolicy = "rename", bool sortReceived = false}) async {
    _stopping = false;
    await directory.create(recursive: true);
    _directory = Directory(await directory.resolveSymbolicLinks());
    identity = await Identity.load(directory);
    await inbox.create(recursive: true);
    sharedFiles = SharedFiles(directory, documents: folderProvider);
    await sharedFiles.load();
    sharedFolders = SharedFolders(directory, documents: folderProvider);
    await sharedFolders.load();
    access = AccessRules(directory);
    await access.load();
    uploads = UploadStore(directory, inbox);
    received = ReceiveStorage(directory, inbox);
    await received.load();
    received.destination = destination; received.conflict = conflictPolicy; received.sortByType = sortReceived;
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
    await _listen(listenPort);
    if (discoveryEnabled) await _startDiscovery();
    _healthTimer = Timer.periodic(const Duration(seconds: 5), (_) => unawaited(checkPeers()));
    onChanged();
  }

  Future<void> _listen(int listenPort) async {
    try {
      _server = await HttpServer.bindSecure(InternetAddress.anyIPv4,
        listenPort, identity.context);
    } on SocketException {
      _server = await HttpServer.bindSecure(InternetAddress.anyIPv4, 0, identity.context);
      onActivity(Activity(localizeMessage("Порт подключения изменён"),
        localizeMessage("Порт {0} занят. Используется {1}. Создайте новый QR и обновите правило Windows Firewall.", [listenPort, port]), error: true));
    }
    if (preferredPort != 0) await File(p.join(directory.path, 'listen-port')).writeAsString('$port', flush: true);
    _server!.idleTimeout = const Duration(seconds: 30);
    _server!.listen((request) => unawaited(_handle(request)), onError: (Object error) {
      onActivity(Activity(localizeMessage("Ошибка соединения"), '$error', error: true));
    });
  }

  bool get hasActiveTransfers => transferName != null || _activeTransfers.isNotEmpty || _downloads > 0;
  Future<void> _networkChanges = Future.value();

  List<String> preferredAddresses = [];

  Future<List<String>> addresses() async {
    final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4,
      includeLoopback: false);
    return [...preferredAddresses, ...interfaces.expand((i) => i.addresses).map((a) => a.address)]
      .where(isConnectionHost).toSet().toList();
  }

  Future<void> networkChanged(List<String> preferred) {
    return _networkChanges = _networkChanges.catchError((Object _) {}).then((_) => _changeNetwork(preferred));
  }

  Future<void> _changeNetwork(List<String> preferred) async {
    if (_server == null || _stopping) return;
    preferredAddresses = preferred;
    for (final client in _clients.toList()) { client.close(force: true); }
    for (final dialer in _dialers.values.toList()) { dialer.close(); }
    final listenPort = port;
    await _server?.close(force: true);
    if (_stopping) return;
    await _listen(listenPort);
    _discoveryTimer?.cancel();
    _discovery?.close();
    _discovery = null;
    if (discoveryEnabled) await _startDiscovery();
    _localAddresses = await addresses();
    if (relayUrl != null) await configureRelay(relayUrl);
    _announce();
    await checkPeers();
    onChanged();
  }

  Future<void> configureRelay(String? address) async {
    if (address != null && !validRelayUrl(address)) throw FormatException(localizeMessage("Нужен адрес wss:// сервера"));
    await relayHost?.close();
    relayHost = null;
    relayUrl = address;
    final file = File(p.join(directory.path, 'relay-room'));
    if (relayRoom == null) {
      relayRoom = await file.exists() ? (await file.readAsString()).trim() : randomToken();
      await file.writeAsString(relayRoom!, flush: true);
    }
    if (address != null) {
      relayHost = RelayHost(url: address, room: relayRoom!, localPort: port, changed: onChanged);
      await relayHost!.start();
    }
    onChanged();
  }

  PairInvite invite(String host) {
    _inviteSecret ??= randomToken();
    if (_inviteExpiry == null || !_inviteExpiry!.isAfter(DateTime.now())) {
      _inviteSecret = randomToken();
      _inviteExpiry = DateTime.now().add(const Duration(minutes: 5));
    }
    return PairInvite(id: identity.id, name: name, host: host, port: port,
      fingerprint: identity.fingerprint, secret: _inviteSecret!, expiresAt: _inviteExpiry!,
      hosts: _localAddresses.take(8).toList(), relayUrl: relayUrl, relayRoom: relayRoom);
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

  HttpClient _client(String fingerprint, {bool relay = false, String? relayAddress, String? room, bool direct = false}) {
    final client = HttpClient(context: SecurityContext(withTrustedRoots: false));
    client.connectionTimeout = const Duration(seconds: 8);
    client.findProxy = (_) => 'DIRECT';
    client.badCertificateCallback = (certificate, host, port) =>
      secureEquals(certificateFingerprint(certificate.pem), fingerprint);
    Peer? peer;
    for (final value in peers.values) { if (value.fingerprint == fingerprint) { peer = value; break; } }
    if (relay || (!direct && peer?.activeRelay == true)) {
      final address = relayAddress ?? peer?.relayUrl;
      final targetRoom = room ?? peer?.relayRoom;
      if (address == null || targetRoom == null) throw const SocketException('No relay route');
      final dialer = RelayDialer(address, targetRoom,
        acceptCertificate: (certificate) => secureEquals(certificateFingerprint(certificate.pem), fingerprint));
      _dialers[client] = dialer;
      client.connectionFactory = dialer.connect;
    }
    _clients.add(client);
    return client;
  }

  Future<Map<String, dynamic>> _jsonRequest({required String host,
    required int port, required String fingerprint, required String endpoint,
    String? token, Map<String, dynamic>? body, Map<String, String>? query,
    bool relay = false, String? relayAddress, String? room, bool direct = false,
    Set<int> acceptedStatuses = const {200},
    Duration timeout = const Duration(seconds: 15)}) async {
    final client = _client(fingerprint, relay: relay, relayAddress: relayAddress, room: room, direct: direct);
    try {
      return await (() async {
        final request = await client.openUrl(body == null ? 'GET' : 'POST',
          Uri(scheme: 'https', host: host, port: port, path: endpoint, queryParameters: query));
        request.followRedirects = false;
        request.headers.set('X-LinkInDrop-Id', identity.id);
        if (token != null) request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        if (body != null) {
          request.headers.contentType = ContentType.json;
          request.add(utf8.encode(jsonEncode(body)));
        }
        final response = await request.close();
        final raw = await _readBounded(response, ['/browse', '/search', '/preview'].contains(endpoint) ? 2 * 1024 * 1024 : 256 * 1024);
        final decoded = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
        if (!acceptedStatuses.contains(response.statusCode)) {
          throw RemoteFailure(response.statusCode, decoded['error'] as String? ?? 'Request rejected');
        }
        return decoded;
      })().timeout(timeout);
    } finally {
      client.close(force: true);
      _clients.remove(client);
      _dialers.remove(client)?.close();
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
      final attempts = {invite.host, ...invite.hosts}.take(8).map((host) => () async {
        await _jsonRequest(host: host, port: invite.port,
          fingerprint: invite.fingerprint, endpoint: '/ping', direct: true,
          timeout: const Duration(seconds: 5), acceptedStatuses: const {200, 401});
        return host;
      }).toList();
      if (invite.relayUrl != null && invite.relayRoom != null) {
        attempts.add(() async {
          await _jsonRequest(host: '127.0.0.1', port: invite.port, fingerprint: invite.fingerprint,
            endpoint: '/ping', acceptedStatuses: const {200, 401}, relay: true,
            relayAddress: invite.relayUrl, room: invite.relayRoom, timeout: const Duration(seconds: 12));
          return '@relay';
        });
      }
      return await _firstSuccess(attempts);
    } on SocketException catch (error) {
      throw describePairingFailure(error, '${invite.host}:${invite.port}', waitingForApproval: false);
    } on HandshakeException catch (error) {
      throw describePairingFailure(error, '${invite.host}:${invite.port}', waitingForApproval: false);
    } on TimeoutException catch (error) {
      throw describePairingFailure(error, '${invite.host}:${invite.port}', waitingForApproval: false);
    }
  }

  Future<void> pair(PairInvite invite, {void Function(String)? onStage}) async {
    if (invite.id == identity.id) throw StateError(localizeMessage("Это ваше устройство"));
    final target = '${invite.host}:${invite.port}';
    onStage?.call(localizeMessage("Проверка соединения с {0}", [target]));
    final host = await _probeInviteRoute(invite);
    onStage?.call(localizeMessage("Подтвердите подключение на {0}", [invite.name]));
    try {
      await _completePair(PairInvite(id: invite.id, name: invite.name, host: host,
        port: invite.port, fingerprint: invite.fingerprint, secret: invite.secret,
        expiresAt: invite.expiresAt, hosts: invite.hosts, relayUrl: invite.relayUrl, relayRoom: invite.relayRoom));
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
    final response = await _jsonRequest(host: invite.host == '@relay' ? '127.0.0.1' : invite.host, port: invite.port,
      relay: invite.host == '@relay', relayAddress: invite.relayUrl, room: invite.relayRoom,
      fingerprint: invite.fingerprint, endpoint: '/pair',
      timeout: const Duration(minutes: 2), body: {
        'v': protocolVersion, 'secret': invite.secret, 'id': identity.id,
        'name': name, 'port': port, 'fingerprint': identity.fingerprint,
        'token': localToken,
        'hosts': _localAddresses,
        if (relayUrl != null) 'relayUrl': relayUrl, if (relayRoom != null) 'relayRoom': relayRoom,
      });
    if (response['id'] != invite.id || response['token'] is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(response['token'] as String)) {
      throw const FormatException('Invalid pairing response');
    }
    peers[invite.id] = Peer(id: invite.id, name: invite.name, host: invite.host == '@relay' ? '127.0.0.1' : invite.host,
      port: invite.port, fingerprint: invite.fingerprint,
      incomingToken: localToken, outgoingToken: response['token'] as String,
      additionalHosts: connectionHosts(response['hosts']), relayUrl: invite.relayUrl, relayRoom: invite.relayRoom)
      ..activeRelay = (invite.host == '@relay')..online = true;
    await savePeers();
    onActivity(Activity(localizeMessage("Устройство подключено"), invite.name));
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
        } catch (error) {
          peer.connectionFailure = error is HandshakeException ? 'certificate' : error is TimeoutException ? 'timeout' : error is RemoteFailure ? 'authorization' : 'unreachable';
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
    final candidates = <(String, int)>{
      if (peer.relayUrl != null && peer.relayRoom != null) ('@relay', peer.port),
      if (peer.remoteHost != null) (peer.remoteHost!, peer.remotePort ?? peer.port),
      (peer.host, peer.port),
      for (final host in peer.additionalHosts) (host, peer.port),
    }.take(10).toList();
    for (var round = 0; round < 2; round++) {
      if (!running || peers[peer.id] != peer) throw StateError(localizeMessage("Устройство отключено"));
      try {
        final route = await _firstSuccess(candidates.map((route) => () async {
          final watch = Stopwatch()..start();
          final result = await _jsonRequest(host: route.$1 == '@relay' ? '127.0.0.1' : route.$1, port: route.$2,
            direct: route.$1 != '@relay', relay: route.$1 == '@relay', relayAddress: peer.relayUrl, room: peer.relayRoom,
            fingerprint: peer.fingerprint, endpoint: '/ping', token: peer.outgoingToken,
            timeout: Duration(seconds: route.$1 == '@relay' ? 12 : 4));
          if (result['id'] != peer.id) throw const FormatException('Device identity mismatch');
          return (route, connectionHosts(result['hosts']), watch.elapsedMilliseconds);
        }));
        if (peers[peer.id] != peer || !running) throw StateError(localizeMessage("Устройство отключено"));
        peer.latencyMs = route.$3;
        peer.connectionFailure = null;
        peer.activeRelay = route.$1.$1 == '@relay';
        peer.activeHost = peer.activeRelay ? '127.0.0.1' : route.$1.$1;
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
      {Map<String, dynamic>? body, Map<String, String>? query}) async {
    for (var attempt = 0; ; attempt++) {
      await _connectPeer(peer);
      try {
        return await _jsonRequest(host: peer.connectionHost, port: peer.connectionPort,
          fingerprint: peer.fingerprint, endpoint: endpoint,
          token: peer.outgoingToken, body: body, query: query,
          timeout: endpoint.endsWith('/complete') || endpoint.startsWith('/receipts/') ? const Duration(hours: 1) : const Duration(seconds: 15));
      } on SocketException {
        if (attempt != 0) rethrow;
      } on TimeoutException {
        if (attempt != 0) rethrow;
      }
    }
  }

  Future<void> sendClipboard(ClipboardPayload payload, {Peer? target}) async {
    final targets = target == null ? peers.values.where((p) => p.clipboardEnabled).toList() : [target];
    if (targets.isEmpty) throw StateError(localizeMessage("Нет подключённых устройств"));
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
    if (delivered == 0) throw StateError(localizeMessage("Не удалось передать буфер"));
    onActivity(Activity(localizeMessage("Буфер отправлен"),
      localizeMessage("{0} · устройств: {1}", [payload.type == 'png' ? localizeMessage("Изображение") : localizeMessage("Текст"), delivered]), kind: 'clipboard'));
  }

  Future<void> sendFile(Peer peer, String path, {String? filename}) async {
    if (transferName != null) throw StateError(localizeMessage("Дождитесь текущей передачи"));
    final file = File(path);
    final length = await file.length();
    if (length > maxFileBytes) throw StateError(localizeMessage("Лимит файла — 8 ТБ"));
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
      request.headers.set('X-LinkInDrop-Id', identity.id);
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${peer.outgoingToken}');
      request.headers.set('X-LinkInDrop-Filename', base64Url.encode(utf8.encode(name)));
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
      if (response.statusCode != 200) throw HttpException(localizeMessage("Передача отклонена ({0})", [response.statusCode]));
      onActivity(Activity(localizeMessage("Файл отправлен"), '$name → ${peer.name}', thumbnailPath: path, name: name, kind: 'upload'));
    } finally {
      client.close(force: true);
      _clients.remove(client);
      _dialers.remove(client)?.close();
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
        throw FormatException(localizeMessage("Введите IPv4/DNS-адрес и порт 1–65535"));
      }
      final result = await _jsonRequest(host: host, port: port,
        fingerprint: peer.fingerprint, endpoint: '/ping', token: peer.outgoingToken, direct: true);
      if (result['id'] != peer.id) throw StateError(localizeMessage("Адрес принадлежит другому устройству"));
    }
    if (peers[peer.id] != peer) throw StateError(localizeMessage("Устройство уже отключено"));
    peer.remoteHost = host;
    peer.remotePort = host == null ? null : port;
    peer.activeRelay = false;
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

  Future<SharedPage> browseFiles(Peer peer, {SharedFile? folder, int offset = 0}) async {
    if (offset < 0 || offset > 100000 ||
        (folder != null && (!folder.isDirectory || folder.folderId == null))) {
      throw const FormatException('Invalid directory request');
    }
    if (folder != null) SharedFile.fromJson(folder.toJson());
    try {
      return SharedPage.fromJson(await _pairedRequest(peer, '/browse', query: {
        if (folder != null) 'folder': folder.folderId!,
        if (folder != null) 'path': folder.relativePath!,
        'offset': '$offset',
      }));
    } on RemoteFailure catch (error) {
      if (error.status != 404 || folder != null || offset != 0) rethrow;
      return SharedPage(await listFiles(peer));
    }
  }

  Future<SharedPage> searchFiles(Peer peer, String query, {SharedFile? folder, String? cursor}) async {
    return SharedPage.fromJson(await _pairedRequest(peer, '/search', query: {
      'q': query, if (cursor != null) 'cursor': cursor,
      if (folder != null) 'folder': folder.folderId!,
      if (folder != null) 'path': folder.relativePath!,
    }));
  }

  Future<Map<String, dynamic>> previewFile(Peer peer, SharedFile entry) async {
    SharedFile.fromJson(entry.toJson());
    return _pairedRequest(peer, '/preview', query: {
      'id': entry.id, if (entry.folderId != null) 'folder': entry.folderId!,
      if (entry.relativePath != null) 'path': entry.relativePath!,
    });
  }

  Future<void> downloadFile(Peer peer, SharedFile entry, {String? relative, String? transferId, String? expectedDigest}) async {
    final id = transferId ?? randomToken(16);
    _transferCancelled = false;
    for (var attempt = 0; ; attempt++) {
      try {
        await _downloadFile(peer, entry, id, relative, expectedDigest);
        return;
      } on SocketException {
        if (attempt != 0 || _transferCancelled) rethrow;
      } on TimeoutException {
        if (attempt != 0 || _transferCancelled) rethrow;
      } on HttpException {
        if (attempt != 0 || _transferCancelled) rethrow;
      }
      onActivity(Activity(localizeMessage("Восстановление соединения"),
        localizeMessage("Получение {0} будет повторено через доступный адрес устройства.", [entry.name])));
      await Future<void>.delayed(const Duration(milliseconds: 350));
      if (_transferCancelled) throw StateError(localizeMessage("Передача отменена"));
    }
  }

  void _beginRate(int total) {
    transferBytes = 0; sessionBytes = 0; transferTotal = total; _pacedBytes = 0; _rateClock = Stopwatch()..start();
  }

  Future<void> _pace(int count) async {
    if (_transferCancelled) throw const TransferStopped();
    _pacedBytes += count;
    while (bytesPerSecond > 0 && _rateClock.elapsedMilliseconds < _pacedBytes * 1000 / bytesPerSecond) {
      if (_transferCancelled) throw const TransferStopped();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  String diagnosticReport() => jsonEncode({'app': 'LinkInDrop', 'version': appVersion,
    'platform': Platform.operatingSystem, 'listening': running,
    'relayConfigured': relayUrl != null, 'relayOnline': relayHost?.online == true,
    'peers': peers.values.map((peer) => {'online': peer.online,
      'route': peer.activeRelay ? 'relay' : 'direct', 'latencyMs': peer.latencyMs,
      'failure': peer.connectionFailure}).toList()});

  Future<bool> verifyReceipt(Peer peer, String token, String digest) async =>
    (await _pairedRequest(peer, '/receipts/$token/verify', body: {'sha256': digest}))['valid'] == true;

  Future<void> _downloadFile(Peer peer, SharedFile entry, String id, String? relative, String? expectedDigest) async {
    if (!receivingEnabled) throw StateError(localizeMessage("Включите приём файлов"));
    if (transferName != null) throw StateError(localizeMessage("Дождитесь текущей передачи"));
    if (!RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(id)) throw const FormatException('Invalid transfer ID');
    SharedFile.fromJson(entry.toJson());
    if (entry.isDirectory) throw StateError(localizeMessage("Выберите файл внутри папки"));
    _beginRate(entry.size);
    final state = await Directory(p.join(directory.path, 'partial')).create(recursive: true);
    final part = File(p.join(state.path, '$id.part'));
    final metaFile = File(p.join(state.path, '$id.json'));
    final Map<String, dynamic> meta = await metaFile.exists()
      ? jsonDecode(await metaFile.readAsString()) as Map<String, dynamic> : {
        'peer': peer.id, 'resource': jsonEncode(entry.toJson()),
        'relative': '${randomToken(8)}_${safeFilename(entry.name)}', 'offset': 0,
      };
    if (meta['peer'] != peer.id || meta['resource'] != jsonEncode(entry.toJson())) {
      throw const FormatException('Transfer source changed');
    }
    Future<void> save() async {
      final next = File('${metaFile.path}.new');
      await next.writeAsString(jsonEncode(meta), flush: true);
      await next.rename(metaFile.path);
    }
    final output = File(p.joinAll([inbox.path, ...portablePath(meta['relative'] as String).split('/')]));
    if (received.receipts.containsKey(received.key(peer.id, id))) return;
    Future<void> deliverCompleted() async {
      final digest = meta['digest'] as String;
      if (expectedDigest != null && digest != expectedDigest) throw const FormatException('Backup checksum mismatch');
      final receipt = await received.deliver(peer.id, id, output, relative ?? entry.name, digest);
      onActivity(Activity(receipt['skipped'] == true ? localizeMessage("Файл пропущен") : localizeMessage("Файл получен"), '${entry.name} · ${peer.name}', path: receipt['location'] as String, name: (receipt['name'] as String?) ?? receipt['location'] as String, kind: 'download'));
    }
    if (meta['done'] == true && await output.exists()) { await deliverCompleted(); return; }
    if (meta['finalizing'] == true && await output.exists()) {
      if ((await sha256.bind(output.openRead()).first).toString() != meta['digest']) {
        throw const FileSystemException('Completed download was changed');
      }
      meta['done'] = true;
      await save();
      await deliverCompleted();
      return;
    }
    if (!await part.exists()) await part.writeAsBytes([]);
    var offset = meta['offset'] as int? ?? 0;
    final existing = await part.length();
    await requireSpace(inbox.path, entry.size * 2 > existing ? entry.size * 2 - existing : 0);
    if (existing < offset) offset = (existing ~/ transferBlockBytes) * transferBlockBytes;
    final handle = await part.open(mode: FileMode.append);
    await handle.truncate(offset);
    await handle.close();
    transferName = entry.name;
    transferProgress = 0;
    onChanged();
    HttpClient? client;
    try {
      var resets = 0;
      while (true) {
        if (_transferCancelled) throw const TransferStopped();
        await _connectPeer(peer);
        client ??= _client(peer.fingerprint);
        _outgoingTransfer = client;
        final request = await client.getUrl(Uri(scheme: 'https', host: peer.connectionHost,
          port: peer.connectionPort, path: entry.id.startsWith('receipt:') ? '/receipts/${entry.id.substring(8)}/file' : entry.folderId == null ? '/files/${entry.id}' : '/browse/file',
          queryParameters: entry.folderId == null ? null : {'folder': entry.folderId!, 'path': entry.relativePath!}))
          .timeout(const Duration(seconds: 15));
        request.followRedirects = false;
        request.headers.set('X-LinkInDrop-Id', identity.id);
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${peer.outgoingToken}');
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-${offset + transferBlockBytes - 1}');
        if (meta['etag'] != null) request.headers.set(HttpHeaders.ifMatchHeader, meta['etag']);
        final response = await request.close().timeout(const Duration(minutes: 2));
        if (response.statusCode == 412 && resets++ == 0) {
          await response.drain<void>();
          await part.writeAsBytes([]);
          offset = 0;
          meta.remove('etag');
          meta['offset'] = 0;
          await save();
          continue;
        }
        if (response.statusCode != 200 && response.statusCode != 206) {
          throw RemoteFailure(response.statusCode, localizeMessage("Не удалось получить файл. Обновите список."));
        }
        final etag = response.headers.value(HttpHeaders.etagHeader);
        if (response.statusCode == 200) {
          final total = response.contentLength;
          if (total < 0 || total > maxFileBytes) throw const FormatException('Invalid file length');
          offset = 0;
          final sink = part.openWrite();
          try {
            await sink.addStream(response.timeout(const Duration(seconds: 30)).map((chunk) {
              if (_transferCancelled) throw const TransferStopped();
              offset += chunk.length;
              if (offset > total) throw const FormatException('Invalid file length');
              transferBytes = offset; transferTotal = total;
        transferProgress = total == 0 ? 1 : offset / total;
              onChanged();
              return chunk;
            }));
            await sink.flush();
          } finally { await sink.close(); }
          if (offset != total) throw const FormatException('Incomplete file');
          meta['offset'] = offset;
          meta['etag'] = etag;
          await save();
          break;
        }
        final range = response.headers.value(HttpHeaders.contentRangeHeader) ?? '';
        final match = RegExp(r'^bytes ([0-9]+)-([0-9]+)/([0-9]+)$').firstMatch(range);
        if (match == null || int.parse(match[1]!) != offset || etag == null) {
          throw const FormatException('Invalid range response');
        }
        final total = int.parse(match[3]!);
        final end = int.parse(match[2]!);
        if (total > maxFileBytes || end < offset || end >= total || end - offset + 1 > transferBlockBytes) {
          throw const FormatException('Invalid range length');
        }
        final bytes = await _readTransferBlock(response, offset, total);
        if (bytes.length != end - offset + 1 || !secureEquals(
            sha256.convert(bytes).toString(), response.headers.value('X-LinkInDrop-SHA256') ?? '')) {
          throw const FormatException('Block checksum mismatch');
        }
        if (_transferCancelled) throw const TransferStopped();
        final sink = await part.open(mode: FileMode.append);
        try { await sink.writeFrom(bytes); await sink.flush(); } finally { await sink.close(); }
        offset += bytes.length;
        meta['offset'] = offset;
        meta['etag'] = etag;
        await save();
        transferBytes = offset; transferTotal = total;
        transferProgress = offset / total;
        onChanged();
        if (offset == total) break;
      }
      if (_transferCancelled) throw const TransferStopped();
      meta['digest'] = (await sha256.bind(part.openRead()).first).toString();
      if (expectedDigest != null && meta['digest'] != expectedDigest) throw const FormatException('Backup checksum mismatch');
      meta['finalizing'] = true;
      await save();
      final destination = await inboxDestination(inbox, meta['relative'] as String);
      await part.rename(destination.path);
      meta['done'] = true;
      meta.remove('finalizing');
      await save();
      final receipt = await received.deliver(peer.id, id, destination, relative ?? entry.name, meta['digest'] as String);
      onActivity(Activity(receipt['skipped'] == true ? localizeMessage("Файл пропущен") : localizeMessage("Файл получен"), '${entry.name} · ${peer.name}', path: receipt['location'] as String, name: (receipt['name'] as String?) ?? receipt['location'] as String, kind: 'download'));
    } finally {
      client?.close(force: true);
      if (client != null) _clients.remove(client);
      _dialers.remove(client)?.close();
      _outgoingTransfer = null;
      transferName = null;
      transferProgress = null;
      onChanged();
    }
  }

  Future<void> discardDownload(String id) async {
    if (!RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(id)) return;
    for (final suffix in ['part', 'json', 'json.new']) {
      final file = File(p.join(directory.path, 'partial', '$id.$suffix'));
      if (await file.exists()) await file.delete();
    }
  }

  Future<void> uploadDirectory(Peer peer, String relative) async {
    await _pairedRequest(peer, '/uploads/mkdir', body: {'relative': relative});
  }

  Future<void> cancelUpload(Peer peer, String id) async {
    await _pairedRequest(peer, '/uploads/$id/cancel', body: {});
  }

  Future<String> uploadSource(Peer peer, String id, String filename,
      Future<SharedRead> Function(int offset, int? length) open,
      {String? relative, String? expectedDigest, void Function(String)? onDigest}) async {
    if (transferName != null) throw StateError(localizeMessage("Дождитесь текущей передачи"));
    _transferCancelled = false;
    transferName = filename;
    transferProgress = 0;
    onChanged();
    try {
      final original = await open(0, null);
      late String digest;
      final version = original.version;
      final total = original.size;
      _beginRate(total);
      lastUploadReceipt = null;
      try {
        if (total < 0 || total > maxFileBytes) throw StateError(localizeMessage("Лимит файла — 8 ТБ"));
        digest = (await sha256.bind(original.stream.map((chunk) {
          if (_transferCancelled) throw const TransferStopped();
          return chunk;
        })).first).toString();
      } finally { await original.close(); }
      if (expectedDigest != null && expectedDigest != digest) throw StateError(localizeMessage("Исходный файл изменился. Добавьте его заново."));
      onDigest?.call(digest);
      _rateClock.reset();
      var status = await _pairedRequest(peer, '/uploads', body: {'id': id, 'name': filename,
        'size': total, 'sha256': digest, if (relative != null) 'relative': relative});
      var offset = status['offset'] as int;
      if (offset < 0 || offset > total) throw const FormatException('Invalid upload offset');
      while (offset < total) {
        if (_transferCancelled) throw const TransferStopped();
        final source = await open(offset, transferBlockBytes);
        late Uint8List bytes;
        try {
          if (source.size != total || (version != null && source.version != version)) {
            throw StateError(localizeMessage("Исходный файл изменился"));
          }
          bytes = await _readBounded(source.stream, transferBlockBytes);
        } finally { await source.close(); }
        if (bytes.isEmpty) throw const FormatException('Incomplete source');
        await _connectPeer(peer);
        final client = _client(peer.fingerprint);
        _outgoingTransfer = client;
        try {
          final request = await client.postUrl(Uri(scheme: 'https', host: peer.connectionHost,
            port: peer.connectionPort, path: '/uploads/$id/block', queryParameters: {'offset': '$offset'}));
          request.followRedirects = false;
          request.headers.set('X-LinkInDrop-Id', identity.id);
          request.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${peer.outgoingToken}');
          request.headers.set('X-LinkInDrop-SHA256', sha256.convert(bytes).toString());
          request.contentLength = bytes.length;
          await request.addStream(() async* {
            for (var start = 0; start < bytes.length; start += 65536) {
              final end = start + 65536 < bytes.length ? start + 65536 : bytes.length;
              await _pace(end - start);
              yield bytes.sublist(start, end);
              sessionBytes += end - start; transferBytes = offset + end; onChanged();
            }
          }());
          final response = await request.close().timeout(const Duration(seconds: 45));
          final result = jsonDecode(utf8.decode(await _readBounded(response, 65536))) as Map<String, dynamic>;
          if (response.statusCode != 200) throw RemoteFailure(response.statusCode, result['error'] as String? ?? 'Upload failed');
          final next = result['offset'];
          if (next is! int || next <= offset || next > total) throw const FormatException('Invalid upload acknowledgement');
          offset = next;
        } finally { client.close(force: true); _clients.remove(client);
      _dialers.remove(client)?.close(); _outgoingTransfer = null; }
        transferBytes = offset; transferTotal = total;
        transferProgress = total == 0 ? 1 : offset / total;
        onChanged();
      }
      if (_transferCancelled) throw const TransferStopped();
      status = await _pairedRequest(peer, '/uploads/$id/complete', body: {});
      lastUploadReceipt = status;
      if (status['sha256'] != digest) throw const FormatException('Upload checksum mismatch');
      onActivity(Activity(status['skipped'] == true ? localizeMessage("Файл пропущен получателем") : localizeMessage("Файл отправлен"), '$filename → ${peer.name}', name: filename, kind: 'upload'));
      return digest;
    } finally { transferName = null; transferProgress = null; onChanged(); }
  }

  Future<Uint8List> _readTransferBlock(Stream<List<int>> stream, int offset, int total) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream.timeout(const Duration(seconds: 30))) {
      if (builder.length + chunk.length > transferBlockBytes) throw const FormatException('Payload is too large');
      await _pace(chunk.length);
      builder.add(chunk); sessionBytes += chunk.length; transferBytes = offset + builder.length; transferTotal = total; onChanged();
    }
    return builder.takeBytes();
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
      final peer = peers[request.headers.value('X-LinkInDrop-Id')];
      if (peer == null || !secureEquals(
          request.headers.value(HttpHeaders.authorizationHeader) ?? '',
          'Bearer ${peer.incomingToken}')) {
        _respond(request, 401, {'error': 'Unauthorized'});
        return;
      }
      peer.online = true;
      if (request.uri.path.startsWith('/receipts/')) {
        final parts = request.uri.pathSegments;
        if (parts.length != 3 || !RegExp(r'^[a-f0-9]{64}$').hasMatch(parts[1])) throw const FormatException('Invalid receipt');
        if (request.method == 'POST' && parts[2] == 'verify') {
          final body = jsonDecode(utf8.decode(await _readBounded(request, 4096))) as Map<String, dynamic>;
          _respond(request, 200, {'valid': await received.verify(peer.id, parts[1], body['sha256'] as String)});
        } else if (request.method == 'GET' && parts[2] == 'file') {
          await _serveSource(request, peer, 'backup', (offset, length) => received.open(peer.id, parts[1], offset, length));
        } else { _respond(request, 404, {'error': 'Not found'}); }
        return;
      }
      if (request.method == 'POST' && request.uri.path.startsWith('/uploads')) {
        await _acceptUpload(request, peer);
        return;
      }
      if (request.method == 'GET' && (request.uri.path == '/search' || request.uri.path == '/preview')) {
        await _serveTools(request, peer);
        return;
      }
      if (request.method == 'GET' &&
          (request.uri.path == '/files' || request.uri.path.startsWith('/files/'))) {
        await _serveSharedFiles(request, peer);
        return;
      }
      if (request.method == 'GET' &&
          (request.uri.path == '/browse' || request.uri.path == '/browse/file')) {
        await _serveFolders(request, peer);
        return;
      }
      switch ((request.method, request.uri.path)) {
        case ('GET', '/ping'):
          _respond(request, 200, {'v': protocolVersion, 'id': identity.id, 'hosts': _localAddresses, 'features': ['blocks', 'search', 'preview', 'relay']});
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
          onActivity(Activity(localizeMessage("Буфер получен"),
            '${payload.type == 'png' ? localizeMessage("Изображение") : localizeMessage("Текст")} · ${peer.name}'));
          _respond(request, 200, {'ok': true});
        case ('POST', '/file'):
          if (!receivingEnabled || !peer.incomingFilesEnabled) {
            _respond(request, 403, {'error': 'Receiving disabled'});
            return;
          }
          await _acceptFile(request, peer);
        default:
          _respond(request, 404, {'error': 'Not found'});
      }
    } on InsufficientSpace {
      _respond(request, 507, {'error': localizeMessage("Недостаточно свободного места у получателя")});
    } on FileSystemException catch (error) {
      onActivity(Activity(localizeMessage("Ошибка передачи"), '$error', error: true));
      _respond(request, 404, {'error': localizeMessage("Папка или файл недоступны. Обновите список.")});
    } on FormatException {
      _respond(request, 400, {'error': 'Invalid payload'});
    } on TimeoutException {
      _respond(request, 408, {'error': 'Timeout'});
    } catch (error) {
      _respond(request, 500, {'error': 'Request failed'});
      onActivity(Activity(localizeMessage("Ошибка передачи"), '$error', error: true));
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
        additionalHosts: connectionHosts(body['hosts']),
        relayUrl: body['relayUrl'] is String && validRelayUrl(body['relayUrl'] as String) ? body['relayUrl'] as String : null,
        relayRoom: body['relayRoom'] is String && RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(body['relayRoom'] as String) ? body['relayRoom'] as String : null)..online = true;
      peers[peer.id] = peer;
      await savePeers();
      cancelInvite();
      _pairAttempts.remove(remote);
      _respond(request, 200, {'id': identity.id, 'token': token, 'hosts': _localAddresses, 'relayUrl': relayUrl, 'relayRoom': relayRoom});
      onActivity(Activity(localizeMessage("Устройство подключено"), peer.name));
    } finally {
      _pairing = false;
    }
  }

  Future<void> _serveSharedFiles(HttpRequest request, Peer peer) async {
    if (!fileSharingEnabled) { _respond(request, 403, {'error': localizeMessage("Владелец не включил доступ к файлам")}); return; }
    if (request.uri.path == '/files') {
      _respond(request, 200, {'files': (await sharedFiles.list()).where((e) => access.allows(e.id, peer.id)).map((e) => e.toJson()).toList()});
      return;
    }
    final parts = request.uri.pathSegments;
    if (parts.length != 2 || !RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(parts[1])) {
      _respond(request, 404, {'error': 'File not shared'}); return;
    }
    if (!access.allows(parts[1], peer.id)) { _respond(request, 403, {'error': localizeMessage("Доступ к файлу закрыт")}); return; }
    final entry = await sharedFiles.metadata(parts[1]);
    if (entry == null) { _respond(request, 404, {'error': 'File not shared'}); return; }
    await _serveSource(request, peer, entry.name,
      (offset, length) => sharedFiles.open(parts[1], offset: offset, length: length));
  }

  Future<void> _serveSource(HttpRequest request, Peer peer, String name,
      Future<SharedRead> Function(int offset, int? length) open) async {
    if (_downloads >= 2) { _respond(request, 429, {'error': 'Receiver busy'}); return; }
    final header = request.headers.value(HttpHeaders.rangeHeader);
    final match = header == null ? null : RegExp(r'^bytes=([0-9]+)-([0-9]*)$').firstMatch(header);
    if (header != null && match == null) { _respond(request, 416, {'error': 'Invalid range'}); return; }
    final offset = match == null ? 0 : int.parse(match[1]!);
    final end = match == null || match[2]!.isEmpty ? offset + transferBlockBytes - 1 : int.parse(match[2]!);
    if (header != null && (end < offset || end - offset + 1 > transferBlockBytes)) {
      _respond(request, 416, {'error': 'Invalid range'}); return;
    }
    _downloads++;
    SharedRead? source;
    try {
      source = await open(offset, header == null ? null : end - offset + 1);
      if (source.size < 0 || source.size > maxFileBytes) throw const FormatException('Invalid file size');
      final etag = '"${source.version ?? source.size}"';
      request.response.headers.set(HttpHeaders.etagHeader, etag);
      request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      if (request.headers.value(HttpHeaders.ifMatchHeader) != null && request.headers.value(HttpHeaders.ifMatchHeader) != etag) {
        _respond(request, 412, {'error': 'File changed'}); return;
      }
      request.response.headers.contentType = ContentType.binary;
      if (header != null && source.size > 0) {
        if (offset >= source.size) { _respond(request, 416, {'error': 'Invalid range'}); return; }
        final bytes = await _readBounded(source.stream, transferBlockBytes);
        if (bytes.isEmpty) throw const FormatException('Incomplete source');
        request.response.statusCode = 206;
        request.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $offset-${offset + bytes.length - 1}/${source.size}');
        request.response.headers.set('X-LinkInDrop-SHA256', sha256.convert(bytes).toString());
        request.response.contentLength = bytes.length;
        request.response.add(bytes);
      } else {
        request.response.contentLength = source.size;
        try { await request.response.addStream(source.stream).timeout(const Duration(minutes: 30)); }
        catch (error) { onActivity(Activity(localizeMessage("Скачивание прервано"), '$error', error: true)); }
      }
    } finally {
      try { await source?.close(); } catch (_) {} finally { _downloads--; }
    }
  }

  Future<void> _acceptUpload(HttpRequest request, Peer peer) async {
    if (!receivingEnabled || !peer.incomingFilesEnabled) {
      _respond(request, 403, {'error': localizeMessage("Приём файлов от этого устройства отключён")}); return;
    }
    final parts = request.uri.pathSegments;
    Map<String, dynamic> result;
    if (parts.length == 2 && parts[1] == 'mkdir') {
      final body = jsonDecode(utf8.decode(await _readBounded(request, 8192))) as Map<String, dynamic>;
      if (body['relative'] is! String) throw const FormatException('Missing directory');
      await received.createDirectory(body['relative'] as String);
      result = {'ok': true};
    } else if (parts.length == 1 && parts[0] == 'uploads') {
      final body = jsonDecode(utf8.decode(await _readBounded(request, 16384))) as Map<String, dynamic>;
      result = await uploads.start(peer.id, body);
      if (result['done'] != true) await requireSpace(inbox.path, (body['size'] as int) * 2 - (result['offset'] as int));
    } else if (parts.length == 3 && parts[2] == 'block') {
      final offset = int.tryParse(request.uri.queryParameters['offset'] ?? '');
      if (offset == null) throw const FormatException('Missing offset');
      result = await uploads.block(peer.id, parts[1], offset, await _readBounded(request, transferBlockBytes),
        request.headers.value('X-LinkInDrop-SHA256') ?? '');
    } else if (parts.length == 3 && parts[2] == 'complete') {
      await _readBounded(request, 8192);
      result = await uploads.complete(peer.id, parts[1]);
      final path = result.remove('path') as String?;
      final token = received.key(peer.id, parts[1]);
      var receipt = received.receipts[token];
      if (receipt == null) {
        final completed = path == null ? await uploads.completedFile(peer.id, parts[1]) : File(path);
        final metadata = await uploads.metadata(peer.id, parts[1]);
        receipt = await received.deliver(peer.id, parts[1], completed, metadata['relative'] as String? ?? metadata['name'] as String, result['sha256'] as String);
        onActivity(Activity(receipt['skipped'] == true ? localizeMessage("Файл пропущен") : localizeMessage("Файл получен"), '${receipt['name']} · ${peer.name}', path: receipt['location'] as String, name: (receipt['name'] as String?) ?? receipt['location'] as String, kind: 'download'));
      }
      result['receipt'] = token;
      result['skipped'] = receipt['skipped'];
    } else if (parts.length == 3 && parts[2] == 'cancel') {
      await _readBounded(request, 8192);
      await uploads.cancel(peer.id, parts[1]);
      result = {'ok': true};
    } else { _respond(request, 404, {'error': 'Not found'}); return; }
    _respond(request, 200, result);
  }

  Future<void> _serveFolders(HttpRequest request, Peer peer) async {
    request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    if (!fileSharingEnabled) {
      _respond(request, 403, {'error': localizeMessage("Владелец не включил доступ к файлам и папкам")});
      return;
    }
    final query = request.uri.queryParameters;
    final id = query['folder'];
    final path = query['path'] ?? '';
    final offset = int.tryParse(query['offset'] ?? '0');
    if (offset == null || offset < 0 || offset > 100000 || !isSharedPath(path) ||
        (id != null && !RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(id))) {
      throw const FormatException('Invalid directory request');
    }
    if (request.uri.path == '/browse') {
      if (id == null) {
        if (path.isNotEmpty) throw const FormatException('Missing folder');
        final entries = [...sharedFolders.roots(), ...await sharedFiles.list()].where((e) => access.allows(e.id, peer.id)).toList();
        final page = entries.skip(offset).take(200).toList();
        _respond(request, 200, SharedPage(page,
          nextOffset: entries.length > offset + 200 ? offset + 200 : null).toJson());
      } else {
        if (!access.allows(id, peer.id)) { _respond(request, 403, {'error': localizeMessage("Доступ к папке закрыт")}); return; }
        _respond(request, 200, (await sharedFolders.list(id, path, offset: offset)).toJson());
      }
      return;
    }
    if (id == null || path.isEmpty) throw const FormatException('Missing file path');
    if (!access.allows(id, peer.id)) { _respond(request, 403, {'error': localizeMessage("Доступ к папке закрыт")}); return; }
    await _serveSource(request, peer, safeFilename(path),
      (offset, length) => sharedFolders.open(id, path, offset: offset, length: length));
  }

  Future<void> _serveTools(HttpRequest request, Peer peer) async {
    if (!fileSharingEnabled) { _respond(request, 403, {'error': localizeMessage("Доступ к файлам отключён")}); return; }
    final query = request.uri.queryParameters;
    final folder = query['folder'];
    final path = query['path'] ?? '';
    if (!isSharedPath(path)) throw const FormatException('Invalid path');
    if (request.uri.path == '/search') {
      if (folder != null && !access.allows(folder, peer.id)) { _respond(request, 403, {'error': localizeMessage("Доступ закрыт")}); return; }
      final page = await searchService.search(peer: peer.id, query: query['q'] ?? '', cursor: query['cursor'],
        folder: folder == null ? null : SharedFile(id: folder, folderId: folder, relativePath: path, name: localizeMessage("Папка"), size: 0, isDirectory: true),
        roots: () async => [...sharedFolders.roots(), ...await sharedFiles.list()].where((e) => access.allows(e.id, peer.id)).toList(),
        list: (directory, offset) async {
          if (!access.allows(directory.id, peer.id)) throw SearchAccessDenied();
          try { return await sharedFolders.list(directory.id, directory.relativePath!, offset: offset); }
          on FileSystemException { throw SearchAccessDenied(); }
        });
      _respond(request, 200, SharedPage(page.entries.where((e) => access.allows(e.id, peer.id)).toList(), cursor: page.cursor).toJson());
      return;
    }
    final id = folder ?? query['id'] ?? '';
    if (!access.allows(id, peer.id)) { _respond(request, 403, {'error': localizeMessage("Доступ закрыт")}); return; }
    SharedRead? source;
    try {
      String name;
      if (folder != null) {
        source = await sharedFolders.open(folder, path);
        name = safeFilename(path);
      } else {
        final entry = await sharedFiles.metadata(id);
        if (entry == null) throw const FileSystemException('File unavailable');
        source = await sharedFiles.open(id);
        name = entry.name;
      }
      _respond(request, 200, await FilePreview.create(name, source));
    } finally { try { await source?.close(); } catch (_) {} }
  }

  Future<void> _acceptFile(HttpRequest request, Peer peer) async {
    final size = request.contentLength;
    if (size < 0 || size > maxFileBytes || _activeTransfers.length >= 2) {
      _respond(request, 413, {'error': 'File too large or receiver busy'});
      return;
    }
    final encoded = request.headers.value('X-LinkInDrop-Filename');
    if (encoded == null || encoded.length > 2048) throw const FormatException('Missing filename');
    final name = safeFilename(utf8.decode(base64Url.decode(encoded)));
    final id = randomToken(8);
    final temporary = File(p.join(inbox.path, '.$id.part'));
    final output = File(p.join(inbox.path, '${id}_$name'));
    _activeTransfers.add(id);
    await requireSpace(inbox.path, size * 2);
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
      final digest = (await sha256.bind(output.openRead()).first).toString();
      final receipt = await this.received.deliver(peer.id, id, output, name, digest);
      onActivity(Activity(receipt['skipped'] == true ? localizeMessage("Файл пропущен") : localizeMessage("Файл получен"), '$name · ${peer.name}', path: receipt['location'] as String, name: (receipt['name'] as String?) ?? receipt['location'] as String, kind: 'download'));
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
            if (data['app'] != 'linkindrop' || data['v'] != protocolVersion ||
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
      onActivity(Activity(localizeMessage("Поиск устройств недоступен"), localizeMessage("Подключение через QR-код работает")));
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
    final data = utf8.encode(jsonEncode({'app': 'linkindrop', 'v': protocolVersion,
      'id': identity.id, 'name': name, 'port': port}));
    try { _discovery?.send(data, InternetAddress('255.255.255.255'), 45832); } catch (_) {}
    onChanged();
  }

  Future<void> stop() async {
    _stopping = true;
    await _networkChanges.catchError((Object _) {});
    await relayHost?.close();
    relayHost = null;
    for (final dialer in _dialers.values.toList()) { dialer.close(); }
    _dialers.clear();
    _healthTimer?.cancel();
    _discoveryTimer?.cancel();
    _discovery?.close();
    for (final client in _clients.toList()) { client.close(force: true); }
    _clients.clear();
    await _server?.close(force: true);
    _server = null;
  }
}

