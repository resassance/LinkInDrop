import 'package:path/path.dart' as p;

const receivedCategories = {
  'Фото': 'jpg jpeg png gif webp heic heif avif bmp tiff tif dng raw svg ico',
  'Видео': 'mp4 mov mkv avi webm m4v mpg mpeg 3gp ts mts',
  'Музыка': 'mp3 flac wav aac m4a ogg opus wma aiff alac',
  'Документы': 'pdf txt md doc docx odt rtf xls xlsx ods csv ppt pptx odp epub fb2 mobi html htm json xml yaml yml log',
  'Архивы': 'zip rar 7z tar gz bz2 xz tgz zst iso',
  'Приложения': 'apk apks aab exe msi msix appimage deb rpm dmg pkg',
};

String organizedReceivedPath(String relative, {required bool enabled}) {
  if (!enabled || relative.contains('/')) return relative;
  final extension = p.posix.extension(relative).toLowerCase().replaceFirst('.', '');
  var category = 'Другое';
  for (final entry in receivedCategories.entries) {
    if (entry.value.split(' ').contains(extension)) { category = entry.key; break; }
  }
  return '$category/$relative';
}
