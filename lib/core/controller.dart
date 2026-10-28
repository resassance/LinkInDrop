import '../l10n/messages.dart';
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
import 'android_folders.dart';
import 'shared_folders.dart';
import 'transfer_protocol.dart';
import 'transfer_queue.dart';
import 'photo_backup.dart';
import 'desktop_shell.dart';
import 'access_rules.dart';
import 'release_info.dart';
import 'receive_storage.dart';
import 'send_selection.dart';
import 'media_library.dart';
import 'file_preview.dart';

class BridgeController extends ChangeNotifier {
  BridgeController({ClipboardAdapter? clipboard, this.launchedAtStartup = false}) : clipboard = clipboard ?? ClipboardAdapter() {
    selection.addListener(notifyListeners);
  }
  final ClipboardAdapter clipboard;
  final bool launchedAtStartup;
  final selection = SendSelection();
  final Map<String, String> gallerySources = {};
  String themePreference = 'system';
  String languagePreference = 'system';
  final List<Activity> activities = [];
  final List<String> pendingFiles = [];
  final platformChannel = const MethodChannel('linkindrop/system');
  BridgeNode? node;
  TransferQueue? queue;
  PhotoBackup? backup;
  DesktopShell? desktop;
  bool closeToTray = true;
  bool startMinimized = true;
  String? relayAddress;
  String? receiveDestination;
  String conflictPolicy = "rename";
  bool sortReceived = true;
  bool androidDirectWifi = false;
  Map<String, dynamic> localNetwork = {};
  int speedLimit = 0;
  bool androidBackground = true;
  bool androidBoot = false;
  Map<String, dynamic> backgroundStatus = {};
  final List<String> recentPeers = [];
  final List<Map<String, dynamic>> favorites = [];
  Map<String, String>? newerRelease;
  String? updateMessage;
  Directory? directory;
  bool loading = true;
  bool busy = false;
  bool autoClipboard = true;
  bool receiveClipboard = true;
  bool receiveFiles = true;
  bool shareFiles = false;
  bool mobileActive = !Platform.isAndroid;
  DateTime _lastNotification = DateTime.fromMillisecondsSinceEpoch(0);
  String deviceName = Platform.localHostname;
  String? startupError;
  String? selectedPeerId;
  String? pairingStage;
  String? _lastDigest;
  Timer? _clipboardTimer;
  bool _polling = false;
  Future<void> _clipboardQueue = Future.value();
  Future<bool> Function(String)? pairingApproval;
  Future<void> _settingsSaving = Future.value();
  bool get isAndroid => Platform.isAndroid;
  List<Peer> get peers => node?.peers.values.toList() ?? [];
  int get onlineCount => peers.where((p) => p.online).length;
  Peer? get selectedPeer {
    for (final peer in peers) {
      if (peer.id == selectedPeerId) return peer;
    }
    return peers.length == 1 ? peers.single : null;
  }

  void changed() => notifyListeners();

  void _nodeChanged() {
    notifyListeners();
    if (isAndroid && DateTime.now().difference(_lastNotification).inSeconds >= 1) {
      _lastNotification = DateTime.now();
      unawaited(platformChannel.invokeMethod<void>('updateConnectionStatus', {'text': node?.transferName == null ? localizeMessage("Устройств: {0} · в очереди: {1}", [onlineCount, queue?.pending ?? 0]) : '${node!.transferName} · ${((node!.transferProgress ?? 0) * 100).round()}%'}).catchError((Object _) {}));
    }
  }

