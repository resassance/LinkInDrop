import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:nearbridge/core/file_preview.dart';
import 'package:nearbridge/core/shared_folders.dart';

void main() {
  test('thumbnail bounds both dimensions and text previews have a byte limit', () async {
    final bytes = img.encodePng(img.Image(width: 100, height: 800));
    final preview = await FilePreview.create('photo.png', SharedRead(bytes.length, Stream.value(bytes), () async {}));
    expect(preview['type'], 'image');
    final decoded = img.decodeJpg(base64.decode(preview['data'] as String))!;
    expect(decoded.width, lessThanOrEqualTo(400));
    expect(decoded.height, lessThanOrEqualTo(400));
    final text = utf8.encode('x' * 100000);
    final result = await FilePreview.create('file.txt', SharedRead(text.length, Stream.value(text), () async {}));
    expect((result['text'] as String).length, 65536);
    expect(result['truncated'], isTrue);
  });
}
