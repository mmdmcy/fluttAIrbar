import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fluttairbar/providers/codex_capability_store.dart';
import 'package:fluttairbar/providers/harness_store.dart';
import 'package:fluttairbar/providers/theme_store.dart';
import 'package:fluttairbar/providers/usage_store.dart';
import 'package:fluttairbar/services/codex_capability_manager.dart';
import 'package:fluttairbar/services/harness_config.dart';
import 'package:fluttairbar/services/harness_preferences.dart';
import 'package:fluttairbar/services/usage_preferences.dart';
import 'package:fluttairbar/ui/panel_page.dart';

void main() {
  testWidgets('optional provider controls live in the Settings view', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final directory = Directory.systemTemp.createTempSync(
      'fluttairbar-settings-panel-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final environment = _environment(directory.path);
    final usageStore = UsageStore(
      preferences: UsagePreferences(environment: environment),
    );
    addTearDown(usageStore.dispose);
    final harnessStore = HarnessStore(
      preferences: HarnessPreferences(environment: environment),
    );
    final capabilityStore = CodexCapabilityStore(
      manager: CodexCapabilityManager(environment: environment),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 500,
            height: 700,
            child: PanelPage(
              store: usageStore,
              themeStore: ThemeStore(),
              harnessStore: harnessStore,
              codexCapabilityStore: capabilityStore,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Cursor'), findsNothing);
    expect(find.byTooltip('Usage provider settings'), findsNothing);

    await tester.tap(find.byTooltip('Switch view'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    expect(find.text('Usage providers'), findsOneWidget);
    expect(find.text('Cursor usage'), findsOneWidget);
    expect(find.byTooltip('Refresh usage'), findsNothing);
    expect(
      tester
          .widget<SwitchListTile>(
            find.widgetWithText(SwitchListTile, 'Cursor usage'),
          )
          .value,
      isFalse,
    );
  });
}

HarnessEnvironment _environment(String directory) {
  return HarnessEnvironment(
    home: directory,
    configHome: directory,
    dataHome: directory,
    piDirectory: directory,
    codexHome: directory,
    grokConfigPath: null,
    appData: null,
    localAppData: null,
    isWindows: false,
    isMacOS: false,
  );
}
