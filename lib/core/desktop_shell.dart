import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:path/path.dart' as p;
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

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
    launchAtStartup.setup(appName: 'Nearbridge', appPath: Platform.resolvedExecutable);
    startupEnabled = await launchAtStartup.isEnabled();
    try {
      final extension = Platform.isWindows ? 'ico' : 'png';
      final bytes = await rootBundle.load('assets/icons/tray.$extension');
      final file = File(p.join(directory.path, 'tray.$extension'));
      await file.writeAsBytes(bytes.buffer.asUint8List());
      trayManager.addListener(this);
      await trayManager.setIcon(file.path);
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(key: 'show', label: 'Открыть Nearbridge'),
        MenuItem.separator(), MenuItem(key: 'quit', label: 'Выйти'),
      ]));
      trayAvailable = true;
      await windowManager.setPreventClose(true);
    } catch (_) {
      trayAvailable = false;
      await windowManager.setPreventClose(false);
    }
  }

  Future<void> setStartup(bool enabled) async {
    if (enabled) await launchAtStartup.enable(); else await launchAtStartup.disable();
    startupEnabled = await launchAtStartup.isEnabled();
  }

  Future<void> show() async { await windowManager.show(); await windowManager.focus(); }
  @override
  void onTrayIconMouseDown() { unawaited(show()); }
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
