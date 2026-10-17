import '../l10n/app_strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/controller.dart';
import '../core/models.dart';
import '../core/release_info.dart';
import 'design_system.dart';
import 'receive_destination.dart';

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
  String size(num bytes) => stringsOf(context).size(bytes);

  Future<void> _copies() async {
    final copies = c.backup?.copies.values.where((copy) => copy['peer'] == c.backup?.peerId).toList() ?? [];
    await showDialog<void>(context: context, builder: (context) => AlertDialog(
      title: Text(tr(context, "Сохранённые фотографии")),
      content: SizedBox(width: 460, height: 340, child: copies.isEmpty ? Text(tr(context, "Квитанции появятся после отправки фото новой версией приложения."))
        : ListView.builder(itemCount: copies.length, itemBuilder: (context, index) {
          final copy = copies[index];
          return ListTile(title: Text(copy['name'] as String),
            subtitle: Text(copy['verifiedAt'] == null ? tr(context, "Ещё не проверено") : copy['valid'] == true ? tr(context, "Содержимое проверено") : tr(context, "Копия отсутствует или повреждена")),
            trailing: IconButton(tooltip: tr(context, "Восстановить в папку получения"), icon: Icon(Icons.restore),
              onPressed: () => c.run(() => c.restorePhoto(copy))));
        })),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(tr(context, "Закрыть")))]));
  }

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    ReceiveDestination(controller: c), const SizedBox(height: 16),
    SwitchListTile(contentPadding: EdgeInsets.zero, title: Text(tr(context, 'Раскладывать файлы по типам')),
      subtitle: Text(tr(context, 'Фото, видео, музыка и документы')), value: c.sortReceived, onChanged: (value) => c.run(() => c.setSortReceived(value))),
    const SizedBox(height: 12),
    Row(children: [Expanded(child: FutureBuilder<int?>(future: _space, builder: (context, snapshot) => Text(c.receiveDestination?.startsWith('content://') == true
      ? tr(context, 'Место для временного файла: {0}. Свободное место у провайдера Android может быть недоступно.', [snapshot.data == null ? tr(context, 'неизвестно') : size(snapshot.data!)])
      : snapshot.data == null ? tr(context, 'Свободное место: не удалось определить') : tr(context, 'Свободно: {0}', [size(snapshot.data!)])))),
      IconButton(tooltip: tr(context, 'Проверить свободное место'), onPressed: () => setState(_refreshSpace), icon: const Icon(Icons.refresh_rounded))]),
    const SizedBox(height: 16), ChoiceField<String>(label: tr(context, 'Если имя файла уже занято'), value: c.conflictPolicy,
      options: {'rename': tr(context, 'Переименовать новый файл'), 'skip': tr(context, 'Пропустить новый файл'), 'replace': tr(context, 'Заменить существующий файл')},
      onChanged: c.node == null ? null : (value) => c.run(() => c.setReceiveStorage(c.receiveDestination, value))),
    const SizedBox(height: 16), ChoiceField<int>(label: tr(context, 'Ограничение скорости передач'), value: c.speedLimit,
      options: {0: tr(context, 'Без ограничения'), 65536: tr(context, '64 КБ/с'), 262144: tr(context, '256 КБ/с'), 1048576: tr(context, '1 МБ/с'), 4194304: tr(context, '4 МБ/с'), 16777216: tr(context, '16 МБ/с')},
      onChanged: c.node == null ? null : (value) => c.run(() => c.setSpeedLimit(value))),
    const Divider(height: 40),
    if (c.isAndroid) ...[
      SectionHeading(tr(context, 'Подключение'), help: tr(context, 'Только для LinkInDrop. Весь его трафик, включая ретранслятор и проверку обновлений, пойдёт напрямую через Wi-Fi.')),
      SwitchListTile(contentPadding: EdgeInsets.zero, title: Text(tr(context, "LinkInDrop через Wi-Fi мимо VPN")),
        value: c.androidDirectWifi, onChanged: (value) => c.run(() => c.setDirectWifi(value))),
      Text(c.localNetwork['direct'] == true ? tr(context, "Прямой маршрут Wi-Fi выбран") : c.androidDirectWifi && c.localNetwork['wifi'] != true ? tr(context, "Ожидается подключение к Wi-Fi") : tr(context, "Используется системный маршрут")),
      if (c.localNetwork['error'] != null) Text(c.localNetwork['error'] as String),
      Align(alignment: Alignment.centerLeft, child: HelpButton(title: tr(context, 'Подключение'), message: tr(context, "NekoBox: включите обход локальной сети (Bypass LAN) или исключите LinkInDrop из VPN-маршрутизации. Системный запрет соединений без VPN может блокировать прямой режим."))),
      TextButton(onPressed: () => c.run(() => c.refreshLocalNetwork(reconnect: true)), child: Text(tr(context, "Проверить маршрут"))),
      SizedBox(height: 12),
    ],
    Text(tr(context, "Диагностика соединений"), style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
    for (final peer in c.peers) ListTile(contentPadding: EdgeInsets.zero, title: Text(peer.name),
      subtitle: Text('${peer.online ? peer.routeLabel : tr(context, "Не в сети")}${peer.latencyMs == null ? '' : tr(context, " · {0} мс", [peer.latencyMs])}${peer.connectionFailure == null ? '' : '\n${{'certificate': tr(context, "Не совпал сертификат устройства"), 'timeout': tr(context, "Истекло время подключения"), 'authorization': tr(context, "Устройство отклонило авторизацию"), 'unreachable': tr(context, "Нет доступного маршрута")}[peer.connectionFailure] ?? tr(context, "Ошибка соединения")}'}')),
    Wrap(spacing: 8, children: [
      TextButton.icon(onPressed: c.node == null || c.busy ? null : () => c.run(() => c.node!.checkPeers()), icon: Icon(Icons.network_check), label: Text(tr(context, "Проверить соединения"))),
      TextButton.icon(onPressed: c.node == null ? null : () async {
        await Clipboard.setData(ClipboardData(text: c.node!.diagnosticReport()));
        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr(context, "Отчёт без адресов, имён устройств, путей, ключей и токенов скопирован"))));
      }, icon: Icon(Icons.copy), label: Text(tr(context, "Скопировать отчёт"))),
    ]),
    Divider(height: 32),
    SectionHeading(tr(context, 'Проверка фотобэкапа'), help: tr(context, "После проверки запустите копирование, чтобы восстановить недостающие копии из оригиналов. Восстановленные фото попадут в RestoredPhotos в папке получения.")),
    Text(c.backup?.verifying == true ? tr(context, "Сверяем SHA-256 сохранённых фото…") : tr(context, "Проверено: {0} · отсутствует или повреждено: {1}", [c.backup?.verified ?? 0, c.backup?.missing ?? 0])),
    Wrap(spacing: 8, children: [
      TextButton(onPressed: c.backup == null || c.backup!.verifying || c.busy ? null : () => c.run(() => c.backup!.verify()), child: Text(tr(context, "Проверить сохранённые копии"))),
      TextButton(onPressed: c.backup == null ? null : _copies, child: Text(tr(context, "Копии и восстановление"))),
    ]),
    if (c.recentPeers.isNotEmpty) ...[
      Divider(height: 32), Text(tr(context, "Недавние получатели")),
      Wrap(spacing: 8, children: c.recentPeers.where((id) => c.node?.peers.containsKey(id) == true).map((id) => ActionChip(
        label: Text(c.node!.peers[id]!.name), onPressed: () => c.selectPeer(id))).toList()),
    ],
    SizedBox(height: 12), Text(tr(context, "Избранные удалённые папки")),
    if (c.favorites.isEmpty) Text(tr(context, "Нажмите звезду рядом с папкой в файлах устройства.")),
    for (final favorite in c.favorites) ListTile(contentPadding: EdgeInsets.zero,
      title: Text((favorite['entry'] as Map)['name'] as String), subtitle: Text(c.node?.peers[favorite['peer']]?.name ?? tr(context, "Устройство удалено")),
      onTap: c.node?.peers[favorite['peer']] == null ? null : () => widget.openFolder(c.node!.peers[favorite['peer']]!, SharedFile.fromJson((favorite['entry'] as Map).cast<String, dynamic>())),
      trailing: IconButton(tooltip: tr(context, "Убрать из избранного"), icon: Icon(Icons.star),
        onPressed: () => c.toggleFavorite(favorite['peer'] as String, SharedFile.fromJson((favorite['entry'] as Map).cast<String, dynamic>())))),
    Divider(height: 32),
    Text('LinkInDrop $appVersion'),
    if (c.updateMessage != null) Text(c.updateMessage!),
    Wrap(spacing: 8, children: [
      TextButton.icon(onPressed: c.busy ? null : () => c.run(c.checkUpdates), icon: Icon(Icons.system_update), label: Text(tr(context, "Проверить обновления"))),
      if (c.newerRelease != null) TextButton(onPressed: () => c.run(() => openRelease(c.newerRelease!['url']!)), child: Text(tr(context, "Открыть страницу обновления"))),
    ]),
  ]);
}

