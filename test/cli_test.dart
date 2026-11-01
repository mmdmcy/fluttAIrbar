import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

import 'package:fluttairbar/cli/cli.dart';
import 'package:fluttairbar/cli/harnesses_command.dart';
import 'package:fluttairbar/cli/usage_command.dart';
import 'package:fluttairbar/cli/usage_report.dart';
import 'package:fluttairbar/cli/version.dart';
import 'package:fluttairbar/models/harness.dart';
import 'package:fluttairbar/models/usage_snapshot.dart';
import 'package:fluttairbar/services/harness_config.dart';
import 'package:fluttairbar/services/harness_manager.dart';
import 'package:fluttairbar/services/usage_fetcher.dart';
import 'package:fluttairbar/services/usage_preferences.dart';

const _email = 'person@example.com';
const _accountId = 'acct-0123456789abcdef0123456789abcdef';

CodexUsage _codex({UsageState state = UsageState.ok}) => CodexUsage(
  email: _email,
  accountId: _accountId,
  authSource: 'codex-cli',
  planType: 'pro',
  state: state,
  fetchedAt: DateTime.utc(2026, 11, 1, 12),
  primary: const RateWindow(
    usedPercent: 12.5,
    resetAfterSeconds: 3600,
    limitWindowSeconds: 18000,
    label: '5h',
  ),
  secondary: RateWindow(
    usedPercent: 40,
    resetAt: DateTime.utc(2026, 11, 3, 8),
    limitWindowSeconds: 604800,
    label: 'Weekly',
  ),
);

final _claude = ClaudeUsage(
  plan: 'max',
  windows: [
    RateWindow(
      id: 'session',
      label: '5 hours',
      usedPercent: 3,
      resetAt: DateTime.utc(2026, 11, 1, 18),
      limitWindowSeconds: 18000,
    ),
    const RateWindow(
      id: 'weekly-opus',
      label: '7 days · Opus',
      usedPercent: 86,
      limitWindowSeconds: 604800,
    ),
  ],
);

