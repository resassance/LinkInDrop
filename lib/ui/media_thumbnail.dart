import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import '../core/media_library.dart';

class MediaThumbnail extends StatefulWidget {
  const MediaThumbnail({super.key, required this.path, required this.name, this.size = 56, this.fit = BoxFit.cover, this.radius = 10});
  final String path;
  final String name;
  final double size;
  final BoxFit fit;
  final double radius;
  static bool isImage(String name) => RegExp(r'\.(png|jpe?g|webp|gif|heic|heif)$', caseSensitive: false).hasMatch(name);
  static bool isVideo(String name) => RegExp(r'\.(mp4|mov|mkv|webm|m4v|3gp|avi)$', caseSensitive: false).hasMatch(name);
  @override
  State<MediaThumbnail> createState() => _MediaThumbnailState();
}

class _MediaThumbnailState extends State<MediaThumbnail> {
  Future<Uint8List?>? _thumbnail;
  void _load() {
    _thumbnail = widget.path.startsWith('content://') || (defaultTargetPlatform == TargetPlatform.android && (MediaThumbnail.isImage(widget.name) || MediaThumbnail.isImage(widget.path))) || (MediaThumbnail.isVideo(widget.name) && !MediaThumbnail.isImage(widget.path))
      ? MediaLibrary.thumbnail(widget.path, video: MediaThumbnail.isVideo(widget.name) && !MediaThumbnail.isImage(widget.path)) : null;
  }
  @override
  void initState() { super.initState(); _load(); }
  @override
  void didUpdateWidget(MediaThumbnail oldWidget) { super.didUpdateWidget(oldWidget); if (oldWidget.path != widget.path) _load(); }
  Widget _fallback() => ColoredBox(color: Theme.of(context).colorScheme.primary.withValues(alpha: .07),
    child: Center(child: Icon(MediaThumbnail.isVideo(widget.name) ? Icons.videocam_outlined : MediaThumbnail.isImage(widget.name) ? Icons.image_outlined : Icons.description_outlined,
      color: Theme.of(context).colorScheme.onSurfaceVariant)));
  @override
  Widget build(BuildContext context) => SizedBox(width: widget.size, height: widget.size, child: ClipRRect(borderRadius: BorderRadius.circular(widget.radius),
    child: Stack(fit: StackFit.expand, children: [
      if (_thumbnail != null) FutureBuilder<Uint8List?>(future: _thumbnail, builder: (context, snapshot) => snapshot.data == null ? _fallback()
        : Image.memory(snapshot.data!, fit: widget.fit, gaplessPlayback: true, errorBuilder: (_, error, stack) => _fallback()))
      else if (MediaThumbnail.isImage(widget.name) || MediaThumbnail.isImage(widget.path)) Image.file(File(widget.path), fit: widget.fit, cacheWidth: widget.size > 200 ? 1000 : 240,
        errorBuilder: (_, error, stack) => _fallback())
      else _fallback(),
      if (MediaThumbnail.isVideo(widget.name)) const Center(child: Icon(Icons.play_circle_fill_rounded, color: Colors.white, size: 32)),
    ])));
}
