import 'package:flutter/material.dart';

import 'providers/harness_store.dart';
import 'providers/theme_store.dart';
import 'providers/usage_store.dart';
import 'ui/panel_page.dart';

class FluttAIrbarApp extends StatelessWidget {
  const FluttAIrbarApp({
    super.key,
    required this.store,
    required this.themeStore,
    required this.harnessStore,
  });

  final UsageStore store;
  final ThemeStore themeStore;
  final HarnessStore harnessStore;

  ThemeData _theme(Brightness brightness) {
    final base = ColorScheme.fromSeed(
      seedColor: const Color(0xFF14B8A6),
      brightness: brightness,
    );
    return ThemeData(
      colorScheme: base,
      useMaterial3: true,
      brightness: brightness,
      scaffoldBackgroundColor: base.surface,
      textTheme: Typography.englishLike2021.apply(
        fontFamily: 'Cantarell',
        bodyColor: base.onSurface,
        displayColor: base.onSurface,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: themeStore,
      builder: (context, _) {
        return MaterialApp(
          title: 'fluttAIrbar',
          debugShowCheckedModeBanner: false,
          themeMode: themeStore.mode,
          theme: _theme(Brightness.light),
          darkTheme: _theme(Brightness.dark),
          home: PanelPage(
            store: store,
            themeStore: themeStore,
            harnessStore: harnessStore,
          ),
        );
      },
    );
  }
}
