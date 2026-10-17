import 'dart:io';

import 'package:path/path.dart' as p;

Future<Directory> resolveAppDirectory(Directory proposed) async {
  if (p.basename(proposed.path).toLowerCase() != 'linkindrop' ||
      await File(p.join(proposed.path, 'identity.json')).exists()) return proposed;
  for (final name in ['nearbridge', 'Nearbridge']) {
    final legacy = Directory(p.join(proposed.parent.path, name));
    if (await File(p.join(legacy.path, 'identity.json')).exists()) return legacy;
  }
  return proposed;
}
