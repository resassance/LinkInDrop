import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkindrop/core/connection_error.dart';
import 'package:linkindrop/core/models.dart';
import 'package:linkindrop/core/node.dart';
import 'package:linkindrop/core/shared_folders.dart';

class _TransferTestBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

BridgeNode makeNode(Directory directory, String name, {List<Activity>? activities}) => BridgeNode(
  directory: directory, name: name, preferredPort: 0, discoveryEnabled: false,
  onPairRequest: (_) async => true, onClipboard: (_) async {},
  onActivity: (activity) => activities?.add(activity), onChanged: () {});

void main() {
  _TransferTestBinding();

  for (final external in [false, true]) {
    test('receive through an Android-style private path alias with ${external ? 'a selected folder' : 'the built-in folder'}', () async {
      final root = await Directory.systemTemp.createTemp('linkindrop-android-path-');
      final private = await Directory('${root.path}/private').create();
      final alias = Link('${root.path}/android-path');
      await alias.create(private.path);
      final receiver = makeNode(Directory(alias.path), 'receiver');
      final sender = makeNode(Directory('${root.path}/sender'), 'sender');
      try {
        final destination = external ? await Directory('${root.path}/received').create() : null;
        await receiver.start(destination: destination?.path, sortReceived: true);
        expect(receiver.directory.path, await private.resolveSymbolicLinks());
        await sender.start();
        await sender.pair(receiver.invite('127.0.0.1'));
        final peer = sender.peers.values.single;
        final file = await File('${root.path}/Снимок экрана (366).png').writeAsString('photo-data');
        final size = await file.length();
        Future<SharedRead> open(int offset, int? length) async => SharedRead(size,
          file.openRead(offset, length == null ? null : (offset + length > size ? size : offset + length)), () async {});
        final id = randomToken(16);
        final digest = await sender.uploadSource(peer, id, 'Снимок экрана (366).png', open);
        final receipt = receiver.received.receipts.values.single;
        final output = File(receipt['location'] as String);
        expect(output.path, '${destination?.path ?? '${private.path}/inbox'}/Фото/Снимок экрана (366).png');
        expect(await output.readAsString(), 'photo-data');
        final token = sender.lastUploadReceipt!['receipt'] as String;
        expect(await sender.verifyReceipt(peer, token, digest), isTrue);
        await sender.uploadSource(peer, id, 'Снимок экрана (366).png', open);
        expect(receiver.received.receipts.length, 1);
        await sender.uploadDirectory(peer, 'Folder/Empty');
        final expected = destination?.path ?? '${private.path}/inbox';
        expect(await Directory('$expected/Folder/Empty').exists(), isTrue);
        await sender.uploadSource(peer, randomToken(16), 'nested.png', open, relative: 'Folder/Nested/nested.png');
        expect(await File('$expected/Folder/Nested/nested.png').readAsString(), 'photo-data');
        await receiver.stop();
        await receiver.start(destination: destination?.path, sortReceived: true);
        expect(await receiver.received.verify(sender.identity.id, token, digest), isTrue);
      } finally {
        await sender.stop(); await receiver.stop();
        await root.delete(recursive: true);
      }
    }, skip: Platform.isWindows, timeout: const Timeout(Duration(minutes: 2)));
  }

  test('an aliased private root exports a canonical staging file to the Android document tree', () async {
    final root = await Directory.systemTemp.createTemp('linkindrop-android-export-');
    final private = await Directory('${root.path}/private').create();
    final alias = Link('${root.path}/android-path');
    await alias.create(private.path);
    final receiver = makeNode(Directory(alias.path), 'receiver');
    final sender = makeNode(Directory('${root.path}/sender'), 'sender');
    const channel = MethodChannel('linkindrop/system');
    const tree = 'content://test.documents/tree/received';
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final exports = <Map<dynamic, dynamic>>[];
    final exported = File('${root.path}/exported.png');
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'exportReceived') throw MissingPluginException(call.method);
      final arguments = call.arguments as Map;
      exports.add(arguments);
      final source = File(arguments['source'] as String);
      expect(source.path, await source.resolveSymbolicLinks());
      expect(arguments['tree'], tree);
      expect(arguments['relative'], 'Фото/photo.png');
      await source.copy(exported.path);
      return {'location': 'content://test.documents/document/photo.png', 'skipped': false};
    });
    try {
      await receiver.start(destination: tree, sortReceived: true); await sender.start();
      await sender.pair(receiver.invite('127.0.0.1'));
      final bytes = utf8.encode('photo-data');
      Future<SharedRead> open(int offset, int? length) async => SharedRead(bytes.length,
        Stream.value(bytes.sublist(offset, length == null || offset + length > bytes.length ? bytes.length : offset + length)), () async {});
      await sender.uploadSource(sender.peers.values.single, randomToken(16), 'photo.png', open);
      expect(exports, hasLength(1));
      expect(await exported.readAsBytes(), bytes);
      expect(receiver.received.receipts.values.single['location'], 'content://test.documents/document/photo.png');
    } finally {
      messenger.setMockMethodCallHandler(channel, null);
      await sender.stop(); await receiver.stop();
      await root.delete(recursive: true);
    }
  }, skip: Platform.isWindows, timeout: const Timeout(Duration(minutes: 2)));

  test('a trusted private root alias does not allow an incoming folder to escape the inbox', () async {
    final root = await Directory.systemTemp.createTemp('linkindrop-android-path-escape-');
    final private = await Directory('${root.path}/private').create();
    final alias = Link('${root.path}/android-path');
    await alias.create(private.path);
    final activities = <Activity>[];
    final receiver = makeNode(Directory(alias.path), 'receiver', activities: activities);
    final sender = makeNode(Directory('${root.path}/sender'), 'sender');
    try {
      await receiver.start(); await sender.start();
      await sender.pair(receiver.invite('127.0.0.1'));
      final outside = await Directory('${root.path}/outside').create();
      await Link('${receiver.inbox.path}/Nested').create(outside.path);
      final peer = sender.peers.values.single;
      await expectLater(sender.uploadDirectory(peer, 'Nested/Unwanted'), throwsA(isA<RemoteFailure>()));
      final bytes = utf8.encode('incoming');
      Future<SharedRead> open(int offset, int? length) async => SharedRead(bytes.length,
        Stream.value(bytes.sublist(offset, length == null || offset + length > bytes.length ? bytes.length : offset + length)), () async {});
      await expectLater(sender.uploadSource(peer, randomToken(16), 'file.txt', open, relative: 'Nested/file.txt'), throwsA(isA<RemoteFailure>()));
      expect(await outside.list().isEmpty, isTrue);
      expect(activities.where((activity) => activity.error && activity.detail.contains('Unsafe destination')), isNotEmpty);
      expect(await receiver.received.verify(sender.identity.id, 'missing', '0' * 64), isFalse);
    } finally {
      await sender.stop(); await receiver.stop();
      await root.delete(recursive: true);
    }
  }, skip: Platform.isWindows, timeout: const Timeout(Duration(minutes: 2)));
}
