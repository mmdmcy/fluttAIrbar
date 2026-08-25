import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fluttairbar/services/harness_config.dart';
import 'package:fluttairbar/services/harness_preferences.dart';

void main() {
  test('harness scan preferences persist disabled IDs', () {
    final directory = Directory.systemTemp.createTempSync(
      'fluttairbar-preferences-',
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
      final preferences = HarnessPreferences(environment: environment);

      expect(preferences.loadDisabled(), isEmpty);
      preferences.saveDisabled({'cursor-agent', 'codex'});

      expect(preferences.loadDisabled(), {'codex', 'cursor-agent'});
      expect(File(preferences.filePath).existsSync(), isTrue);
    } finally {
      directory.deleteSync(recursive: true);
    }
  });
}
