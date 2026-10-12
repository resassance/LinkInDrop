import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'clipboard_adapter.dart';
import 'models.dart';
import 'node.dart';

class BridgeController extends ChangeNotifier {
  BridgeController({ClipboardAdapter? clipboard}) : clipboard = clipboard ?? ClipboardAdapter();
  final ClipboardAdapter clipboard;
  final List<Activity> activities = [];
  final platformChannel = const MethodChannel('nearbridge/system');
  BridgeNode? node;
  Directory? directory;
  bool loading = true;
  bool busy = false;
  bool autoClipboard = true;
  bool receiveClipboard = true;
  bool receiveFiles = true;
  bool mobileActive = true;
  String deviceName = Platform.localHostname;
  String? startupError;
  String? selectedPeerId;
  String? _lastDigest;
  Timer? _clipboardTimer;
  bool _polling = false;
  Future<void> _clipboardQueue = Future.value();
  Future<bool> Function(String)? pairingApproval;
  bool get isAndroid => Platform.isAndroid;
  List<Peer> get peers => node?.peers.values.toList() ?? [];
  int get onlineCount => peers.where((p) => p.online).length;
  Peer? get selectedPeer {
    for (final peer in peers) {
      if (peer.id == selectedPeerId) return peer;
    }
    return null;
  }

  void record(Activity activity) {
    activities.insert(0, activity);
    if (activities.length > 40) activities.removeLast();
    notifyListeners();
  }

