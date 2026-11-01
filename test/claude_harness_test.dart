import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

import 'package:fluttairbar/models/harness.dart';
import 'package:fluttairbar/services/harness_catalog.dart';
import 'package:fluttairbar/services/harness_config.dart';
import 'package:fluttairbar/services/harness_manager.dart';

final _claude = HarnessCatalog.definitions.singleWhere((d) => d.id == 'claude');

HarnessEnvironment _environment(String home, {String? claudeConfigDir}) =>
    HarnessEnvironment(
      home: home,
      configHome: p.join(home, '.config'),
      dataHome: p.join(home, '.local', 'share'),
      piDirectory: p.join(home, '.pi', 'agent'),
      codexHome: p.join(home, '.codex'),
      grokConfigPath: null,
      appData: null,
      localAppData: null,
      isWindows: false,
      isMacOS: false,
      claudeConfigDirectory: claudeConfigDir,
    );

void main() {
  late Directory home;
  setUp(() => home = Directory.systemTemp.createTempSync('fluttairbar-cc-'));
  tearDown(() => home.deleteSync(recursive: true));

  test('Claude Code is in the catalog with its official channel', () {
    expect(_claude.executable, 'claude');
    expect(_claude.versionArgs, ['--version']);
    expect(_claude.updateArgs, ['update']);
    expect(_claude.updateSource, HarnessUpdateSource.officialChannel);
    expect(_claude.npmPackage, '@anthropic-ai/claude-code');
    expect(_claude.supportsUpdate, isTrue);
    expect(
      _claude.releaseChannel!.urlTemplate,
      'https://downloads.claude.ai/claude-code-releases/{channel}',
    );

    final configs = const HarnessConfigInspector().inspect(
      _claude,
      environment: _environment(home.path),
    );
    expect(configs.map((c) => c.path), [
      p.join(home.path, '.claude', 'settings.json'),
      p.join(home.path, '.claude', 'CLAUDE.md'),
      p.join(home.path, '.claude', 'skills'),
      p.join(home.path, '.claude.json'),
      p.join(home.path, '.claude', '.credentials.json'),
    ]);
    expect(configs.where((c) => c.sensitive).map((c) => p.basename(c.path)), [
      '.claude.json',
      '.credentials.json',
    ]);
  });

  test('CLAUDE_CONFIG_DIR moves every Claude file, global state too', () {
    final custom = p.join(home.path, 'claude-profile');
    final env = _environment(home.path, claudeConfigDir: custom);

    expect(env.resolve('{claudeDir}/settings.json'), '$custom/settings.json');
    expect(env.resolve('{claudeGlobalConfig}'), '$custom/.claude.json');
  });

  test('config view summarizes folders and hides credentials', () {
    final claudeDir = Directory(p.join(home.path, '.claude'))..createSync();
    Directory(
      p.join(claudeDir.path, 'skills', 'one'),
    ).createSync(recursive: true);
    Directory(p.join(claudeDir.path, 'skills', 'two')).createSync();
    File(p.join(claudeDir.path, 'settings.json')).writeAsStringSync(
      jsonEncode({
        'model': 'opus',
        'env': {'ANTHROPIC_API_KEY': 'test-token'},
      }),
    );
    File(
      p.join(claudeDir.path, '.credentials.json'),
    ).writeAsStringSync('{"claudeAiOauth":{"accessToken":"test-token"}}');

    final configs = const HarnessConfigInspector().inspect(
      _claude,
      environment: _environment(home.path),
    );
    String? summary(String label) =>
        configs.singleWhere((c) => c.label == label).summary;

    expect(summary('Skills'), 'Folder · 2 entries');
    expect(summary('Settings'), 'model: opus');
    expect(summary('Credentials'), 'Present · contents hidden');
    expect(configs.map((c) => c.summary).join(), isNot(contains('test-token')));
  });

  test(
    'a native install checks the official channel and runs claude update',
    () async {
      final runner = _FakeCommandRunner(
        updatedVersion: '2.1.316 (Claude Code)',
      );
      final executable = p.join(home.path, '.local', 'bin', 'claude');
      runner.responses['which claude'] = CommandResult(
        exitCode: 0,
        stdout: '$executable\n',
        stderr: '',
      );
      runner.responses['$executable --version'] = const CommandResult(
        exitCode: 0,
        stdout: '2.1.300 (Claude Code)\n',
        stderr: '',
      );
      final requested = <Uri>[];
      final manager = HarnessManager(
        runner: runner,
        client: MockClient((request) async {
          requested.add(request.url);
          return http.Response('2.1.316\n', 200);
        }),
        environment: _environment(home.path),
        definitions: [_claude],
      );
      addTearDown(manager.dispose);

      final status = (await manager.discover()).single;

      expect(
        requested.single.toString(),
        'https://downloads.claude.ai/claude-code-releases/latest',
      );
      expect(status.currentVersion, '2.1.300');
      expect(status.release!.latestVersion, '2.1.316');
      expect(status.updateSource, HarnessUpdateSource.officialChannel);
      expect(status.requiresReleaseAge, isFalse);
      expect(status.updateCandidate, isTrue);

      final result = await manager.update(status);

      expect(result.outcome, HarnessUpdateOutcome.updated);
      expect(runner.calls, contains('$executable update'));
      expect(runner.calls.where((call) => call.contains('npm')), isEmpty);
    },
  );

  test(
    'the channel comes from settings.json and only from the allowlist',
    () async {
      final claudeDir = Directory(p.join(home.path, '.claude'))..createSync();
      final settings = File(p.join(claudeDir.path, 'settings.json'));
      final runner = _FakeCommandRunner();
      final executable = p.join(home.path, '.local', 'bin', 'claude');
      runner.responses['which claude'] = CommandResult(
        exitCode: 0,
        stdout: '$executable\n',
        stderr: '',
      );
      runner.responses['$executable --version'] = const CommandResult(
        exitCode: 0,
        stdout: '2.1.309 (Claude Code)\n',
        stderr: '',
      );
      final requested = <String>[];
      HarnessManager manager() => HarnessManager(
        runner: runner,
        client: MockClient((request) async {
          requested.add(request.url.pathSegments.last);
          return http.Response('2.1.309', 200);
        }),
        environment: _environment(home.path),
        definitions: [_claude],
      );

      settings.writeAsStringSync('{"autoUpdatesChannel": "stable"}');
      final stable = manager();
      final status = (await stable.discover()).single;
      stable.dispose();
      settings.writeAsStringSync('{"autoUpdatesChannel": "../../evil"}');
      final fallback = manager();
      await fallback.discover();
      fallback.dispose();

      expect(requested, ['stable', 'latest']);
      expect(status.updateAvailable, isFalse);
    },
  );

  test('a channel that does not answer skips the update', () async {
    final runner = _FakeCommandRunner();
    final executable = p.join(home.path, '.local', 'bin', 'claude');
    runner.responses['which claude'] = CommandResult(
      exitCode: 0,
      stdout: '$executable\n',
      stderr: '',
    );
    runner.responses['$executable --version'] = const CommandResult(
      exitCode: 0,
      stdout: '2.1.300 (Claude Code)\n',
      stderr: '',
    );
    final manager = HarnessManager(
      runner: runner,
      client: MockClient((_) async => http.Response('<html>', 503)),
      environment: _environment(home.path),
      definitions: [_claude],
    );
    addTearDown(manager.dispose);

    final status = (await manager.discover()).single;
    final result = await manager.update(status);

    expect(status.checkError, 'Official channel check failed (503)');
    expect(result.outcome, HarnessUpdateOutcome.skipped);
    expect(runner.calls, isNot(contains('$executable update')));
  });

  test(
    'an npm install follows npm and its 14-day release-age gate',
    () async {
      final prefix = p.join(home.path, 'node');
      final binary = p.join(
        prefix,
        'lib',
        'node_modules',
        '@anthropic-ai',
        'claude-code',
        'bin',
        'claude.exe',
      );
      File(binary).createSync(recursive: true);
      final executable = p.join(prefix, 'bin', 'claude');
      Link(executable).createSync(binary, recursive: true);
      final npm = p.join(prefix, 'bin', 'npm');
      File(npm).createSync();

      final runner = _FakeCommandRunner(
        updatedVersion: '2.1.316 (Claude Code)',
      );
      runner.responses['which claude'] = CommandResult(
        exitCode: 0,
        stdout: '$executable\n',
        stderr: '',
      );
      runner.responses['$executable --version'] = const CommandResult(
        exitCode: 0,
        stdout: '2.1.300 (Claude Code)\n',
        stderr: '',
      );
      runner.responses['$npm view @anthropic-ai/claude-code version time --json'] =
          const CommandResult(
            exitCode: 0,
            stdout:
                '{"version":"2.1.316","time":{"2.1.316":"2026-10-31T00:00:00Z"}}',
            stderr: '',
          );
      final manager = HarnessManager(
        runner: runner,
        client: MockClient((request) async {
          fail('npm installs must not query the native channel');
        }),
        environment: _environment(home.path),
        definitions: [_claude],
        now: () => DateTime.utc(2026, 11, 1),
      );
      addTearDown(manager.dispose);

      final status = (await manager.discover()).single;

      expect(status.updateSource, HarnessUpdateSource.npm);
      expect(status.requiresReleaseAge, isTrue);
      expect(status.release!.latestVersion, '2.1.316');

      final gated = await manager.update(status);
      expect(gated.outcome, HarnessUpdateOutcome.skipped);
      expect(gated.message, contains('14-day age gate'));
      expect(runner.calls.where((call) => call.contains(' install ')), isEmpty);

      final early = await manager.update(status, allowEarlyRelease: true);
      expect(early.outcome, HarnessUpdateOutcome.updated);
      final install = runner.calls.singleWhere(
        (call) => call.contains(' install '),
      );
      expect(
        install,
        '$npm install --global --prefix $prefix --min-release-age-exclude '
        '@anthropic-ai/claude-code,@anthropic-ai/claude-code-* '
        '@anthropic-ai/claude-code@2.1.316',
      );
      expect(runner.calls, isNot(contains('$executable update')));
    },
    skip: Platform.isWindows,
  );
}

class _FakeCommandRunner implements CommandRunner {
  _FakeCommandRunner({this.updatedVersion = '2.0.0'});

  final Map<String, CommandResult> responses = {};
  final List<String> calls = [];
  final String updatedVersion;
  bool _updated = false;

  @override
  Future<CommandResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 10),
    Map<String, String> environment = const {},
  }) async {
    final key = '$executable ${arguments.join(' ')}';
    calls.add(key);
    if ((arguments.length == 1 && arguments.single == 'update') ||
        arguments.contains('install')) {
      _updated = true;
    }
    if (_updated && arguments.length == 1 && arguments.single == '--version') {
      return CommandResult(
        exitCode: 0,
        stdout: '$updatedVersion\n',
        stderr: '',
      );
    }
    return responses[key] ??
        const CommandResult(exitCode: 0, stdout: '', stderr: '');
  }
}
