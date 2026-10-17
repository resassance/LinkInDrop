import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:open_filex/open_filex.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:desktop_drop/desktop_drop.dart';

import '../core/controller.dart';
import '../core/models.dart';
import '../core/android_folders.dart';
import 'remote_files_dialog.dart';
import '../core/transfer_queue.dart';
import '../core/access_rules.dart';
import 'reliability_panel.dart';
import '../core/send_selection.dart';
import '../l10n/app_strings.dart';
import 'app_theme.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

class NearbridgeApp extends StatelessWidget {
  const NearbridgeApp({super.key, required this.controller, this.start = true});
  final BridgeController controller;
  final bool start;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(animation: controller, builder: (context, _) => MaterialApp(
    title: 'LinkInDrop', debugShowCheckedModeBanner: false,
    theme: linkInDropTheme(Brightness.light), darkTheme: linkInDropTheme(Brightness.dark),
    themeMode: switch (controller.themePreference) { 'light' => ThemeMode.light, 'dark' => ThemeMode.dark, _ => ThemeMode.system },
    locale: controller.languagePreference == 'system' ? null : Locale(controller.languagePreference),
    supportedLocales: [Locale('en'), Locale('ru')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    home: BridgeHome(controller: controller, start: start)));
}

class BridgeHome extends StatefulWidget {
  const BridgeHome({super.key, required this.controller, required this.start});
  final BridgeController controller;
  final bool start;
  @override
  State<BridgeHome> createState() => _BridgeHomeState();
}

class _BridgeHomeState extends State<BridgeHome> with WidgetsBindingObserver {
  BridgeController get c => widget.controller;
  String? _draggingPeer;
  bool _dropping = false;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    c.pairingApproval = _approve;
    c.mobileActive = WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    if (widget.start) unawaited(c.start());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    c.mobileActive = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.resumed && c.isAndroid && !c.loading) {
      unawaited(c.refreshBackground());
      unawaited(c.handleShared());
      unawaited(c.node?.checkPeers());
      unawaited(c.backup?.scan());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    c.pairingApproval = null;
    _scroll.dispose();
    super.dispose();
  }

