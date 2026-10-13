import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearbridge/core/connection_error.dart';
import 'package:nearbridge/core/windows_network.dart';

void main() {
  test('network timeout reports the destination and concrete network checks', () {
    final failure = describePairingFailure(const SocketException('HTTP connection timed out'),
      '192.168.31.45:45831', waitingForApproval: false);
    expect(failure.kind, ConnectionFailureKind.unreachable);
    expect(failure.message, contains('192.168.31.45:45831'));
    expect(failure.message, contains('VPN'));
    expect(failure.message, contains('Windows Firewall'));
    expect(failure.details, contains('HTTP connection timed out'));
  });

  test('certificate failures are not reported as firewall failures', () {
    final failure = describePairingFailure(const HandshakeException('certificate mismatch'),
      '192.168.31.45:45831', waitingForApproval: false);
    expect(failure.kind, ConnectionFailureKind.certificate);
    expect(failure.message, isNot(contains('Firewall')));
  });

  test('approval timeout and declined or expired codes stay distinguishable', () {
    expect(describePairingFailure(TimeoutException('waiting'), 'pc',
      waitingForApproval: true).kind, ConnectionFailureKind.approvalTimeout);
    expect(describePairingFailure(const RemoteFailure(403, 'Pairing rejected'), 'pc',
      waitingForApproval: true).kind, ConnectionFailureKind.rejected);
    expect(describePairingFailure(const RemoteFailure(403, 'Pairing code invalid or expired'), 'pc',
      waitingForApproval: true).kind, ConnectionFailureKind.expired);
  });

  test('firewall setup treats executable paths as data and limits inbound scope', () {
    final template = File('assets/windows/configure-network.ps1').readAsStringSync();
    const path = r"C:\Apps\test'; Remove-Item important\nearbridge.exe";
    final script = renderFirewallScript(template, path, 49152);
    expect(script, isNot(contains(path)));
    expect(script, contains(base64.encode(utf8.encode(path))));
    expect(script, contains(r'$port = 49152'));
    expect(script, contains('-RemoteAddress LocalSubnet'));
    expect(script, isNot(contains('Set-NetFirewallProfile')));
    expect(() => renderFirewallScript(template, path, 0), throwsArgumentError);
    final bytes = base64.decode(encodePowerShell('Nearbridge Ω'));
    final units = [for (var i = 0; i < bytes.length; i += 2) bytes[i] | bytes[i + 1] << 8];
    expect(String.fromCharCodes(units), 'Nearbridge Ω');
  });
}