class BackgroundSettings extends StatelessWidget {
  const BackgroundSettings({super.key, required this.controller});
  final BridgeController controller;
  @override
  Widget build(BuildContext context) {
    final c = controller;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SectionHeading(tr(context, 'Фоновая работа'), help: tr(context, 'Разрешите фоновую работу и автозапуск в настройках телефона. После принудительной остановки Android потребуется снова открыть LinkInDrop.')),
      SwitchListTile(contentPadding: EdgeInsets.zero, title: Text(tr(context, "Передавать при выключенном экране")),
        subtitle: Text(tr(context, "Поддерживать связь после сворачивания и закрытия окна. Расход батареи увеличится.")),
        value: c.androidBackground, onChanged: (value) => c.run(() => c.setAndroidBackground(value, c.androidBoot))),
      SwitchListTile(contentPadding: EdgeInsets.zero, title: Text(tr(context, "Запускать после перезагрузки")),
        value: c.androidBoot, onChanged: !c.androidBackground ? null : (value) => c.run(() => c.setAndroidBackground(true, value))),
      Text(tr(context, "Служба: {0}", [c.backgroundStatus['running'] == true ? tr(context, "работает") : tr(context, "остановлена")])),
      Text(tr(context, "Уведомления: {0}", [c.backgroundStatus['notifications'] == true ? tr(context, "разрешены") : tr(context, "нужно разрешение")])),
      Text(tr(context, "Батарея: {0}", [c.backgroundStatus['batteryUnrestricted'] == true ? tr(context, "без оптимизации") : tr(context, "нужно снять ограничения")])),
      Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton(onPressed: () => c.run(() => c.platformChannel.invokeMethod<void>('batterySettings')), child: Text(tr(context, "Разрешить работу без ограничений"))),
        TextButton(onPressed: () => c.run(() => c.platformChannel.invokeMethod<void>('notificationSettings')), child: Text(tr(context, "Разрешить уведомления"))),
      ]),
      Divider(height: 32),
    ]);
  }
}
