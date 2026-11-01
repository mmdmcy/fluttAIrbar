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

      final store = UsageStore(
        preferences: preferences,
        claudeCredentialsPresent: () => false,
      );
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

  test('Claude polls by default only when a Claude Code session exists', () {
    final directory = Directory.systemTemp.createTempSync(
      'fluttairbar-usage-preferences-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final preferences = UsagePreferences(
      environment: HarnessEnvironment(
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
      ),
    );

    expect(preferences.loadClaudeEnabled(), isNull);
    final withSession = UsageStore(
      preferences: preferences,
      claudeCredentialsPresent: () => true,
    );
    addTearDown(withSession.dispose);
    expect(withSession.claudeEnabled, isTrue);
    final withoutSession = UsageStore(
      preferences: preferences,
      claudeCredentialsPresent: () => false,
    );
    addTearDown(withoutSession.dispose);
    expect(withoutSession.claudeEnabled, isFalse);

    // An explicit choice wins over the session check, both ways.
    expect(withSession.setClaudeEnabled(false), isTrue);
    expect(preferences.loadClaudeEnabled(), isFalse);
    final paused = UsageStore(
      preferences: preferences,
      claudeCredentialsPresent: () => true,
    );
    addTearDown(paused.dispose);
    expect(paused.claudeEnabled, isFalse);
    expect(paused.snapshot.claude, isNull);
    preferences.saveClaudeEnabled(true);
    final enabled = UsageStore(
      preferences: preferences,
      claudeCredentialsPresent: () => false,
    );
    addTearDown(enabled.dispose);
    expect(enabled.claudeEnabled, isTrue);
  });
}