  void record(Activity activity) {
    if (activity.kind == 'upload' && queue?.active != null) return;
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
        themePreference = ['system', 'light', 'dark'].contains(data['theme']) ? data['theme'] as String : 'system';
        languagePreference = ['system', 'ru', 'en'].contains(data['language']) ? data['language'] as String : 'system';
        deviceName = data['name'] as String? ?? deviceName;
        autoClipboard = data['autoClipboard'] as bool? ?? true;
        receiveClipboard = data['receiveClipboard'] as bool? ?? true;
        receiveFiles = data['receiveFiles'] as bool? ?? true;
        shareFiles = data['shareFiles'] as bool? ?? false;
        closeToTray = data['closeToTray'] as bool? ?? true;
        startMinimized = data['startMinimized'] as bool? ?? true;
        relayAddress = data['relay'] as String?;
        receiveDestination = data['receiveDestination'] as String?;
        conflictPolicy = data['conflictPolicy'] as String? ?? 'rename';
        sortReceived = data['sortReceived'] as bool? ?? true;
        androidDirectWifi = data['androidDirectWifi'] == true;
        speedLimit = data['speedLimit'] as int? ?? 0;
        androidBackground = data['androidBackground'] as bool? ?? true;
        androidBoot = data['androidBoot'] as bool? ?? false;
        selectedPeerId = data['selectedPeer'] as String?;
        recentPeers.addAll((data['recentPeers'] as List? ?? []).cast<String>());
        favorites.addAll((data['favorites'] as List? ?? []).map((e) => (e as Map).cast<String, dynamic>()));
      }
      messageLanguage = languagePreference;
      if (isAndroid) {
        localNetwork = await platformChannel.invokeMapMethod<String, dynamic>('setDirectWifi', {'enabled': androidDirectWifi}) ?? {};
      }
      if (isAndroid && receiveDestination?.startsWith('content://') == true) await const AndroidFolders().retain(receiveDestination!);
      node = BridgeNode(directory: directory!, name: deviceName,
        folderProvider: isAndroid ? const AndroidFolders() : null,
        onPairRequest: (name) async => await pairingApproval?.call(name) ?? false,
        onClipboard: _receiveClipboard, onActivity: record, onChanged: _nodeChanged);
      node!.clipboardReceivingEnabled = receiveClipboard; node!.receivingEnabled = receiveFiles; node!.fileSharingEnabled = shareFiles;
      node!.bytesPerSecond = speedLimit;
      node!.preferredAddresses = (localNetwork['addresses'] as List? ?? []).cast<String>();
      await node!.start(destination: receiveDestination, conflictPolicy: conflictPolicy, sortReceived: sortReceived);
      if (relayAddress != null) unawaited(node!.configureRelay(relayAddress));
      queue = TransferQueue(directory: directory!, execute: _executeJob,
        interrupt: () => node?.cancelTransfer(), completed: (job) async { await backup?.completed(job); await _rememberTransfer(job); await _cleanShared(job); },
        discard: (job) async {
          await node?.discardDownload(job.id);
          backup?.cancelled(job);
          await _cleanShared(job);
          final peer = node?.peers[job.peerId];
          if (peer != null && peer.online && job.progress > 0 && (job.kind == 'upload' || job.kind == 'backup')) {
            try { await node!.cancelUpload(peer, job.id); } catch (_) {}
          }
        })..addListener(notifyListeners);
      await queue!.load();
      backup = PhotoBackup(directory: directory!,
        sources: SharedFolders(directory!, documents: isAndroid ? const AndroidFolders() : null,
          stateFilename: 'backup-folders.json'), enqueue: queue!.addAll,
        available: (id) => node?.peers[id]?.online == true, changed: notifyListeners,
        verifyCopy: (id, receipt, digest) => node!.verifyReceipt(node!.peers[id]!, receipt, digest));
      await backup!.load(queue!.jobs);
      await queue!.setBackupEnabled(backup!.enabled);
      queue!.start();
      if (Platform.isWindows || Platform.isLinux) {
        desktop = DesktopShell(directory: directory!, hideOnClose: () => closeToTray, shutdown: shutdown);
        try { await desktop!.start(launchedAtStartup: launchedAtStartup, startMinimized: startMinimized, language: languagePreference); } catch (error) { record(Activity(localizeMessage("Фоновый режим недоступен"), '$error', error: true)); }
      }
      final delivered = node!.received.receipts.values.where((item) => item['skipped'] != true).toList().reversed.take(20);
      final recorded = <String>{};
      for (final item in delivered) {
        final location = item['location'] as String;
        if (!recorded.add(location)) continue;
        activities.add(Activity(localizeMessage("Файл получен"), item['name'] as String, path: location));
      }
      final received = await node!.inbox.list().where((item) => item is File &&
        !p.basename(item.path).startsWith('.') && !recorded.contains(item.path)).cast<File>().toList();
      received.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
      for (final file in received.take(activities.length >= 20 ? 0 : 20 - activities.length)) {
        activities.add(Activity(localizeMessage("Файл получен"), p.basename(file.path).replaceFirst(RegExp(r'^[A-Za-z0-9_-]{11}_'), ''), path: file.path));
      }
      node!.clipboardReceivingEnabled = receiveClipboard;
      node!.receivingEnabled = receiveFiles;
      node!.fileSharingEnabled = shareFiles;
      _clipboardTimer = Timer.periodic(const Duration(milliseconds: 1200),
        (_) => unawaited(_pollClipboard()));
      await node!.checkPeers();
      unawaited(backup?.scan());
      if (isAndroid) {
        platformChannel.setMethodCallHandler((call) async {
          if (call.method == 'shared') await handleShared();
          if (call.method == 'localNetworkChanged') await refreshLocalNetwork(reconnect: true);
        });
        await platformChannel.invokeMethod<void>('setLanguage', {'language': languagePreference});
        await platformChannel.invokeMethod<void>('setBackgroundSettings', {'enabled': androidBackground, 'boot': androidBoot});
        await refreshBackground();
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
    final content = jsonEncode({
      'theme': themePreference, 'language': languagePreference,
      'name': deviceName, 'autoClipboard': autoClipboard,
      'receiveClipboard': receiveClipboard, 'receiveFiles': receiveFiles,
      'shareFiles': shareFiles, 'closeToTray': closeToTray, 'startMinimized': startMinimized, 'relay': relayAddress,
      'receiveDestination': receiveDestination, 'conflictPolicy': conflictPolicy, 'speedLimit': speedLimit,
      'sortReceived': sortReceived, 'androidDirectWifi': androidDirectWifi,
      'androidBackground': androidBackground, 'androidBoot': androidBoot, 'recentPeers': recentPeers,
      'selectedPeer': selectedPeerId, 'favorites': favorites,
    });
    _settingsSaving = _settingsSaving.catchError((Object _) {}).then((_) async {
      final file = File(p.join(directory!.path, 'settings.json.new'));
      await file.writeAsString(content, flush: true);
      await file.rename(p.join(directory!.path, 'settings.json'));
    });
    await _settingsSaving;
  }

