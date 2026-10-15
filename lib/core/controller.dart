import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'clipboard_adapter.dart';
import 'models.dart';
import 'node.dart';
import 'windows_network.dart';

class BridgeController extends ChangeNotifier {
  BridgeController({ClipboardAdapter? clipboard}) : clipboard = clipboard ?? ClipboardAdapter();
  final ClipboardAdapter clipboard;
  final List<Activity> activities = [];
  final List<String> pendingFiles = [];
  final platformChannel = const MethodChannel('nearbridge/system');
  BridgeNode? node;
  Directory? directory;
  bool loading = true;
  bool busy = false;
  bool autoClipboard = true;
  bool receiveClipboard = true;
  bool receiveFiles = true;
  bool shareFiles = false;
  bool mobileActive = true;
  String deviceName = Platform.localHostname;
  String? startupError;
  String? selectedPeerId;
  String? pairingStage;
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
        shareFiles = data['shareFiles'] as bool? ?? false;
      }
      node = BridgeNode(directory: directory!, name: deviceName,
        onPairRequest: (name) async => await pairingApproval?.call(name) ?? false,
        onClipboard: _receiveClipboard, onActivity: record, onChanged: notifyListeners);
      await node!.start();
      final received = await node!.inbox.list().where((item) => item is File &&
        !p.basename(item.path).startsWith('.')).cast<File>().toList();
      received.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
      for (final file in received.take(20)) {
        activities.add(Activity('Файл получен', p.basename(file.path).replaceFirst(RegExp(r'^[A-Za-z0-9_-]{11}_'), ''), path: file.path));
      }
      node!.clipboardReceivingEnabled = receiveClipboard;
      node!.receivingEnabled = receiveFiles;
      node!.fileSharingEnabled = shareFiles;
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
      'shareFiles': shareFiles,
    }), flush: true);
  }

  Future<void> setSettings({bool? automatic, bool? clipboardReceiving, bool? filesReceiving,
    bool? fileSharing}) async {
    if (automatic != null) autoClipboard = automatic;
    if (clipboardReceiving != null) receiveClipboard = clipboardReceiving;
    if (filesReceiving != null) receiveFiles = filesReceiving;
    if (fileSharing != null) shareFiles = fileSharing;
    node?.clipboardReceivingEnabled = receiveClipboard;
    node?.receivingEnabled = receiveFiles;
    node?.fileSharingEnabled = shareFiles;
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
    final invite = PairInvite.parse(code);
    try {
      await node!.pair(invite, onStage: (stage) {
        pairingStage = stage;
        notifyListeners();
      });
      selectedPeerId = invite.id;
    } finally {
      pairingStage = null;
      notifyListeners();
    }
  }

  Future<void> configureNetwork() async {
    final current = node;
    if (current == null) throw StateError('Соединение ещё не запущено');
    await configureWindowsNetwork(current.port);
    record(Activity('Локальные подключения разрешены', 'Windows Firewall · TCP ${current.port} · UDP 45832'));
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
        await node!.sendClipboard(payload);
        _lastDigest = digest;
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
    await node!.sendClipboard(payload);
    _lastDigest = payload.digest;
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

  Future<void> sendPendingFiles() async {
    for (final path in pendingFiles.toList()) {
      await sendFile(path);
      pendingFiles.remove(path);
      if (directory != null && p.isWithin(p.join(directory!.path, 'shared'), path)) {
        final file = File(path);
        if (await file.exists()) await file.delete();
      }
      notifyListeners();
    }
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
      pendingFiles.addAll(files);
      if (selectedPeer == null && peers.where((p) => p.online).length == 1) {
        selectedPeerId = peers.firstWhere((p) => p.online).id;
      }
      if (selectedPeer != null) await run(sendPendingFiles);
      notifyListeners();
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

