import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:super_clipboard/super_clipboard.dart';

import 'models.dart';

class ClipboardAdapter {
  Future<ClipboardPayload?> read() async {
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) return null;
    final reader = await clipboard.read();
    if (reader.canProvide(Formats.png)) {
      final completer = Completer<Uint8List>();
      reader.getFile(Formats.png, (file) async {
        try {
          final builder = BytesBuilder(copy: false);
          await for (final chunk in file.getStream()) {
            if (builder.length + chunk.length > maxClipboardBytes) {
              throw StateError('Изображение в буфере больше 8 МБ');
            }
            builder.add(chunk);
          }
          if (!completer.isCompleted) completer.complete(builder.takeBytes());
        } catch (error, stack) {
          if (!completer.isCompleted) completer.completeError(error, stack);
        }
      }, onError: (error) {
        if (!completer.isCompleted) completer.completeError(error);
      });
      final bytes = await completer.future.timeout(const Duration(seconds: 10));
      return ClipboardPayload(id: randomToken(16), type: 'png', data: bytes,
        createdAt: DateTime.now());
    }
    if (reader.canProvide(Formats.plainText)) {
      final text = await reader.readValue(Formats.plainText);
      if (text == null || text.isEmpty || text.startsWith('nearbridge://pair/')) return null;
      final bytes = Uint8List.fromList(utf8.encode(text));
      if (bytes.length > maxTextBytes) throw StateError('Текст в буфере больше 256 КБ');
      return ClipboardPayload(id: randomToken(16), type: 'text', data: bytes,
        createdAt: DateTime.now());
    }
    return null;
  }

  Future<void> write(ClipboardPayload payload) async {
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) throw StateError('Буфер обмена недоступен');
    final item = DataWriterItem();
    if (payload.type == 'png') {
      item.add(Formats.png(payload.data));
    } else {
      item.add(Formats.plainText(payload.text));
    }
    await clipboard.write([item]);
  }
}
