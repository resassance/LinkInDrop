import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkindrop/core/clipboard_adapter.dart';
import 'package:linkindrop/core/controller.dart';
import 'package:linkindrop/core/models.dart';
import 'package:linkindrop/core/node.dart';

class _Clipboard extends ClipboardAdapter {
  @override
  Future<ClipboardPayload?> read() async => ClipboardPayload(id: randomToken(16), type: 'text', data: Uint8List.fromList(utf8.encode('clipboard')), createdAt: DateTime.now());
}

void main() {
  test('manual clipboard and text target one peer while automatic broadcast keeps both', () async {
    final root = await Directory.systemTemp.createTemp('linkindrop-manual-clipboard-');
    final deliveries = <String>[];
    BridgeNode make(String name) => BridgeNode(directory: Directory('${root.path}/$name'), name: name, preferredPort: 0, discoveryEnabled: false,
      onPairRequest: (_) async => true, onClipboard: (_) async => deliveries.add(name), onActivity: (_) {}, onChanged: () {});
    final sender = make('sender'), first = make('first'), second = make('second');
    final controller = BridgeController(clipboard: _Clipboard())..node = sender..selectedPeerId = 'not-yet-paired';
    try {
      await sender.start(); await first.start(); await second.start();
      await sender.pair(first.invite('127.0.0.1')); await sender.pair(second.invite('127.0.0.1'));
      controller.selectedPeerId = first.identity.id;
      await controller.pushClipboard();
      expect(deliveries, ['first']);
      await controller.sendText('edited');
      expect(deliveries, ['first', 'first']);
      deliveries.clear();
      await sender.sendClipboard((await _Clipboard().read())!);
      expect(deliveries, unorderedEquals(['first', 'second']));
      controller.selectedPeerId = null;
      await expectLater(controller.pushClipboard(), throwsStateError);
    } finally { controller.dispose(); await sender.stop(); await first.stop(); await second.stop(); await root.delete(recursive: true); }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
