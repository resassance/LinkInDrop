import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkindrop/core/android_folders.dart';
import 'package:linkindrop/core/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const provider = AndroidFolders();
  const channel = MethodChannel('linkindrop/system');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('Android document pages keep relative paths and opaque grant IDs', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'listFolder');
      expect((call.arguments as Map)['path'], 'nested');
      return {'files': [{'name': 'hello.txt', 'relativePath': 'nested/hello.txt',
        'directory': false, 'size': 5}], 'nextOffset': null};
    });
    final id = randomToken(16);
    final page = await provider.list('content://test/tree/root', id, 'nested', 0);
    expect(page.entries.single.folderId, id);
    expect(page.entries.single.relativePath, 'nested/hello.txt');
  });

  test('removing a shared root keeps the same document tree available as a receive destination', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async { calls.add(call); return null; });
    const uri = 'content://test/tree/shared-and-received';
    await provider.retain(uri);
    await provider.retain(uri);
    await provider.revoke(uri);
    expect(calls, isEmpty);
    await provider.revoke(uri);
    expect(calls.single.method, 'revokeFolder');
    expect((calls.single.arguments as Map)['uri'], uri);
  });

  test('Android document readers close after completion and stream cancellation', () async {
    for (final cancel in [false, true]) {
      var reads = 0;
      var closes = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'openFolderFile': return {'reader': 'reader-id', 'size': 3};
          case 'readFolderFile':
            reads++;
            return reads == 1 ? Uint8List.fromList([1, 2, 3]) : null;
          case 'closeFolderFile': closes++; return null;
          default: throw StateError('Unexpected method ${call.method}');
        }
      });
      final file = await provider.open('content://test/tree/root', 'hello.txt');
      expect(file.size, 3);
      final chunks = await (cancel ? file.stream.take(1) : file.stream).toList();
      expect(chunks.single, [1, 2, 3]);
      await file.close();
      expect(closes, 1);
      expect(reads, cancel ? 1 : 2);
    }
  });
}
