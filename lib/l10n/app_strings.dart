import 'package:flutter/material.dart';

import 'messages.dart';
export 'messages.dart' show AppStrings;

AppStrings stringsOf(BuildContext context) => AppStrings(Localizations.localeOf(context).languageCode);
String tr(BuildContext context, String key, [List<Object?> arguments = const []]) => stringsOf(context).text(key, arguments);
String trFiles(BuildContext context, int count) => stringsOf(context).files(count);
