import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

String encodePowerShell(String script) {
  final bytes = <int>[];
  for (final unit in script.codeUnits) {
    bytes.add(unit & 255);
    bytes.add(unit >> 8);
  }
  return base64.encode(bytes);
}

String renderFirewallScript(String template, String executable, int port) {
  if (port < 1 || port > 65535) throw ArgumentError.value(port, 'port');
  return template.replaceAll('__PROGRAM__', base64.encode(utf8.encode(executable)))
    .replaceAll('__PORT__', port.toString());
}

Future<void> configureWindowsNetwork(int port) async {
  if (!Platform.isWindows) throw UnsupportedError('Windows only');
  final template = await rootBundle.loadString('assets/windows/configure-network.ps1');
  final script = renderFirewallScript(template, Platform.resolvedExecutable, port);
  final encoded = encodePowerShell(script);
  final launcher = r'''
$ErrorActionPreference = 'Stop'
try {
    $process = Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile', '-EncodedCommand', '__COMMAND__')
    exit $process.ExitCode
} catch {
    Write-Error $_
    exit 1
}
'''.replaceAll('__COMMAND__', encoded);
  final result = await Process.run('powershell.exe', ['-NoProfile', '-NonInteractive',
    '-EncodedCommand', encodePowerShell(launcher)]);
  if (result.exitCode != 0) {
    throw StateError('Windows не разрешил изменить правила сети. Повторите и подтвердите запрос администратора.');
  }
}