  Future<void> setAppearance({String? theme, String? language}) async {
    if (theme != null && !['system', 'light', 'dark'].contains(theme)) throw ArgumentError.value(theme);
    if (language != null && !['system', 'ru', 'en'].contains(language)) throw ArgumentError.value(language);
    if (theme != null) themePreference = theme;
    if (language != null) languagePreference = language;
    messageLanguage = languagePreference;
    notifyListeners();
    await _saveSettings();
    await desktop?.refreshLabels(languagePreference);
    if (isAndroid) await platformChannel.invokeMethod<void>('setLanguage', {'language': languagePreference});
  }

  Future<void> stageFiles(List<String> paths, {Map<String, String> names = const {}}) async {
    await selection.add(paths, names: names);
    notifyListeners();
  }

  Future<void> removeSelected(SelectedSource source) async {
    if (selection.sending) return;
    selection.remove(source);
    gallerySources.removeWhere((uri, path) => path == source.path);
    pendingFiles.remove(source.path);
    if (source.directory && directory != null && p.isWithin(p.join(directory!.path, 'shared'), source.path)) {
      final folder = Directory(source.path);
      if (await folder.exists()) await folder.delete(recursive: true);
    } else { await _cleanSharedSource(source.path); }
    notifyListeners();
  }

  Future<void> sendSelection() async {
    final peer = selectedPeer;
    if (peer == null) throw StateError(localizeMessage("Выберите устройство"));
    await selection.send((items) async {
      await enqueuePaths(peer, items.map((item) => item.path).toList(),
        names: {for (final item in items) item.path: item.name});
      pendingFiles.removeWhere((path) => items.any((item) => item.path == path));
      gallerySources.removeWhere((uri, path) => items.any((item) => item.path == path));
    });
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
    if (name.isEmpty || name.length > 80) throw StateError(localizeMessage("Имя должно содержать 1–80 символов"));
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
      record(Activity(localizeMessage("Не получилось"), '$error', error: true));
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> pair(String code) async {
    final invite = PairInvite.parse(code);
    if (relayAddress == null && invite.relayUrl != null) await setRelay(invite.relayUrl!);
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
    if (current == null) throw StateError(localizeMessage("Соединение ещё не запущено"));
    await configureWindowsNetwork(current.port);
    record(Activity(localizeMessage("Локальные подключения разрешены"), 'Windows Firewall · TCP ${current.port} · UDP 45832'));
  }

  Future<void> setPeerClipboard(Peer peer, bool enabled) async {
    peer.clipboardEnabled = enabled;
    await node?.savePeers();
    notifyListeners();
  }

  Future<void> forget(Peer peer) async {
    if (queue != null) {
      for (final job in queue!.jobs.where((j) => j.peerId == peer.id).toList()) { await queue!.cancel(job); }
    }
    if (backup?.peerId == peer.id) await setPhotoBackup(false);
    recentPeers.remove(peer.id); favorites.removeWhere((f) => f['peer'] == peer.id);
    await _saveSettings();
    await node?.forget(peer.id);
    if (selectedPeerId == peer.id) selectedPeerId = null;
    notifyListeners();
  }

  void selectPeer(String id) {
    selectedPeerId = id;
    recentPeers.remove(id); recentPeers.insert(0, id);
    if (recentPeers.length > 8) recentPeers.removeLast();
    unawaited(_saveSettings());
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
      throw StateError(localizeMessage("Приложение пометило буфер как конфиденциальный"));
    }
    final payload = await clipboard.read();
    if (payload == null) throw StateError(localizeMessage("В буфере нет текста или изображения"));
    final peer = selectedPeer;
    if (peer == null) throw StateError(localizeMessage('Выберите устройство'));
    await node!.sendClipboard(payload, target: peer);
    _lastDigest = payload.digest;
  });

  Future<void> _receiveClipboard(ClipboardPayload payload) => _serializeClipboard(() async {
    if (!receiveClipboard) return;
    await clipboard.write(payload);
    _lastDigest = payload.digest;
  });

  Future<void> sendText(String text) async {
    if (text.trim().isEmpty) throw StateError(localizeMessage("Введите текст"));
    final data = Uint8List.fromList(utf8.encode(text));
    if (data.length > maxTextBytes) throw StateError(localizeMessage("Текст больше 256 КБ"));
    final peer = selectedPeer;
    if (peer == null) throw StateError(localizeMessage('Выберите устройство'));
    await node!.sendClipboard(ClipboardPayload(id: randomToken(16), type: 'text',
      data: data, createdAt: DateTime.now()), target: peer);
  }

  Future<void> sendFile(String path, {String? name}) async {
    final peer = selectedPeer;
    if (peer == null) throw StateError(localizeMessage("Выберите устройство"));
    await enqueuePaths(peer, [path], names: name == null ? null : {path: name});
  }

  Future<void> _rememberTransfer(TransferJob job) async {
    if (job.kind != 'upload' && job.kind != 'backup') return;
    String? thumbnail;
    if (job.source != null) {
      try {
        Uint8List? bytes;
        if (isAndroid || RegExp(r'\.(mp4|mov|mkv|webm|m4v|3gp|avi)$', caseSensitive: false).hasMatch(job.name)) {
          bytes = await MediaLibrary.thumbnail(job.source!, video: !RegExp(r'\.(png|jpe?g|webp|gif)$', caseSensitive: false).hasMatch(job.name));
        } else if (RegExp(r'\.(png|jpe?g|webp|gif)$', caseSensitive: false).hasMatch(job.name) && await File(job.source!).length() <= 8 * 1024 * 1024) {
          final preview = await compute(FilePreview.thumbnail, await File(job.source!).readAsBytes());
          if (preview['data'] != null) bytes = base64.decode(preview['data'] as String);
        }
        if (bytes != null) {
          final folder = await Directory(p.join(directory!.path, 'activity-thumbnails')).create(recursive: true);
          final target = File(p.join(folder.path, '${job.id}.jpg'));
          await target.writeAsBytes(bytes);
          thumbnail = target.path;
          final files = await folder.list().where((file) => file is File).cast<File>().toList();
          if (files.length > 40) {
            files.sort((a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()));
            for (final file in files.take(files.length - 40)) { await file.delete(); }
          }
        }
      } catch (_) {}
    }
    if (thumbnail == null && job.source != null && !p.isWithin(p.join(directory!.path, 'shared'), job.source!) &&
        RegExp(r'\.(png|jpe?g|webp|gif|heic|heif)$', caseSensitive: false).hasMatch(job.name)) thumbnail = job.source;
    final activity = Activity(localizeMessage(job.skipped ? 'Файл пропущен получателем' : 'Файл отправлен'),
      '${localizeMessage('На {0}', [node?.peers[job.peerId]?.name ?? job.peerId])} · ${job.name}',
      name: job.name, thumbnailPath: thumbnail, kind: 'upload');
    activities.insert(0, activity);
    if (activities.length > 40) activities.removeLast();
    notifyListeners();
  }

  Future<void> _cleanShared(TransferJob job) async {
    if (job.kind == 'upload' && job.source != null) await _cleanSharedSource(job.source!);
  }

  Future<void> _cleanSharedSource(String path) async {
    if (directory == null || !p.isWithin(p.join(directory!.path, 'shared'), path)) return;
    final file = File(path);
    if (await file.exists()) await file.delete();
    final parent = file.parent;
    if (p.isWithin(p.join(directory!.path, 'shared'), parent.path) && await parent.exists() && await parent.list().isEmpty) {
      await parent.delete();
    }
  }

  Future<void> _executeJob(TransferJob job, void Function(double) progress) async {
    final peer = node!.peers[job.peerId];
    if (peer == null) throw StateError(localizeMessage("Устройство отключено"));
    final clock = Stopwatch()..start();
    var lastBytes = 0;
    var lastTime = 0;
    void update() {
      if (node!.transferTotal > 0 && node!.transferName != null) job.totalBytes = node!.transferTotal;
      final done = node!.transferName == null ? job.doneBytes : node!.transferBytes;
      final elapsed = clock.elapsedMilliseconds;
      final sent = node!.sessionBytes;
      if (sent > lastBytes && elapsed > lastTime) {
        final rate = (sent - lastBytes) * 1000 / (elapsed - lastTime);
        job.bytesPerSecond = job.bytesPerSecond == 0 ? rate : job.bytesPerSecond * 0.7 + rate * 0.3;
        lastBytes = sent; lastTime = elapsed;
      }
      progress(node!.transferName != null && job.totalBytes > 0 ? (done / job.totalBytes).clamp(0.0, 1.0) : node!.transferProgress ?? job.progress);
    }
    final timer = Timer.periodic(const Duration(milliseconds: 200), (_) => update());
    try {
      if (job.kind == 'downloadDirectory') {
        await node!.received.createDirectory(job.relative!);
      } else if (job.kind == 'uploadDirectory') {
        await node!.uploadDirectory(peer, job.relative!);
      } else if (job.kind == 'download') {
        await node!.downloadFile(peer, job.entry!, relative: job.relative, transferId: job.id, expectedDigest: job.digest);
        job.skipped = node!.received.receipts[node!.received.key(peer.id, job.id)]?['skipped'] == true;
      } else {
        Future<SharedRead> open(int offset, int? length) async {
          if (job.sourceFolder != null) return backup!.sources.open(job.sourceFolder!, job.source!, offset: offset, length: length);
          final file = File(job.source!);
          final stat = await file.stat();
          if (stat.type != FileSystemEntityType.file || offset > stat.size) throw const FileSystemException('Source unavailable');
          final end = length == null ? stat.size : (offset + length < stat.size ? offset + length : stat.size);
          return SharedRead(stat.size, file.openRead(offset, end), () async {}, version: contentVersion(stat.size, stat.modified));
        }
        job.digest = await node!.uploadSource(peer, job.id, job.name, open,
          relative: job.relative, expectedDigest: job.digest,
          onDigest: (digest) { job.digest = digest; unawaited(queue!.save()); });
        if (node!.lastUploadReceipt?['skipped'] == true && job.kind == 'backup') throw StateError(localizeMessage("Получатель пропустил фото из-за совпадения имени"));
        job.receipt = node!.lastUploadReceipt?['receipt'] as String?;
        job.skipped = node!.lastUploadReceipt?['skipped'] == true;
      }
    } finally { timer.cancel(); update(); }
  }

  Future<void> enqueuePaths(Peer peer, List<String> paths, {Map<String, String>? names}) async {
    final jobs = <TransferJob>[];
    final batch = randomToken(8);
    for (final path in paths) {
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.directory) {
        final root = Directory(path);
        final label = safeFilename(p.basename(path));
        jobs.add(TransferJob(id: randomToken(16), peerId: peer.id, kind: 'uploadDirectory', name: label, batchId: batch, relative: '${batch}_$label'));
        await for (final entry in root.list(recursive: true, followLinks: false)) {
          if (entry is Link) continue;
          if (jobs.length >= 20000) throw StateError(localizeMessage("В папке больше 20 000 элементов. Выберите подпапку."));
          final relative = p.relative(entry.path, from: path).split(p.separator).join('/');
          if (entry is Directory) {
            jobs.add(TransferJob(id: randomToken(16), peerId: peer.id, kind: 'uploadDirectory',
              name: p.basename(entry.path), batchId: batch, relative: '${batch}_$label/$relative'));
            continue;
          }
          if (entry is! File || await entry.length() > maxFileBytes) continue;
          jobs.add(TransferJob(id: randomToken(16), peerId: peer.id, kind: 'upload',
            name: p.basename(entry.path), source: entry.path, batchId: batch, relative: '${batch}_$label/$relative'));
        }
      } else if (type == FileSystemEntityType.file) {
        if (await File(path).length() > maxFileBytes) throw StateError(localizeMessage("Лимит файла — 8 ТБ"));
        jobs.add(TransferJob(id: randomToken(16), peerId: peer.id, kind: 'upload', name: names?[path] ?? p.basename(path), source: path));
      } else { throw StateError(localizeMessage("Файл или папка недоступны: {0}", [path])); }
    }
    for (final job in jobs) {
      if (job.source != null) job.totalBytes = await File(job.source!).length();
    }
    selectPeer(peer.id);
    await queue!.addAll(jobs);
    record(Activity(localizeMessage("Добавлено в очередь"), localizeMessage("{0} файлов → {1}", [jobs.length, peer.name])));
  }

  Future<void> enqueueDownload(Peer peer, SharedFile entry) async {
    if (!entry.isDirectory) {
      await queue!.addAll([TransferJob(id: randomToken(16), peerId: peer.id, kind: 'download', name: entry.name, entry: entry, totalBytes: entry.size)]);
      return;
    }
    final jobs = <TransferJob>[];
    final pending = <(SharedFile, int)>[(entry, 0)];
    final group = '${randomToken(8)}_${entry.name}';
    jobs.add(TransferJob(id: randomToken(16), peerId: peer.id, kind: 'downloadDirectory', name: entry.name, batchId: group, relative: group));
    final prefix = entry.relativePath!.isEmpty ? '' : '${entry.relativePath}/';
    while (pending.isNotEmpty) {
      final next = pending.removeLast();
      final page = await node!.browseFiles(peer, folder: next.$1, offset: next.$2);
      if (page.nextOffset != null) pending.add((next.$1, page.nextOffset!));
      for (final child in page.entries) {
        if (child.isDirectory) {
          pending.add((child, 0));
          jobs.add(TransferJob(id: randomToken(16), peerId: peer.id, kind: 'downloadDirectory', name: child.name, batchId: group,
            relative: '$group/${child.relativePath!.substring(prefix.length)}'));
          continue;
        }
        if (!child.relativePath!.startsWith(prefix)) throw const FormatException('Invalid folder response');
        jobs.add(TransferJob(id: randomToken(16), peerId: peer.id, kind: 'download',
          name: child.name, entry: child, totalBytes: child.size, batchId: group, relative: '$group/${child.relativePath!.substring(prefix.length)}'));
        if (jobs.length > 20000) throw StateError(localizeMessage("В папке больше 20 000 файлов. Выберите подпапку."));
      }
    }
    await queue!.addAll(jobs);
    record(Activity(localizeMessage("Папка добавлена в очередь"), localizeMessage("{0} · {1} файлов", [entry.name, jobs.length])));
  }

  Future<void> revealReceivedFolder() async {
    try { await openReceivedFolder(); }
    catch (error) { record(Activity(localizeMessage("Не удалось открыть папку"), '$error', error: true)); }
  }

  Future<void> openReceivedFolder() async {
    final current = node;
    if (current == null) throw StateError(localizeMessage("Папка получения ещё не готова"));
    if (isAndroid) {
      await platformChannel.invokeMethod<void>('openReceivedFolder', {'tree': receiveDestination});
      return;
    }
    final folder = receiveDestination ?? current.inbox.path;
    await Directory(folder).create(recursive: true);
    final result = Platform.isWindows ? await Process.run('explorer.exe', [folder]) : await Process.run('xdg-open', [folder]);
    if (result.exitCode != 0 && !(Platform.isWindows && result.exitCode == 1)) throw StateError(localizeMessage("Не удалось открыть папку получения"));
  }

  Future<void> setSortReceived(bool enabled) async {
    sortReceived = enabled;
    node?.received.sortByType = enabled;
    await _saveSettings();
    notifyListeners();
  }

  Future<void> refreshLocalNetwork({bool reconnect = false}) async {
    if (!isAndroid) return;
    final previous = localNetwork;
    localNetwork = await platformChannel.invokeMapMethod<String, dynamic>('localNetworkStatus') ?? {};
    final addresses = (localNetwork['addresses'] as List? ?? []).cast<String>();
    final routeChanged = previous['direct'] != localNetwork['direct'] || previous['vpn'] != localNetwork['vpn'] || previous['wifi'] != localNetwork['wifi'] ||
      !listEquals((previous['addresses'] as List? ?? []).cast<String>(), addresses);
    if (reconnect && routeChanged) await node?.networkChanged(addresses);
    else if (reconnect) await node?.checkPeers();
    notifyListeners();
  }

  Future<void> setDirectWifi(bool enabled) async {
    if (node?.hasActiveTransfers == true || queue?.active != null) throw StateError(localizeMessage("Сначала приостановите текущую передачу"));
    localNetwork = await platformChannel.invokeMapMethod<String, dynamic>('setDirectWifi', {'enabled': enabled}) ?? {};
    androidDirectWifi = enabled;
    await _saveSettings();
    await node?.networkChanged((localNetwork['addresses'] as List? ?? []).cast<String>());
    notifyListeners();
  }

  Future<void> setReceiveStorage(String? destination, String policy) async {
    if (!['rename', 'skip', 'replace'].contains(policy)) throw const FormatException('Invalid conflict policy');
    if (destination != null && !destination.startsWith('content://')) {
      final folder = Directory(destination);
      final root = await folder.resolveSymbolicLinks();
      if (!p.equals(root, p.normalize(destination)) || p.equals(root, directory!.path) || p.isWithin(directory!.path, root)) throw StateError(localizeMessage("Выберите папку вне данных LinkInDrop"));
      final probe = File(p.join(root, '.linkindrop-${randomToken(8)}'));
      try { await probe.writeAsString('', flush: true); } finally { if (await probe.exists()) await probe.delete(); }
      destination = root;
    }
    if (destination != receiveDestination && (node?.hasActiveTransfers == true || queue?.active != null)) {
      throw StateError(localizeMessage('Сначала приостановите текущую передачу'));
    }
    final previous = receiveDestination;
    if (isAndroid && destination != previous && destination?.startsWith('content://') == true) await const AndroidFolders().retain(destination!);
    receiveDestination = destination; conflictPolicy = policy;
    node!.received.destination = destination; node!.received.conflict = policy;
    await _saveSettings();
    if (isAndroid && previous != destination && previous?.startsWith('content://') == true) {
      await const AndroidFolders().revoke(previous!);
      await platformChannel.invokeMethod<void>('releaseFolderWrite', {'uri': previous});
    }
    notifyListeners();
  }

  Future<void> setSpeedLimit(int bytes) async {
    if (bytes < 0 || bytes > 1024 * 1024 * 1024) throw const FormatException('Invalid speed limit');
    speedLimit = bytes; node!.bytesPerSecond = bytes; await _saveSettings(); notifyListeners();
  }

  Future<int?> receiveFreeSpace() => freeBytes(receiveDestination?.startsWith('content://') == true ? node!.inbox.path : receiveDestination ?? node!.inbox.path);

  Future<void> setPhotoBackup(bool enabled) async {
    final current = backup;
    if (current == null) return;
    if (enabled && (current.peerId == null || current.sources.roots().isEmpty)) throw StateError(localizeMessage("Выберите устройство и папку с фото"));
    final saving = current.setEnabled(enabled);
    await queue?.setBackupEnabled(enabled);
    await saving;
    if (enabled) unawaited(current.scan());
    notifyListeners();
  }

  Future<void> refreshBackground() async {
    if (!isAndroid) return;
    backgroundStatus = await platformChannel.invokeMapMethod<String, dynamic>('backgroundStatus') ?? {};
    notifyListeners();
  }

  Future<void> setAndroidBackground(bool enabled, bool boot) async {
    androidBackground = enabled; androidBoot = boot && enabled;
    await _saveSettings();
    await platformChannel.invokeMethod<void>('setBackgroundSettings', {'enabled': enabled, 'boot': androidBoot});
    await refreshBackground();
  }

  Future<void> checkUpdates() async {
    newerRelease = await checkRelease();
    updateMessage = newerRelease == null ? localizeMessage("Установлена актуальная версия") : localizeMessage("Доступна {0}", [newerRelease!['version']]);
    notifyListeners();
  }

  bool isFavorite(String peer, SharedFile folder) => favorites.any((f) => f['peer'] == peer && f['folder'] == folder.folderId && f['path'] == folder.relativePath);

  Future<void> toggleFavorite(String peer, SharedFile folder) async {
    if (isFavorite(peer, folder)) {
      favorites.removeWhere((f) => f['peer'] == peer && f['folder'] == folder.folderId && f['path'] == folder.relativePath);
    } else {
      if (favorites.length >= 50) throw StateError(localizeMessage("Можно сохранить 50 папок"));
      favorites.add({'peer': peer, 'folder': folder.folderId, 'path': folder.relativePath, 'entry': folder.toJson()});
    }
    await _saveSettings(); notifyListeners();
  }

  Future<void> repeat(TransferJob job) async {
    if (job.kind == 'upload' && job.source != null) {
      await enqueuePaths(node!.peers[job.peerId]!, [job.source!]);
    } else if (job.kind == 'download' && job.entry != null) {
      await enqueueDownload(node!.peers[job.peerId]!, job.entry!);
    }
  }

  Future<void> restorePhoto(Map<String, dynamic> copy) async {
    final peer = node!.peers[copy['peer']];
    if (peer == null) throw StateError(localizeMessage("Устройство не привязано"));
    await queue!.addAll([TransferJob(id: randomToken(16), peerId: peer.id, kind: 'download', name: copy['name'] as String,
      digest: copy['digest'] as String, totalBytes: copy['bytes'] as int? ?? 0,
      relative: 'RestoredPhotos/${copy['name']}',
      entry: SharedFile(id: 'receipt:${copy['receipt']}', name: copy['name'] as String, size: copy['bytes'] as int? ?? 0))]);
  }

  Future<void> setIncomingFiles(Peer peer, bool enabled) async {
    peer.incomingFilesEnabled = enabled;
    await node!.savePeers();
    notifyListeners();
  }

  Future<void> setShareAccess(String id, Set<String>? peers, DateTime? expires) async {
    await node!.access.set(id, ShareAccess(peerIds: peers, expiresAt: expires));
    notifyListeners();
  }

  Future<void> setDesktop({bool? hide, bool? startup, bool? minimized}) async {
    if (startup != null) await desktop?.setStartup(startup);
    if (hide != null) closeToTray = hide;
    if (minimized != null) startMinimized = minimized;
    await _saveSettings();
    notifyListeners();
  }

  Future<void> setRelay(String value) async {
    final address = value.trim();
    await node!.configureRelay(address.isEmpty ? null : address);
    relayAddress = address.isEmpty ? null : address;
    await _saveSettings();
    record(Activity(localizeMessage("Интернет-подключение"), node!.relayHost?.online == true ? localizeMessage("Ретранслятор подключён") : address.isEmpty ? localizeMessage("Ретранслятор выключен") : localizeMessage("Ожидается подключение к серверу")));
    notifyListeners();
  }

  Future<void> sendPendingFiles() async {
    for (final path in pendingFiles.toList()) {
      await sendFile(path);
      pendingFiles.remove(path);
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
      await stageFiles(files);
      notifyListeners();
    }
  }

  Future<void> shutdown() async {
    _clipboardTimer?.cancel();
    if (isAndroid) await platformChannel.invokeMethod<void>('stopConnection');
    await backup?.close();
    await queue?.close();
    await node?.stop();
    await desktop?.close();
    await _settingsSaving;
  }

  @override
  void dispose() {
    _clipboardTimer?.cancel();
    queue?.removeListener(notifyListeners);
    selection.removeListener(notifyListeners);
    selection.dispose();
    super.dispose();
  }
}

