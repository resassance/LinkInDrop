import 'dart:async';

import 'package:flutter/material.dart';

import 'core/controller.dart';
import 'ui/app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = BridgeController();
  unawaited(controller.start());
  runApp(LinkInDropApp(controller: controller, start: false));
}
