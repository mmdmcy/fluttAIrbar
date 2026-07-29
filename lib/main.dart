import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'providers/theme_store.dart';
import 'providers/usage_store.dart';
import 'ui/tray_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  final store = UsageStore();
  final themeStore = ThemeStore();
  final tray = TrayController(store);
  await tray.init();

  runApp(FluttAIrbarApp(store: store, themeStore: themeStore));
}
