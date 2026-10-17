import 'dart:convert';
import 'dart:typed_data';
import 'dart:isolate';
import 'dart:math';

import 'package:image/image.dart' as img;

import 'shared_folders.dart';

class FilePreview {
  static Future<Map<String, dynamic>> create(String name, SharedRead source) async {
    final lower = name.toLowerCase();
    final image = RegExp(r'\.(png|jpg|jpeg|webp|gif)$').hasMatch(lower);
    if (image && source.size > 8 * 1024 * 1024) return {'type': 'metadata', 'reason': "Для предпросмотра изображение слишком большое"};
    final limit = image ? 8 * 1024 * 1024 : 65536;
    final builder = BytesBuilder(copy: false);
    await for (final chunk in source.stream) {
      final remaining = limit - builder.length;
      if (remaining <= 0) break;
      builder.add(chunk.length <= remaining ? chunk : chunk.sublist(0, remaining));
      if (builder.length >= limit) break;
    }
    final bytes = builder.takeBytes();
    if (image) {
      return Isolate.run(() => thumbnail(bytes));
    }
    final text = RegExp(r'\.(txt|md|json|csv|log|yaml|yml|xml|ini|dart|kt|js|py|html|css)$').hasMatch(lower);
    if (!text || bytes.contains(0)) return {'type': 'metadata'};
    return {'type': 'text', 'text': utf8.decode(bytes, allowMalformed: true), 'truncated': source.size > limit};
  }
  static Map<String, dynamic> thumbnail(Uint8List bytes) {
    final decoder = img.findDecoderForData(bytes);
    final info = decoder?.startDecode(bytes);
    if (decoder == null || info == null || info.width * info.height > 16000000 || info.width < 1 || info.height < 1) {
      return {'type': 'metadata', 'reason': "Предпросмотр изображения недоступен"};
    }
    final decoded = decoder.decodeFrame(0);
    if (decoded == null) return {'type': 'metadata'};
    final scale = min(1.0, min(400 / decoded.width, 400 / decoded.height));
    final resized = img.copyResize(decoded, width: max(1, (decoded.width * scale).round()), height: max(1, (decoded.height * scale).round()));
    return {'type': 'image', 'mime': 'image/jpeg', 'data': base64.encode(img.encodeJpg(resized, quality: 75))};
  }

}
