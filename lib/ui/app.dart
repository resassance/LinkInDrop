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

const mint = Color(0xffb7f779);
const background = Color(0xff111411);
const surface = Color(0xff1b201b);
const subdued = Color(0xffa1aba0);

class NearbridgeApp extends StatelessWidget {
  const NearbridgeApp({super.key, required this.controller, this.start = true});
  final BridgeController controller;
  final bool start;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Nearbridge', debugShowCheckedModeBanner: false,
    theme: ThemeData(brightness: Brightness.dark, useMaterial3: true,
      scaffoldBackgroundColor: background,
      colorScheme: ColorScheme.fromSeed(seedColor: mint, brightness: Brightness.dark,
        primary: mint, surface: surface),
      fontFamily: Platform.isWindows ? 'Segoe UI' : null,
      inputDecorationTheme: InputDecorationTheme(filled: true, fillColor: background,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none)),
      filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)))),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating)),
    home: BridgeHome(controller: controller, start: start));
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    c.pairingApproval = _approve;
    if (widget.start) unawaited(c.start());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    c.mobileActive = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.resumed && c.isAndroid && !c.loading) {
      unawaited(c.handleShared());
      unawaited(c.node?.checkPeers());
      unawaited(c.backup?.scan());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    c.pairingApproval = null;
    super.dispose();
  }

  Future<bool> _approve(String name) async {
    if (!mounted) return false;
    return await showDialog<bool>(context: context, barrierDismissible: false,
      builder: (context) => AlertDialog(title: const Text('Подключить устройство?'),
        content: Text('$name получит доступ к отправке файлов и общему буферу. Подтвердите, если это ваше устройство.'),
        actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Отклонить')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Подключить'))])) ?? false;
  }

  Future<void> _showInvite() async {
    final node = c.node;
    if (node == null) return;
    final addresses = await node.addresses();
    if (!mounted) return;
    if (addresses.isEmpty && node.relayUrl != null) addresses.add('127.0.0.1');
    if (addresses.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Подключитесь к Wi-Fi или локальной сети')));
      return;
    }
    var host = addresses.first;
    await showDialog<void>(context: context, builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) {
        final code = node.invite(host).encode();
        return AlertDialog(title: const Text('Добавить устройство'),
          content: SizedBox(width: 340, child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(padding: const EdgeInsets.all(12), color: Colors.white,
              child: QrImageView(data: code, size: 250, backgroundColor: Colors.white)),
            const SizedBox(height: 18),
            const Text('Откройте Nearbridge на другом устройстве и отсканируйте код. Используйте общую сеть или настроенный ретранслятор.',
              style: TextStyle(color: subdued)),
            if (addresses.length > 1) DropdownButton<String>(value: host, isExpanded: true,
              items: addresses.map((ip) => DropdownMenuItem(value: ip, child: Text(ip))).toList(),
              onChanged: (value) => setDialogState(() => host = value!)),
            const SizedBox(height: 8),
            SelectableText('$host:${node.port}', style: const TextStyle(color: subdued)),
            const Text('Выберите адрес сети, доступной второму устройству. Для подключения на расстоянии используйте адрес общей VPN-сети.',
              style: TextStyle(color: subdued, fontSize: 12)),
            const SizedBox(height: 12),
            TextButton.icon(onPressed: () async {
              await Clipboard.setData(ClipboardData(text: code));
              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Код скопирован. Действует 5 минут')));
            }, icon: const Icon(Icons.copy_rounded), label: const Text('Скопировать код')),
          ])),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Закрыть'))]);
      }));
  }

  Future<void> _enterCode() async {
    final text = TextEditingController();
    final value = await showDialog<String>(context: context, builder: (context) => AlertDialog(
      title: const Text('Подключиться'), content: SizedBox(width: 420,
        child: TextField(controller: text, maxLines: 4, autofocus: true,
          decoration: const InputDecoration(hintText: 'Вставьте код с другого устройства'))),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
        FilledButton(onPressed: () => Navigator.pop(context, text.text), child: const Text('Подключиться'))]));
    text.dispose();
    if (value != null) await c.run(() => c.pair(value));
  }

  Future<void> _scan() async {
    final code = await Navigator.push<String>(context,
      MaterialPageRoute(builder: (_) => const ScanScreen()));
    if (code != null) await c.run(() => c.pair(code));
  }

  Future<void> _sendFiles() async {
    if (c.selectedPeer == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Сначала выберите устройство')));
      return;
    }
    final files = await openFiles();
    for (final file in files) {
      await c.run(() => c.sendFile(file.path, name: file.name));
    }
  }

  Future<void> _remoteAddress(Peer peer) async {
    final host = TextEditingController(text: peer.remoteHost ?? '');
    final port = TextEditingController(text: '${peer.remotePort ?? peer.port}');
    final value = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: Text('Адрес: ${peer.name}'),
      content: SizedBox(width: 420, child: SingleChildScrollView(child: Column(
        mainAxisSize: MainAxisSize.min, children: [
          const Text('Для доступа через интернет подключите оба устройства к одной VPN-сети, например Tailscale. Укажите IPv4 или DNS-имя другого устройства. Nearbridge должен быть запущен.'),
          const SizedBox(height: 16),
          TextField(controller: host, decoration: const InputDecoration(
            labelText: 'IPv4 / DNS', hintText: '100.64.0.12')),
          const SizedBox(height: 10),
          TextField(controller: port, keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Порт Nearbridge')),
          const SizedBox(height: 10),
          const Text('Пустой адрес возвращает локальное подключение. На Windows разрешите входящий TCP из адреса VPN в брандмауэре.',
            style: TextStyle(color: subdued)),
        ]))),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Отмена')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Проверить и сохранить'))]));
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
        title: const Text('Мои файлы и папки'),
        content: SizedBox(width: 460, height: 320, child: Column(children: [
          const Text('Привязанные устройства смогут просматривать выбранные папки целиком, включая новые и вложенные файлы. Доступ действует, пока включено скачивание.'),
          const SizedBox(height: 12),
          Expanded(child: ListView(children: [
            if (entries.isEmpty) const Text('Файлы и папки пока не выбраны'),
            for (final entry in entries) ListTile(
              leading: Icon(entry.isDirectory ? Icons.folder_outlined : Icons.insert_drive_file_outlined),
              title: Text(entry.name),
              subtitle: Text(entry.isDirectory ? 'Папка со всем содержимым' : _fileSize(entry.size)),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(tooltip: 'Кому доступно и срок', icon: const Icon(Icons.manage_accounts_outlined),
                  onPressed: () => _shareAccess(entry)),
                IconButton(tooltip: 'Закрыть доступ', icon: const Icon(Icons.remove_circle_outline),
                onPressed: () async {
                  await c.run(() => entry.isDirectory
                    ? node.sharedFolders.remove(entry.id) : node.sharedFiles.remove(entry.id));
                  final updated = await ownEntries();
                  if (context.mounted) setDialogState(() => entries = updated);
                })])),
          ])),
        ])),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Закрыть')),
          FilledButton.icon(icon: const Icon(Icons.add), label: const Text('Добавить файлы'),
            onPressed: () async {
              final files = await openFiles();
              await c.run(() async {
                for (final file in files) { await node.sharedFiles.add(file.path); }
              });
              final updated = await ownEntries();
              if (context.mounted) setDialogState(() => entries = updated);
            }),
          OutlinedButton.icon(icon: const Icon(Icons.create_new_folder_outlined), label: const Text('Добавить папку'),
            onPressed: () async {
              await c.run(() async {
                if (c.isAndroid) {
                  final selected = await const AndroidFolders().pick();
                  if (selected != null) await node.sharedFolders.add(selected['uri'] as String,
                    name: selected['name'] as String?);
                } else {
                  final selected = await getDirectoryPath(confirmButtonText: 'Открыть доступ к папке');
                  if (selected != null) await node.sharedFolders.add(selected);
                }
              });
              final updated = await ownEntries();
              if (context.mounted) setDialogState(() => entries = updated);
            })])));
  }

  Future<void> _browseFiles() async {
    final peer = c.selectedPeer;
    final node = c.node;
    if (peer == null || node == null) return;
    final chosen = await showDialog<SharedFile>(context: context, builder: (context) => RemoteFilesDialog(
      deviceName: peer.name, canDownload: c.receiveFiles,
      load: (folder, offset) => node.browseFiles(peer, folder: folder, offset: offset),
      search: (folder, query, cursor) => node.searchFiles(peer, query, folder: folder, cursor: cursor),
      preview: (entry) => node.previewFile(peer, entry)));
    if (chosen != null) await c.run(() => c.enqueueDownload(peer, chosen));
  }

  String _fileSize(int bytes) => bytes < 1024 ? '$bytes Б'
    : bytes < 1024 * 1024 ? '${(bytes / 1024).toStringAsFixed(1)} КБ'
    : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} МБ';

  Future<void> _shareAccess(SharedFile entry) async {
    final old = c.node!.access.rules[entry.id] ?? ShareAccess();
    var all = old.peerIds == null;
    final selected = Set<String>.from(old.peerIds ?? c.peers.map((p) => p.id));
    var duration = old.expiresAt == null ? 'never' : 'keep';
    final saved = await showDialog<bool>(context: context, builder: (context) => StatefulBuilder(
      builder: (context, update) => AlertDialog(title: Text('Доступ: ${entry.name}'),
        content: SizedBox(width: 430, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          SwitchListTile(title: const Text('Все привязанные устройства'), value: all,
            onChanged: (value) => update(() => all = value)),
          if (!all) for (final peer in c.peers) CheckboxListTile(title: Text(peer.name),
            value: selected.contains(peer.id), onChanged: (value) => update(() {
              if (value == true) selected.add(peer.id); else selected.remove(peer.id);
            })),
          DropdownButton<String>(value: duration, isExpanded: true, items: [
            if (old.expiresAt != null) const DropdownMenuItem(value: 'keep', child: Text('Не менять срок')),
            const DropdownMenuItem(value: 'never', child: Text('Бессрочно')),
            const DropdownMenuItem(value: '15', child: Text('На 15 минут')),
            const DropdownMenuItem(value: '60', child: Text('На час')),
            const DropdownMenuItem(value: '1440', child: Text('На сутки')),
          ], onChanged: (value) => update(() => duration = value!)),
        ]))), actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Сохранить'))])));
    if (saved == true) await c.run(() => c.setShareAccess(entry.id, all ? null : selected,
      duration == 'keep' ? old.expiresAt : duration == 'never' ? null : DateTime.now().add(Duration(minutes: int.parse(duration)))));
  }

  Future<void> _relaySettings() async {
    final text = TextEditingController(text: c.relayAddress ?? '');
    final saved = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('Подключение через интернет'),
      content: SizedBox(width: 430, child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Укажите адрес сервера Nearbridge. Код подключения передаст его второму устройству. VPN не нужен; содержимое защищено соединением с проверкой сертификата устройства.'),
        const SizedBox(height: 14), TextField(controller: text,
          decoration: const InputDecoration(labelText: 'Адрес сервера', hintText: 'wss://relay.example.com')),
        const SizedBox(height: 10), const Text('Пустой адрес выключает ретранслятор.'),
      ])), actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Отмена')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Подключить'))]));
    final value = text.text;
    text.dispose();
    if (saved == true) await c.run(() => c.setRelay(value));
  }

  Future<void> _backupFolder() async {
    await c.run(() async {
      if (c.isAndroid) {
        final selected = await const AndroidFolders().pick();
        if (selected != null) await c.backup!.sources.add(selected['uri'] as String, name: selected['name'] as String?);
      } else {
        final selected = await getDirectoryPath(confirmButtonText: 'Выбрать папку с фото');
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
    const labels = {'waiting': 'Ожидает', 'running': 'Передаётся', 'paused': 'Приостановлено',
      'failed': 'Не получилось', 'completed': 'Готово', 'cancelled': 'Отменено'};
    return _panel(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [const Expanded(child: Text('Очередь передач', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600))),
        if (jobs.isNotEmpty) TextButton(onPressed: () => queue!.clearFinished(), child: const Text('Убрать готовые'))]),
      if (jobs.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 12),
        child: Text('Здесь появятся файлы и папки. Передачи можно приостановить и продолжить.', style: TextStyle(color: subdued))),
      for (final job in visible) ListTile(contentPadding: EdgeInsets.zero,
        leading: Icon(job.kind == 'download' ? Icons.download_rounded : job.kind == 'backup' ? Icons.photo_library_outlined : Icons.upload_rounded),
        title: Text(job.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${labels[job.state] ?? job.state}${job.state == 'running' ? ' · ${(job.progress * 100).round()}%' : ''}', style: const TextStyle(color: subdued)),
          if (job.error != null) Text(job.error!, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.redAccent)),
          if (job.state == 'running') LinearProgressIndicator(value: job.progress),
        ]),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          if (job.state == 'running' || job.state == 'waiting') IconButton(tooltip: 'Пауза', icon: const Icon(Icons.pause_rounded),
            onPressed: () => queue!.pause(job)),
          if (job.state == 'paused' || job.state == 'failed') IconButton(tooltip: 'Продолжить', icon: const Icon(Icons.play_arrow_rounded),
            onPressed: () => queue!.resume(job)),
          if (job.state != 'completed' && job.state != 'cancelled') IconButton(tooltip: 'Отменить', icon: const Icon(Icons.close_rounded),
            onPressed: () => queue!.cancel(job)),
        ])),
    ]));
  }

  Widget _settings() {
    final backup = c.backup;
    return _panel(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Фоновая работа и подключение', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
      if (Platform.isWindows || Platform.isLinux) ...[
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Сворачивать в трей при закрытии'),
          value: c.closeToTray, onChanged: (value) => c.run(() => c.setDesktop(hide: value))),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Запускать вместе с системой'),
          value: c.desktop?.startupEnabled ?? false,
          onChanged: c.desktop == null ? null : (value) => c.run(() => c.setDesktop(startup: value))),
        const Text('Перетащите файлы или папку на карточку устройства, чтобы добавить их в очередь.', style: TextStyle(color: subdued)),
      ],
      const SizedBox(height: 12),
      Text(c.node?.relayHost?.online == true ? 'Интернет: ретранслятор подключён'
        : c.relayAddress == null ? 'Интернет: ретранслятор не настроен' : 'Интернет: ожидается сервер', style: const TextStyle(color: subdued)),
      TextButton.icon(onPressed: c.busy ? null : _relaySettings, icon: const Icon(Icons.public_rounded),
        label: const Text('Настроить доступ без VPN')),
      const Divider(height: 32),
      const Text('Резервное копирование фото', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      const Text('Новые фото из выбранных папок отправляются на устройство ниже. Оригиналы сохраняются; одинаковые снимки повторно не передаются.', style: TextStyle(color: subdued)),
      if (backup != null) ...[
        DropdownButton<String>(isExpanded: true,
          value: c.peers.any((p) => p.id == backup.peerId) ? backup.peerId : null,
          hint: const Text('Куда копировать фото'),
          items: c.peers.map((peer) => DropdownMenuItem(value: peer.id, child: Text(peer.name))).toList(),
          onChanged: (value) async { backup.peerId = value; await backup.save(); c.changed(); }),
        for (final root in backup.sources.roots()) ListTile(contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.folder_outlined), title: Text(root.name),
          trailing: IconButton(tooltip: 'Убрать из резервного копирования', icon: const Icon(Icons.close_rounded),
            onPressed: () => c.run(() async {
              for (final job in c.queue!.jobs.where((j) => j.sourceFolder == root.id).toList()) { await c.queue!.cancel(job); }
              await backup.sources.remove(root.id); c.changed();
            }))),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Автоматически копировать новые фото'), value: backup.enabled,
          onChanged: backup.peerId == null || backup.sources.roots().isEmpty ? null : (value) async {
            backup.enabled = value; await backup.save(); c.changed(); if (value) unawaited(backup.scan());
          }),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(onPressed: c.busy ? null : _backupFolder, icon: const Icon(Icons.add_photo_alternate_outlined), label: const Text('Выбрать папку с фото')),
          TextButton(onPressed: backup.scanning || !backup.enabled ? null : () => backup.scan(), child: const Text('Проверить сейчас')),
        ]),
        Text(backup.scanning ? 'Проверяем новые снимки…' : 'Скопировано: ${backup.copied}', style: const TextStyle(color: subdued)),
        if (backup.lastError != null) SelectableText(backup.lastError!, style: const TextStyle(color: Colors.redAccent)),
      ],
    ]));
  }

  Future<void> _sendText() async {
    final text = TextEditingController();
    final value = await showDialog<String>(context: context, builder: (context) => AlertDialog(
      title: const Text('Отправить текст'), content: SizedBox(width: 420,
        child: TextField(controller: text, minLines: 3, maxLines: 8, autofocus: true,
          decoration: const InputDecoration(hintText: 'Текст или ссылка'))),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
        FilledButton(onPressed: () => Navigator.pop(context, text.text), child: const Text('Отправить'))]));
    text.dispose();
    if (value != null) await c.run(() => c.sendText(value));
  }

  Future<void> _rename() async {
    final text = TextEditingController(text: c.deviceName);
    final value = await showDialog<String>(context: context, builder: (context) => AlertDialog(
      title: const Text('Имя устройства'), content: TextField(controller: text, maxLength: 80),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
        FilledButton(onPressed: () => Navigator.pop(context, text.text), child: const Text('Сохранить'))]));
    text.dispose();
    if (value != null) await c.run(() => c.rename(value));
  }

  Future<void> _networkHelp() => showDialog<void>(context: context,
    builder: (context) => AlertDialog(title: const Text('Подключение по локальной сети'),
      content: const SingleChildScrollView(child: SelectableText(
        '1. Подключите оба устройства к одной обычной Wi-Fi сети. Гостевая сеть может запрещать связь между устройствами.\n\n'
        '2. Проверьте доступ к локальной сети в VPN на телефоне и ПК. Для проверки временно отключите VPN, WARP и сетевые фильтры.\n\n'
        '3. На Windows нажмите «Разрешить локальные подключения» в Nearbridge. Windows запросит права администратора. Правила разрешают только Nearbridge и только локальную подсеть.\n\n'
        '4. Если адаптеров несколько, выберите в QR адрес сети второго устройства. Проверьте порт под QR: после смены порта обновите правило Windows Firewall.\n\n'
        '5. Для доступа на расстоянии подключите оба устройства к общей VPN-сети. В меню устройства укажите его удалённый адрес. Разрешите входящий TCP из адреса VPN в брандмауэре и оставьте Nearbridge запущенным.')),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Закрыть'))]));

  Future<void> _showActivity(Activity activity) => showDialog<void>(context: context,
    builder: (context) => AlertDialog(title: Text(activity.title),
      content: SizedBox(width: 480, child: SingleChildScrollView(child: SelectableText(activity.detail))),
      actions: [TextButton(onPressed: _networkHelp, child: const Text('Проверить сеть')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Закрыть'))]));

  Future<void> _forget(Peer peer) async {
    final yes = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: Text('Отключить ${peer.name}?'),
      content: const Text('Доступ к файлам и буферу будет отозван. Для подключения понадобится новый код.'),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Отмена')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Отключить'))]));
    if (yes == true) await c.run(() => c.forget(peer));
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(animation: c, builder: (context, _) => Scaffold(
    body: SafeArea(child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1180),
      child: ListView(padding: const EdgeInsets.all(24), children: [
        Row(children: [Container(width: 42, height: 42,
          decoration: BoxDecoration(color: mint, borderRadius: BorderRadius.circular(12)),
          child: const Icon(Icons.swap_horiz_rounded, color: background, size: 30)),
          const SizedBox(width: 12), const Expanded(child: Text('nearbridge', maxLines: 1,
            overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 25, fontWeight: FontWeight.w700))),
          _badge('0.1 · alpha', subdued)]),
        const SizedBox(height: 32),
        Row(children: [Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Ваши устройства.\nОдин буфер.', style: TextStyle(fontSize: 34, height: 1.15, fontWeight: FontWeight.w700)),
          const SizedBox(height: 12), Text(c.deviceName, style: const TextStyle(color: subdued, fontSize: 15)),
        ])), IconButton(onPressed: _rename, tooltip: 'Имя устройства', icon: const Icon(Icons.edit_outlined))]),
        const SizedBox(height: 24),
        if (c.loading) const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator())),
        if (c.startupError != null) _panel(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Не удалось запустить соединение', style: TextStyle(fontSize: 18)),
          const SizedBox(height: 8), SelectableText(c.startupError!, style: const TextStyle(color: Colors.redAccent)),
        ])),
        if (!c.loading && c.startupError == null) ...[
          LayoutBuilder(builder: (context, constraints) {
            final devices = _devices();
            final clipboard = _clipboard();
            if (constraints.maxWidth < 760) return Column(children: [devices, const SizedBox(height: 16), clipboard]);
            return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(flex: 5, child: devices), const SizedBox(width: 20), Expanded(flex: 6, child: clipboard)]);
          }),
          const SizedBox(height: 20),
          _transfers(),
          const SizedBox(height: 20),
          _queue(),
          const SizedBox(height: 20),
          _settings(),
          const SizedBox(height: 20),
          _history(),
          const SizedBox(height: 20),
          const Text('Локальная сеть или VPN · без аккаунта · проверка сертификата',
            style: TextStyle(color: subdued, fontSize: 12)),
        ],
      ])))),
    bottomNavigationBar: c.busy ? const LinearProgressIndicator(minHeight: 3) : null));

  Widget _devices() => _panel(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Row(children: [const Expanded(child: Text('Устройства', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600))),
      _badge('${c.onlineCount} в сети', mint)]),
    const SizedBox(height: 18),
    if (c.peers.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 24),
      child: Text('Свяжите телефон и компьютер один раз.\nДальше они будут узнавать друг друга.', style: TextStyle(color: subdued, height: 1.6))),
    for (final peer in c.peers) Padding(padding: const EdgeInsets.only(bottom: 8), child: _device(peer)),
    const SizedBox(height: 12),
    Wrap(spacing: 8, runSpacing: 8, children: [
      FilledButton.icon(onPressed: c.busy ? null : _showInvite, icon: const Icon(Icons.add_rounded), label: const Text('Добавить')),
      OutlinedButton(onPressed: c.busy ? null : _enterCode, child: const Text('Ввести код')),
      if (c.isAndroid) IconButton(onPressed: c.busy ? null : _scan, tooltip: 'Сканировать QR', icon: const Icon(Icons.qr_code_scanner_rounded)),
    ]),
    if (c.pairingStage != null) Padding(padding: const EdgeInsets.only(top: 12),
      child: Text(c.pairingStage!, style: const TextStyle(color: mint))),
    if (c.node?.nearby.isNotEmpty == true) Padding(padding: const EdgeInsets.only(top: 16),
      child: Text('Рядом: ${c.node!.nearby.values.map((d) => d['name']).join(', ')}',
        style: const TextStyle(color: subdued, fontSize: 12))),
    const SizedBox(height: 12),
    TextButton.icon(onPressed: _networkHelp, icon: const Icon(Icons.wifi_rounded),
      label: const Text('Не получается подключиться?')),
    if (Platform.isWindows) ...[
      const Text('Windows запросит разрешение администратора. Доступ получит только Nearbridge из локальной подсети.',
        style: TextStyle(color: subdued, fontSize: 12)),
      TextButton.icon(onPressed: c.busy ? null : () => c.run(c.configureNetwork),
        icon: const Icon(Icons.settings_ethernet_rounded), label: const Text('Разрешить локальные подключения')),
    ],
  ]));

  Widget _device(Peer peer) {
    final tile = Container(decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(14),
      border: Border.all(color: _draggingPeer == peer.id || c.selectedPeerId == peer.id ? mint : Colors.transparent)),
      child: ListTile(onTap: () => c.selectPeer(peer.id),
        leading: Icon(Icons.devices_rounded, color: peer.online ? mint : subdued),
        title: Text(peer.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text('${peer.online ? 'Подключено' : 'Не в сети'}${peer.activeRelay ? ' · интернет' : ''}', style: const TextStyle(color: subdued)),
        trailing: PopupMenuButton<String>(onSelected: (value) {
          if (value == 'forget') unawaited(_forget(peer));
          if (value == 'clipboard') unawaited(c.setPeerClipboard(peer, !peer.clipboardEnabled));
          if (value == 'address') unawaited(_remoteAddress(peer));
          if (value == 'incoming') unawaited(c.setIncomingFiles(peer, !peer.incomingFilesEnabled));
        }, itemBuilder: (_) => [
          PopupMenuItem(value: 'clipboard', child: Text(peer.clipboardEnabled ? 'Отключить общий буфер' : 'Включить общий буфер')),
          PopupMenuItem(value: 'incoming', child: Text(peer.incomingFilesEnabled ? 'Запретить приём файлов' : 'Разрешить приём файлов')),
          const PopupMenuItem(value: 'address', child: Text('Локальный / удалённый адрес')),
          const PopupMenuItem(value: 'forget', child: Text('Забыть устройство'))])));
    if (!Platform.isWindows && !Platform.isLinux) return tile;
    return DropTarget(onDragEntered: (_) => setState(() => _draggingPeer = peer.id),
      onDragExited: (_) => setState(() => _draggingPeer = null),
      onDragDone: (detail) {
        setState(() => _draggingPeer = null);
        unawaited(c.run(() => c.enqueuePaths(peer, detail.files.map((f) => f.path).toList())));
      }, child: tile);
  }

  Widget _clipboard() => _panel(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Row(children: [const Icon(Icons.content_paste_rounded, color: mint), const SizedBox(width: 10),
      const Expanded(child: Text('Общий буфер', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)))]),
    const SizedBox(height: 18),
    const Text('Текст, ссылки и изображения', style: TextStyle(fontSize: 18)),
    const SizedBox(height: 8),
    Text(c.isAndroid ? 'Для отправки откройте Nearbridge и нажмите «Отправить буфер» или используйте «Поделиться».'
      : 'Скопируйте здесь — вставьте на связанном устройстве. Приложение должно оставаться запущенным.',
      style: const TextStyle(color: subdued, height: 1.5)),
    const SizedBox(height: 12),
    SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Отправлять изменения'),
      subtitle: Text(c.isAndroid ? 'Пока приложение открыто' : 'Автоматически', style: const TextStyle(color: subdued)),
      value: c.autoClipboard, onChanged: (value) => unawaited(c.setSettings(automatic: value))),
    SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Принимать в буфер'),
      value: c.receiveClipboard, onChanged: (value) => unawaited(c.setSettings(clipboardReceiving: value))),
    const SizedBox(height: 12),
    Wrap(spacing: 8, runSpacing: 8, children: [
      FilledButton.icon(onPressed: c.busy || c.onlineCount == 0 ? null : () => c.run(c.pushClipboard),
        icon: const Icon(Icons.send_rounded, size: 18), label: const Text('Отправить буфер')),
      TextButton(onPressed: c.busy || c.onlineCount == 0 ? null : _sendText, child: const Text('Написать текст')),
    ]),
  ]));

  Widget _transfers() => _panel(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Row(children: [const Icon(Icons.file_upload_outlined, color: mint), const SizedBox(width: 10),
      const Expanded(child: Text('Передача файлов', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600))),
      Switch(value: c.receiveFiles, onChanged: (value) => unawaited(c.setSettings(filesReceiving: value)))]),
    const SizedBox(height: 12),
    Text(c.selectedPeer == null ? 'Выберите устройство выше, затем отправьте файлы.' : 'Получатель: ${c.selectedPeer!.name}',
      style: const TextStyle(color: subdued)),
    const SizedBox(height: 16),
    Wrap(spacing: 8, runSpacing: 8, children: [
      FilledButton.icon(onPressed: c.busy || c.selectedPeer == null ? null : _sendFiles,
        icon: const Icon(Icons.attach_file_rounded), label: const Text('Выбрать файлы')),
      OutlinedButton.icon(onPressed: c.busy || c.selectedPeer == null ? null : _browseFiles,
        icon: const Icon(Icons.folder_open_rounded), label: const Text('Файлы устройства')),
      TextButton(onPressed: c.busy ? null : _manageSharedFiles, child: const Text('Мои файлы и папки')),
    ]),
    SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Разрешить доступ к моим файлам и папкам'),
      subtitle: const Text('Доступ только для привязанных устройств', style: TextStyle(color: subdued)),
      value: c.shareFiles, onChanged: (value) => unawaited(c.setSettings(fileSharing: value))),
    if (c.pendingFiles.isNotEmpty) ...[
      const SizedBox(height: 14),
      Text('Ожидают отправки: ${c.pendingFiles.length}', style: const TextStyle(color: subdued)),
      TextButton(onPressed: c.busy || c.selectedPeer == null ? null : () => c.run(c.sendPendingFiles),
        child: const Text('Отправить выбранному устройству')),
    ],
    if (c.node?.transferName != null) ...[
      const SizedBox(height: 18), Text(c.node!.transferName!), const SizedBox(height: 8),
      LinearProgressIndicator(value: c.node!.transferProgress),
      TextButton(onPressed: c.node!.cancelTransfer, child: const Text('Отменить передачу')),
    ],
    const SizedBox(height: 14),
    const Text('До 2 ГБ на файл. Полученные файлы доступны в списке ниже.', style: TextStyle(color: subdued, fontSize: 12)),
  ]));

  Widget _history() => _panel(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    const Text('Последние передачи', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
    const SizedBox(height: 12),
    if (c.activities.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 16),
      child: Text('Здесь появятся результаты передачи. Содержимое буфера не сохраняется.', style: TextStyle(color: subdued))),
    for (final activity in c.activities.take(12)) ListTile(contentPadding: EdgeInsets.zero,
      onTap: () => _showActivity(activity),
      leading: Icon(activity.error ? Icons.error_outline_rounded : activity.path != null
        ? Icons.insert_drive_file_outlined : Icons.check_circle_outline_rounded,
        color: activity.error ? Colors.redAccent : mint),
      title: Text(activity.title), subtitle: Text(activity.detail.split('\n\nПодробности:').first,
        maxLines: activity.error ? null : 2, overflow: activity.error ? null : TextOverflow.ellipsis,
        style: const TextStyle(color: subdued)),
      trailing: activity.path == null ? Text('${activity.time.hour.toString().padLeft(2, '0')}:${activity.time.minute.toString().padLeft(2, '0')}',
        style: const TextStyle(color: subdued, fontSize: 12)) : IconButton(icon: const Icon(Icons.open_in_new_rounded),
        tooltip: 'Открыть файл', onPressed: () async {
          final result = await OpenFilex.open(activity.path!);
          if (result.type != ResultType.done) c.record(Activity('Не удалось открыть', result.message, error: true));
        })),
  ]));

  Widget _panel(Widget child) => Container(width: double.infinity, padding: const EdgeInsets.all(22),
    decoration: BoxDecoration(color: surface, borderRadius: BorderRadius.circular(22),
      border: Border.all(color: const Color(0xff30382f))), child: child);

  Widget _badge(String text, Color color) => Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
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
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('Сканировать код')),
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