  Future<void> start() async {
    try {
      directory = await getApplicationSupportDirectory();
      final settings = File(p.join(directory!.path, 'settings.json'));
      if (await settings.exists()) {
        final data = jsonDecode(await settings.readAsString()) as Map<String, dynamic>;
        deviceName = data['name'] as String? ?? deviceName;
        autoClipboard = data['autoClipboard'] as bool? ?? true;
        receiveClipboard = data['receiveClipboard'] as bool? ?? true;
        receiveFiles = data['receiveFiles'] as bool? ?? true;
      }
      node = BridgeNode(directory: directory!, name: deviceName,
        onPairRequest: (name) async => await pairingApproval?.call(name) ?? false,
        onClipboard: _receiveClipboard, onActivity: record, onChanged: notifyListeners);
      await node!.start();
      node!.clipboardReceivingEnabled = receiveClipboard;
      node!.receivingEnabled = receiveFiles;
      _clipboardTimer = Timer.periodic(const Duration(milliseconds: 1200),
        (_) => unawaited(_pollClipboard()));
      await node!.checkPeers();
      if (isAndroid) {
        platformChannel.setMethodCallHandler((call) async {
          if (call.method == 'shared') await handleShared();
        });
        await platformChannel.invokeMethod<void>('startConnection');
        await handleShared();
      }
    } catch (error) {
      startupError = '$error';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> _saveSettings() async {
    if (directory == null) return;
    await File(p.join(directory!.path, 'settings.json')).writeAsString(jsonEncode({
      'name': deviceName, 'autoClipboard': autoClipboard,
      'receiveClipboard': receiveClipboard, 'receiveFiles': receiveFiles,
    }), flush: true);
  }

  Future<void> setSettings({bool? automatic, bool? clipboardReceiving, bool? filesReceiving}) async {
    if (automatic != null) autoClipboard = automatic;
    if (clipboardReceiving != null) receiveClipboard = clipboardReceiving;
    if (filesReceiving != null) receiveFiles = filesReceiving;
    node?.clipboardReceivingEnabled = receiveClipboard;
    node?.receivingEnabled = receiveFiles;
    await _saveSettings();
    notifyListeners();
  }

  Future<void> rename(String value) async {
    final name = value.trim();
    if (name.isEmpty || name.length > 80) throw StateError('Имя должно содержать 1–80 символов');
    deviceName = name;
    node?.name = name;
    await _saveSettings();
    notifyListeners();
  }

  Future<void> run(Future<void> Function() operation) async {
    if (busy) return;
    busy = true;
    notifyListeners();
    try {
      await operation();
    } catch (error) {
      record(Activity('Не получилось', '$error', error: true));
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> pair(String code) async {
    await node!.pair(PairInvite.parse(code));
    selectedPeerId = peers.last.id;
    notifyListeners();
  }

  Future<void> setPeerClipboard(Peer peer, bool enabled) async {
    peer.clipboardEnabled = enabled;
    await node?.savePeers();
    notifyListeners();
  }

  Future<void> forget(Peer peer) async {
    await node?.forget(peer.id);
    if (selectedPeerId == peer.id) selectedPeerId = null;
    notifyListeners();
  }

  void selectPeer(String id) {
    selectedPeerId = id;
    notifyListeners();
  }

  Future<void> _serializeClipboard(Future<void> Function() action) {
    final next = _clipboardQueue.catchError((Object _) {}).then((_) => action());
    _clipboardQueue = next;
    return next;
  }

  Future<void> _pollClipboard() async {
    if (_polling || !autoClipboard || node == null ||
        (isAndroid && !mobileActive) || onlineCount == 0) return;
    _polling = true;
    try {
      await _serializeClipboard(() async {
        if (isAndroid && await platformChannel.invokeMethod<bool>('clipboardSensitive') == true) return;
        final payload = await clipboard.read();
        if (payload == null) { _lastDigest = null; return; }
        final digest = payload.digest;
        if (_lastDigest == null) { _lastDigest = digest; return; }
        if (digest == _lastDigest) return;
        _lastDigest = digest;
        await node!.sendClipboard(payload);
      });
    } catch (_) {
    } finally {
      _polling = false;
    }
  }

  Future<void> pushClipboard() => _serializeClipboard(() async {
    if (isAndroid && await platformChannel.invokeMethod<bool>('clipboardSensitive') == true) {
      throw StateError('Приложение пометило буфер как конфиденциальный');
    }
    final payload = await clipboard.read();
    if (payload == null) throw StateError('В буфере нет текста или изображения');
    _lastDigest = payload.digest;
    await node!.sendClipboard(payload);
  });

  Future<void> _receiveClipboard(ClipboardPayload payload) => _serializeClipboard(() async {
    if (!receiveClipboard) return;
    await clipboard.write(payload);
    _lastDigest = payload.digest;
  });

  Future<void> sendText(String text) async {
    if (text.trim().isEmpty) throw StateError('Введите текст');
    final data = Uint8List.fromList(utf8.encode(text));
    if (data.length > maxTextBytes) throw StateError('Текст больше 256 КБ');
    await node!.sendClipboard(ClipboardPayload(id: randomToken(16), type: 'text',
      data: data, createdAt: DateTime.now()));
  }

  Future<void> sendFile(String path, {String? name}) async {
    final peer = selectedPeer;
    if (peer == null) throw StateError('Выберите устройство');
    await node!.sendFile(peer, path, filename: name);
  }

  Future<void> handleShared() async {
    if (!isAndroid || node == null) return;
    final shared = await platformChannel.invokeMapMethod<String, dynamic>('takeShared');
    if (shared == null) return;
    if (shared['clipboard'] == true) {
      await run(pushClipboard);
      return;
    }
    final text = shared['text'] as String?;
    if (text != null && text.isNotEmpty) await run(() => sendText(text));
    final files = (shared['files'] as List<dynamic>? ?? []).cast<String>();
    if (files.isNotEmpty) {
      if (selectedPeer == null && peers.where((p) => p.online).length == 1) {
        selectedPeerId = peers.firstWhere((p) => p.online).id;
      }
      for (final file in files) {
        await run(() => sendFile(file));
      }
    }
  }

  Future<void> shutdown() async {
    _clipboardTimer?.cancel();
    if (isAndroid) await platformChannel.invokeMethod<void>('stopConnection');
    await node?.stop();
  }

  @override
  void dispose() {
    _clipboardTimer?.cancel();
    super.dispose();
  }
}
