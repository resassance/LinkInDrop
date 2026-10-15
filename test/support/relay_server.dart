import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

String _token() => base64Url.encode(List.generate(24, (_) => Random.secure().nextInt(256))).replaceAll('=', '');

class RelayServer {
  RelayServer({this.maxRooms = 1000, this.maxTunnels = 2000});
  final int maxRooms;
  final int maxTunnels;
  final Map<String, WebSocket> _hosts = {};
  final Map<String, _Pending> _pending = {};
  final Set<WebSocket> _sockets = {};
  HttpServer? _server;
  int get port => _server!.port;

  Future<void> start({String host = '127.0.0.1', int port = 8080, SecurityContext? tls}) async {
    _server = tls == null ? await HttpServer.bind(host, port) : await HttpServer.bindSecure(host, port, tls);
    _server!.listen((request) => unawaited(_handle(request)));
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      if (request.uri.path == '/health' && request.method == 'GET') {
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"ok":true}');
        await request.response.close();
        return;
      }
      final room = request.uri.queryParameters['room'] ?? '';
      if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(room) || !WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = 400; await request.response.close(); return;
      }
      final role = request.uri.path;
      if (role == '/host') {
        if (_hosts.containsKey(room) || _hosts.length >= maxRooms) {
          request.response.statusCode = 409; await request.response.close(); return;
        }
        final ws = await WebSocketTransformer.upgrade(request);
        if (_hosts.containsKey(room)) { await ws.close(1008); return; }
        _hosts[room] = ws;
        _sockets.add(ws);
        ws.pingInterval = const Duration(seconds: 20);
        ws.listen((data) {
          if (data is! String || data.length > 128) unawaited(ws.close(1008));
        }, onDone: () {
          if (_hosts[room] == ws) _hosts.remove(room);
          _sockets.remove(ws);
        }, onError: (Object _) { _hosts.remove(room); _sockets.remove(ws); });
      } else if (role == '/join') {
        final host = _hosts[room];
        final count = _pending.values.where((p) => p.room == room).length;
        if (host == null || _sockets.length >= maxTunnels * 2 || count >= 16) {
          request.response.statusCode = host == null ? 503 : 429; await request.response.close(); return;
        }
        final ws = await WebSocketTransformer.upgrade(request);
        _sockets.add(ws);
        final id = _token();
        final pending = _Pending(room, ws);
        _pending[id] = pending;
        pending.timer = Timer(const Duration(seconds: 15), () {
          if (_pending.remove(id) != null) { _sockets.remove(ws); unawaited(ws.close(1013)); }
        });
        host.add(jsonEncode({'type': 'open', 'id': id}));
      } else if (role == '/accept') {
        final id = request.uri.queryParameters['id'];
        final pending = _pending[id];
        if (pending == null || pending.room != room) {
          request.response.statusCode = 404; await request.response.close(); return;
        }
        _pending.remove(id);
        pending.timer?.cancel();
        final ws = await WebSocketTransformer.upgrade(request);
        _sockets.add(ws);
        _bridge(pending.socket, ws);
      } else {
        request.response.statusCode = 404; await request.response.close();
      }
    } catch (_) {
      try { request.response.statusCode = 500; await request.response.close(); } catch (_) {}
    }
  }

  void _bridge(WebSocket first, WebSocket second) {
    var closed = false;
    Future<void> close() async {
      if (closed) return;
      closed = true;
      _sockets.remove(first); _sockets.remove(second);
      await Future.wait([first.close(), second.close()]);
    }
    Stream<List<int>> bytes(WebSocket socket) async* {
      await for (final frame in socket) {
        if (frame is! List<int> || frame.length > 1024 * 1024) throw const FormatException('Invalid tunnel frame');
        yield frame;
      }
    }
    unawaited(() async { try { await first.addStream(bytes(second)); } catch (_) {} finally { await close(); } }());
    unawaited(() async { try { await second.addStream(bytes(first)); } catch (_) {} finally { await close(); } }());
  }

  Future<void> close() async {
    for (final value in _pending.values) { value.timer?.cancel(); }
    _pending.clear(); _hosts.clear();
    await Future.wait(_sockets.toList().map((s) => s.close()));
    _sockets.clear();
    await _server?.close(force: true);
  }
}

class _Pending {
  _Pending(this.room, this.socket);
  final String room;
  final WebSocket socket;
  Timer? timer;
}