void main() {
  test('usage JSON follows fluttairbar.usage.v1', () {
    final json = UsageReport.from(codex: _codex(), claude: _claude).toJson();

    expect(json['schema'], 'fluttairbar.usage.v1');
    final providers = (json['providers'] as List).cast<Map<String, Object?>>();
    expect(providers.map((provider) => provider['id']), [
      'codex',
      'claude',
      'cursor',
    ]);
    for (final provider in providers) {
      expect(provider.keys, ['id', 'state', 'detail', 'plan', 'windows']);
      expect(provider['detail'], isA<String>());
      expect(provider['plan'], isA<String>());
      for (final window in (provider['windows'] as List).cast<Map>()) {
        expect(window.keys, ['id', 'label', 'used_percent', 'resets_at']);
      }
    }

    final codex = providers[0];
    expect(codex['state'], 'ok');
    expect(codex['plan'], 'pro');
    expect(codex['windows'], [
      {
        'id': 'session',
        'label': '5 hours',
        'used_percent': 12.5,
        'resets_at': '2026-11-01T13:00:00.000Z',
      },
      {
        'id': 'weekly',
        'label': '7 days',
        'used_percent': 40.0,
        'resets_at': '2026-11-03T08:00:00.000Z',
      },
    ]);

    final claude = providers[1];
    expect(claude['state'], 'ok');
    expect(claude['plan'], 'max');
    expect((claude['windows'] as List).last, {
      'id': 'weekly-opus',
      'label': '7 days · Opus',
      'used_percent': 86.0,
      'resets_at': null,
    });

    final cursor = providers[2];
    expect(cursor['state'], 'paused');
    expect(cursor['plan'], '');
    expect(cursor['windows'], isEmpty);
  });

  test('usage output never carries emails, account ids or tokens', () {
    final report = UsageReport.from(
      codex: CodexUsage(
        email: _email,
        accountId: _accountId,
        authSource: 'none',
        state: UsageState.error,
        error:
            'wham/usage HTTP 500: {"user":"$_email","account":"$_accountId",'
            '"auth":"Bearer test-token-0123456789abcdefghijklmnopqrstuv"}\n'
            'second line',
      ),
      claude: _claude,
      cursor: const CursorUsage(
        authSource: 'cursor-app',
        email: _email,
        planName: 'pro',
        usedPercent: 20,
      ),
    );
    final text =
        '${jsonEncode(report.toJson())}\n${report.toLines().join('\n')}';

    expect(text, isNot(contains(_email)));
    expect(text, isNot(contains(_accountId)));
    expect(text, isNot(contains('test-token')));
    final codexDetail = report.providers.first.detail;
    expect(codexDetail, isNot(contains('\n')));
    expect(codexDetail, startsWith('wham/usage HTTP 500'));
  });

  test('states map to the contract names and stale keeps its windows', () {
    final stale = UsageReport.from(
      codex: _codex(state: UsageState.stale),
      claude: const ClaudeUsage(
        state: UsageState.expired,
        error: UsageFetcher.claudeExpiredMessage,
      ),
      cursor: const CursorUsage(
        authSource: 'none',
        state: UsageState.signedOut,
        error: 'No Cursor credentials found.\nSign in to the Cursor app.',
      ),
    ).toJson();
    final providers = (stale['providers'] as List).cast<Map>();

    expect(providers.map((provider) => provider['state']), [
      'stale',
      'expired',
      'signed-out',
    ]);
    expect(providers[0]['detail'], UsageFetcher.codexStaleMessage);
    expect(providers[0]['windows'], hasLength(2));
    expect(
      providers[1]['detail'],
      'Claude session expired: run claude to renew it.',
    );
    expect(
      providers[2]['detail'],
      'No Cursor credentials found. Sign in to the Cursor app.',
    );
    expect(UsageState.values.map((state) => state.jsonName), [
      'ok',
      'signed-out',
      'expired',
      'stale',
      'paused',
      'error',
    ]);
  });

  test('usage command prints one JSON document and exits 0', () async {
    final directory = Directory.systemTemp.createTempSync('fluttairbar-cli-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final preferences = UsagePreferences(
      environment: _environment(directory.path),
    );
    final fetcher = _FakeFetcher();
    final out = StringBuffer();
    final err = StringBuffer();

    final code = await runUsageCommand(
      ['--json'],
      out: out,
      err: err,
      fetcher: fetcher,
      preferences: preferences,
    );

    expect(code, 0);
    expect(err.toString(), isEmpty);
    final json = jsonDecode(out.toString()) as Map<String, dynamic>;
    expect(json['schema'], 'fluttairbar.usage.v1');
    expect((json['providers'] as List).map((provider) => provider['state']), [
      'signed-out',
      'ok',
      'paused',
    ]);
    expect(fetcher.codexResetCredits, isFalse);
    expect(fetcher.cursorCalls, 0);

    preferences.saveClaudeEnabled(false);
    preferences.saveCursorEnabled(true);
    final second = StringBuffer();
    await runUsageCommand(
      const [],
      out: second,
      err: err,
      fetcher: fetcher,
      preferences: preferences,
    );
    final lines = second.toString().trim().split('\n');
    expect(lines, hasLength(3));
    expect(lines[0], startsWith('codex  signed-out · No ChatGPT/Codex'));
    expect(lines[1], startsWith('claude paused'));
    expect(lines[2], startsWith('cursor signed-out'));
    expect(fetcher.claudeCalls, 1);
    expect(fetcher.cursorCalls, 1);

    expect(
      await runUsageCommand(
        ['--jsn'],
        out: StringBuffer(),
        err: StringBuffer(),
        fetcher: fetcher,
        preferences: preferences,
      ),
      64,
    );
  });

  test('harnesses command keeps the update_harnesses JSON shape', () async {
    final directory = Directory.systemTemp.createTempSync('fluttairbar-cli-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final out = StringBuffer();
    const definition = HarnessDefinition(
      id: 'codex',
      displayName: 'Codex CLI',
      executable: 'codex',
      versionArgs: ['--version'],
      updateArgs: ['update'],
      updateSource: HarnessUpdateSource.npm,
      npmPackage: '@openai/codex',
      configs: [],
    );

    final code = await runHarnessesCommand(
      ['--json', '--only', 'codex'],
      out: out,
      err: StringBuffer(),
      managerFor: (definitions) {
        expect(definitions!.map((d) => d.id), ['codex']);
        return HarnessManager(
          runner: _NothingInstalled(),
          environment: _environment(directory.path),
          definitions: const [definition],
        );
      },
    );

    expect(code, 0);
    final json = (jsonDecode(out.toString()) as List).single as Map;
    expect(json.keys, [
      'id',
      'name',
      'installed',
      'path',
      'currentVersion',
      'latestVersion',
      'daemonVersion',
      'daemonAhead',
      'publishedAt',
      'updateAvailable',
      'ageGateSatisfied',
      'updateSource',
      'checkError',
      'configs',
    ]);
    expect(json['installed'], isFalse);
    expect(json['updateSource'], 'npm');

    final err = StringBuffer();
    expect(
      await runHarnessesCommand(['--only', 'nope'], out: out, err: err),
      64,
    );
    expect(err.toString(), contains('Unknown harness id(s): nope'));
  });

  test('help, version and wrong usage', () async {
    final out = StringBuffer();
    final err = StringBuffer();

    expect(await runCli(['--help'], out: out, err: err), 0);
    expect(out.toString(), contains('fluttairbar-cli usage [--json]'));
    expect(out.toString(), contains('claude'));
    expect(await runCli(['usage', '--help'], out: out, err: err), 0);

    final version = StringBuffer();
    expect(await runCli(['version'], out: version, err: err), 0);
    expect(version.toString().trim(), 'fluttairbar-cli $fluttairbarVersion');

    expect(await runCli([], out: out, err: err), 64);
    expect(await runCli(['bogus'], out: out, err: err), 64);
    expect(err.toString(), contains('Unknown command: bogus'));
  });

  test('the CLI version matches pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match = RegExp(
      r'^version:\s*([0-9.]+)',
      multiLine: true,
    ).firstMatch(pubspec);
    expect(match!.group(1), fluttairbarVersion);
  });

  test('the CLI import graph contains no Flutter code', () {
    final pending = ['tool/fluttairbar_cli.dart'];
    final seen = <String>{};
    final import = RegExp(
      r'''^(?:import|export)\s+'([^']+)'.*;''',
      multiLine: true,
    );
    while (pending.isNotEmpty) {
      final path = pending.removeLast();
      if (!seen.add(path)) continue;
      for (final match in import.allMatches(File(path).readAsStringSync())) {
        final uri = match.group(1)!;
        expect(uri, isNot(startsWith('package:flutter')), reason: path);
        expect(uri, isNot(startsWith('dart:ui')), reason: path);
        if (uri.startsWith('package:fluttairbar/')) {
          pending.add('lib/${uri.substring('package:fluttairbar/'.length)}');
        } else if (!uri.contains(':')) {
          pending.add(p.normalize(p.join(p.dirname(path), uri)));
        }
      }
    }
    expect(seen, contains('lib/services/usage_fetcher.dart'));
    expect(seen, contains('lib/services/harness_manager.dart'));
  });
}