  Future<bool> _approve(String name) async {
    if (!mounted) return false;
    return await showDialog<bool>(context: context, barrierDismissible: false,
      builder: (context) => AlertDialog(title: Text(tr(context, "Подключить устройство?")),
        content: Text(tr(context, "{0} получит доступ к отправке файлов и общему буферу. Подтвердите, если это ваше устройство.", [name])),
        actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr(context, "Отклонить"))),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr(context, "Подключить")))])) ?? false;
  }

  Future<void> _showInvite() async {
    final node = c.node;
    if (node == null) return;
    final addresses = await node.addresses();
    if (!mounted) return;
    if (addresses.isEmpty && node.relayUrl != null) addresses.add('127.0.0.1');
    if (addresses.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr(context, "Подключитесь к Wi-Fi или локальной сети"))));
      return;
    }
    var host = addresses.first;
    await showDialog<void>(context: context, builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) {
        final code = node.invite(host).encode();
        return AlertDialog(scrollable: true, title: Text(tr(context, "Добавить устройство")),
          content: SizedBox(width: 340, child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(padding: EdgeInsets.all(12), color: Colors.white,
              child: QrImageView(data: code, size: 250, backgroundColor: Colors.white)),
            SizedBox(height: 18),
            Text(tr(context, "Откройте LinkInDrop на другом устройстве и отсканируйте код. Используйте общую сеть или настроенный ретранслятор."),
              style: TextStyle(color: subdued)),
            if (addresses.length > 1) DropdownButton<String>(value: host, isExpanded: true,
              items: addresses.map((ip) => DropdownMenuItem(value: ip, child: Text(ip))).toList(),
              onChanged: (value) => setDialogState(() => host = value!)),
            SizedBox(height: 8),
            SelectableText('$host:${node.port}', style: TextStyle(color: subdued)),
            Text(tr(context, "Выберите адрес сети, доступной второму устройству. Для подключения на расстоянии используйте адрес общей VPN-сети."),
              style: TextStyle(color: subdued, fontSize: 12)),
            SizedBox(height: 12),
            TextButton.icon(onPressed: () async {
              await Clipboard.setData(ClipboardData(text: code));
              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(tr(context, "Код скопирован. Действует 5 минут"))));
            }, icon: Icon(Icons.copy_rounded), label: Text(tr(context, "Скопировать код"))),
          ])),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(tr(context, "Закрыть")))]);
      }));
  }

  Future<void> _enterCode() async {
    final text = TextEditingController();
    final value = await showDialog<String>(context: context, builder: (context) => AlertDialog(
      title: Text(tr(context, "Подключиться")), content: SizedBox(width: 420,
        child: TextField(controller: text, maxLines: 4, autofocus: true,
          decoration: InputDecoration(hintText: tr(context, "Вставьте код с другого устройства")))),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(tr(context, "Отмена"))),
        FilledButton(onPressed: () => Navigator.pop(context, text.text), child: Text(tr(context, "Подключиться")))]));
    text.dispose();
    if (value != null) await c.run(() => c.pair(value));
  }

  Future<void> _scan() async {
    final code = await Navigator.push<String>(context,
      MaterialPageRoute(builder: (_) => ScanScreen()));
    if (code != null) await c.run(() => c.pair(code));
  }

  Future<void> _sendFiles() async {
    final files = await openFiles();
    if (!mounted || files.isEmpty) return;
    await c.run(() => c.stageFiles(files.map((file) => file.path).toList(),
      names: {for (final file in files) file.path: file.name}));
  }

  Future<void> _remoteAddress(Peer peer) async {
    final host = TextEditingController(text: peer.remoteHost ?? '');
    final port = TextEditingController(text: '${peer.remotePort ?? peer.port}');
    final value = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: Text(tr(context, "Адрес: {0}", [peer.name])),
      content: SizedBox(width: 420, child: SingleChildScrollView(child: Column(
        mainAxisSize: MainAxisSize.min, children: [
          Text(tr(context, "Для доступа через интернет подключите оба устройства к одной VPN-сети, например Tailscale. Укажите IPv4 или DNS-имя другого устройства. LinkInDrop должен быть запущен.")),
          SizedBox(height: 16),
          TextField(controller: host, decoration: InputDecoration(
            labelText: 'IPv4 / DNS', hintText: '100.64.0.12')),
          SizedBox(height: 10),
          TextField(controller: port, keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: tr(context, "Порт LinkInDrop"))),
          SizedBox(height: 10),
          Text(tr(context, "Пустой адрес возвращает локальное подключение. На Windows разрешите входящий TCP из адреса VPN в брандмауэре."),
            style: TextStyle(color: subdued)),
        ]))),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr(context, "Отмена"))),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr(context, "Проверить и сохранить")))]));
    final address = host.text.trim();
    final number = int.tryParse(port.text);
    host.dispose();
    port.dispose();
    if (value == true) await c.run(() => c.node!.setRemoteAddress(peer,
      address.isEmpty ? null : address, number));
  }

  Future<void> _manageSharedFiles() async {
    final node = c.node;
    if (node == null) return;
    Future<List<SharedFile>> ownEntries() async => [
      ...node.sharedFolders.roots(), ...await node.sharedFiles.list()];
    var entries = await ownEntries();
    if (!mounted) return;
    await showDialog<void>(context: context, builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: Text(tr(context, "Мои файлы и папки")),
        content: SizedBox(width: 460, height: 320, child: ListView(children: [
          Text(c.shareFiles ? tr(context, "Доступ включён. Привязанные устройства видят выбранные файлы и папки.") : tr(context, "Доступ выключен. Включите его ниже или добавьте файлы и папки.")),
          if (!c.shareFiles) TextButton(onPressed: () async { await c.setSettings(fileSharing: true); if (context.mounted) setDialogState(() {}); }, child: Text(tr(context, "Включить доступ"))),
          Text(tr(context, "На телефоне выберите папку системным диалогом и подтвердите «Использовать эту папку». Для повторного доступа разрешение сохраняется.")),
          SizedBox(height: 12),

            if (entries.isEmpty) Text(tr(context, "Файлы и папки пока не выбраны")),
            for (final entry in entries) ListTile(
              leading: Icon(entry.isDirectory ? Icons.folder_outlined : Icons.insert_drive_file_outlined),
              title: Text(entry.name, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(entry.isDirectory ? tr(context, "Папка со всем содержимым") : _fileSize(entry.size)),
                Wrap(children: [
                IconButton(tooltip: tr(context, "Кому доступно и срок"), icon: Icon(Icons.manage_accounts_outlined),
                  onPressed: () => _shareAccess(entry)),
                IconButton(tooltip: tr(context, "Закрыть доступ"), icon: Icon(Icons.remove_circle_outline),
                onPressed: () async {
                  await c.run(() => entry.isDirectory
                    ? node.sharedFolders.remove(entry.id) : node.sharedFiles.remove(entry.id));
                  final updated = await ownEntries();
                  if (context.mounted) setDialogState(() => entries = updated);
                })]),
              ])),
        ])),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(tr(context, "Закрыть"))),
          FilledButton.icon(icon: Icon(Icons.add), label: Text(tr(context, "Добавить файлы")),
            onPressed: () async {
              await c.run(() async {
                final paths = c.isAndroid ? await AndroidFolders().pickFiles() : (await openFiles()).map((file) => file.path).toList();
                for (final path in paths) { await node.sharedFiles.add(path); }
                if (paths.isNotEmpty) await c.setSettings(fileSharing: true);
              });
              final updated = await ownEntries();
              if (context.mounted) setDialogState(() => entries = updated);
            }),
          OutlinedButton.icon(icon: Icon(Icons.create_new_folder_outlined), label: Text(tr(context, "Добавить папку")),
            onPressed: () async {
              await c.run(() async {
                if (c.isAndroid) {
                  final selected = await AndroidFolders().pick();
                  if (selected != null) await node.sharedFolders.add(selected['uri'] as String,
                    name: selected['name'] as String?);
                  if (selected != null) await c.setSettings(fileSharing: true);
                } else {
                  final selected = await getDirectoryPath(confirmButtonText: tr(context, "Открыть доступ к папке"));
                  if (selected != null) { await node.sharedFolders.add(selected); await c.setSettings(fileSharing: true); }
                }
              });
              final updated = await ownEntries();
              if (context.mounted) setDialogState(() => entries = updated);
            })])));
  }

  Future<void> _browseFiles({Peer? target, SharedFile? initial}) async {
    var peer = target ?? c.selectedPeer;
    final node = c.node;
    if (node == null) return;
    if (peer == null && c.peers.isNotEmpty) {
      peer = await showDialog<Peer>(context: context, builder: (context) => SimpleDialog(
        title: Text(tr(context, "Файлы какого устройства открыть?")),
        children: c.peers.map((device) => SimpleDialogOption(
          onPressed: () => Navigator.pop(context, device),
          child: Text('${device.name}${device.online ? '' : tr(context, " · не в сети")}'))).toList()));
      if (peer != null) c.selectPeer(peer.id);
    }
    if (!mounted) return;
    if (peer == null) {
      if (c.peers.isEmpty) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr(context, "Сначала добавьте устройство по QR или коду подключения"))));
      return;
    }
    final device = peer;
    final chosen = await showDialog<SharedFile>(context: context, builder: (context) => RemoteFilesDialog(
      deviceName: device.name, canDownload: c.receiveFiles, initialFolder: initial,
      isFavorite: (folder) => c.isFavorite(device.id, folder),
      toggleFavorite: (folder) => c.toggleFavorite(device.id, folder),
      load: (folder, offset) => node.browseFiles(device, folder: folder, offset: offset),
      search: (folder, query, cursor) => node.searchFiles(device, query, folder: folder, cursor: cursor),
      preview: (entry) => node.previewFile(device, entry)));
    if (chosen != null) {
      try { await c.enqueueDownload(device, chosen); }
      catch (error) { c.record(Activity(tr(context, "Не получилось скачать"), '$error', error: true)); }
    }
  }

  String _remaining(int seconds) => seconds < 60 ? tr(context, "{0} с", [seconds]) : seconds < 3600 ? tr(context, "{0} мин", [seconds ~/ 60]) : tr(context, "{0} ч {1} мин", [seconds ~/ 3600, (seconds % 3600) ~/ 60]);

  String _fileSize(int bytes) => stringsOf(context).size(bytes);

  Future<void> _shareAccess(SharedFile entry) async {
    final old = c.node!.access.rules[entry.id] ?? ShareAccess();
    var all = old.peerIds == null;
    final selected = Set<String>.from(old.peerIds ?? c.peers.map((p) => p.id));
    var duration = old.expiresAt == null ? 'never' : 'keep';
    final saved = await showDialog<bool>(context: context, builder: (context) => StatefulBuilder(
      builder: (context, update) => AlertDialog(title: Text(tr(context, "Доступ: {0}", [entry.name])),
        content: SizedBox(width: 430, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          SwitchListTile(title: Text(tr(context, "Все привязанные устройства")), value: all,
            onChanged: (value) => update(() => all = value)),
          if (!all) for (final peer in c.peers) CheckboxListTile(title: Text(peer.name),
            value: selected.contains(peer.id), onChanged: (value) => update(() {
              if (value == true) selected.add(peer.id); else selected.remove(peer.id);
            })),
          DropdownButton<String>(value: duration, isExpanded: true, items: [
            if (old.expiresAt != null) DropdownMenuItem(value: 'keep', child: Text(tr(context, "Не менять срок"))),
            DropdownMenuItem(value: 'never', child: Text(tr(context, "Бессрочно"))),
            DropdownMenuItem(value: '15', child: Text(tr(context, "На 15 минут"))),
            DropdownMenuItem(value: '60', child: Text(tr(context, "На час"))),
            DropdownMenuItem(value: '1440', child: Text(tr(context, "На сутки"))),
          ], onChanged: (value) => update(() => duration = value!)),
        ]))), actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr(context, "Отмена"))),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr(context, "Сохранить")))])));
    if (saved == true) await c.run(() => c.setShareAccess(entry.id, all ? null : selected,
      duration == 'keep' ? old.expiresAt : duration == 'never' ? null : DateTime.now().add(Duration(minutes: int.parse(duration)))));
  }

  Future<void> _relaySettings() async {
    final text = TextEditingController(text: c.relayAddress ?? '');
    final saved = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      scrollable: true, title: Text(tr(context, "Подключение через интернет")),
      content: SizedBox(width: 430, child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(tr(context, "Укажите адрес сервера LinkInDrop. Код подключения передаст его второму устройству. VPN не нужен; содержимое защищено соединением с проверкой сертификата устройства.")),
        SizedBox(height: 14), TextField(controller: text,
          decoration: InputDecoration(labelText: tr(context, "Адрес сервера"), hintText: 'wss://relay.example.com')),
        SizedBox(height: 10), Text(tr(context, "Пустой адрес выключает ретранслятор.")),
      ])), actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr(context, "Отмена"))),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr(context, "Подключить")))]));
    final value = text.text;
    text.dispose();
    if (saved == true) await c.run(() => c.setRelay(value));
  }

  Future<void> _backupFolder() async {
    await c.run(() async {
      if (c.isAndroid) {
        final selected = await AndroidFolders().pick();
        if (selected != null) await c.backup!.sources.add(selected['uri'] as String, name: selected['name'] as String?);
      } else {
        final selected = await getDirectoryPath(confirmButtonText: tr(context, "Выбрать папку с фото"));
        if (selected != null) await c.backup!.sources.add(selected);
      }
      c.changed();
    });
  }

  Widget _queue() {
    final queue = c.queue;
    final jobs = queue?.jobs ?? <TransferJob>[];
    final visible = [...jobs.where((j) => j.state != 'completed' && j.state != 'cancelled'),
      ...jobs.reversed.where((j) => j.state == 'completed' || j.state == 'cancelled')].take(30);
    final labels = {'waiting': tr(context, "Ожидает"), 'running': tr(context, "Передаётся"), 'paused': tr(context, "Приостановлено"),
      'failed': tr(context, "Не получилось"), 'completed': tr(context, "Готово"), 'cancelled': tr(context, "Отменено")};
    return _panel(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [Expanded(child: Text(tr(context, "Очередь передач"), style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600))),
        if (jobs.isNotEmpty) TextButton(onPressed: () => queue!.clearFinished(), child: Text(tr(context, "Убрать готовые")))]),
      if (jobs.isEmpty) Padding(padding: EdgeInsets.symmetric(vertical: 12),
        child: Text(tr(context, "Здесь появятся файлы и папки. Передачи можно приостановить и продолжить."), style: TextStyle(color: subdued))),
      for (final job in visible) Padding(padding: EdgeInsets.symmetric(vertical: 10), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [Icon(job.kind == 'download' ? Icons.download_rounded : job.kind == 'backup' ? Icons.photo_library_outlined : Icons.upload_rounded), SizedBox(width: 12),
          Expanded(child: Text(job.name, maxLines: 2, overflow: TextOverflow.ellipsis))]),
        SizedBox(height: 6),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${job.backupPaused ? tr(context, "Фотобэкап выключен") : job.state == 'completed' && job.skipped ? tr(context, "Пропущено") : labels[job.state] ?? job.state}${job.state == 'running' ? ' · ${(job.progress * 100).round()}%' : ''}', style: TextStyle(color: subdued)),
          if (job.error != null) Text(job.error!, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          if (job.state == 'running') ...[
            Text(tr(context, "{0} / {1} · {2}/с{3}", [_fileSize(job.doneBytes), _fileSize(job.totalBytes), _fileSize(job.bytesPerSecond.round()), job.remainingSeconds == null ? '' : tr(context, " · осталось {0}", [_remaining(job.remainingSeconds!)])])),
            LinearProgressIndicator(value: job.progress),
          ],
          if (job.batchId != null) Text(tr(context, "Папка: {0}%", [(queue!.batchProgress(job.batchId!) * 100).round()])),
        ]),
        Wrap(spacing: 4, children: [
          if (job.state == 'waiting' || job.state == 'paused' || job.state == 'failed') PopupMenuButton<int>(tooltip: tr(context, "Приоритет"),
            onSelected: (priority) => queue!.setPriority(job, priority),
            itemBuilder: (_) => [PopupMenuItem(value: 1, child: Text(tr(context, "Высокий приоритет"))), PopupMenuItem(value: 0, child: Text(tr(context, "Обычный приоритет"))), PopupMenuItem(value: -1, child: Text(tr(context, "Низкий приоритет")))]),
          if (job.state == 'completed' && (job.kind == 'upload' || job.kind == 'download')) IconButton(tooltip: tr(context, "Отправить снова"), icon: Icon(Icons.replay), onPressed: () => c.run(() => c.repeat(job))),
          if (job.state == 'running' || job.state == 'waiting') IconButton(tooltip: tr(context, "Пауза"), icon: Icon(Icons.pause_rounded),
            onPressed: () => queue!.pause(job)),
          if (job.state == 'paused' || job.state == 'failed') IconButton(tooltip: tr(context, "Продолжить"), icon: Icon(Icons.play_arrow_rounded),
            onPressed: job.kind == 'backup' && c.backup?.enabled != true ? null : () => queue!.resume(job)),
          if (job.state != 'completed' && job.state != 'cancelled') IconButton(tooltip: tr(context, "Отменить"), icon: Icon(Icons.close_rounded),
            onPressed: () => queue!.cancel(job)),
        ]),
      ])),
    ]));
  }

  Widget _settings() {
    final backup = c.backup;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (c.isAndroid) BackgroundSettings(controller: c),
      Text(tr(context, "Фоновая работа и подключение"), style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
      if (Platform.isWindows || Platform.isLinux) ...[
        SwitchListTile(contentPadding: EdgeInsets.zero, title: Text(tr(context, "Сворачивать в трей при закрытии")),
          value: c.closeToTray, onChanged: (value) => c.run(() => c.setDesktop(hide: value))),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: Text(tr(context, "Запускать вместе с системой")),
          value: c.desktop?.startupEnabled ?? false,
          onChanged: c.desktop == null ? null : (value) => c.run(() => c.setDesktop(startup: value))),
        Text(tr(context, "Перетащите файлы или папку на устройство, чтобы подготовить передачу."), style: TextStyle(color: subdued)),
      ],
      SizedBox(height: 12),
      Text(c.node?.relayHost?.online == true ? tr(context, "Интернет: ретранслятор подключён")
        : c.relayAddress == null ? tr(context, "Интернет: ретранслятор не настроен") : tr(context, "Интернет: ожидается сервер"), style: TextStyle(color: subdued)),
      TextButton.icon(onPressed: c.busy ? null : _relaySettings, icon: Icon(Icons.public_rounded),
        label: Text(tr(context, "Настроить доступ без VPN"))),
      Divider(height: 32),
      Text(tr(context, "Резервное копирование фото"), style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
      SizedBox(height: 8),
      Text(tr(context, "Новые фото из выбранных папок отправляются на устройство ниже. Оригиналы сохраняются; одинаковые снимки повторно не передаются."), style: TextStyle(color: subdued)),
      if (backup != null) ...[
        DropdownButton<String>(isExpanded: true,
          selectedItemBuilder: (context) => c.peers.map((peer) => Align(alignment: Alignment.centerLeft, child: Text(peer.name, maxLines: 1, overflow: TextOverflow.ellipsis))).toList(),
          value: c.peers.any((p) => p.id == backup.peerId) ? backup.peerId : null,
          hint: Text(tr(context, "Куда копировать фото")),
          items: c.peers.map((peer) => DropdownMenuItem(value: peer.id, child: Text(peer.name, maxLines: 1, overflow: TextOverflow.ellipsis))).toList(),
          onChanged: (value) async { backup.peerId = value; await backup.save(); c.changed(); }),
        for (final root in backup.sources.roots()) ListTile(contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.folder_outlined), title: Text(root.name),
          trailing: IconButton(tooltip: tr(context, "Убрать из резервного копирования"), icon: Icon(Icons.close_rounded),
            onPressed: () => c.run(() async {
              for (final job in c.queue!.jobs.where((j) => j.sourceFolder == root.id).toList()) { await c.queue!.cancel(job); }
              await backup.sources.remove(root.id); c.changed();
            }))),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: Text(tr(context, "Автоматически копировать новые фото")), value: backup.enabled,
          subtitle: Text(backup.enabled ? tr(context, "Выключение остановит поиск и приостановит передачи фото") : tr(context, "Копирование выключено; уже полученные фото сохраняются")),
          onChanged: !backup.enabled && (backup.peerId == null || backup.sources.roots().isEmpty) ? null : (value) => c.setPhotoBackup(value)),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(onPressed: c.busy ? null : _backupFolder, icon: Icon(Icons.add_photo_alternate_outlined), label: Text(tr(context, "Выбрать папку с фото"))),
          TextButton(onPressed: backup.scanning || !backup.enabled ? null : () => backup.scan(), child: Text(tr(context, "Проверить сейчас"))),
        ]),
        Text(!backup.enabled ? tr(context, "Копирование выключено · скопировано: {0}", [backup.copied]) : backup.scanning ? tr(context, "Проверяем новые снимки…") : tr(context, "Скопировано: {0}", [backup.copied]), style: TextStyle(color: subdued)),
        if (backup.lastError != null) SelectableText(backup.lastError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      ],
    ]);
  }

  Future<void> _sendText() async {
    final text = TextEditingController();
    final value = await showDialog<String>(context: context, builder: (context) => AlertDialog(
      title: Text(tr(context, "Отправить текст")), content: SizedBox(width: 420,
        child: TextField(controller: text, minLines: 3, maxLines: 8, autofocus: true,
          decoration: InputDecoration(hintText: tr(context, "Текст или ссылка")))),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(tr(context, "Отмена"))),
        FilledButton(onPressed: () => Navigator.pop(context, text.text), child: Text(tr(context, "Отправить")))]));
    text.dispose();
    if (value != null) await c.run(() => c.sendText(value));
  }

  Future<void> _rename() async {
    final text = TextEditingController(text: c.deviceName);
    final value = await showDialog<String>(context: context, builder: (context) => AlertDialog(
      title: Text(tr(context, "Имя устройства")), content: TextField(controller: text, maxLength: 80),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(tr(context, "Отмена"))),
        FilledButton(onPressed: () => Navigator.pop(context, text.text), child: Text(tr(context, "Сохранить")))]));
    text.dispose();
    if (value != null) await c.run(() => c.rename(value));
  }

  Future<void> _networkHelp() => showDialog<void>(context: context,
    builder: (context) => AlertDialog(title: Text(tr(context, "Подключение по локальной сети")),
      content: SingleChildScrollView(child: SelectableText(
        tr(context, "1. Подключите оба устройства к одной обычной Wi-Fi сети. Гостевая сеть может запрещать связь между устройствами.\n\n2. Проверьте доступ к локальной сети в VPN на телефоне и ПК. Для проверки временно отключите VPN, WARP и сетевые фильтры.\n\n3. На Windows нажмите «Разрешить локальные подключения» в LinkInDrop. Windows запросит права администратора. Правила разрешают только LinkInDrop и только локальную подсеть.\n\n4. Если адаптеров несколько, выберите в QR адрес сети второго устройства. Проверьте порт под QR: после смены порта обновите правило Windows Firewall.\n\n5. Для доступа на расстоянии подключите оба устройства к общей VPN-сети. В меню устройства укажите его удалённый адрес. Разрешите входящий TCP из адреса VPN в брандмауэре и оставьте LinkInDrop запущенным."))),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(tr(context, "Закрыть")))]));

  Future<void> _showActivity(Activity activity) => showDialog<void>(context: context,
    builder: (context) => AlertDialog(title: Text(activity.title),
      content: SizedBox(width: 480, child: SingleChildScrollView(child: SelectableText(activity.detail))),
      actions: [TextButton(onPressed: _networkHelp, child: Text(tr(context, "Проверить сеть"))),
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr(context, "Закрыть")))]));

  Future<void> _forget(Peer peer) async {
    final yes = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: Text(tr(context, "Отключить {0}?", [peer.name])),
      content: Text(tr(context, "Доступ к файлам и буферу будет отозван. Для подключения понадобится новый код.")),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr(context, "Отмена"))),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr(context, "Отключить")))]));
    if (yes == true) await c.run(() => c.forget(peer));
  }

  int _page = 0;
  double _viewportWidth = 800;
  Color get mint => Theme.of(context).colorScheme.primary;
  Color get background => Theme.of(context).scaffoldBackgroundColor;
  Color get surface => Theme.of(context).colorScheme.surface;
  Color get subdued => Theme.of(context).colorScheme.onSurfaceVariant;
  bool get _compact => _viewportWidth < 700;

  void _navigate(int value) {
    if (_page == value) return;
    setState(() => _page = value);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  Widget _themeSwitch() {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(decoration: BoxDecoration(border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      borderRadius: BorderRadius.circular(10)), child: Row(mainAxisSize: MainAxisSize.min, children: [
      IconButton(key: ValueKey('theme-light'), tooltip: tr(context, "Светлая тема"), isSelected: !dark,
        style: IconButton.styleFrom(foregroundColor: subdued, backgroundColor: !dark ? mint.withValues(alpha: .10) : null),
        onPressed: () => c.run(() => c.setAppearance(theme: 'light')), icon: Icon(Icons.light_mode_outlined)),
      IconButton(key: ValueKey('theme-dark'), tooltip: tr(context, "Тёмная тема"), isSelected: dark,
        style: IconButton.styleFrom(foregroundColor: subdued, backgroundColor: dark ? mint.withValues(alpha: .14) : null),
        onPressed: () => c.run(() => c.setAppearance(theme: 'dark')), icon: Icon(Icons.dark_mode_outlined)),
    ]));
  }

  Widget _brandHeader(bool compact) => Container(
    padding: EdgeInsets.symmetric(horizontal: compact ? 16 : 24, vertical: 12),
    decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Theme.of(context).colorScheme.outlineVariant))),
    child: Row(children: [
      Image.asset('assets/icons/brand.png', width: compact ? 32 : 42, height: compact ? 32 : 42, semanticLabel: 'LinkInDrop'),
      SizedBox(width: 10),
      Expanded(child: Text('LinkInDrop', maxLines: 1, overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, letterSpacing: -.6))),
      _themeSwitch(),
      if (!compact) ...[SizedBox(width: 20), Icon(Icons.desktop_windows_outlined, size: 22), SizedBox(width: 8),
        Flexible(child: TextButton(onPressed: _rename, child: Text(c.deviceName, maxLines: 1, overflow: TextOverflow.ellipsis)))],
    ]));

  Widget _destination(int index, IconData icon, String label) => Padding(
    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    child: IconButton(key: ValueKey('nav-$index'), tooltip: label, isSelected: _page == index,
      style: IconButton.styleFrom(fixedSize: Size(52, 52),
        foregroundColor: _page == index ? mint : subdued,
        backgroundColor: _page == index ? mint.withValues(alpha: .10) : null,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
      onPressed: () => _navigate(index), icon: Icon(icon, size: 26)));

  Widget _rail() => Container(width: 80, decoration: BoxDecoration(
    border: Border(right: BorderSide(color: Theme.of(context).colorScheme.outlineVariant))),
    child: Column(children: [SizedBox(height: 12),
      _destination(0, Icons.file_upload_outlined, tr(context, "Передача")),
      _destination(1, Icons.file_download_outlined, tr(context, "Полученные")),
      _destination(2, Icons.devices_outlined, tr(context, "Устройства")),
      Spacer(), _destination(3, Icons.settings_outlined, tr(context, "Настройки")), SizedBox(height: 16)]));

  Widget _pageHeader(String title) => Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
    Expanded(child: Text(title, maxLines: 2, style: TextStyle(fontSize: _compact ? 25 : 32, fontWeight: FontWeight.w700, letterSpacing: -.6))),
    SizedBox(width: 8),
    if (_compact && (_viewportWidth < 360 || MediaQuery.textScalerOf(context).scale(14) > 18)) IconButton(key: ValueKey('received-shortcut'),
      tooltip: tr(context, 'Полученные файлы'), onPressed: c.node == null ? null : c.revealReceivedFolder, icon: Icon(Icons.folder_open_outlined))
    else if (_compact) TextButton.icon(key: ValueKey('received-shortcut'),
      style: TextButton.styleFrom(padding: EdgeInsets.symmetric(horizontal: 6), minimumSize: Size(44, 44)),
      onPressed: c.node == null ? null : c.revealReceivedFolder,
      icon: Icon(Icons.folder_open_outlined, size: 20), label: Text(tr(context, "Полученные файлы"),
        maxLines: 1, style: TextStyle(fontSize: 12)))
    else TextButton.icon(key: ValueKey('received-shortcut'), onPressed: c.node == null ? null : c.revealReceivedFolder,
      icon: Icon(Icons.folder_open_outlined), label: Text(tr(context, "Полученные файлы"))),
  ]);

  Widget _recipient() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(tr(context, "Получатель"), style: TextStyle(color: subdued)), SizedBox(height: 8),
    LayoutBuilder(builder: (context, constraints) {
      final selector = DropdownButtonFormField<String>(key: ValueKey('recipient-${c.selectedPeer?.id}'),
        value: c.selectedPeer?.id, isExpanded: true,
        hint: Text(tr(context, "Выберите устройство")),
        items: c.peers.map((peer) => DropdownMenuItem(value: peer.id, child: Row(children: [
          Icon(Icons.devices_outlined, size: 20), SizedBox(width: 10),
          Expanded(child: Text(peer.name, maxLines: 1, overflow: TextOverflow.ellipsis)), SizedBox(width: 8),
          Icon(Icons.circle, size: 8, color: peer.online ? Color(0xff22a85c) : subdued),
          SizedBox(width: 6), Text(peer.online ? tr(context, "В сети") : tr(context, "Не в сети"), style: TextStyle(fontSize: 12, color: subdued)),
        ]))).toList(), onChanged: (value) { if (value != null) c.selectPeer(value); });
      if (constraints.maxWidth < 900) return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [selector,
        SizedBox(height: 4), Wrap(alignment: WrapAlignment.spaceBetween, spacing: 8, children: [
          TextButton.icon(onPressed: c.node == null ? null : _browseFiles, icon: Icon(Icons.folder_outlined, size: 18), label: Text(tr(context, "Файлы устройства"))),
          if (c.peers.isEmpty) TextButton.icon(onPressed: c.busy ? null : _showInvite, icon: Icon(Icons.add, size: 18), label: Text(tr(context, "Добавить устройство")))])]);
      return Row(children: [Expanded(child: selector), SizedBox(width: 12),
        OutlinedButton.icon(onPressed: c.node == null ? null : _browseFiles, icon: Icon(Icons.folder_outlined), label: Text(tr(context, "Файлы устройства"))),
        SizedBox(width: 12), OutlinedButton.icon(onPressed: c.busy ? null : _showInvite,
          icon: Icon(Icons.add), label: Text(tr(context, "Добавить устройство")))]);
    }),
  ]);

  Future<void> _selectFolder() async {
    final selected = await getDirectoryPath();
    if (selected != null && mounted) await c.run(() => c.stageFiles([selected]));
  }

  Widget _sourceRow(SelectedSource source) => Padding(padding: EdgeInsets.symmetric(vertical: 6), child: Row(children: [
    Container(width: 42, height: 42, decoration: BoxDecoration(color: mint.withValues(alpha: .08), borderRadius: BorderRadius.circular(8)),
      child: Icon(source.directory ? Icons.folder_outlined : Icons.description_outlined, color: mint)),
    SizedBox(width: 12), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(source.name, maxLines: 2, overflow: TextOverflow.ellipsis),
      Text(source.directory ? tr(context, "Папка со всем содержимым") : _fileSize(source.size), style: TextStyle(color: subdued, fontSize: 12)),
    ])), IconButton(tooltip: tr(context, "Убрать файл"), onPressed: c.busy || c.selection.sending ? null : () => c.run(() => c.removeSelected(source)), icon: Icon(Icons.close, size: 20)),
  ]));

  Widget _photo(SelectedSource source) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Stack(children: [
      AspectRatio(aspectRatio: _compact ? 1.4 : 2.1, child: ClipRRect(borderRadius: BorderRadius.circular(8),
        child: Image.file(File(source.path), fit: BoxFit.cover, cacheWidth: 600,
          errorBuilder: (_, error, stack) => ColoredBox(color: surface, child: Center(child: Icon(Icons.image_outlined, size: 36)))))),
      Positioned(top: 4, right: 4, child: IconButton.filledTonal(tooltip: tr(context, "Убрать файл"),
        style: IconButton.styleFrom(backgroundColor: surface.withValues(alpha: .95)),
        onPressed: c.busy || c.selection.sending ? null : () => c.run(() => c.removeSelected(source)), icon: Icon(Icons.close, size: 18))),
    ]), SizedBox(height: 6), Text(source.name, maxLines: 1, overflow: TextOverflow.ellipsis),
    Text(_fileSize(source.size), style: TextStyle(color: subdued, fontSize: 12)),
  ]);

  Widget _selectionPreview() {
    final photos = c.selection.items.where((source) => source.image).toList();
    final others = c.selection.items.where((source) => !source.image);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(height: 20),
      Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.center, spacing: 16, runSpacing: 4, children: [
        Text(tr(context, "К отправке"), style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
        Text('${c.selection.items.length} · ${_fileSize(c.selection.totalBytes)}${c.selection.hasDirectories ? tr(context, " + папки") : ''}', style: TextStyle(color: subdued)),
      ]), SizedBox(height: 12),
      if (photos.isNotEmpty) LayoutBuilder(builder: (context, constraints) {
        final columns = constraints.maxWidth < 300 ? 1 : 2;
        final availableWidth = (constraints.maxWidth - (columns - 1) * 12) / columns;
        final width = !_compact && availableWidth > 440 ? 440.0 : availableWidth;
        return Wrap(spacing: 12, runSpacing: 14, children: photos.map((source) => SizedBox(width: width, child: _photo(source))).toList());
      }),
      if (others.isNotEmpty) ...[SizedBox(height: 10), for (final source in others) ...[_sourceRow(source), Divider(height: 1)]],
    ]);
  }

  Widget _transferPage() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    _pageHeader(tr(context, "Передача")), SizedBox(height: 20), _recipient(),
    if (c.selection.items.isNotEmpty) _selectionPreview(),
    SizedBox(height: 16),
    if (c.isAndroid) OutlinedButton.icon(onPressed: c.busy || c.selection.loading || c.selection.sending ? null : _sendFiles,
      icon: Icon(Icons.add), label: Text(tr(context, "Добавить файлы")))
    else _dropZone(),
    if (c.selection.loading) Padding(padding: EdgeInsets.all(8), child: LinearProgressIndicator()),
    SizedBox(height: 10),
    if (_compact) ...[
      Align(alignment: Alignment.centerLeft, child: TextButton.icon(onPressed: c.busy ? null : _sendText,
        icon: Icon(Icons.notes_outlined), label: Text(tr(context, "Добавить текст")))),
      if (c.selection.items.isNotEmpty) FilledButton(key: ValueKey('send-selection'),
        onPressed: c.busy || c.selectedPeer == null || c.selection.sending || c.selection.loading ? null : () => c.run(c.sendSelection),
        child: Text(c.selection.sending ? tr(context, "Добавляем в очередь…") : c.selection.hasDirectories ? tr(context, 'Передать выбранное') : trFiles(context, c.selection.items.length))),
    ] else Row(children: [TextButton.icon(onPressed: c.busy ? null : _sendText,
      icon: Icon(Icons.notes_outlined), label: Text(tr(context, "Добавить текст"))), Spacer(),
      if (c.selection.items.isNotEmpty) FilledButton(key: ValueKey('send-selection'),
        onPressed: c.busy || c.selectedPeer == null || c.selection.sending || c.selection.loading ? null : () => c.run(c.sendSelection),
        child: Text(c.selection.sending ? tr(context, "Добавляем в очередь…") : c.selection.hasDirectories ? tr(context, 'Передать выбранное') : trFiles(context, c.selection.items.length))),
    ]),
    SizedBox(height: 20),
    if ((c.queue?.pending ?? 0) > 0) ...[_queue(), SizedBox(height: 16)],
    _history(),
  ]);

  Widget _receivedPage() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    _pageHeader(tr(context, "Полученные")), SizedBox(height: 20),
    Text(c.receiveDestination ?? tr(context, "Встроенная папка LinkInDrop"), style: TextStyle(color: subdued)),
    SizedBox(height: 16), _history(receivedOnly: true),
    SizedBox(height: 24),
    Text(tr(context, "Приём файлов"), style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
    SwitchListTile(contentPadding: EdgeInsets.zero, title: Text(tr(context, "Разрешить приём файлов")),
      value: c.receiveFiles, onChanged: (value) => c.setSettings(filesReceiving: value)),
  ]);

  Widget _appearance() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(tr(context, "Оформление и язык"), style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)), SizedBox(height: 16),
    DropdownButtonFormField<String>(key: ValueKey('theme-${c.themePreference}'), value: c.themePreference, isExpanded: true,
      decoration: InputDecoration(labelText: tr(context, "Тема")), items: [
        DropdownMenuItem(value: 'system', child: Text(tr(context, "Как в системе"))),
        DropdownMenuItem(value: 'light', child: Text(tr(context, "Светлая"))), DropdownMenuItem(value: 'dark', child: Text(tr(context, "Тёмная")))],
      onChanged: (value) { if (value != null) unawaited(c.run(() => c.setAppearance(theme: value))); }),
    SizedBox(height: 16),
    DropdownButtonFormField<String>(key: ValueKey('language-${c.languagePreference}'), value: c.languagePreference, isExpanded: true,
      decoration: InputDecoration(labelText: tr(context, "Язык")), items: [
        DropdownMenuItem(value: 'system', child: Text(tr(context, "Как в системе"))),
        DropdownMenuItem(value: 'ru', child: Text('Русский')), DropdownMenuItem(value: 'en', child: Text('English'))],
      onChanged: (value) { if (value != null) unawaited(c.run(() => c.setAppearance(language: value))); }),
    SizedBox(height: 12), ListTile(contentPadding: EdgeInsets.zero, title: Text(c.deviceName),
      subtitle: Text(tr(context, "Имя устройства")), trailing: IconButton(tooltip: tr(context, "Изменить имя"), onPressed: _rename, icon: Icon(Icons.edit_outlined))),
  ]);

  @override
  Widget build(BuildContext context) => AnimatedBuilder(animation: c, builder: (context, _) => LayoutBuilder(builder: (context, constraints) {
    _viewportWidth = constraints.maxWidth;
    final compact = _compact;
    final sections = <Widget>[
      if (c.loading) Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())),
      if (c.startupError != null) ...[Text(tr(context, 'Не удалось запустить соединение')), SizedBox(height: 12), SelectableText(c.startupError!)],
      if (!c.loading && c.startupError == null) ...[
        if (_page == 0) _transferPage(),
        if (_page == 1) _receivedPage(),
        if (_page == 2) ...[
          _pageHeader(tr(context, 'Устройства')), SizedBox(height: 20), _devices(), SizedBox(height: 24),
          _section(tr(context, 'Мои файлы и папки'), Icons.folder_shared_outlined, Column(children: [
            SwitchListTile(title: Text(tr(context, 'Разрешить доступ к моим файлам и папкам')),
              subtitle: Text(tr(context, 'Доступ только для привязанных устройств')), value: c.shareFiles,
              onChanged: (value) => c.setSettings(fileSharing: value)),
            TextButton(onPressed: _manageSharedFiles, child: Text(tr(context, 'Выбрать файлы и папки'))),
          ])),
        ],
        if (_page == 3) ...[
          _pageHeader(tr(context, 'Настройки')), SizedBox(height: 20), _appearance(), Divider(height: 32),
          _section(tr(context, 'Общий буфер'), Icons.content_paste, _clipboard()), SizedBox(height: 16),
          _section(tr(context, 'Фоновая работа и фотобэкап'), Icons.settings_outlined, _settings()), SizedBox(height: 16),
          _section(tr(context, 'Хранение и подключение'), Icons.tune, ReliabilityPanel(controller: c,
            openFolder: (peer, folder) => _browseFiles(target: peer, initial: folder))),
        ],
      ],
    ];
    final content = SingleChildScrollView(key: PageStorageKey('home-scroll'), controller: _scroll,
      padding: EdgeInsets.fromLTRB(compact ? 18 : 36, compact ? 16 : 24, compact ? 18 : 36, 24),
      child: Align(alignment: Alignment.topCenter, child: ConstrainedBox(constraints: BoxConstraints(maxWidth: 1280),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: sections))));
    return Scaffold(
      body: SafeArea(child: Column(children: [
        _brandHeader(compact),
        if (c.busy) LinearProgressIndicator(minHeight: 2) else SizedBox(height: 2),
        Expanded(child: Row(children: [
          if (!compact) _rail(),
          Expanded(child: Scrollbar(controller: _scroll, thumbVisibility: !compact, child: content)),
        ])),
      ])),
      bottomNavigationBar: compact ? NavigationBar(selectedIndex: _page, onDestinationSelected: _navigate, destinations: [
        NavigationDestination(icon: Icon(Icons.file_upload_outlined), label: tr(context, 'Передача')),
        NavigationDestination(icon: Icon(Icons.file_download_outlined), label: tr(context, 'Полученные')),
        NavigationDestination(icon: Icon(Icons.devices_outlined), label: tr(context, 'Устройства')),
        NavigationDestination(icon: Icon(Icons.settings_outlined), label: tr(context, 'Настройки')),
      ]) : null);
  }));

  Widget _devices() => _panel(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Row(children: [Expanded(child: Text(tr(context, "Устройства"), style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600))),
      _badge(tr(context, "{0} в сети", [c.onlineCount]), mint)]),
    SizedBox(height: 18),
    if (c.peers.isEmpty) Padding(padding: EdgeInsets.symmetric(vertical: 24),
      child: Text(tr(context, "Свяжите телефон и компьютер один раз.\nДальше они будут узнавать друг друга."), style: TextStyle(color: subdued, height: 1.6))),
    for (final peer in c.peers) Padding(padding: EdgeInsets.only(bottom: 8), child: _device(peer)),
    SizedBox(height: 12),
    Wrap(spacing: 8, runSpacing: 8, children: [
      FilledButton.icon(onPressed: c.busy ? null : _showInvite, icon: Icon(Icons.add_rounded), label: Text(tr(context, "Добавить"))),
      OutlinedButton(onPressed: c.busy ? null : _enterCode, child: Text(tr(context, "Ввести код"))),
      if (c.isAndroid) IconButton(onPressed: c.busy ? null : _scan, tooltip: tr(context, "Сканировать QR"), icon: Icon(Icons.qr_code_scanner_rounded)),
    ]),
    if (c.pairingStage != null) Padding(padding: EdgeInsets.only(top: 12),
      child: Text(c.pairingStage!, style: TextStyle(color: mint))),
    if (c.node?.nearby.isNotEmpty == true) Padding(padding: EdgeInsets.only(top: 16),
      child: Text(tr(context, "Рядом: {0}", [c.node!.nearby.values.map((d) => d['name']).join(', ')]),
        style: TextStyle(color: subdued, fontSize: 12))),
    SizedBox(height: 12),
    TextButton.icon(onPressed: _networkHelp, icon: Icon(Icons.wifi_rounded),
      label: Text(tr(context, "Не получается подключиться?"))),
    if (Platform.isWindows) ...[
      Text(tr(context, "Windows запросит разрешение администратора. Доступ получит только LinkInDrop из локальной подсети."),
        style: TextStyle(color: subdued, fontSize: 12)),
      TextButton.icon(onPressed: c.busy ? null : () => c.run(c.configureNetwork),
        icon: Icon(Icons.settings_ethernet_rounded), label: Text(tr(context, "Разрешить локальные подключения"))),
    ],
  ]));

  Widget _device(Peer peer) {
    final tile = Container(decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(14),
      border: Border.all(color: _draggingPeer == peer.id || c.selectedPeer?.id == peer.id ? mint : Colors.transparent)),
      child: ListTile(onTap: () => c.selectPeer(peer.id),
        leading: Icon(Icons.devices_rounded, color: peer.online ? mint : subdued),
        title: Text(peer.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text('${peer.online ? tr(context, "Подключено") : tr(context, "Не в сети")}${peer.activeRelay ? tr(context, " · интернет") : ''}', style: TextStyle(color: subdued)),
        trailing: PopupMenuButton<String>(onSelected: (value) {
          if (value == 'files') unawaited(_browseFiles(target: peer));
          if (value == 'forget') unawaited(_forget(peer));
          if (value == 'clipboard') unawaited(c.setPeerClipboard(peer, !peer.clipboardEnabled));
          if (value == 'address') unawaited(_remoteAddress(peer));
          if (value == 'incoming') unawaited(c.setIncomingFiles(peer, !peer.incomingFilesEnabled));
        }, itemBuilder: (_) => [
          PopupMenuItem(value: 'files', child: Text(tr(context, "Открыть файлы устройства"))),
          PopupMenuItem(value: 'clipboard', child: Text(peer.clipboardEnabled ? tr(context, "Отключить общий буфер") : tr(context, "Включить общий буфер"))),
          PopupMenuItem(value: 'incoming', child: Text(peer.incomingFilesEnabled ? tr(context, "Запретить приём файлов") : tr(context, "Разрешить приём файлов"))),
          PopupMenuItem(value: 'address', child: Text(tr(context, "Локальный / удалённый адрес"))),
          PopupMenuItem(value: 'forget', child: Text(tr(context, "Забыть устройство")))])));
    if (!Platform.isWindows && !Platform.isLinux) return tile;
    return DropTarget(onDragEntered: (_) => setState(() => _draggingPeer = peer.id),
      onDragExited: (_) => setState(() => _draggingPeer = null),
      onDragDone: (detail) {
        setState(() => _draggingPeer = null);
        c.selectPeer(peer.id);
        _navigate(0);
        unawaited(_dropFiles(detail.files.map((f) => f.path).toList()));
      }, child: tile);
  }

  Widget _clipboard() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(tr(context, "Текст, ссылки и изображения"), style: TextStyle(fontSize: 18)),
    SizedBox(height: 8),
    Text(c.isAndroid ? tr(context, "Для отправки откройте LinkInDrop и нажмите «Отправить буфер» или используйте «Поделиться».")
      : tr(context, "Скопируйте здесь — вставьте на связанном устройстве. Приложение должно оставаться запущенным."),
      style: TextStyle(color: subdued, height: 1.5)),
    SizedBox(height: 12),
    SwitchListTile(contentPadding: EdgeInsets.zero, title: Text(tr(context, "Отправлять изменения")),
      subtitle: Text(c.isAndroid ? tr(context, "Пока приложение открыто") : tr(context, "Автоматически"), style: TextStyle(color: subdued)),
      value: c.autoClipboard, onChanged: (value) => unawaited(c.setSettings(automatic: value))),
    SwitchListTile(contentPadding: EdgeInsets.zero, title: Text(tr(context, "Принимать в буфер")),
      value: c.receiveClipboard, onChanged: (value) => unawaited(c.setSettings(clipboardReceiving: value))),
    SizedBox(height: 12),
    Wrap(spacing: 8, runSpacing: 8, children: [
      FilledButton.icon(onPressed: c.busy || c.onlineCount == 0 ? null : () => c.run(c.pushClipboard),
        icon: Icon(Icons.send_rounded, size: 18), label: Text(tr(context, "Отправить буфер"))),
      TextButton(onPressed: c.busy || c.onlineCount == 0 ? null : _sendText, child: Text(tr(context, "Написать текст"))),
    ]),
  ]);

  Widget _history({bool receivedOnly = false}) => _panel(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(tr(context, "Последние передачи"), style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
    SizedBox(height: 12),
    if (c.activities.isEmpty) Padding(padding: EdgeInsets.symmetric(vertical: 16),
      child: Text(tr(context, "Здесь появятся результаты передачи. Содержимое буфера не сохраняется."), style: TextStyle(color: subdued))),
    for (final activity in c.activities.where((item) => !receivedOnly || item.path != null).take(12)) ListTile(contentPadding: EdgeInsets.zero,
      onTap: () => _showActivity(activity),
      leading: Icon(activity.error ? Icons.error_outline_rounded : activity.path != null
        ? Icons.insert_drive_file_outlined : Icons.check_circle_outline_rounded,
        color: activity.error ? Theme.of(context).colorScheme.error : mint),
      title: Text(activity.title), subtitle: Text(activity.detail.split(tr(context, "\n\nПодробности:")).first,
        maxLines: activity.error ? null : 2, overflow: activity.error ? null : TextOverflow.ellipsis,
        style: TextStyle(color: subdued)),
      trailing: activity.path == null ? Text('${activity.time.hour.toString().padLeft(2, '0')}:${activity.time.minute.toString().padLeft(2, '0')}',
        style: TextStyle(color: subdued, fontSize: 12)) : IconButton(icon: Icon(Icons.open_in_new_rounded),
        tooltip: tr(context, "Открыть файл"), onPressed: () async {
          if (activity.path!.startsWith('content://')) {
            await c.run(() => c.platformChannel.invokeMethod<void>('openReceivedFile', {'location': activity.path})); return;
          }
          final result = await OpenFilex.open(activity.path!);
          if (result.type != ResultType.done) c.record(Activity(tr(context, "Не удалось открыть"), result.message, error: true));
        })),
  ]));

  Future<void> _dropFiles(List<String> paths) async {
    final failure = tr(context, 'Не получилось');
    try { await c.stageFiles(paths); }
    catch (error) { c.record(Activity(failure, '$error', error: true)); }
  }

  Widget _dropZone() {
    final empty = c.selection.items.isEmpty;
    final content = Container(key: ValueKey('file-drop-zone'), width: double.infinity,
      padding: EdgeInsets.all(empty ? 28 : 14), decoration: BoxDecoration(
        color: mint.withValues(alpha: _dropping ? .12 : .025), borderRadius: BorderRadius.circular(8),
        border: Border.all(color: mint.withValues(alpha: _dropping ? 1 : .5))),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (empty) ...[Icon(Icons.upload_file_outlined, size: 52, color: mint), SizedBox(height: 16)],
        Text(_dropping ? tr(context, "Отпустите, чтобы добавить") : empty ? tr(context, "Перетащите сюда файлы или папки") : tr(context, "Перетащите ещё файлы сюда"),
          textAlign: TextAlign.center, style: TextStyle(fontSize: empty ? 20 : 14, fontWeight: FontWeight.w600)),
        SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
          OutlinedButton(onPressed: c.busy || c.selection.sending || c.selection.loading ? null : _sendFiles,
            child: Text(empty ? tr(context, "Выбрать файлы") : tr(context, "Добавить файлы"))),
          TextButton(onPressed: c.busy || c.selection.sending || c.selection.loading ? null : _selectFolder, child: Text(tr(context, "Добавить папку"))),
        ]),
      ]));
    return DropTarget(onDragEntered: (_) => setState(() => _dropping = true),
      onDragExited: (_) => setState(() => _dropping = false),
      onDragDone: (detail) { setState(() => _dropping = false); unawaited(_dropFiles(detail.files.map((file) => file.path).toList())); },
      child: content);
  }

  Widget _section(String title, IconData icon, Widget child) => Container(
    decoration: BoxDecoration(color: surface, borderRadius: BorderRadius.circular(8), border: Border.all(color: Theme.of(context).colorScheme.outlineVariant)),
    child: ExpansionTile(key: PageStorageKey(title), shape: Border(), collapsedShape: Border(),
      leading: Icon(icon, color: mint), title: Text(title), tilePadding: EdgeInsets.symmetric(horizontal: 14),
      childrenPadding: EdgeInsets.fromLTRB(14, 0, 14, 14), children: [child]));

  Widget _panel(Widget child) => Container(width: double.infinity, padding: EdgeInsets.all(_viewportWidth < 500 ? 12 : 16),
    decoration: BoxDecoration(color: surface, borderRadius: BorderRadius.circular(8),
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant)), child: child);

  Widget _badge(String text, Color color) => Container(padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(color: color.withValues(alpha: .08), borderRadius: BorderRadius.circular(30)),
    child: Text(text, style: TextStyle(color: color, fontSize: 12)));
}

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});
  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final controller = MobileScannerController();
  bool done = false;
  @override
  void dispose() { unawaited(controller.dispose()); super.dispose(); }
  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: Text(tr(context, "Сканировать код"))),
    body: MobileScanner(controller: controller, onDetect: (capture) {
      if (done) return;
      for (final barcode in capture.barcodes) {
        final value = barcode.rawValue;
        if (value != null && value.startsWith('nearbridge://pair/')) {
          done = true;
          Navigator.pop(context, value);
          break;
        }
      }
    }));
}

