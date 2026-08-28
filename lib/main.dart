import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'providers/codex_capability_store.dart';
import 'providers/harness_store.dart';
import 'providers/theme_store.dart';
import 'providers/usage_store.dart';
import 'ui/tray_controller.dart';

const backgroundArgument = '--background';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  final store = UsageStore();
  final themeStore = ThemeStore();
  final harnessStore = HarnessStore();
  final codexCapabilityStore = CodexCapabilityStore();
  final tray = TrayController(store);
  await tray.init(startHidden: args.contains(backgroundArgument));

  runApp(
    FluttAIrbarApp(
      store: store,
      themeStore: themeStore,
      harnessStore: harnessStore,
      codexCapabilityStore: codexCapabilityStore,
    ),
  );
}