HarnessEnvironment _environment(String directory) => HarnessEnvironment(
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

class _FakeFetcher extends UsageFetcher {
  _FakeFetcher()
    : super(client: MockClient((_) async => http.Response('', 500)));

  bool? codexResetCredits;
  int claudeCalls = 0;
  int cursorCalls = 0;

  @override
  Future<CodexUsage> codex({
    bool refreshAuthFile = false,
    bool includeResetCredits = true,
  }) async {
    expect(refreshAuthFile, isFalse);
    codexResetCredits = includeResetCredits;
    return CodexUsage(
      email: '?',
      accountId: '',
      authSource: 'none',
      state: UsageState.signedOut,
      error: 'No ChatGPT/Codex credentials found.\nRun `codex login`.',
    );
  }

  @override
  Future<ClaudeUsage> claude() async {
    claudeCalls++;
    return _claude;
  }

  @override
  Future<CursorUsage> cursor() async {
    cursorCalls++;
    return const CursorUsage(
      authSource: 'none',
      state: UsageState.signedOut,
      error: 'No Cursor credentials found.',
    );
  }
}

class _NothingInstalled implements CommandRunner {
  @override
  Future<CommandResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 10),
    Map<String, String> environment = const {},
  }) async => const CommandResult(exitCode: 1, stdout: '', stderr: '');
}
