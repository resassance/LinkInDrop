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
import 'design_system.dart';
import 'text_compose_dialog.dart';
import 'attachment_sheet.dart';
import 'media_composer.dart';
import 'media_thumbnail.dart';
import 'receive_destination.dart';
import '../core/media_library.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

class LinkInDropApp extends StatelessWidget {
  const LinkInDropApp({super.key, required this.controller, this.start = true});
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
            if (addresses.length > 1) ChoiceField<String>(label: tr(context, 'IPv4 / DNS'), value: host, options: {for (final ip in addresses) ip: ip},
              onChanged: (value) => setDialogState(() => host = value)),
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
    if (c.isAndroid) {
      final uris = await AndroidFolders().pickFiles();
      if (uris.isEmpty) return;
      final paths = await const MediaLibrary().importItems(uris);
      await c.stageFiles(paths);
    } else {
      final files = await openFiles();
      if (!mounted || files.isEmpty) return;
      await c.run(() => c.stageFiles(files.map((file) => file.path).toList(), names: {for (final file in files) file.path: file.name}));
    }
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
          ChoiceField<String>(label: tr(context, 'Срок доступа'), value: duration, options: {
            if (old.expiresAt != null) 'keep': tr(context, 'Не менять срок'), 'never': tr(context, 'Бессрочно'),
            '15': tr(context, 'На 15 минут'), '60': tr(context, 'На час'), '1440': tr(context, 'На сутки')},
            onChanged: (value) => update(() => duration = value)),
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
          Text('${job.backupPaused ? tr(context, "Фотобэкап выключен") : job.state == 'completed' && job.skipped ? tr(context, "Пропущено") : labels[job.state] ?? job.state}${job.state == 'running' ? ' · ${(job.progress * 100).round()}%' : ''}', style: TextStyle(color: job.state == 'completed' ? successColor(context) : job.state == 'failed' ? Theme.of(context).colorScheme.error : job.state == 'paused' ? warningColor(context) : subdued)),
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
      if (!c.isAndroid) SectionHeading(tr(context, 'Фоновая работа')),
      if (Platform.isWindows || Platform.isLinux) ...[
        SwitchListTile(contentPadding: EdgeInsets.zero, title: Text(tr(context, "Сворачивать в трей при закрытии")),
          value: c.closeToTray, onChanged: (value) => c.run(() => c.setDesktop(hide: value))),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: Text(tr(context, "Запускать вместе с системой")),
          value: c.desktop?.startupEnabled ?? false,
          onChanged: c.desktop == null ? null : (value) => c.run(() => c.setDesktop(startup: value))),
        Text(tr(context, "Перетащите файлы или папку на устройство, чтобы подготовить передачу."), style: TextStyle(color: subdued)),
      ],
      Divider(height: 32),
      SectionHeading(tr(context, 'Резервное копирование фото'), help: tr(context, 'Новые фото из выбранных папок отправляются на устройство ниже. Оригиналы сохраняются; одинаковые снимки повторно не передаются.')),
      if (backup != null) ...[
        ChoiceField<String>(label: tr(context, 'Куда копировать фото'), value: c.peers.any((peer) => peer.id == backup.peerId) ? backup.peerId : null,
          options: {for (final peer in c.peers) peer.id: peer.name}, onChanged: (value) async { backup.peerId = value; await backup.save(); c.changed(); }), const SizedBox(height: 12),
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
    final value = await showDialog<String>(context: context, builder: (_) => TextComposeDialog(recipient: c.selectedPeer?.name));
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

  Widget _themeSwitch() => PopupMenuButton<String>(key: const ValueKey('theme-menu'), tooltip: tr(context, 'Тема'),
    initialValue: c.themePreference, position: PopupMenuPosition.under,
    onSelected: (value) => c.run(() => c.setAppearance(theme: value)),
    icon: Icon(switch (c.themePreference) { 'light' => Icons.light_mode_outlined, 'dark' => Icons.dark_mode_outlined, _ => Icons.brightness_auto_outlined }),
    itemBuilder: (context) => [for (final item in [('light', Icons.light_mode_outlined, 'Светлая'), ('dark', Icons.dark_mode_outlined, 'Тёмная'), ('system', Icons.brightness_auto_outlined, 'Как в системе')])
      PopupMenuItem(value: item.$1, child: Row(children: [Icon(item.$2, color: mint), const SizedBox(width: 12), Expanded(child: Text(tr(context, item.$3))),
        if (c.themePreference == item.$1) Icon(Icons.check_rounded, color: mint)]))]);

  Widget _brandHeader(bool compact) => Container(
    padding: EdgeInsets.symmetric(horizontal: compact ? 16 : 24, vertical: 12),
    decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Theme.of(context).colorScheme.outlineVariant))),
    child: Row(children: [Image.asset('assets/icons/brand.png', width: 36, height: 36, semanticLabel: 'LinkInDrop'), const SizedBox(width: 10),
      Expanded(child: Text('LinkInDrop', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, letterSpacing: -.6))),
      if (!compact) ...[const Icon(Icons.desktop_windows_outlined, size: 22), const SizedBox(width: 8),
        ConstrainedBox(constraints: const BoxConstraints(maxWidth: 260), child: TextButton(onPressed: _rename, child: Text(c.deviceName, maxLines: 1, overflow: TextOverflow.ellipsis))), const SizedBox(width: 16)],
      _themeSwitch(),
    ]));

  Widget _destination(int index, IconData icon, String label) => Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    child: TextButton(key: ValueKey('nav-$index'), style: TextButton.styleFrom(alignment: Alignment.centerLeft,
      foregroundColor: _page == index ? mint : subdued, backgroundColor: _page == index ? mint.withValues(alpha: .10) : null),
      onPressed: () => _navigate(index), child: Row(children: [Icon(icon), const SizedBox(width: 12), Expanded(child: Text(label))])));

  Widget _rail() => Container(width: 184, decoration: BoxDecoration(border: Border(right: BorderSide(color: Theme.of(context).colorScheme.outlineVariant))),
    child: Column(children: [const SizedBox(height: 16), _destination(0, Icons.file_upload_outlined, tr(context, 'Передача')),
      _destination(1, Icons.file_download_outlined, tr(context, 'Полученные')), _destination(2, Icons.devices_outlined, tr(context, 'Устройства')),
      const Spacer(), _destination(3, Icons.settings_outlined, tr(context, 'Настройки')), const SizedBox(height: 16)]));

  Widget _pageHeader(String title) => Text(title, style: TextStyle(fontSize: _compact ? 26 : 32, fontWeight: FontWeight.w700, letterSpacing: -.6));

  Widget _recipient() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    ChoiceField<String>(key: const ValueKey('recipient'), label: tr(context, 'Получатель'), value: c.selectedPeer?.id,
      options: {for (final peer in c.peers) peer.id: '${peer.name} · ${peer.online ? tr(context, 'В сети') : tr(context, 'Не в сети')}'},
      icon: Icons.devices_outlined, selectedChild: c.selectedPeer == null ? null : Row(children: [
        Expanded(child: Text(c.selectedPeer!.name, maxLines: 1, overflow: TextOverflow.ellipsis)), const SizedBox(width: 8),
        Icon(Icons.circle, size: 8, color: c.selectedPeer!.online ? successColor(context) : subdued), const SizedBox(width: 6),
        Text(c.selectedPeer!.online ? tr(context, 'В сети') : tr(context, 'Не в сети'), style: TextStyle(color: c.selectedPeer!.online ? successColor(context) : subdued, fontSize: 12)),
      ]), onChanged: c.busy ? null : c.selectPeer),
    const SizedBox(height: 8), Align(alignment: Alignment.centerLeft, child: TextButton.icon(onPressed: c.node == null ? null : _browseFiles,
      icon: const Icon(Icons.folder_open_outlined), label: Text(c.selectedPeer == null ? tr(context, 'Файлы устройства') : tr(context, 'Открыть файлы {0}', [c.selectedPeer!.name])))),
    if (c.peers.isEmpty) Align(alignment: Alignment.centerLeft, child: OutlinedButton.icon(onPressed: c.busy ? null : _showInvite,
      icon: const Icon(Icons.add_rounded), label: Text(tr(context, 'Добавить устройство')))),
  ]);

  Future<void> _selectFolder() async {
    if (c.isAndroid) {
      final selected = await AndroidFolders().pick();
      if (selected == null) return;
      final path = await const MediaLibrary().exportFolder(selected['uri'] as String);
      if (path != null) await c.stageFiles([path]);
    } else {
      final selected = await getDirectoryPath();
      if (selected != null && mounted) await c.run(() => c.stageFiles([selected]));
    }
  }

  Future<void> _attachments() async {
    final next = await showModalBottomSheet<bool>(context: context, isScrollControlled: true, useSafeArea: true, showDragHandle: false,
      builder: (context) => AttachmentSheet(controller: c, pickFiles: _sendFiles, pickFolder: _selectFolder));
    if (next == true && mounted) await _composeMedia();
  }

  Future<void> _composeMedia() => showModalBottomSheet<void>(context: context, isScrollControlled: true, useSafeArea: true,
    constraints: const BoxConstraints(maxWidth: 620), builder: (context) => SizedBox(height: MediaQuery.sizeOf(context).height * .88,
      child: MediaComposer(controller: c, addFiles: () async { Navigator.pop(context); await _attachments(); })));

  Future<void> _pushClipboard() async {
    final before = c.activities.isEmpty ? null : c.activities.first;
    await c.run(c.pushClipboard);
    if (!mounted) return;
    final activity = c.activities.isEmpty ? null : c.activities.first;
    if (activity != null && activity != before) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      backgroundColor: activity.error ? Theme.of(context).colorScheme.errorContainer : successColor(context),
      content: Text(activity.error ? activity.detail : activity.title, style: TextStyle(color: activity.error ? Theme.of(context).colorScheme.onErrorContainer : Colors.white))));
  }

  Widget _sourceRow(SelectedSource source) => Padding(padding: EdgeInsets.symmetric(vertical: 6), child: Row(children: [
    source.directory ? Container(width: 56, height: 56, decoration: BoxDecoration(color: mint.withValues(alpha: .08), borderRadius: BorderRadius.circular(10)),
      child: Icon(Icons.folder_outlined, color: mint)) : MediaThumbnail(path: source.path, name: source.name),
    SizedBox(width: 12), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(source.name, maxLines: 2, overflow: TextOverflow.ellipsis),
      Text(source.directory ? tr(context, "Папка со всем содержимым") : _fileSize(source.size), style: TextStyle(color: subdued, fontSize: 12)),
    ])), IconButton(tooltip: tr(context, "Убрать файл"), onPressed: c.busy || c.selection.sending ? null : () => c.run(() => c.removeSelected(source)), icon: Icon(Icons.close, size: 20)),
  ]));

  Widget _selectionPreview() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    const SizedBox(height: 20), SectionHeading(tr(context, 'К отправке')),
    Text('${c.selection.items.length} · ${_fileSize(c.selection.totalBytes)}${c.selection.hasDirectories ? tr(context, ' + папки') : ''}', style: TextStyle(color: subdued)),
    const SizedBox(height: 8), for (final source in c.selection.items) ...[InkWell(onTap: source.image || source.video ? _composeMedia : null, child: _sourceRow(source)), const Divider(height: 1)],
  ]);

  Widget _transferPage() {
    final disabled = c.busy || c.selection.loading || c.selection.sending;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _pageHeader(tr(context, 'Передача')), const SizedBox(height: 24), _recipient(), const SizedBox(height: 16),
      if (c.isAndroid) ...[
        if (c.selection.items.isEmpty) FilledButton.icon(key: const ValueKey('attach'), onPressed: disabled ? null : _attachments,
          icon: const Icon(Icons.attach_file_rounded), label: Text(tr(context, 'Прикрепить')))
        else OutlinedButton.icon(key: const ValueKey('attach'), onPressed: disabled ? null : _attachments, icon: const Icon(Icons.attach_file_rounded), label: Text(tr(context, 'Прикрепить'))), const SizedBox(height: 8),
        ActionRow(flexes: const [2, 3], children: [
          OutlinedButton.icon(key: const ValueKey('compose-text'), onPressed: disabled ? null : _sendText, icon: const Icon(Icons.notes_outlined), label: Text(tr(context, 'Текст'))),
          OutlinedButton.icon(key: const ValueKey('send-clipboard'), onPressed: disabled || c.selectedPeer == null ? null : _pushClipboard, icon: const Icon(Icons.send_rounded), label: Text(tr(context, 'Отправить буфер'))),
        ]),
      ] else ActionRow(children: [
        OutlinedButton.icon(onPressed: disabled ? null : _sendFiles, icon: const Icon(Icons.description_outlined), label: Text(tr(context, 'Выбрать файлы'))),
        OutlinedButton.icon(onPressed: disabled ? null : _selectFolder, icon: const Icon(Icons.folder_outlined), label: Text(tr(context, 'Добавить папку'))),
        OutlinedButton.icon(key: const ValueKey('compose-text'), onPressed: disabled ? null : _sendText, icon: const Icon(Icons.notes_outlined), label: Text(tr(context, 'Текст'))),
        OutlinedButton.icon(key: const ValueKey('send-clipboard'), onPressed: disabled || c.selectedPeer == null ? null : _pushClipboard, icon: const Icon(Icons.send_rounded), label: Text(tr(context, 'Отправить буфер'))),
      ]),
      Row(children: [Expanded(child: Text(c.selectedPeer == null ? tr(context, 'Выберите устройство') : tr(context, 'Отправка сразу на {0}', [c.selectedPeer!.name]),
        style: TextStyle(color: subdued, fontSize: 12))), HelpButton(title: tr(context, 'Отправить буфер'),
          message: tr(context, 'Сразу отправляет текущий текст или изображение из буфера выбранному получателю. Для редактирования используйте «Текст».'))]),
      if (c.selection.items.isNotEmpty) _selectionPreview(),
      if (!c.isAndroid) ...[const SizedBox(height: 16), _dropZone()],
      if (c.selection.loading) const Padding(padding: EdgeInsets.all(8), child: LinearProgressIndicator()),
      if (c.selection.items.isNotEmpty) ...[const SizedBox(height: 16), Align(alignment: _compact ? Alignment.center : Alignment.centerRight, child: FilledButton.icon(
        key: const ValueKey('send-selection'), onPressed: disabled || c.selectedPeer == null ? null : () => c.run(c.sendSelection),
        icon: const Icon(Icons.file_upload_outlined), label: Text(c.selection.sending ? tr(context, 'Добавляем в очередь…') : c.selection.hasDirectories ? tr(context, 'Передать выбранное') : trFiles(context, c.selection.items.length))))],
      const SizedBox(height: 24), if ((c.queue?.pending ?? 0) > 0) ...[_queue(), const SizedBox(height: 24)], _history(),
    ]);
  }

  Widget _receivedPage() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    _pageHeader(tr(context, 'Полученные')), const SizedBox(height: 24), ReceiveDestination(controller: c), const SizedBox(height: 16),
    SwitchListTile(contentPadding: EdgeInsets.zero, title: Text(tr(context, 'Разрешить приём файлов')),
      value: c.receiveFiles, onChanged: (value) => c.run(() => c.setSettings(filesReceiving: value))),
    const SizedBox(height: 24), _history(receivedOnly: true),
  ]);

  Widget _appearance() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    SectionHeading(tr(context, 'Оформление и язык')),
    ChoiceField<String>(label: tr(context, 'Тема'), value: c.themePreference, icon: Icons.palette_outlined,
      options: {'system': tr(context, 'Как в системе'), 'light': tr(context, 'Светлая'), 'dark': tr(context, 'Тёмная')},
      onChanged: (value) => c.run(() => c.setAppearance(theme: value))), const SizedBox(height: 16),
    ChoiceField<String>(label: tr(context, 'Язык'), value: c.languagePreference, icon: Icons.language_rounded,
      options: {'system': tr(context, 'Как в системе'), 'ru': 'Русский', 'en': 'English'}, onChanged: (value) => c.run(() => c.setAppearance(language: value))),
    const SizedBox(height: 12), ListTile(contentPadding: EdgeInsets.zero, title: Text(c.deviceName), subtitle: Text(tr(context, 'Имя устройства')),
      trailing: IconButton(tooltip: tr(context, 'Изменить имя'), onPressed: _rename, icon: const Icon(Icons.edit_outlined))),
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
            Align(alignment: Alignment.centerLeft, child: OutlinedButton.icon(onPressed: _manageSharedFiles, icon: const Icon(Icons.folder_outlined), label: Text(tr(context, 'Выбрать файлы и папки')))),
          ])),
        ],
        if (_page == 3) ...[
          _pageHeader(tr(context, 'Настройки')), SizedBox(height: 20), _appearance(), Divider(height: 32),
          _section(tr(context, 'Общий буфер'), Icons.content_paste, _clipboard()), SizedBox(height: 16),
          _settings(), SizedBox(height: 16),
          SectionHeading(tr(context, 'Интернет-подключение')),
      SizedBox(height: 12),
      Text(c.node?.relayHost?.online == true ? tr(context, "Интернет: ретранслятор подключён")
        : c.relayAddress == null ? tr(context, "Интернет: ретранслятор не настроен") : tr(context, "Интернет: ожидается сервер"), style: TextStyle(color: subdued)),
      TextButton.icon(onPressed: c.busy ? null : _relaySettings, icon: Icon(Icons.public_rounded),
        label: Text(tr(context, "Настроить доступ без VPN"))),
          const Divider(height: 32),
          ReliabilityPanel(controller: c, openFolder: (peer, folder) => _browseFiles(target: peer, initial: folder)),
        ],
      ],
    ];
    final content = SingleChildScrollView(key: PageStorageKey('home-scroll'), controller: _scroll,
      padding: EdgeInsets.fromLTRB(compact ? 18 : 36, compact ? 16 : 24, compact ? 18 : 36, 24),
      child: Align(alignment: Alignment.topCenter, heightFactor: 1, child: ConstrainedBox(constraints: BoxConstraints(maxWidth: 1280),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: sections))));
    return Scaffold(
      body: SafeArea(child: Column(children: [
        _brandHeader(compact),
        if (c.busy) LinearProgressIndicator(minHeight: 2) else SizedBox(height: 2),
        Expanded(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
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
    Row(children: [Expanded(child: Text(tr(context, 'Мои устройства'), style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600))),
      _badge(tr(context, "{0} в сети", [c.onlineCount]), successColor(context))]),
    SizedBox(height: 18),
    if (c.peers.isEmpty) Padding(padding: EdgeInsets.symmetric(vertical: 24),
      child: Text(tr(context, "Свяжите телефон и компьютер один раз.\nДальше они будут узнавать друг друга."), style: TextStyle(color: subdued, height: 1.6))),
    for (final peer in c.peers) Padding(padding: EdgeInsets.only(bottom: 8), child: _device(peer)),
    SizedBox(height: 12),
    ActionRow(children: [FilledButton.icon(onPressed: c.busy ? null : _showInvite, icon: const Icon(Icons.add_rounded), label: Text(tr(context, 'Добавить'))),
      OutlinedButton(onPressed: c.busy ? null : _enterCode, child: Text(tr(context, 'Ввести код')))]),
    if (c.isAndroid) ...[const SizedBox(height: 8), OutlinedButton.icon(onPressed: c.busy ? null : _scan, icon: const Icon(Icons.qr_code_scanner_rounded), label: Text(tr(context, 'Сканировать QR')))],
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
    SwitchListTile(contentPadding: EdgeInsets.zero, title: Text(tr(context, 'Отправлять изменения')),
      subtitle: Text(c.isAndroid ? tr(context, 'Пока приложение открыто') : tr(context, 'Автоматически')),
      value: c.autoClipboard, onChanged: (value) => c.run(() => c.setSettings(automatic: value))),
    SwitchListTile(contentPadding: EdgeInsets.zero, title: Text(tr(context, 'Принимать в буфер')),
      value: c.receiveClipboard, onChanged: (value) => c.run(() => c.setSettings(clipboardReceiving: value))),
  ]);

  Widget _history({bool receivedOnly = false}) {
    final items = c.activities.where((item) => receivedOnly ? item.path != null && item.kind != 'upload' : item.kind != null || item.path != null).take(12).toList();
    final errors = c.activities.where((item) => item.error && item.kind == null).take(2);
    return _panel(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionHeading(tr(context, 'Последние передачи')),
      if (items.isEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 24), child: Column(children: [
        Icon(receivedOnly ? Icons.inbox_outlined : Icons.swap_horiz_rounded, size: 40, color: subdued), const SizedBox(height: 12),
        Text(tr(context, receivedOnly ? 'Пока нет полученных файлов' : 'Здесь появятся результаты передачи'), style: TextStyle(color: subdued)),
      ])),
      for (final activity in items) Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: InkWell(onTap: () => _showActivity(activity), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (activity.thumbnailPath != null || activity.path != null) MediaThumbnail(path: activity.thumbnailPath ?? activity.path!, name: activity.name ?? activity.path!)
        else Icon(activity.error ? Icons.error_outline_rounded : Icons.check_circle_outline_rounded, color: activity.error ? Theme.of(context).colorScheme.error : successColor(context)),
        const SizedBox(width: 12), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(activity.name ?? activity.title, maxLines: 2, overflow: TextOverflow.ellipsis),
          Text(activity.detail, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: subdued, fontSize: 12)), const SizedBox(height: 4),
          Text(activity.title, style: TextStyle(color: activity.error ? Theme.of(context).colorScheme.error : successColor(context), fontSize: 12)),
        ])),
        if (activity.path == null) Text('${activity.time.hour.toString().padLeft(2, '0')}:${activity.time.minute.toString().padLeft(2, '0')}', style: TextStyle(color: subdued, fontSize: 12))
        else IconButton(icon: const Icon(Icons.open_in_new_rounded), tooltip: tr(context, 'Открыть файл'), onPressed: () => c.run(() async {
          if (activity.path!.startsWith('content://')) { await c.platformChannel.invokeMethod<void>('openReceivedFile', {'location': activity.path}); return; }
          final result = await OpenFilex.open(activity.path!);
          if (result.type != ResultType.done) throw FileSystemException(result.message);
        })),
      ]))),
      if (!receivedOnly) for (final activity in errors) ListTile(contentPadding: EdgeInsets.zero, onTap: () => _showActivity(activity),
        leading: Icon(Icons.error_outline_rounded, color: Theme.of(context).colorScheme.error), title: Text(activity.title), subtitle: Text(activity.detail.split(tr(context, "\n\nПодробности:")).first)),
    ]));
  }

  Future<void> _dropFiles(List<String> paths) async {
    final failure = tr(context, 'Не получилось');
    try { await c.stageFiles(paths); }
    catch (error) { c.record(Activity(failure, '$error', error: true)); }
  }

  Widget _dropZone() {
    final content = Container(key: const ValueKey('file-drop-zone'), width: double.infinity, padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      decoration: BoxDecoration(color: mint.withValues(alpha: _dropping ? .12 : .025), borderRadius: BorderRadius.circular(12)),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.upload_file_outlined, color: mint), const SizedBox(width: 12),
        Flexible(child: Text(_dropping ? tr(context, 'Отпустите, чтобы добавить') : tr(context, 'Перетащите сюда файлы или папки'), textAlign: TextAlign.center))]));
    return DropTarget(onDragEntered: (_) => setState(() => _dropping = true), onDragExited: (_) => setState(() => _dropping = false),
      onDragDone: (detail) { setState(() => _dropping = false); unawaited(_dropFiles(detail.files.map((file) => file.path).toList())); },
      child: CustomPaint(foregroundPainter: _DropBorder(mint.withValues(alpha: _dropping ? 1 : .4)), child: content));
  }

  Widget _section(String title, IconData icon, Widget child) => _panel(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    SectionHeading(title, help: title == tr(context, 'Общий буфер') ? tr(context, 'Скопируйте здесь — вставьте на связанном устройстве. Приложение должно оставаться запущенным.') : null), child,
  ]));

  Widget _panel(Widget child) => Container(width: double.infinity, padding: EdgeInsets.all(_viewportWidth < 500 ? 12 : 16),
    decoration: BoxDecoration(color: surface, borderRadius: BorderRadius.circular(12),
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
        if (value != null && value.startsWith('linkindrop://pair/')) {
          done = true;
          Navigator.pop(context, value);
          break;
        }
      }
    }));
}


class _DropBorder extends CustomPainter {
  const _DropBorder(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()..addRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(12)));
    final paint = Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 1;
    for (final metric in path.computeMetrics()) {
      for (double start = 0; start < metric.length; start += 12) { canvas.drawPath(metric.extractPath(start, start + 6), paint); }
    }
  }
  @override
  bool shouldRepaint(_DropBorder oldDelegate) => color != oldDelegate.color;
}
