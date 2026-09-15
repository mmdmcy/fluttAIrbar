import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fluttairbar/models/codex_shortcut.dart';
import 'package:fluttairbar/services/codex_shortcut_installer.dart';
import 'package:fluttairbar/services/harness_config.dart';

void main() {
  test('installs the exact shortcut profiles from this machine', () async {
    final directory = Directory.systemTemp.createTempSync(
      'fluttairbar-codex-shortcuts-',
    );
    try {
      final installer = CodexShortcutInstaller(
        environment: _environment(directory.path),
        shell: '/bin/bash',
        currentPath: '${directory.path}/bin:/usr/bin',
        supported: true,
      );

      final before = installer.inspect();
      expect(before.allInstalled, isFalse);
      expect(before.pathAvailable, isFalse);

      final result = await installer.install();

      expect(result.ok, isTrue);
      expect(result.status.allInstalled, isTrue);
      expect(result.status.pathConfigured, isTrue);
      for (final definition in codexShortcutDefinitions) {
        final file = File('${installer.installDirectory}/${definition.name}');
        expect(file.readAsStringSync(), definition.scriptContents());
        expect(FileStat.statSync(file.path).mode & 0x40, isNonZero);
      }
    } finally {
      directory.deleteSync(recursive: true);
    }
  });

  test(
    'installed wrappers forward arguments to the Codex executable',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'fluttairbar-codex-shortcuts-execution-',
      );
      try {
        final codex = File('${directory.path}/codex-bin/codex')
          ..createSync(recursive: true)
          ..writeAsStringSync('#!/bin/sh\nprintf \'%s\\n\' "\$@"\n');
        Process.runSync('chmod', ['u+rwx,go+rx', codex.path]);
        final installer = CodexShortcutInstaller(
          environment: _environment(directory.path),
          currentPath: '/usr/bin',
          supported: true,
        );
        await installer.install();
        final path = '${codex.parent.path}:${installer.installDirectory}';
        final environment = Map<String, String>.from(Platform.environment)
          ..['PATH'] = path;

        final unsafe = await Process.run(
          '${installer.installDirectory}/codexunsafe',
          ['hello'],
          runInShell: false,
          environment: environment,
        );
        final resume = await Process.run(
          '${installer.installDirectory}/codexunsaferesume',
          ['follow-up'],
          runInShell: false,
          environment: environment,
        );

        expect(unsafe.exitCode, 0);
        expect(unsafe.stdout.trim().split('\n'), [
          '--dangerously-bypass-approvals-and-sandbox',
          'hello',
        ]);
        expect(resume.exitCode, 0);
        expect(resume.stdout.trim().split('\n'), [
          '--dangerously-bypass-approvals-and-sandbox',
          'resume',
          '--all',
          '--no-alt-screen',
          'follow-up',
        ]);
      } finally {
        directory.deleteSync(recursive: true);
      }
    },
  );

  test('configures PATH once and removes only its managed block', () async {
    final directory = Directory.systemTemp.createTempSync(
      'fluttairbar-codex-shortcuts-path-',
    );
    try {
      final shellConfig = File('${directory.path}/.bashrc')
        ..writeAsStringSync('export EDITOR=vim\n');
      final installer = CodexShortcutInstaller(
        environment: _environment(directory.path),
        shell: '/bin/bash',
        currentPath: '/usr/bin',
        supported: true,
      );

      await installer.install();
      final first = shellConfig.readAsStringSync();
      expect(first, startsWith('export EDITOR=vim\n'));
      expect(first, contains('>>> fluttAIrbar Codex shortcuts PATH >>>'));
      expect(first.split('>>> fluttAIrbar').length, 2);

      await installer.install();
      expect(shellConfig.readAsStringSync(), first);

      final result = await installer.uninstall();
      expect(result.ok, isTrue);
      expect(shellConfig.readAsStringSync(), 'export EDITOR=vim\n');
    } finally {
      directory.deleteSync(recursive: true);
    }
  });

  test('does not overwrite a conflicting shortcut file', () async {
    final directory = Directory.systemTemp.createTempSync(
      'fluttairbar-codex-shortcuts-conflict-',
    );
    try {
      final installer = CodexShortcutInstaller(
        environment: _environment(directory.path),
        currentPath: '',
        supported: true,
      );
      final conflictingFile = File('${installer.installDirectory}/codexunsafe')
        ..createSync(recursive: true);
      conflictingFile.writeAsStringSync('# a user command\n');

      final result = await installer.install();

      expect(result.ok, isFalse);
      expect(result.message, contains('codexunsafe'));
      expect(conflictingFile.readAsStringSync(), '# a user command\n');
    } finally {
      directory.deleteSync(recursive: true);
    }
  });

  test('recognizes an existing PATH setup without adding its own block', () {
    final directory = Directory.systemTemp.createTempSync(
      'fluttairbar-codex-shortcuts-existing-path-',
    );
    try {
      final shellConfig = File('${directory.path}/.bashrc')
        ..writeAsStringSync('export PATH="\$HOME/.local/bin:\$PATH"\n');
      final installer = CodexShortcutInstaller(
        environment: _environment(directory.path),
        shell: '/bin/bash',
        currentPath: '/usr/bin',
        supported: true,
      );

      final status = installer.inspect();

      expect(status.pathConfigured, isTrue);
      expect(status.pathAvailable, isFalse);
      expect(status.pathConfigPath, shellConfig.path);
    } finally {
      directory.deleteSync(recursive: true);
    }
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
