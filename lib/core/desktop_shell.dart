import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:path/path.dart' as p;
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../l10n/messages.dart';

class DesktopShell with TrayListener, WindowListener {
  DesktopShell({required this.directory, required this.hideOnClose, required this.shutdown});
  final Directory directory;
  final bool Function() hideOnClose;
  final Future<void> Function() shutdown;
  bool trayAvailable = false;
  bool startupEnabled = false;
  bool _quitting = false;

  Future<void> start() async {
    if (!Platform.isWindows && !Platform.isLinux) return;
    await windowManager.ensureInitialized();
    windowManager.addListener(this);
    launchAtStartup.setup(appName: 'LinkInDrop', appPath: Platform.resolvedExecutable);
    startupEnabled = await launchAtStartup.isEnabled();
    try {
      final extension = Platform.isWindows ? 'ico' : 'png';
      final bytes = await rootBundle.load('assets/icons/tray.$extension');
      final file = File(p.join(directory.path, 'tray.$extension'));
      await file.writeAsBytes(bytes.buffer.asUint8List());
      trayManager.addListener(this);
      await trayManager.setIcon(file.path);
      if (Platform.isLinux) {
        try { await windowManager.setIcon(file.path); } catch (_) {}
      }
      await windowManager.setTitle('LinkInDrop');
      trayAvailable = true;
      await windowManager.setPreventClose(true);
    } catch (_) {
      trayAvailable = false;
      await windowManager.setPreventClose(false);
    }
  }

  Future<void> refreshLabels(String language) async {
    if (!trayAvailable) return;
    final russian = resolveLanguage(language) == 'ru';
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(key: 'show', label: russian ? 'Открыть LinkInDrop' : 'Open LinkInDrop'),
      MenuItem.separator(), MenuItem(key: 'quit', label: russian ? 'Выйти' : 'Quit'),
    ]));
    try { await trayManager.setToolTip('LinkInDrop'); } catch (_) {}
  }

  Future<void> setStartup(bool enabled) async {
    if (enabled) await launchAtStartup.enable(); else await launchAtStartup.disable();
    startupEnabled = await launchAtStartup.isEnabled();
  }

  Future<void> show() async { await windowManager.show(); await windowManager.focus(); }
  @override
  void onTrayIconMouseDown() { unawaited(show()); }
  @override
  void onTrayIconRightMouseDown() { unawaited(trayManager.popUpContextMenu()); }
  @override
  void onTrayMenuItemClick(MenuItem item) {
    if (item.key == 'show') unawaited(show());
    if (item.key == 'quit') unawaited(quit());
  }
  @override
  void onWindowClose() {
    if (trayAvailable && hideOnClose()) unawaited(windowManager.hide());
    else unawaited(quit());
  }
  Future<void> quit() async {
    if (_quitting) return;
    _quitting = true;
    await shutdown();
    await windowManager.destroy();
    exit(0);
  }
  Future<void> close() async {
    if (!Platform.isWindows && !Platform.isLinux) return;
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    if (trayAvailable) await trayManager.destroy();
  }
}
