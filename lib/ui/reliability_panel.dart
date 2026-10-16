import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/controller.dart';
import '../core/models.dart';
import '../core/release_info.dart';

class ReliabilityPanel extends StatefulWidget {
  const ReliabilityPanel({super.key, required this.controller, required this.openFolder});
  final BridgeController controller;
  final Future<void> Function(Peer, SharedFile) openFolder;
  @override
  State<ReliabilityPanel> createState() => _ReliabilityPanelState();
}

class _ReliabilityPanelState extends State<ReliabilityPanel> {
  BridgeController get c => widget.controller;
  Future<int?>? _space;
  String? _spacePath;
  @override
  void initState() { super.initState(); _refreshSpace(); }
  @override
  void didUpdateWidget(ReliabilityPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_spacePath != c.receiveDestination) _refreshSpace();
  }
  void _refreshSpace() { _spacePath = c.receiveDestination; _space = c.node == null ? Future.value(null) : c.receiveFreeSpace(); }
  String size(num bytes) => bytes >= 1024 * 1024 * 1024 ? '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} ГБ' : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} МБ';

  Future<void> _chooseDestination() async {
    await c.run(() async {
      String? selected;
      if (c.isAndroid) {
        final result = await c.platformChannel.invokeMapMethod<String, dynamic>('pickFolder', {'write': true});
        selected = result?['uri'] as String?;
      } else { selected = await getDirectoryPath(confirmButtonText: 'Получать сюда'); }
      if (selected == null) return;
      await c.setReceiveStorage(selected, c.conflictPolicy);
      if (mounted) setState(_refreshSpace);
    });
  }

  Future<void> _copies() async {
    final copies = c.backup?.copies.values.where((copy) => copy['peer'] == c.backup?.peerId).toList() ?? [];
    await showDialog<void>(context: context, builder: (context) => AlertDialog(
      title: const Text('Сохранённые фотографии'),
      content: SizedBox(width: 460, height: 340, child: copies.isEmpty ? const Text('Квитанции появятся после отправки фото новой версией приложения.')
        : ListView.builder(itemCount: copies.length, itemBuilder: (context, index) {
          final copy = copies[index];
          return ListTile(title: Text(copy['name'] as String),
            subtitle: Text(copy['verifiedAt'] == null ? 'Ещё не проверено' : copy['valid'] == true ? 'Содержимое проверено' : 'Копия отсутствует или повреждена'),
            trailing: IconButton(tooltip: 'Восстановить в папку получения', icon: const Icon(Icons.restore),
              onPressed: () => c.run(() => c.restorePhoto(copy))));
        })),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Закрыть'))]));
  }

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    const Text('Получение и надёжность', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
    const SizedBox(height: 12),
    Text('Папка получения: ${c.receiveDestination ?? 'Встроенная папка Nearbridge'}'),
    Wrap(spacing: 8, children: [
      TextButton.icon(onPressed: c.busy || c.node == null ? null : _chooseDestination, icon: const Icon(Icons.folder_open), label: const Text('Выбрать папку получения')),
      if (c.receiveDestination != null) TextButton(onPressed: () => c.run(() => c.setReceiveStorage(null, c.conflictPolicy)), child: const Text('Встроенная папка')),
      IconButton(tooltip: 'Проверить свободное место', onPressed: () => setState(_refreshSpace), icon: const Icon(Icons.refresh)),
    ]),
    FutureBuilder<int?>(future: _space, builder: (context, snapshot) => Text(c.receiveDestination?.startsWith('content://') == true
      ? 'Место для временного файла: ${snapshot.data == null ? 'неизвестно' : size(snapshot.data!)}. Свободное место у провайдера Android может быть недоступно.'
      : snapshot.data == null ? 'Свободное место: не удалось определить' : 'Свободно: ${size(snapshot.data!)}')),
    DropdownButtonFormField<String>(value: c.conflictPolicy, decoration: const InputDecoration(labelText: 'Если имя файла уже занято'),
      items: const [DropdownMenuItem(value: 'rename', child: Text('Переименовать новый файл')),
        DropdownMenuItem(value: 'skip', child: Text('Пропустить новый файл')),
        DropdownMenuItem(value: 'replace', child: Text('Заменить существующий файл'))],
      onChanged: c.node == null ? null : (value) => c.run(() => c.setReceiveStorage(c.receiveDestination, value!))),
    const SizedBox(height: 12),
    DropdownButtonFormField<int>(value: c.speedLimit, decoration: const InputDecoration(labelText: 'Ограничение скорости передач'),
      items: const [DropdownMenuItem(value: 0, child: Text('Без ограничения')),
        DropdownMenuItem(value: 65536, child: Text('64 КБ/с')), DropdownMenuItem(value: 262144, child: Text('256 КБ/с')),
        DropdownMenuItem(value: 1048576, child: Text('1 МБ/с')), DropdownMenuItem(value: 4194304, child: Text('4 МБ/с')),
        DropdownMenuItem(value: 16777216, child: Text('16 МБ/с'))],
      onChanged: c.node == null ? null : (value) => c.run(() => c.setSpeedLimit(value!))),
    const Divider(height: 32),
    const Text('Диагностика соединений', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
    for (final peer in c.peers) ListTile(contentPadding: EdgeInsets.zero, title: Text(peer.name),
      subtitle: Text('${peer.online ? peer.routeLabel : 'Не в сети'}${peer.latencyMs == null ? '' : ' · ${peer.latencyMs} мс'}${peer.connectionFailure == null ? '' : '\n${const {'certificate': 'Не совпал сертификат устройства', 'timeout': 'Истекло время подключения', 'authorization': 'Устройство отклонило авторизацию', 'unreachable': 'Нет доступного маршрута'}[peer.connectionFailure] ?? 'Ошибка соединения'}'}')),
    Wrap(spacing: 8, children: [
      TextButton.icon(onPressed: c.node == null || c.busy ? null : () => c.run(() => c.node!.checkPeers()), icon: const Icon(Icons.network_check), label: const Text('Проверить соединения')),
      TextButton.icon(onPressed: c.node == null ? null : () async {
        await Clipboard.setData(ClipboardData(text: c.node!.diagnosticReport()));
        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Отчёт без адресов, имён устройств, путей, ключей и токенов скопирован')));
      }, icon: const Icon(Icons.copy), label: const Text('Скопировать отчёт')),
    ]),
    if (Platform.isAndroid) ...[
      const Divider(height: 32),
      const Text('Служба передачи Android', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
      SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Работать после закрытия окна'),
        value: c.androidBackground, onChanged: (value) => c.run(() => c.setAndroidBackground(value, c.androidBoot))),
      SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Восстанавливать после перезагрузки'),
        value: c.androidBoot, onChanged: !c.androidBackground ? null : (value) => c.run(() => c.setAndroidBackground(true, value))),
      Text('Служба: ${c.backgroundStatus['running'] == true ? 'работает' : 'остановлена'}. Уведомления: ${c.backgroundStatus['notifications'] == true ? 'разрешены' : 'проверьте настройки'}. Батарея: ${c.backgroundStatus['batteryUnrestricted'] == true ? 'без оптимизации' : 'возможны ограничения'}.',),
      Wrap(spacing: 8, children: [
        TextButton(onPressed: () => c.platformChannel.invokeMethod<void>('batterySettings'), child: const Text('Настройки батареи')),
        TextButton(onPressed: () => c.platformChannel.invokeMethod<void>('notificationSettings'), child: const Text('Настройки уведомлений')),
      ]),
      const Text('Принудительная остановка и ограничения производителя могут остановить службу. Автоматическое чтение буфера в фоне Android недоступно.'),
    ],
    const Divider(height: 32),
    const Text('Проверка фотобэкапа', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
    Text(c.backup?.verifying == true ? 'Сверяем SHA-256 сохранённых фото…' : 'Проверено: ${c.backup?.verified ?? 0} · отсутствует или повреждено: ${c.backup?.missing ?? 0}'),
    const Text('После проверки запустите копирование, чтобы восстановить недостающие копии из оригиналов. Восстановленные фото попадут в RestoredPhotos в папке получения.'),
    Wrap(spacing: 8, children: [
      TextButton(onPressed: c.backup == null || c.backup!.verifying || c.busy ? null : () => c.run(() => c.backup!.verify()), child: const Text('Проверить сохранённые копии')),
      TextButton(onPressed: c.backup == null ? null : _copies, child: const Text('Копии и восстановление')),
    ]),
    if (c.recentPeers.isNotEmpty) ...[
      const Divider(height: 32), const Text('Недавние получатели'),
      Wrap(spacing: 8, children: c.recentPeers.where((id) => c.node?.peers.containsKey(id) == true).map((id) => ActionChip(
        label: Text(c.node!.peers[id]!.name), onPressed: () => c.selectPeer(id))).toList()),
    ],
    const SizedBox(height: 12), const Text('Избранные удалённые папки'),
    if (c.favorites.isEmpty) const Text('Нажмите звезду рядом с папкой в файлах устройства.'),
    for (final favorite in c.favorites) ListTile(contentPadding: EdgeInsets.zero,
      title: Text((favorite['entry'] as Map)['name'] as String), subtitle: Text(c.node?.peers[favorite['peer']]?.name ?? 'Устройство удалено'),
      onTap: c.node?.peers[favorite['peer']] == null ? null : () => widget.openFolder(c.node!.peers[favorite['peer']]!, SharedFile.fromJson((favorite['entry'] as Map).cast<String, dynamic>())),
      trailing: IconButton(tooltip: 'Убрать из избранного', icon: const Icon(Icons.star),
        onPressed: () => c.toggleFavorite(favorite['peer'] as String, SharedFile.fromJson((favorite['entry'] as Map).cast<String, dynamic>())))),
    const Divider(height: 32),
    Text('Nearbridge $appVersion'),
    if (c.updateMessage != null) Text(c.updateMessage!),
    Wrap(spacing: 8, children: [
      TextButton.icon(onPressed: c.busy ? null : () => c.run(c.checkUpdates), icon: const Icon(Icons.system_update), label: const Text('Проверить обновления')),
      if (c.newerRelease != null) TextButton(onPressed: () => c.run(() => openRelease(c.newerRelease!['url']!)), child: const Text('Открыть страницу обновления')),
    ]),
  ]);
}
