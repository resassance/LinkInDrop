import '../l10n/messages.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

bool validRelayUrl(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null || uri.host.isEmpty || uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment ||
      (uri.path.isNotEmpty && uri.path != '/')) return false;
  return uri.scheme == 'wss' || (uri.scheme == 'ws' && ['127.0.0.1', 'localhost', '::1'].contains(uri.host));
}

Uri relayEndpoint(String url, String role, String room, {String? id}) {
  if (!validRelayUrl(url) || !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(room)) {
    throw FormatException(localizeMessage("Нужен адрес wss:// сервера ретрансляции"));
  }
  return Uri.parse(url).replace(path: '/$role', queryParameters: {'room': room, if (id != null) 'id': id});
}

Future<void> bridgeSocket(WebSocket ws, Socket socket) async {
  var closed = false;
  Future<void> close() async {
    if (closed) return;
    closed = true;
    socket.destroy();
    try { await ws.close(); } catch (_) {}
  }
  Stream<List<int>> frames() async* {
    await for (final frame in ws) {
      if (frame is! List<int> || frame.length > 1024 * 1024) throw const FormatException('Invalid tunnel data');
      yield frame;
    }
  }
  await Future.wait([
    () async { try { await ws.addStream(() async* {
      await for (final chunk in socket) {
        for (var offset = 0; offset < chunk.length; offset += 65536) {
          yield chunk.sublist(offset, offset + 65536 < chunk.length ? offset + 65536 : chunk.length);
        }
      }
    }()); } catch (_) {} finally { await close(); } }(),
    () async { try { await socket.addStream(frames()); } catch (_) {} finally { await close(); } }(),
  ]);
  try { await ws.close(); } catch (_) {}
}

class RelayDialer {
  RelayDialer(this.url, this.room, {required this.acceptCertificate});
  final String url;
  final String room;
  final bool Function(X509Certificate) acceptCertificate;
  ServerSocket? _listener;
  Future<int>? _port;
  final Set<Socket> _sockets = {};
  final Set<WebSocket> _websockets = {};
  bool _closed = false;

  Future<ConnectionTask<Socket>> connect(Uri uri, String? proxyHost, int? proxyPort) async {
    final port = await (_port ??= _listen());
    if (_closed) throw const SocketException('Tunnel closed');
    return SecureSocket.startConnect(InternetAddress.loopbackIPv4, port,
      context: SecurityContext(withTrustedRoots: false), onBadCertificate: acceptCertificate);
  }

  Future<int> _listen() async {
    _listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    if (_closed) { await _listener!.close(); throw const SocketException('Tunnel closed'); }
    _listener!.listen((socket) => unawaited(() async {
      _sockets.add(socket);
      WebSocket? ws;
      try {
        ws = await WebSocket.connect(relayEndpoint(url, 'join', room).toString()).timeout(const Duration(seconds: 15));
        if (_closed) { await ws.close(); return; }
        _websockets.add(ws);
        await bridgeSocket(ws, socket);
      } catch (_) { socket.destroy(); } finally {
        _sockets.remove(socket);
        if (ws != null) _websockets.remove(ws);
        socket.destroy();
      }
    }()));
    return _listener!.port;
  }

  void close() {
    _closed = true;
    unawaited(_listener?.close());
    for (final socket in _sockets.toList()) { socket.destroy(); }
    for (final ws in _websockets.toList()) {
      unawaited(() async { try { await ws.close(); } catch (_) {} }());
    }
    _sockets.clear(); _websockets.clear();
  }
}

class RelayHost {
  RelayHost({required this.url, required this.room, required this.localPort, required this.changed});
  final String url;
  final String room;
  final int localPort;
  final void Function() changed;
  bool online = false;
  bool _closed = false;
  WebSocket? _control;
  Timer? _retry;
  final Set<WebSocket> _tunnels = {};
  final Set<Socket> _local = {};

  Future<void> start() async {
    if (_closed) return;
    try {
      final ws = await WebSocket.connect(relayEndpoint(url, 'host', room).toString()).timeout(const Duration(seconds: 15));
      if (_closed) { await ws.close(); return; }
      _control = ws;
      online = true;
      changed();
      ws.pingInterval = const Duration(seconds: 20);
      ws.listen((frame) {
        if (frame is! String || frame.length > 1024) { unawaited(ws.close(1008)); return; }
        try {
          final data = jsonDecode(frame) as Map<String, dynamic>;
          final id = data['id'];
          if (data['type'] == 'open' && id is String && RegExp(r'^[A-Za-z0-9_-]{32}$').hasMatch(id) && _tunnels.length < 16) {
            unawaited(_accept(id));
          }
        } catch (_) {}
      }, onDone: _reconnect, onError: (Object _) => _reconnect());
    } catch (_) { _reconnect(); }
  }

  void _reconnect() {
    online = false;
    changed();
    _retry?.cancel();
    if (!_closed) _retry = Timer(const Duration(seconds: 5), () => unawaited(start()));
  }

  Future<void> _accept(String id) async {
    WebSocket? ws;
    Socket? socket;
    try {
      ws = await WebSocket.connect(relayEndpoint(url, 'accept', room, id: id).toString()).timeout(const Duration(seconds: 15));
      socket = await Socket.connect(InternetAddress.loopbackIPv4, localPort, timeout: const Duration(seconds: 5));
      if (_closed) return;
      _tunnels.add(ws); _local.add(socket);
      await bridgeSocket(ws, socket);
    } catch (_) {} finally {
      if (ws != null) { _tunnels.remove(ws); try { await ws.close(); } catch (_) {} }
      if (socket != null) { _local.remove(socket); socket.destroy(); }
    }
  }

  Future<void> close() async {
    _closed = true;
    _retry?.cancel();
    online = false;
    await _control?.close();
    for (final socket in _local.toList()) { socket.destroy(); }
    await Future.wait(_tunnels.toList().map((ws) async { try { await ws.close(); } catch (_) {} }));
    _tunnels.clear(); _local.clear();
  }
}
