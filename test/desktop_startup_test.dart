import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:linkindrop/core/desktop_startup.dart';
import 'package:linkindrop/core/desktop_shell.dart';
import 'package:linkindrop/core/controller.dart';
import 'package:linkindrop/ui/app.dart';

class _Launcher implements LaunchAtStartup {
  _Launcher({this.registered, this.approved = true, this.linux = false});
  String? registered;
  bool approved;
  final bool linux;
  String command = '';
  int enabled = 0;
  @override
  void setup({
    required String appName,
    required String appPath,
    String? packageName,
    List<String> args = const [],
  }) {
    command = [appPath, ...args].join(' ');
  }

  @override
  Future<bool> isEnabled() async =>
      approved && registered != null && (linux || registered == command);
  @override
  Future<bool> enable() async {
    registered = command;
    approved = true;
    enabled++;
    return true;
  }

  @override
  Future<bool> disable() async {
    registered = null;
    return true;
  }
}

class _Startup extends DesktopStartup {
  @override
  Future<bool> initialize() async => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const window = MethodChannel('window_manager');
  const tray = MethodChannel('tray_manager');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(window, null);
    messenger.setMockMethodCallHandler(tray, null);
  });

  test(
    'existing Windows autostart migrates to a quoted executable with the startup flag',
    () async {
      const executable = r'C:\Program Files\LinkInDrop\LinkInDrop.exe';
      final launcher = _Launcher(registered: executable);
      final startup = DesktopStartup(
        launcher: launcher,
        executable: executable,
        windows: true,
      );
      expect(await startup.initialize(), isTrue);
      expect(launcher.registered, '"$executable" --autostart');
      expect(launcher.enabled, 1);
      expect(await startup.initialize(), isTrue);
      expect(launcher.enabled, 1);
    },
  );

  test(
    'Windows autostart disabled by the system is not re-enabled during initialization',
    () async {
      final launcher = _Launcher(registered: 'app.exe', approved: false);
      final startup = DesktopStartup(
        launcher: launcher,
        executable: 'app.exe',
        windows: true,
      );
      expect(await startup.initialize(), isFalse);
      expect(launcher.enabled, 0);
      expect(await startup.setEnabled(true), isTrue);
      expect(launcher.registered, '"app.exe" --autostart');
      expect(await startup.setEnabled(false), isFalse);
      expect(launcher.registered, isNull);
    },
  );

  test('Linux autostart disabled in desktop settings stays disabled', () async {
    final root = await Directory.systemTemp.createTemp('linkindrop-startup-');
    final entry = File('${root.path}/LinkInDrop.desktop');
    await entry.writeAsString(
      '[Desktop Entry]\nExec=/opt/LinkInDrop\nHidden=true\n',
    );
    final launcher = _Launcher(registered: '/opt/LinkInDrop', linux: true);
    try {
      final startup = DesktopStartup(
        launcher: launcher,
        executable: '/opt/LinkInDrop',
        windows: false,
        linuxEntry: entry,
      );
      expect(await startup.initialize(), isFalse);
      expect(launcher.enabled, 0);
      expect(await entry.readAsString(), contains('Hidden=true'));
    } finally {
      await root.delete(recursive: true);
    }
  });

  test(
    'Linux autostart migrates a path with spaces and keeps an up-to-date entry intact',
    () async {
      final root = await Directory.systemTemp.createTemp('linkindrop-startup-');
      final entry = File('${root.path}/LinkInDrop.desktop');
      const executable = '/opt/LinkInDrop App/LinkInDrop';
      final launcher = _Launcher(registered: executable, linux: true);
      final startup = DesktopStartup(
        launcher: launcher,
        executable: executable,
        windows: false,
        linuxEntry: entry,
      );
      try {
        await entry.writeAsString('[Desktop Entry]\nExec=$executable\n');
        expect(await startup.initialize(), isTrue);
        expect(launcher.registered, '"$executable" --autostart');
        expect(launcher.enabled, 1);
        await entry.writeAsString(
          '[Desktop Entry]\nExec=${launcher.registered}\n',
        );
        expect(await startup.initialize(), isTrue);
        expect(launcher.enabled, 1);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );

  testWidgets(
    'minimized startup is available with autostart enabled and saves the choice',
    (tester) async {
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('linkindrop-startup-settings-'),
      ))!;
      final controller = BridgeController()
        ..loading = false
        ..languagePreference = 'en'
        ..directory = root;
      controller.desktop = DesktopShell(
        directory: root,
        hideOnClose: () => true,
        shutdown: () async {},
        startup: _Startup(),
      );
      await tester.binding.setSurfaceSize(const Size(1100, 1600));
      try {
        await tester.pumpWidget(
          LinkInDropApp(controller: controller, start: false),
        );
        await tester.tap(find.byKey(const ValueKey('nav-3')));
        await tester.pumpAndSettle();
        final setting = find.widgetWithText(SwitchListTile, 'Start minimized');
        await tester.ensureVisible(setting);
        expect(tester.widget<SwitchListTile>(setting).onChanged, isNull);
        expect(tester.widget<SwitchListTile>(setting).value, isTrue);
        controller.desktop!.startupEnabled = true;
        await tester.runAsync(() => controller.setDesktop(minimized: true));
        await tester.pumpAndSettle();
        expect(tester.widget<SwitchListTile>(setting).onChanged, isNotNull);
        await tester.runAsync(() async {
          await tester.tap(setting);
          for (var attempt = 0; controller.busy && attempt < 100; attempt++) {
            await Future<void>.delayed(const Duration(milliseconds: 1));
          }
          expect(controller.busy, isFalse);
        });
        await tester.pumpAndSettle();
        final settings = (await tester.runAsync(
          () => File('${root.path}/settings.json').readAsString(),
        ))!;
        expect((jsonDecode(settings) as Map)['startMinimized'], isFalse);
        expect(controller.startMinimized, isFalse);
      } finally {
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
        await tester.runAsync(() => root.delete(recursive: true));
        await tester.binding.setSurfaceSize(null);
      }
    },
  );

  for (final scenario in [
    (
      name: 'system launch stays hidden after tray creation',
      automatic: true,
      minimized: true,
      trayWorks: true,
      hidden: true,
    ),
    (
      name: 'manual launch opens the window',
      automatic: false,
      minimized: true,
      trayWorks: true,
      hidden: false,
    ),
    (
      name: 'system launch opens the window when minimized startup is off',
      automatic: true,
      minimized: false,
      trayWorks: true,
      hidden: false,
    ),
    (
      name: 'system launch opens the window if the tray is unavailable',
      automatic: true,
      minimized: true,
      trayWorks: false,
      hidden: false,
    ),
  ]) {
    test(scenario.name, () async {
      final root = await Directory.systemTemp.createTemp(
        'linkindrop-tray-startup-',
      );
      final calls = <String>[];
      messenger.setMockMethodCallHandler(window, (call) async {
        calls.add('window:${call.method}');
        if (call.method == 'isMinimized') return false;
        return null;
      });
      messenger.setMockMethodCallHandler(tray, (call) async {
        calls.add('tray:${call.method}');
        if (!scenario.trayWorks && call.method == 'setIcon') {
          throw PlatformException(code: 'unavailable');
        }
        return null;
      });
      final shell = DesktopShell(
        directory: root,
        hideOnClose: () => true,
        shutdown: () async {},
        startup: _Startup(),
      );
      try {
        await shell.start(
          launchedAtStartup: scenario.automatic,
          startMinimized: scenario.minimized,
        );
        expect(calls.contains('window:hide'), scenario.hidden);
        expect(calls.contains('window:show'), !scenario.hidden);
        if (scenario.hidden) {
          expect(
            calls.indexOf('tray:setContextMenu'),
            lessThan(calls.indexOf('window:hide')),
          );
        }
        calls.clear();
        await shell.show();
        expect(calls, containsAllInOrder(['window:show', 'window:focus']));
      } finally {
        await shell.close();
        await root.delete(recursive: true);
      }
    });
  }
}
