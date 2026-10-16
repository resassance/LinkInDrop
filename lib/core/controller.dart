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

class BridgeController extends ChangeNotifier {
  BridgeController({ClipboardAdapter? clipboard}) : clipboard = clipboard ?? ClipboardAdapter();
  final ClipboardAdapter clipboard;
  final List<Activity> activities = [];
  final List<String> pendingFiles = [];
  final platformChannel = const MethodChannel('nearbridge/system');
  BridgeNode? node;
  TransferQueue? queue;
  PhotoBackup? backup;
  DesktopShell? desktop;
  bool closeToTray = true;
  String? relayAddress;
  String? receiveDestination;
  String conflictPolicy = "rename";
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
    return null;
  }

  void changed() => notifyListeners();

  void _nodeChanged() {
    notifyListeners();
    if (isAndroid && DateTime.now().difference(_lastNotification).inSeconds >= 1) {
      _lastNotification = DateTime.now();
      unawaited(platformChannel.invokeMethod<void>('updateConnectionStatus', {'text': 'Устройств: $onlineCount · в очереди: ${queue?.pending ?? 0}'}).catchError((Object _) {}));
    }
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
        closeToTray = data['closeToTray'] as bool? ?? true;
        relayAddress = data['relay'] as String?;
        receiveDestination = data['receiveDestination'] as String?;
        conflictPolicy = data['conflictPolicy'] as String? ?? 'rename';
        speedLimit = data['speedLimit'] as int? ?? 0;
        androidBackground = data['androidBackground'] as bool? ?? true;
        androidBoot = data['androidBoot'] as bool? ?? false;
        selectedPeerId = data['selectedPeer'] as String?;
        recentPeers.addAll((data['recentPeers'] as List? ?? []).cast<String>());
        favorites.addAll((data['favorites'] as List? ?? []).map((e) => (e as Map).cast<String, dynamic>()));
      }
      if (isAndroid && receiveDestination?.startsWith('content://') == true) await const AndroidFolders().retain(receiveDestination!);
      node = BridgeNode(directory: directory!, name: deviceName,
        folderProvider: isAndroid ? const AndroidFolders() : null,
        onPairRequest: (name) async => await pairingApproval?.call(name) ?? false,
        onClipboard: _receiveClipboard, onActivity: record, onChanged: _nodeChanged);
      node!.clipboardReceivingEnabled = receiveClipboard; node!.receivingEnabled = receiveFiles; node!.fileSharingEnabled = shareFiles;
      node!.bytesPerSecond = speedLimit;
      await node!.start(destination: receiveDestination, conflictPolicy: conflictPolicy);
      if (relayAddress != null) unawaited(node!.configureRelay(relayAddress));
      queue = TransferQueue(directory: directory!, execute: _executeJob,
        interrupt: () => node?.cancelTransfer(), completed: (job) async { await backup?.completed(job); await _cleanShared(job); },
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
      queue!.start();
      if (Platform.isWindows || Platform.isLinux) {
        desktop = DesktopShell(directory: directory!, hideOnClose: () => closeToTray, shutdown: shutdown);
        try { await desktop!.start(); } catch (error) { record(Activity('Фоновый режим недоступен', '$error', error: true)); }
      }
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
      unawaited(backup?.scan());
      if (isAndroid) {
        platformChannel.setMethodCallHandler((call) async {
          if (call.method == 'shared') await handleShared();
        });
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
      'name': deviceName, 'autoClipboard': autoClipboard,
      'receiveClipboard': receiveClipboard, 'receiveFiles': receiveFiles,
      'shareFiles': shareFiles, 'closeToTray': closeToTray, 'relay': relayAddress,
      'receiveDestination': receiveDestination, 'conflictPolicy': conflictPolicy, 'speedLimit': speedLimit,
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
    if (queue != null) {
      for (final job in queue!.jobs.where((j) => j.peerId == peer.id).toList()) { await queue!.cancel(job); }
    }
    if (backup?.peerId == peer.id) { backup!.enabled = false; await backup!.save(); }
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
    await enqueuePaths(peer, [path], names: name == null ? null : {path: name});
  }

  Future<void> _cleanShared(TransferJob job) async {
    final path = job.source;
    if (job.kind == 'upload' && path != null && directory != null && p.isWithin(p.join(directory!.path, 'shared'), path)) {
      final file = File(path);
      if (await file.exists()) await file.delete();
    }
  }

  Future<void> _executeJob(TransferJob job, void Function(double) progress) async {
    final peer = node!.peers[job.peerId];
    if (peer == null) throw StateError('Устройство отключено');
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
        if (node!.lastUploadReceipt?['skipped'] == true && job.kind == 'backup') throw StateError('Получатель пропустил фото из-за совпадения имени');
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
          if (jobs.length >= 20000) throw StateError('В папке больше 20 000 элементов. Выберите подпапку.');
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
        if (await File(path).length() > maxFileBytes) throw StateError('Лимит файла — 8 ТБ');
        jobs.add(TransferJob(id: randomToken(16), peerId: peer.id, kind: 'upload', name: names?[path] ?? p.basename(path), source: path));
      } else { throw StateError('Файл или папка недоступны: $path'); }
    }
    for (final job in jobs) {
      if (job.source != null) job.totalBytes = await File(job.source!).length();
    }
    selectPeer(peer.id);
    await queue!.addAll(jobs);
    record(Activity('Добавлено в очередь', '${jobs.length} файлов → ${peer.name}'));
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
        if (jobs.length > 20000) throw StateError('В папке больше 20 000 файлов. Выберите подпапку.');
      }
    }
    await queue!.addAll(jobs);
    record(Activity('Папка добавлена в очередь', '${entry.name} · ${jobs.length} файлов'));
  }

  Future<void> setReceiveStorage(String? destination, String policy) async {
    if (!['rename', 'skip', 'replace'].contains(policy)) throw const FormatException('Invalid conflict policy');
    if (destination != null && !destination.startsWith('content://')) {
      final folder = Directory(destination);
      final root = await folder.resolveSymbolicLinks();
      if (!p.equals(root, p.normalize(destination)) || p.equals(root, directory!.path) || p.isWithin(directory!.path, root)) throw StateError('Выберите папку вне данных Nearbridge');
      final probe = File(p.join(root, '.nearbridge-${randomToken(8)}'));
      try { await probe.writeAsString('', flush: true); } finally { if (await probe.exists()) await probe.delete(); }
      destination = root;
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
    updateMessage = newerRelease == null ? 'Установлена актуальная версия' : 'Доступна ${newerRelease!['version']}';
    notifyListeners();
  }

  bool isFavorite(String peer, SharedFile folder) => favorites.any((f) => f['peer'] == peer && f['folder'] == folder.folderId && f['path'] == folder.relativePath);

  Future<void> toggleFavorite(String peer, SharedFile folder) async {
    if (isFavorite(peer, folder)) {
      favorites.removeWhere((f) => f['peer'] == peer && f['folder'] == folder.folderId && f['path'] == folder.relativePath);
    } else {
      if (favorites.length >= 50) throw StateError('Можно сохранить 50 папок');
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
    if (peer == null) throw StateError('Устройство не привязано');
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

  Future<void> setDesktop({bool? hide, bool? startup}) async {
    if (hide != null) closeToTray = hide;
    if (startup != null) await desktop?.setStartup(startup);
    await _saveSettings();
    notifyListeners();
  }

  Future<void> setRelay(String value) async {
    final address = value.trim();
    await node!.configureRelay(address.isEmpty ? null : address);
    relayAddress = address.isEmpty ? null : address;
    await _saveSettings();
    record(Activity('Интернет-подключение', node!.relayHost?.online == true ? 'Ретранслятор подключён' : address.isEmpty ? 'Ретранслятор выключен' : 'Ожидается подключение к серверу'));
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
      if (selectedPeer != null) await run(sendPendingFiles);
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
    super.dispose();
  }
}

