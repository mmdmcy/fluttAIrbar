import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:fluttairbar/models/harness.dart';
import 'package:fluttairbar/services/harness_catalog.dart';
import 'package:fluttairbar/services/harness_config.dart';
import 'package:fluttairbar/services/harness_manager.dart';

void main() {
  test('release age gate uses the publication timestamp', () {
    final release = HarnessRelease(
      latestVersion: '2.0.0',
      source: HarnessUpdateSource.npm,
      publishedAt: DateTime.utc(2026, 8, 1),
    );
    final now = DateTime.utc(2026, 8, 22);

    expect(release.ageGateSatisfied(now: now), isTrue);
    expect(release.ageGateSatisfied(now: DateTime.utc(2026, 8, 14)), isFalse);
  });

  test('version comparison handles stable and prerelease versions', () {
    expect(compareVersions('v1.10.0', '1.9.9'), greaterThan(0));
    expect(compareVersions('1.0.0', '1.0.0-beta.1'), greaterThan(0));
    expect(compareVersions('1.0.0-alpha.2', '1.0.0-alpha.10'), lessThan(0));
  });

  test('discovery prioritizes harnesses with verified updates', () async {
    final runner = _FakeCommandRunner();
    const candidate = HarnessDefinition(
      id: 'candidate',
      displayName: 'Candidate',
      executable: 'candidate',
      versionArgs: ['--version'],
      updateArgs: ['update'],
      updateSource: HarnessUpdateSource.npm,
      npmPackage: 'candidate-package',
      configs: [],
    );
    const current = HarnessDefinition(
      id: 'current',
      displayName: 'Current',
      executable: 'current',
      versionArgs: ['--version'],
      updateArgs: ['update'],
      updateSource: HarnessUpdateSource.npm,
      npmPackage: 'current-package',
      configs: [],
    );
    const missing = HarnessDefinition(
      id: 'missing',
      displayName: 'Missing',
      executable: 'missing',
      versionArgs: ['--version'],
      updateArgs: ['update'],
      updateSource: HarnessUpdateSource.npm,
      npmPackage: 'missing-package',
      configs: [],
    );
    final manager = HarnessManager(
      runner: runner,
      definitions: const [missing, current, candidate],
      now: () => DateTime.utc(2026, 8, 22),
    );
    runner.responses['which candidate'] = const CommandResult(
      exitCode: 0,
      stdout: '/tmp/candidate\n',
      stderr: '',
    );
    runner.responses['candidate --version'] = const CommandResult(
      exitCode: 0,
      stdout: '1.0.0\n',
      stderr: '',
    );
    runner.responses['npm view candidate-package version time --json'] =
        const CommandResult(
          exitCode: 0,
          stdout:
              '{"version":"2.0.0","time":{"2.0.0":"2026-07-01T00:00:00.000Z"}}',
          stderr: '',
        );
    runner.responses['which current'] = const CommandResult(
      exitCode: 0,
      stdout: '/tmp/current\n',
      stderr: '',
    );
    runner.responses['current --version'] = const CommandResult(
      exitCode: 0,
      stdout: '1.0.0\n',
      stderr: '',
    );
    runner.responses['npm view current-package version time --json'] =
        const CommandResult(
          exitCode: 0,
          stdout:
              '{"version":"1.0.0","time":{"1.0.0":"2026-07-01T00:00:00.000Z"}}',
          stderr: '',
        );
    runner.responses['which missing'] = const CommandResult(
      exitCode: 1,
      stdout: '',
      stderr: '',
    );

    final statuses = await manager.discover();

    expect(statuses.map((status) => status.definition.id), [
      'candidate',
      'current',
      'missing',
    ]);

    final filtered = await manager.discover(excludedIds: {'current'});
    expect(filtered.map((status) => status.definition.id), [
      'candidate',
      'missing',
    ]);
    manager.dispose();
  });

  test('update callbacks expose each harness start and completion', () async {
    final runner = _FakeCommandRunner();
    const definition = HarnessDefinition(
      id: 'test',
      displayName: 'Test',
      executable: 'test',
      versionArgs: ['--version'],
      updateArgs: ['update'],
      updateSource: HarnessUpdateSource.npm,
      npmPackage: 'test-package',
      configs: [],
    );
    final manager = HarnessManager(
      runner: runner,
      definitions: const [definition],
      now: () => DateTime.utc(2026, 8, 22),
    );
    runner.responses['which test'] = const CommandResult(
      exitCode: 0,
      stdout: '/tmp/test\n',
      stderr: '',
    );
    runner.responses['/tmp/test --version'] = const CommandResult(
      exitCode: 0,
      stdout: '1.0.0\n',
      stderr: '',
    );
    runner.responses['npm view test-package version time --json'] =
        const CommandResult(
          exitCode: 0,
          stdout:
              '{"version":"2.0.0","time":{"2.0.0":"2026-07-01T00:00:00.000Z"}}',
          stderr: '',
        );
    runner.responses['/tmp/test update'] = const CommandResult(
      exitCode: 0,
      stdout: 'updated\n',
      stderr: '',
    );
    final statuses = await manager.discover();
    final events = <String>[];

    final report = await manager.updateAll(
      statuses,
      onStart: (status) => events.add('start:${status.definition.id}'),
      onComplete: (result) => events.add(
        'complete:${result.status.definition.id}:'
        '${result.outcome.name}',
      ),
    );

    expect(report.updatedCount, 1);
    expect(events, ['start:test', 'complete:test:updated']);
    manager.dispose();
  });

  test('global npm updates target the verified release version', () async {
    final runner = _FakeCommandRunner();
    const definition = HarnessDefinition(
      id: 'test',
      displayName: 'Test',
      executable: 'test',
      versionArgs: ['--version'],
      updateArgs: ['update'],
      updateSource: HarnessUpdateSource.npm,
      npmPackage: 'test-package',
      updateWithNpmGlobal: true,
      configs: [],
    );
    final manager = HarnessManager(
      runner: runner,
      definitions: const [definition],
      now: () => DateTime.utc(2026, 8, 22),
    );
    runner.responses['which test'] = const CommandResult(
      exitCode: 0,
      stdout: '/tmp/test\n',
      stderr: '',
    );
    runner.responses['/tmp/test --version'] = const CommandResult(
      exitCode: 0,
      stdout: '1.0.0\n',
      stderr: '',
    );
    runner.responses['npm view test-package version time --json'] =
        const CommandResult(
          exitCode: 0,
          stdout:
              '{"version":"2.0.0","time":{"2.0.0":"2026-07-01T00:00:00.000Z"}}',
          stderr: '',
        );

    final statuses = await manager.discover();
    final report = await manager.updateAll(statuses);

    expect(report.results.single.outcome, HarnessUpdateOutcome.updated);
    expect(runner.calls, contains('npm install --global test-package@2.0.0'));
    manager.dispose();
  });

  test(
    'global npm updates use npm and prefix from the discovered executable',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'fluttairbar-node-prefix-',
      );
      final prefix = p.join(directory.path, 'node');
      final executable = p.join(
        prefix,
        'lib',
        'node_modules',
        'test-package',
        'bin',
        'test',
      );
      final npm = p.join(prefix, 'bin', Platform.isWindows ? 'npm.cmd' : 'npm');
      File(executable).createSync(recursive: true);
      File(npm).createSync(recursive: true);

      try {
        final runner = _FakeCommandRunner();
        const definition = HarnessDefinition(
          id: 'test',
          displayName: 'Test',
          executable: 'test',
          versionArgs: ['--version'],
          updateArgs: ['update'],
          updateSource: HarnessUpdateSource.npm,
          npmPackage: 'test-package',
          updateWithNpmGlobal: true,
          configs: [],
        );
        final manager = HarnessManager(
          runner: runner,
          definitions: const [definition],
          now: () => DateTime.utc(2026, 8, 22),
        );
        runner.responses['which test'] = CommandResult(
          exitCode: 0,
          stdout: '$executable\n',
          stderr: '',
        );
        runner.responses['$executable --version'] = const CommandResult(
          exitCode: 0,
          stdout: '1.0.0\n',
          stderr: '',
        );
        runner.responses['$npm view test-package version time --json'] =
            const CommandResult(
              exitCode: 0,
              stdout:
                  '{"version":"2.0.0","time":{"2.0.0":"2026-07-01T00:00:00.000Z"}}',
              stderr: '',
            );

        final statuses = await manager.discover();
        final report = await manager.updateAll(statuses);

        expect(report.results.single.outcome, HarnessUpdateOutcome.updated);
        expect(
          runner.calls,
          contains('$npm install --global --prefix $prefix test-package@2.0.0'),
        );
        manager.dispose();
      } finally {
        directory.deleteSync(recursive: true);
      }
    },
  );

  test(
    'npm release checks use the npm sibling of an nvm-style executable',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'fluttairbar-nvm-prefix-',
      );
      final prefix = p.join(directory.path, 'node');
      final executable = p.join(prefix, 'bin', 'codex');
      final npm = p.join(prefix, 'bin', Platform.isWindows ? 'npm.cmd' : 'npm');
      File(executable).createSync(recursive: true);
      File(npm).createSync(recursive: true);

      try {
        final runner = _FakeCommandRunner();
        const definition = HarnessDefinition(
          id: 'codex',
          displayName: 'Codex',
          executable: 'codex',
          versionArgs: ['--version'],
          updateArgs: ['update'],
          updateSource: HarnessUpdateSource.npm,
          npmPackage: '@openai/codex',
          updateWithNpmGlobal: true,
          configs: [],
        );
        final manager = HarnessManager(
          runner: runner,
          definitions: const [definition],
          now: () => DateTime.utc(2026, 8, 22),
        );
        runner.responses['which codex'] = CommandResult(
          exitCode: 0,
          stdout: '$executable\n',
          stderr: '',
        );
        runner.responses['$executable --version'] = const CommandResult(
          exitCode: 0,
          stdout: '1.0.0\n',
          stderr: '',
        );
        runner.responses['$npm view @openai/codex version time --json'] =
            const CommandResult(
              exitCode: 0,
              stdout:
                  '{"version":"2.0.0","time":{"2.0.0":"2026-07-01T00:00:00.000Z"}}',
              stderr: '',
            );

        final statuses = await manager.discover();

        expect(statuses.single.updateAvailable, isTrue);
        expect(
          runner.calls,
          contains('$npm view @openai/codex version time --json'),
        );
        expect(
          runner.calls,
          isNot(contains('npm view @openai/codex version time --json')),
        );
        manager.dispose();
      } finally {
        directory.deleteSync(recursive: true);
      }
    },
  );

  test(
    'successful update commands fail when the executable remains outdated',
    () async {
      final runner = _FakeCommandRunner(updatedVersion: '1.0.0');
      const definition = HarnessDefinition(
        id: 'test',
        displayName: 'Test',
        executable: 'test',
        versionArgs: ['--version'],
        updateArgs: ['update'],
        updateSource: HarnessUpdateSource.npm,
        npmPackage: 'test-package',
        configs: [],
      );
      final manager = HarnessManager(
        runner: runner,
        definitions: const [definition],
        now: () => DateTime.utc(2026, 8, 22),
      );
      runner.responses['which test'] = const CommandResult(
        exitCode: 0,
        stdout: '/tmp/test\n',
        stderr: '',
      );
      runner.responses['/tmp/test --version'] = const CommandResult(
        exitCode: 0,
        stdout: '1.0.0\n',
        stderr: '',
      );
      runner.responses['npm view test-package version time --json'] =
          const CommandResult(
            exitCode: 0,
            stdout:
                '{"version":"2.0.0","time":{"2.0.0":"2026-07-01T00:00:00.000Z"}}',
            stderr: '',
          );

      final statuses = await manager.discover();
      final report = await manager.updateAll(statuses);

      expect(report.results.single.outcome, HarnessUpdateOutcome.failed);
      expect(report.results.single.message, contains('still reports 1.0.0'));
      manager.dispose();
    },
  );

  test(
    'Codex finds and updates outdated copies behind a current PATH entry',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'fluttairbar-copies-',
      );
      try {
        final runner = _FakeCommandRunner();
        final definition = HarnessCatalog.definitions.singleWhere(
          (d) => d.id == 'codex',
        );
        final executables = <String>[];
        final npmPaths = <String>[];
        for (var index = 0; index < 3; index++) {
          final prefix = p.join(directory.path, 'node$index');
          final executable = p.join(prefix, 'bin', 'codex');
          final npm = p.join(
            prefix,
            'bin',
            Platform.isWindows ? 'npm.cmd' : 'npm',
          );
          File(executable).createSync(recursive: true);
          File(npm).createSync(recursive: true);
          executables.add(executable);
          npmPaths.add(npm);
          runner.responses['$executable --version'] = CommandResult(
            exitCode: 0,
            stdout: index == 0 ? '2.0.0' : '1.$index.0',
            stderr: '',
          );
        }
        // Repeated PATH entries must not produce repeated updates.
        runner.responses['which codex'] = CommandResult(
          exitCode: 0,
          stdout: executables.first,
          stderr: '',
        );
        runner.responses['which -a codex'] = CommandResult(
          exitCode: 0,
          stdout: [...executables, executables.last].join('\n'),
          stderr: '',
        );
        runner.responses['${npmPaths.first} view @openai/codex version time --json'] =
            const CommandResult(
              exitCode: 0,
              stdout:
                  '{"version":"2.0.0","time":{"2.0.0":"2026-07-01T00:00:00Z"}}',
              stderr: '',
            );
        final manager = HarnessManager(
          runner: runner,
          definitions: [definition],
          now: () => DateTime.utc(2026, 8, 22),
        );
        addTearDown(manager.dispose);
        final status = (await manager.discover()).single;
        expect(status.currentVersion, '1.1.0');
        expect(status.executablePath, executables[1]);
        expect(status.additionalExecutablePaths, [executables[2]]);
        expect(status.updateCandidate, isTrue);
        final result = await manager.update(status);
        expect(result.outcome, HarnessUpdateOutcome.updated);
        final installs = runner.calls
            .where((call) => call.contains(' install '))
            .toList();
        expect(installs.length, 2);
        for (var index = 1; index < 3; index++) {
          expect(
            installs,
            contains(
              '${npmPaths[index]} install --global --prefix ${p.dirname(p.dirname(executables[index]))} --min-release-age-exclude @openai/codex,@openai/codex-* @openai/codex@2.0.0',
            ),
          );
        }
      } finally {
        directory.deleteSync(recursive: true);
      }
    },
    skip: Platform.isWindows,
  );

  test(
    'OpenCode exempts its platform binaries in parent and child npm',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'fluttairbar-opencode-',
      );
      try {
        final executable = p.join(
          directory.path,
          'lib',
          'node_modules',
          'opencode-ai',
          'bin',
          'opencode',
        );
        File(executable).createSync(recursive: true);
        final runner = _FakeCommandRunner();
        final definition = HarnessCatalog.definitions.singleWhere(
          (d) => d.id == 'opencode',
        );
        final manager = HarnessManager(runner: runner);
        addTearDown(manager.dispose);
        final status = HarnessStatus(
          definition: definition,
          configs: const [],
          executablePath: executable,
          currentVersion: '1.0.0',
          release: HarnessRelease(
            latestVersion: '2.0.0',
            publishedAt: DateTime.utc(2026, 7, 1),
            source: HarnessUpdateSource.npm,
          ),
        );
        final result = await manager.update(status);
        expect(result.outcome, HarnessUpdateOutcome.updated);
        final install = runner.calls.singleWhere(
          (call) => call.contains(' install '),
        );
        expect(
          install,
          'npm install --prefix ${p.join(directory.path, "lib")} --no-save --no-package-lock --min-release-age-exclude opencode-ai,opencode-* opencode-ai@2.0.0',
        );
        expect(runner.environments[install], {
          'npm_config_min_release_age_exclude': 'opencode-ai,opencode-*',
        });
      } finally {
        directory.deleteSync(recursive: true);
      }
    },
  );

  test(
    'local runner passes per-command environment to child processes',
    () async {
      final result = await const LocalCommandRunner().run(
        '/bin/sh',
        ['-c', 'printenv npm_config_min_release_age_exclude'],
        environment: {
          'npm_config_min_release_age_exclude': 'opencode-ai,opencode-*',
        },
      );
      expect(result.exitCode, 0);
      expect(result.stdout.trim(), 'opencode-ai,opencode-*');
      expect(
        Platform.environment['npm_config_min_release_age_exclude'],
        isNull,
      );
    },
    skip: Platform.isWindows,
  );

  test('fx catalog points at its native settings and credential files', () {
    final definition = HarnessCatalog.definitions.singleWhere(
      (definition) => definition.id == 'fx',
    );

    expect(
      definition.configs.map((config) => config.pathTemplate),
      contains('{home}/.fx/settings.json'),
    );
    final credentials = definition.configs.singleWhere(
      (config) => config.label == 'Credentials',
    );
    expect(credentials.pathTemplate, '{home}/.fx/auth.json');
    expect(credentials.sensitive, isTrue);
  });

  test('config summaries expose provider hints without secrets', () {
    final directory = Directory.systemTemp.createTempSync(
      'fluttairbar-config-',
    );
    try {
      final settingsPath = p.join(directory.path, 'settings.json');
      File(settingsPath).writeAsStringSync('''
{
  "provider": "openrouter",
  "defaultModel": "stealth/ox-alpha",
  "model": "thinkingmachines/inkling:free",
  "apiKey": "placeholder-test-value"
}
''');
      const definition = HarnessDefinition(
        id: 'test',
        displayName: 'Test',
        executable: 'test',
        versionArgs: [],
        updateArgs: [],
        updateSource: HarnessUpdateSource.officialChannel,
        configs: [
          HarnessConfigSpec(
            label: 'Settings',
            pathTemplate: '{home}/settings.json',
          ),
        ],
      );
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

      final config = const HarnessConfigInspector()
          .inspect(definition, environment: environment)
          .single;

      expect(config.exists, isTrue);
      expect(config.summary, contains('OpenRouter referenced'));
      expect(config.summary, contains('Ox Alpha selected'));
      expect(config.summary, contains('Inkling :free selected'));
      expect(config.summary, isNot(contains('placeholder-test-value')));
    } finally {
      directory.deleteSync(recursive: true);
    }
  });

  test(
    'npm updates are skipped while the release is younger than 14 days',
    () async {
      final runner = _FakeCommandRunner();
      const definition = HarnessDefinition(
        id: 'test',
        displayName: 'Test',
        executable: 'test',
        versionArgs: ['--version'],
        updateArgs: ['update'],
        updateSource: HarnessUpdateSource.npm,
        npmPackage: 'test-package',
        configs: [],
      );
      final manager = HarnessManager(
        runner: runner,
        definitions: const [definition],
        now: () => DateTime.utc(2026, 8, 22),
      );
      runner.responses['which test'] = const CommandResult(
        exitCode: 0,
        stdout: '/tmp/test\n',
        stderr: '',
      );
      runner.responses['/tmp/test --version'] = const CommandResult(
        exitCode: 0,
        stdout: '1.0.0\n',
        stderr: '',
      );
      runner.responses['npm view test-package version time --json'] =
          const CommandResult(
            exitCode: 0,
            stdout:
                '{"version":"2.0.0","time":{"2.0.0":"2026-08-15T00:00:00.000Z"}}',
            stderr: '',
          );

      final statuses = await manager.discover();
      final report = await manager.updateAll(statuses);

      expect(report.results.single.outcome, HarnessUpdateOutcome.skipped);
      expect(runner.calls.where((call) => call.contains('update')), isEmpty);
      manager.dispose();
    },
  );

  test(
    'npm updates use the discovered executable after the gate passes',
    () async {
      final runner = _FakeCommandRunner();
      const definition = HarnessDefinition(
        id: 'test',
        displayName: 'Test',
        executable: 'test',
        versionArgs: ['--version'],
        updateArgs: ['update'],
        updateSource: HarnessUpdateSource.npm,
        npmPackage: 'test-package',
        configs: [],
      );
      final manager = HarnessManager(
        runner: runner,
        definitions: const [definition],
        now: () => DateTime.utc(2026, 8, 22),
      );
      runner.responses['which test'] = const CommandResult(
        exitCode: 0,
        stdout: '/tmp/test\n',
        stderr: '',
      );
      runner.responses['/tmp/test --version'] = const CommandResult(
        exitCode: 0,
        stdout: 'codex-cli 1.0.0\n',
        stderr: '',
      );
      runner.responses['npm view test-package version time --json'] =
          const CommandResult(
            exitCode: 0,
            stdout:
                '{"version":"2.0.0","time":{"2.0.0":"2026-07-01T00:00:00.000Z"}}',
            stderr: '',
          );
      runner.responses['/tmp/test update'] = const CommandResult(
        exitCode: 0,
        stdout: 'updated\n',
        stderr: '',
      );

      final statuses = await manager.discover();
      final report = await manager.updateAll(statuses);

      expect(statuses.single.currentVersion, '1.0.0');
      expect(report.results.single.outcome, HarnessUpdateOutcome.updated);
      expect(runner.calls, contains('/tmp/test update'));
      manager.dispose();
    },
  );

  test('explicit early update can bypass the release age gate', () async {
    final runner = _FakeCommandRunner();
    const definition = HarnessDefinition(
      id: 'test',
      displayName: 'Test',
      executable: 'test',
      versionArgs: ['--version'],
      updateArgs: ['update'],
      updateSource: HarnessUpdateSource.npm,
      npmPackage: 'test-package',
      configs: [],
    );
    final manager = HarnessManager(
      runner: runner,
      definitions: const [definition],
      now: () => DateTime.utc(2026, 8, 22),
    );
    runner.responses['which test'] = const CommandResult(
      exitCode: 0,
      stdout: '/tmp/test\n',
      stderr: '',
    );
    runner.responses['/tmp/test --version'] = const CommandResult(
      exitCode: 0,
      stdout: '1.0.0\n',
      stderr: '',
    );
    runner.responses['npm view test-package version time --json'] =
        const CommandResult(
          exitCode: 0,
          stdout:
              '{"version":"2.0.0","time":{"2.0.0":"2026-08-15T00:00:00.000Z"}}',
          stderr: '',
        );
    runner.responses['/tmp/test update'] = const CommandResult(
      exitCode: 0,
      stdout: 'updated\n',
      stderr: '',
    );

    final statuses = await manager.discover();
    final report = await manager.updateAll(statuses, allowEarlyRelease: true);

    expect(report.results.single.outcome, HarnessUpdateOutcome.updated);
    expect(runner.calls, contains('/tmp/test update'));
    manager.dispose();
  });

  test('isolated npm harnesses update their in-place package tree', () async {
    final runner = _FakeCommandRunner();
    const definition = HarnessDefinition(
      id: 'test',
      displayName: 'Test',
      executable: 'test',
      versionArgs: ['--version'],
      updateArgs: ['upgrade'],
      updateSource: HarnessUpdateSource.npm,
      npmPackage: 'test-package',
      updatePackageInPlace: true,
      configs: [],
    );
    final manager = HarnessManager(
      runner: runner,
      definitions: const [definition],
      now: () => DateTime.utc(2026, 8, 22),
    );
    runner.responses['which test'] = const CommandResult(
      exitCode: 0,
      stdout: '/tmp/agent-tools/test/lib/node_modules/test-package/bin/test\n',
      stderr: '',
    );
    runner.responses['/tmp/agent-tools/test/lib/node_modules/test-package/bin/test --version'] =
        const CommandResult(exitCode: 0, stdout: '1.0.0\n', stderr: '');
    runner.responses['npm view test-package version time --json'] =
        const CommandResult(
          exitCode: 0,
          stdout:
              '{"version":"2.0.0","time":{"2.0.0":"2026-07-01T00:00:00.000Z"}}',
          stderr: '',
        );
    runner.responses['npm install --prefix /tmp/agent-tools/test/lib --no-save --no-package-lock test-package@2.0.0'] =
        const CommandResult(exitCode: 0, stdout: 'updated\n', stderr: '');

    final statuses = await manager.discover();
    final report = await manager.updateAll(statuses);

    expect(report.results.single.outcome, HarnessUpdateOutcome.updated);
    expect(
      runner.calls,
      contains(
        'npm install --prefix /tmp/agent-tools/test/lib --no-save '
        '--no-package-lock test-package@2.0.0',
      ),
    );
    expect(
      runner.calls,
      isNot(
        contains(
          '/tmp/agent-tools/test/lib/node_modules/test-package/bin/test upgrade',
        ),
      ),
    );
    manager.dispose();
  });

  test(
    'official update checks fail closed when metadata is unavailable',
    () async {
      final runner = _FakeCommandRunner();
      const definition = HarnessDefinition(
        id: 'test',
        displayName: 'Test',
        executable: 'test',
        versionArgs: ['--version'],
        updateArgs: ['update'],
        updateSource: HarnessUpdateSource.officialChannel,
        checkArgs: ['update', '--check', '--json'],
        configs: [],
      );
      final manager = HarnessManager(
        runner: runner,
        definitions: const [definition],
      );
      runner.responses['which test'] = const CommandResult(
        exitCode: 0,
        stdout: '/tmp/test\n',
        stderr: '',
      );
      runner.responses['/tmp/test --version'] = const CommandResult(
        exitCode: 0,
        stdout: '1.0.0\n',
        stderr: '',
      );
      runner.responses['/tmp/test update --check --json'] = const CommandResult(
        exitCode: 1,
        stdout: '',
        stderr: 'network unavailable',
      );

      final statuses = await manager.discover();
      final report = await manager.updateAll(statuses);

      expect(report.results, isEmpty);
      expect(runner.calls.where((call) => call == '/tmp/test update'), isEmpty);
      manager.dispose();
    },
  );

  test('official updaters without a release check never execute', () async {
    final runner = _FakeCommandRunner();
    const definition = HarnessDefinition(
      id: 'test',
      displayName: 'Test',
      executable: 'test',
      versionArgs: ['--version'],
      updateArgs: ['update'],
      updateSource: HarnessUpdateSource.officialChannel,
      configs: [],
    );
    final manager = HarnessManager(
      runner: runner,
      definitions: const [definition],
    );
    runner.responses['which test'] = const CommandResult(
      exitCode: 0,
      stdout: '/tmp/test\n',
      stderr: '',
    );
    runner.responses['/tmp/test --version'] = const CommandResult(
      exitCode: 0,
      stdout: '1.0.0\n',
      stderr: '',
    );

    final statuses = await manager.discover();
    final directResult = await manager.update(statuses.single);
    final report = await manager.updateAll(statuses);

    expect(directResult.outcome, HarnessUpdateOutcome.skipped);
    expect(
      directResult.message,
      'Skipped: update availability could not be verified',
    );
    expect(report.results, isEmpty);
    expect(runner.calls.where((call) => call == '/tmp/test update'), isEmpty);
    manager.dispose();
  });

  test('harnesses without an updater are never executed', () async {
    final runner = _FakeCommandRunner();
    const definition = HarnessDefinition(
      id: 'test',
      displayName: 'Test',
      executable: 'test',
      versionArgs: ['--version'],
      updateArgs: [],
      updateSource: HarnessUpdateSource.officialChannel,
      supportsUpdate: false,
      configs: [],
    );
    final manager = HarnessManager(
      runner: runner,
      definitions: const [definition],
    );
    runner.responses['which test'] = const CommandResult(
      exitCode: 0,
      stdout: '/tmp/test\n',
      stderr: '',
    );
    runner.responses['/tmp/test --version'] = const CommandResult(
      exitCode: 0,
      stdout: '1.0.0\n',
      stderr: '',
    );

    final statuses = await manager.discover();
    final report = await manager.updateAll(statuses);

    expect(report.results, isEmpty);
    expect(runner.calls.where((call) => call == '/tmp/test'), isEmpty);
    manager.dispose();
  });
  test('codex discovery reads the background daemon version', () async {
    final runner = _FakeCommandRunner();
    const definition = HarnessDefinition(
      id: 'codex',
      displayName: 'Codex',
      executable: 'codex',
      versionArgs: ['--version'],
      updateArgs: ['update'],
      updateSource: HarnessUpdateSource.npm,
      npmPackage: '@openai/codex',
      updateWithNpmGlobal: true,
      daemonVersionArgs: ['app-server', 'daemon', 'version'],
      configs: [],
    );
    final manager = HarnessManager(
      runner: runner,
      definitions: const [definition],
      now: () => DateTime.utc(2026, 8, 22),
    );
    runner.responses['which codex'] = const CommandResult(
      exitCode: 0,
      stdout: '/tmp/codex\n',
      stderr: '',
    );
    runner.responses['/tmp/codex --version'] = const CommandResult(
      exitCode: 0,
      stdout: '0.159.3\n',
      stderr: '',
    );
    runner.responses['npm view @openai/codex version time --json'] =
        const CommandResult(
          exitCode: 0,
          stdout:
              '{"version":"0.162.1","time":{"0.162.1":"2026-07-01T00:00:00.000Z"}}',
          stderr: '',
        );
    runner.responses['/tmp/codex app-server daemon version'] =
        const CommandResult(
          exitCode: 0,
          stdout:
              '{"status":"running","cliVersion":"0.159.3",'
              '"managedCodexVersion":"0.163.0"}',
          stderr: '',
        );

    final status = (await manager.discover()).single;

    expect(status.daemonVersion, '0.163.0');
    expect(status.daemonAhead, isTrue);
    expect(status.daemonSyncCandidate, isTrue);
    manager.dispose();
  });

  test(
    'daemon sync installs the daemon version into every npm copy',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'fluttairbar-daemon-sync-',
      );
      try {
        final runner = _FakeCommandRunner();
        final definition = HarnessCatalog.definitions.singleWhere(
          (d) => d.id == 'codex',
        );
        final executables = <String>[];
        final npmPaths = <String>[];
        for (var index = 0; index < 2; index++) {
          final prefix = p.join(directory.path, 'node$index');
          final executable = p.join(prefix, 'bin', 'codex');
          final npm = p.join(
            prefix,
            'bin',
            Platform.isWindows ? 'npm.cmd' : 'npm',
          );
          File(executable).createSync(recursive: true);
          File(npm).createSync(recursive: true);
          executables.add(executable);
          npmPaths.add(npm);
          runner.responses['$executable --version'] = const CommandResult(
            exitCode: 0,
            stdout: '0.159.3\n',
            stderr: '',
          );
        }
        runner.responses['which codex'] = CommandResult(
          exitCode: 0,
          stdout: '${executables.first}\n',
          stderr: '',
        );
        runner.responses['which -a codex'] = CommandResult(
          exitCode: 0,
          stdout: executables.join('\n'),
          stderr: '',
        );
        runner.responses['${npmPaths.first} view @openai/codex version time --json'] =
            const CommandResult(
              exitCode: 0,
              stdout:
                  '{"version":"0.162.1","time":{"0.162.1":"2026-07-01T00:00:00Z"}}',
              stderr: '',
            );
        runner.responses['${executables.first} app-server daemon version'] =
            const CommandResult(
              exitCode: 0,
              stdout: '{"status":"running","managedCodexVersion":"0.162.1"}',
              stderr: '',
            );
        final manager = HarnessManager(
          runner: runner,
          definitions: [definition],
          now: () => DateTime.utc(2026, 8, 22),
        );
        addTearDown(manager.dispose);
        final status = (await manager.discover()).single;

        final result = await manager.syncToDaemon(status);

        expect(result.outcome, HarnessUpdateOutcome.updated);
        expect(result.message, contains('Synced to background daemon 0.162.1'));
        final installs = runner.calls
            .where((call) => call.contains(' install '))
            .toList();
        expect(installs.length, 2);
        for (var index = 0; index < 2; index++) {
          expect(
            installs,
            contains(
              '${npmPaths[index]} install --global --prefix ${p.dirname(p.dirname(executables[index]))} --min-release-age-exclude @openai/codex,@openai/codex-* @openai/codex@0.162.1',
            ),
          );
        }
        expect(runner.environments[installs.first], {
          'npm_config_min_release_age_exclude': '@openai/codex,@openai/codex-*',
        });
      } finally {
        directory.deleteSync(recursive: true);
      }
    },
    skip: Platform.isWindows,
  );

  test('daemon sync reports up to date when versions already match', () async {
    final runner = _FakeCommandRunner();
    const definition = HarnessDefinition(
      id: 'codex',
      displayName: 'Codex',
      executable: 'codex',
      versionArgs: ['--version'],
      updateArgs: ['update'],
      updateSource: HarnessUpdateSource.npm,
      npmPackage: '@openai/codex',
      updateWithNpmGlobal: true,
      daemonVersionArgs: ['app-server', 'daemon', 'version'],
      configs: [],
    );
    final manager = HarnessManager(
      runner: runner,
      definitions: const [definition],
      now: () => DateTime.utc(2026, 8, 22),
    );
    runner.responses['which codex'] = const CommandResult(
      exitCode: 0,
      stdout: '/tmp/codex\n',
      stderr: '',
    );
    runner.responses['/tmp/codex --version'] = const CommandResult(
      exitCode: 0,
      stdout: '2.0.0\n',
      stderr: '',
    );
    runner.responses['/tmp/codex app-server daemon version'] =
        const CommandResult(
          exitCode: 0,
          stdout: '{"status":"running","managedCodexVersion":"2.0.0"}',
          stderr: '',
        );

    final status = HarnessStatus(
      definition: definition,
      configs: const [],
      executablePath: '/tmp/codex',
      currentVersion: '2.0.0',
      daemonVersion: '2.0.0',
    );

    final result = await manager.syncToDaemon(status);

    expect(result.outcome, HarnessUpdateOutcome.upToDate);
    expect(runner.calls.where((call) => call.contains(' install ')), isEmpty);
    manager.dispose();
  });

  test(
    'daemon sync fails when a copy still reports an older version',
    () async {
      final runner = _FakeCommandRunner(updatedVersion: '1.0.0');
      const definition = HarnessDefinition(
        id: 'codex',
        displayName: 'Codex',
        executable: 'codex',
        versionArgs: ['--version'],
        updateArgs: ['update'],
        updateSource: HarnessUpdateSource.npm,
        npmPackage: '@openai/codex',
        updateWithNpmGlobal: true,
        daemonVersionArgs: ['app-server', 'daemon', 'version'],
        configs: [],
      );
      final manager = HarnessManager(
        runner: runner,
        definitions: const [definition],
        now: () => DateTime.utc(2026, 8, 22),
      );
      runner.responses['which codex'] = const CommandResult(
        exitCode: 0,
        stdout: '/tmp/codex\n',
        stderr: '',
      );
      runner.responses['/tmp/codex --version'] = const CommandResult(
        exitCode: 0,
        stdout: '1.0.0\n',
        stderr: '',
      );
      runner.responses['/tmp/codex app-server daemon version'] =
          const CommandResult(
            exitCode: 0,
            stdout: '{"status":"running","managedCodexVersion":"2.0.0"}',
            stderr: '',
          );

      final status = HarnessStatus(
        definition: definition,
        configs: const [],
        executablePath: '/tmp/codex',
        currentVersion: '1.0.0',
        daemonVersion: '2.0.0',
      );

      final result = await manager.syncToDaemon(status);

      expect(result.outcome, HarnessUpdateOutcome.failed);
      expect(result.message, contains('still reports 1.0.0'));
      manager.dispose();
    },
  );

  test('updateAll routes a daemon-only skew to the sync path', () async {
    final runner = _FakeCommandRunner();
    const definition = HarnessDefinition(
      id: 'codex',
      displayName: 'Codex',
      executable: 'codex',
      versionArgs: ['--version'],
      updateArgs: ['update'],
      updateSource: HarnessUpdateSource.npm,
      npmPackage: '@openai/codex',
      updateWithNpmGlobal: true,
      daemonVersionArgs: ['app-server', 'daemon', 'version'],
      configs: [],
    );
    final manager = HarnessManager(
      runner: runner,
      definitions: const [definition],
      now: () => DateTime.utc(2026, 8, 22),
    );
    runner.responses['which codex'] = const CommandResult(
      exitCode: 0,
      stdout: '/tmp/codex\n',
      stderr: '',
    );
    runner.responses['/tmp/codex --version'] = const CommandResult(
      exitCode: 0,
      stdout: '1.0.0\n',
      stderr: '',
    );
    runner.responses['npm view @openai/codex version time --json'] =
        const CommandResult(
          exitCode: 0,
          stdout:
              '{"version":"1.0.0","time":{"1.0.0":"2026-07-01T00:00:00.000Z"}}',
          stderr: '',
        );
    runner.responses['/tmp/codex app-server daemon version'] =
        const CommandResult(
          exitCode: 0,
          stdout: '{"status":"running","managedCodexVersion":"2.0.0"}',
          stderr: '',
        );

    final statuses = await manager.discover();
    final report = await manager.updateAll(statuses);

    expect(statuses.single.updateCandidate, isFalse);
    expect(report.results.single.outcome, HarnessUpdateOutcome.updated);
    expect(report.results.single.message, contains('daemon 2.0.0'));
    expect(
      runner.calls.where((call) => call.contains(' install ')),
      isNotEmpty,
    );
    manager.dispose();
  });
}

class _FakeCommandRunner implements CommandRunner {
  _FakeCommandRunner({this.updatedVersion = '2.0.0'});

  final Map<String, CommandResult> responses = {};
  final List<String> calls = [];
  final Map<String, Map<String, String>> environments = {};
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
    environments[key] = environment;
    final isPackageUpdate =
        arguments.contains('install') &&
        (arguments.contains('--global') || arguments.contains('--prefix'));
    if (arguments.length == 1 &&
            (arguments.single == 'update' || arguments.single == 'upgrade') ||
        isPackageUpdate) {
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
