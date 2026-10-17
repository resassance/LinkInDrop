import 'dart:ui' show PlatformDispatcher;

import 'translations.dart';

String messageLanguage = 'system';
String resolveLanguage(String preference) {
  if (preference != 'system') return preference == 'ru' ? 'ru' : 'en';
  for (final locale in PlatformDispatcher.instance.locales) {
    if (locale.languageCode == 'ru' || locale.languageCode == 'en') return locale.languageCode;
  }
  return 'en';
}
String localizeMessage(String key, [List<Object?> arguments = const []]) => AppStrings(
  resolveLanguage(messageLanguage)).text(key, arguments);

class AppStrings {
  const AppStrings(this.languageCode);
  final String languageCode;
  bool get russian => languageCode == 'ru';

  String text(String key, [List<Object?> arguments = const []]) {
    final template = russian ? key : englishStrings[key] ?? key;
    return template.replaceAllMapped(RegExp(r'\{(\d+)\}'), (match) {
      final index = int.parse(match[1]!);
      return index < arguments.length ? '${arguments[index]}' : match[0]!;
    });
  }

  String files(int count) {
    if (!russian) return 'Transfer $count ${count == 1 ? 'file' : 'files'}';
    final ending = count % 100 >= 11 && count % 100 <= 14 ? 'файлов'
      : count % 10 == 1 ? 'файл' : count % 10 >= 2 && count % 10 <= 4 ? 'файла' : 'файлов';
    return 'Передать $count $ending';
  }

  String size(num bytes) {
    const divisor = 1024;
    final units = russian ? ['Б', 'КБ', 'МБ', 'ГБ', 'ТБ'] : ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= divisor && unit < units.length - 1) {
      value /= divisor;
      unit++;
    }
    final number = unit == 0 ? value.toStringAsFixed(0) : value.toStringAsFixed(1);
    return '${russian ? number.replaceAll('.', ',') : number} ${units[unit]}';
  }
}

