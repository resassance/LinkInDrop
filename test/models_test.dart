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
