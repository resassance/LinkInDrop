import 'dart:io';
import 'package:launch_at_startup/launch_at_startup.dart';
import '../l10n/messages.dart';

class DesktopStartup {
  DesktopStartup({
    LaunchAtStartup? launcher,
    String? executable,
    bool? windows,
    File? linuxEntry,
  }) : _launcher = launcher ?? launchAtStartup,
       _executable = executable ?? Platform.resolvedExecutable,
       _windows = windows ?? Platform.isWindows,
       _linuxEntry =
           linuxEntry ??
           File(
             '${Platform.environment['HOME']}/.config/autostart/LinkInDrop.desktop',
           );
  final LaunchAtStartup _launcher;
  final String _executable;
  final bool _windows;
  final File _linuxEntry;

  String get _quotedExecutable {
    if (_windows) return '"$_executable"';
    final escaped = _executable
        .replaceAll(r'\', r'\\\\')
        .replaceAll('"', r'\\"')
        .replaceAll(r'$', r'\\$')
        .replaceAll('`', r'\\`')
        .replaceAll('%', '%%');
    return '"$escaped"';
  }

  Future<bool> initialize() async {
    _launcher.setup(appName: 'LinkInDrop', appPath: _executable);
    final legacyEnabled = await _launcher.isEnabled();
    _launcher.setup(
      appName: 'LinkInDrop',
      appPath: _quotedExecutable,
      args: ['--autostart'],
    );
    final enabled = await _launcher.isEnabled();
    var needsMigration = legacyEnabled && !enabled;
    if (!_windows && await _linuxEntry.exists()) {
      final content = await _linuxEntry.readAsString();
      if (RegExp(
        r'^\s*(?:Hidden\s*=\s*true|X-GNOME-Autostart-enabled\s*=\s*false)\s*$',
        multiLine: true,
        caseSensitive: false,
      ).hasMatch(content)) {
        return false;
      }
      needsMigration =
          (legacyEnabled || enabled) &&
          !content.split('\n').contains('Exec=$_quotedExecutable --autostart');
    }
    if (needsMigration) return setEnabled(true);
    return enabled;
  }

  Future<bool> setEnabled(bool enabled) async {
    final success = enabled
        ? await _launcher.enable()
        : await _launcher.disable();
    final actual = await _launcher.isEnabled();
    if (!success || actual != enabled) {
      throw StateError(localizeMessage('Не удалось изменить автозапуск'));
    }
    return actual;
  }
}
