import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'core/controller.dart';
import 'ui/app.dart';

void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = BridgeController(launchedAtStartup: args.contains('--autostart'));
  unawaited(() async {
    await controller.start();
    if (controller.startupError != null && (Platform.isWindows || Platform.isLinux)) {
      try {
        await windowManager.ensureInitialized();
        await windowManager.show();
        await windowManager.focus();
      } catch (_) {}
    }
  }());
  runApp(LinkInDropApp(controller: controller, start: false));
}
