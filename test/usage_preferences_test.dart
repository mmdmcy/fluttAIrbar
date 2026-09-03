import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fluttairbar/services/harness_config.dart';
import 'package:fluttairbar/services/usage_preferences.dart';
import 'package:fluttairbar/providers/usage_store.dart';

void main() {
  test('Cursor display preference defaults off and persists locally', () {
    final directory = Directory.systemTemp.createTempSync(
      'fluttairbar-usage-preferences-',
    );
    try {
      final environment = HarnessEnvironment(
        home: directory.path,
        configHome: directory.path,
        dataHome: directory.path,
        piDirectory: directory.path,
        codexHome: directory.path,
        grokConfigPath: null,
        appData: null,
        localAppData: null,
        isWindows: false,
        isMacOS: false,
      );
      final preferences = UsagePreferences(environment: environment);

      expect(preferences.loadCursorEnabled(), isFalse);
      preferences.saveCursorEnabled(true);
      expect(preferences.loadCursorEnabled(), isTrue);
      expect(File(preferences.filePath).existsSync(), isTrue);

      preferences.saveCursorEnabled(false);
      expect(preferences.loadCursorEnabled(), isFalse);

      final store = UsageStore(preferences: preferences);
      addTearDown(store.dispose);
      expect(store.cursorEnabled, isFalse);
      expect(store.snapshot.cursor, isNull);
      expect(store.setCursorEnabled(true), isTrue);
      expect(store.cursorEnabled, isTrue);
      expect(store.setCursorEnabled(false), isTrue);
      expect(store.snapshot.cursor, isNull);
    } finally {
      directory.deleteSync(recursive: true);
    }
  });
}
