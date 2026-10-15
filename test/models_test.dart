import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearbridge/core/models.dart';

void main() {
  test('pairing codes round-trip and reject expired invitations', () {
    final invite = PairInvite(id: 'phone', name: 'Телефон', host: '192.168.1.20',
      port: 45831, fingerprint: 'a' * 64, secret: randomToken(),
      expiresAt: DateTime.now().add(const Duration(minutes: 5)));
    expect(PairInvite.parse(invite.encode()).name, 'Телефон');
    final expired = PairInvite(id: invite.id, name: invite.name, host: invite.host,
      port: invite.port, fingerprint: invite.fingerprint, secret: invite.secret,
      expiresAt: DateTime.now().subtract(const Duration(seconds: 1)));
    expect(() => PairInvite.parse(expired.encode()), throwsFormatException);
    expect(() => PairInvite.parse('https://example.com'), throwsFormatException);
  });

  test('invites accept only local numeric IPv4 addresses', () {
    for (final address in ['192.168.1.3', '10.2.3.4', '172.16.1.4']) {
      expect(isLocalAddress(address), isTrue);
    }
    for (final address in ['8.8.8.8', 'example.com', '0.0.0.0', '224.0.0.1', '172.15.1.1']) {
      expect(isLocalAddress(address), isFalse);
    }
  });

  test('filenames cannot escape the inbox or use Windows reserved names', () {
    expect(safeFilename('../../private.txt'), 'private.txt');
    expect(safeFilename(r'C:\Windows\file.txt'), 'file.txt');
    expect(safeFilename('CON.txt'), '_CON.txt');
    expect(safeFilename('..'), 'file');
    expect(safeFilename('photo?.png'), 'photo_.png');
  });

  test('VPN endpoints, adapter candidates and remote settings round trip', () {
    for (final host in ['100.64.0.12', 'pc.example.ts.net', '192.168.1.3']) {
      expect(isConnectionHost(host), isTrue);
    }
    for (final host in ['https://host', 'host/path', 'a:45831', '0.0.0.0',
      '224.0.0.1', '999.2.3.4', '-host', ' host', 'host..name']) {
      expect(isConnectionHost(host), isFalse);
    }
    final invite = PairInvite(id: 'pc', name: 'PC', host: '100.64.0.12',
      port: 45831, fingerprint: 'a' * 64, secret: randomToken(),
      expiresAt: DateTime.now().add(const Duration(minutes: 5)), hosts: ['192.168.1.3']);
    expect(PairInvite.parse(invite.encode()).hosts, ['192.168.1.3']);
    final peer = Peer(id: 'pc', name: 'PC', host: '192.168.1.3', port: 45831,
      fingerprint: 'a' * 64, incomingToken: randomToken(), outgoingToken: randomToken(),
      remoteHost: '100.64.0.12', remotePort: 45832, additionalHosts: ['10.0.0.2']);
    final restored = Peer.fromJson(peer.toJson());
    expect(restored.connectionHost, '100.64.0.12');
    expect(restored.connectionPort, 45832);
    expect(restored.additionalHosts, ['10.0.0.2']);
    final legacy = Map<String, dynamic>.from(peer.toJson())
      ..remove('remoteHost')..remove('remotePort')..remove('additionalHosts');
    expect(Peer.fromJson(legacy).connectionHost, '192.168.1.3');
  });

  test('clipboard validates type, size, UTF-8, PNG and freshness', () {
    final value = ClipboardPayload(id: 'one', type: 'text',
      data: Uint8List.fromList(utf8.encode('Привет')), createdAt: DateTime.now());
    expect(ClipboardPayload.fromJson(value.toJson()).text, 'Привет');
    expect(() => ClipboardPayload.fromJson({...value.toJson(), 'type': 'html'}), throwsFormatException);
    expect(() => ClipboardPayload.fromJson({...value.toJson(), 'data': base64.encode([255])}), throwsFormatException);
    expect(() => ClipboardPayload.fromJson({...value.toJson(), 'type': 'png'}), throwsFormatException);
    expect(() => ClipboardPayload.fromJson({...value.toJson(),
      'created': DateTime.now().subtract(const Duration(minutes: 5)).millisecondsSinceEpoch}), throwsFormatException);
    expect(() => ClipboardPayload.fromJson({...value.toJson(),
      'data': base64.encode(List.filled(maxTextBytes + 1, 65))}), throwsFormatException);
  });

  test('token comparison handles mismatch and different lengths', () {
    expect(secureEquals('a', 'a'), isTrue);
    expect(secureEquals('a', 'b'), isFalse);
    expect(secureEquals('a', 'aa'), isFalse);
    expect(secureEquals('', 'x'), isFalse);
  });
}

