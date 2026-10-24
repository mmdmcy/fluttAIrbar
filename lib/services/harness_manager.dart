import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../models/harness.dart';
import 'harness_catalog.dart';
import 'harness_config.dart';

class CommandResult {
  const CommandResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;

  bool get succeeded => exitCode == 0;
}

abstract interface class CommandRunner {
  Future<CommandResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 10),
    Map<String, String> environment = const {},
  });
}

class LocalCommandRunner implements CommandRunner {
  const LocalCommandRunner();

  @override
  Future<CommandResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 10),
    Map<String, String> environment = const {},
  }) async {
    late Process process;
    try {
      process = await Process.start(
        executable,
        arguments,
        runInShell: false,
        environment: {..._childEnvironment(), ...environment},
      );
    } on Object catch (error) {
      return CommandResult(exitCode: -1, stdout: '', stderr: error.toString());
    }

    final stdoutFuture = process.stdout.transform(utf8.decoder).join();
    final stderrFuture = process.stderr.transform(utf8.decoder).join();
    await process.stdin.close();

    var exitCode = -1;
    try {
      exitCode = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      process.kill();
      exitCode = -2;
    }

    final stdout = await stdoutFuture.timeout(
      const Duration(seconds: 1),
      onTimeout: () => '',
    );
    final stderr = await stderrFuture.timeout(
      const Duration(seconds: 1),
      onTimeout: () => '',
    );
    return CommandResult(exitCode: exitCode, stdout: stdout, stderr: stderr);
  }

  Map<String, String> _childEnvironment() {
    final environment = Map<String, String>.from(Platform.environment);
    final currentPath = environment['PATH'];
    final home = environment['HOME'];
    if (home == null ||
        home.isEmpty ||
        !Platform.isLinux && !Platform.isMacOS) {
      return environment;
    }
    const pathListSeparator = ':';

    final entries = <String>[];
    final seen = <String>{};

    void addDirectory(String directory) {
      if (Directory(directory).existsSync() && seen.add(directory)) {
        entries.add(directory);
      }
    }

    void addVersionedBins(String root) {
      final directory = Directory(root);
      if (!directory.existsSync()) return;
      try {
        final children =
            directory
                .listSync(followLinks: false)
                .whereType<Directory>()
                .toList()
              ..sort((left, right) => right.path.compareTo(left.path));
        for (final child in children) {
          addDirectory(p.join(child.path, 'bin'));
        }
      } on Object catch (_) {
        // A missing or unreadable version manager directory is optional.
      }
    }

    // Desktop autostart does not source the user's interactive shell. Include
    // the common per-user tool roots so Node-backed CLIs such as Codex can be
    // executed from the tray app as well as from a terminal.
    addDirectory(p.join(home, '.local', 'bin'));
    addDirectory(p.join(home, '.bun', 'bin'));
    addDirectory(p.join(home, '.volta', 'bin'));
    addDirectory(p.join(home, '.asdf', 'shims'));
    addDirectory(p.join(home, '.local', 'share', 'mise', 'shims'));
    addDirectory(p.join(home, '.local', 'share', 'mise', 'bin'));
    addDirectory(p.join(home, '.nvm', 'current', 'bin'));
    addVersionedBins(
      p.join(home, '.local', 'share', 'mise', 'installs', 'node'),
    );
    addVersionedBins(p.join(home, '.nvm', 'versions', 'node'));

    if (currentPath != null && currentPath.isNotEmpty) {
      entries.addAll(currentPath.split(pathListSeparator));
    }
    environment['PATH'] = entries.toSet().join(pathListSeparator);
    return environment;
  }
}

class _NpmInstallation {
  const _NpmInstallation({required this.executable, required this.prefix});

  final String executable;
  final String prefix;
}

class HarnessManager {
  HarnessManager({
    CommandRunner? runner,
    http.Client? client,
    HarnessEnvironment? environment,
    List<HarnessDefinition>? definitions,
    DateTime Function()? now,
  }) : _runner = runner ?? const LocalCommandRunner(),
       _client = client ?? http.Client(),
       _ownsClient = client == null,
       _environment = environment ?? HarnessEnvironment.system(),
       definitions = definitions ?? HarnessCatalog.definitions,
       _now = now ?? DateTime.now;

  static const minimumReleaseAge = Duration(days: 14);

  final CommandRunner _runner;
  final http.Client _client;
  final bool _ownsClient;
  final HarnessEnvironment _environment;
  final List<HarnessDefinition> definitions;
  final DateTime Function() _now;
  final HarnessConfigInspector _configInspector =
      const HarnessConfigInspector();
  final ConfigOpener _configOpener = const ConfigOpener();

  Future<List<HarnessStatus>> discover({
    Set<String> excludedIds = const {},
  }) async {
    final statuses = await Future.wait(
      definitions
          .where((definition) => !excludedIds.contains(definition.id))
          .map(_inspectDefinition),
    );
    statuses.sort((left, right) {
      int priority(HarnessStatus status) {
        if (status.updateCandidate) return 0;
        if (status.updateAvailable) return 1;
        if (status.installed) return 2;
        return 3;
      }

      final priorityComparison = priority(left).compareTo(priority(right));
      if (priorityComparison != 0) return priorityComparison;
      return left.definition.displayName.compareTo(
        right.definition.displayName,
      );
    });
    return statuses;
  }

  Future<HarnessUpdateReport> updateAll(
    Iterable<HarnessStatus> statuses, {
    bool allowEarlyRelease = false,
    void Function(HarnessStatus status)? onStart,
    void Function(HarnessUpdateResult result)? onComplete,
  }) async {
    final results = <HarnessUpdateResult>[];
    for (final status in statuses.where(
      (status) => status.updateCandidate || status.daemonSyncCandidate,
    )) {
      onStart?.call(status);
      // A verified npm release supersedes the daemon: npm latest is never
      // older than what the daemon runs, and the daemon's own updater closes
      // any residual gap on its next scheduled pass.
      final result = status.updateCandidate
          ? await update(status, allowEarlyRelease: allowEarlyRelease)
          : await syncToDaemon(status);
      results.add(result);
      onComplete?.call(result);
    }
    return HarnessUpdateReport(results);
  }

  Future<HarnessUpdateResult> update(
    HarnessStatus status, {
    bool allowEarlyRelease = false,
  }) async {
    if (!status.installed) {
      return HarnessUpdateResult(
        status: status,
        outcome: HarnessUpdateOutcome.skipped,
        message: 'Not installed',
      );
    }

    if (!status.definition.supportsUpdate) {
      return HarnessUpdateResult(
        status: status,
        outcome: HarnessUpdateOutcome.skipped,
        message: 'Skipped: no safe updater is configured',
      );
    }

    if (status.definition.checkArgs != null && status.checkError != null) {
      return HarnessUpdateResult(
        status: status,
        outcome: HarnessUpdateOutcome.skipped,
        message: 'Skipped: update check failed',
      );
    }

    if (status.release == null || status.currentVersion == null) {
      return HarnessUpdateResult(
        status: status,
        outcome: HarnessUpdateOutcome.skipped,
        message: 'Skipped: update availability could not be verified',
      );
    }

    if (!status.updateAvailable) {
      return HarnessUpdateResult(
        status: status,
        outcome: HarnessUpdateOutcome.upToDate,
        message: 'Already up to date',
      );
    }

    if (status.definition.requiresReleaseAge) {
      final release = status.release!;
      if (release.publishedAt == null) {
        return HarnessUpdateResult(
          status: status,
          outcome: HarnessUpdateOutcome.skipped,
          message: 'Skipped: release age could not be verified',
        );
      }
      if (!release.ageGateSatisfied(
            now: _now(),
            minimumAge: minimumReleaseAge,
          ) &&
          !allowEarlyRelease) {
        return HarnessUpdateResult(
          status: status,
          outcome: HarnessUpdateOutcome.skipped,
          message:
              'Skipped: latest release is younger than the 14-day age gate',
        );
      }
    }

    final executable = status.executablePath!;
    // A terminal and a desktop app can resolve different npm installations.
    // Update every outdated copy discovered on PATH, with its own prefix.
    final executables = [executable, ...status.additionalExecutablePaths];
    CommandResult result = const CommandResult(
      exitCode: 0,
      stdout: '',
      stderr: '',
    );
    for (final path in executables) {
      result = await _runUpdate(status, path);
      if (!result.succeeded) break;
      final verification = await _runner.run(
        path,
        status.definition.versionArgs,
      );
      final version = verification.succeeded
          ? _versionFrom(verification.stdout)
          : null;
      if (version == null ||
          compareVersions(version, status.release!.latestVersion) < 0) {
        return HarnessUpdateResult(
          status: status,
          outcome: HarnessUpdateOutcome.failed,
          message:
              'Update command finished, but $path still reports ${version ?? "an unknown version"} (expected ${status.release!.latestVersion})',
          exitCode: result.exitCode,
        );
      }
    }
    if (result.succeeded) {
      // The updater can replace a symlink or otherwise change which binary is
      // first on PATH. Resolve it again so verification checks the executable
      // the user will actually run after the update.
      final verificationExecutable =
          await _findExecutable(status.definition.executable) ?? executable;
      final verification = await _runner.run(
        verificationExecutable,
        status.definition.versionArgs,
      );
      final verifiedVersion = verification.succeeded
          ? _versionFrom(verification.stdout)
          : null;
      final expectedVersion = status.release!.latestVersion;
      if (verifiedVersion == null ||
          compareVersions(verifiedVersion, expectedVersion) < 0) {
        final detail = !verification.succeeded
            ? _commandFailure(verification, prefix: 'version verification')
            : verifiedVersion == null
            ? 'the installed version could not be verified'
            : 'it still reports $verifiedVersion (expected $expectedVersion)';
        return HarnessUpdateResult(
          status: status,
          outcome: HarnessUpdateOutcome.failed,
          message: 'Update command finished, but $detail',
          exitCode: result.exitCode,
        );
      }
      return HarnessUpdateResult(
        status: status,
        outcome: HarnessUpdateOutcome.updated,
        message: 'Updated to $verifiedVersion',
        exitCode: result.exitCode,
      );
    }
    return HarnessUpdateResult(
      status: status,
      outcome: HarnessUpdateOutcome.failed,
      message: _commandFailure(result),
      exitCode: result.exitCode,
    );
  }

  /// Installs an exact package version into the npm installation that owns
  /// [executable]. npm chooses its global prefix from the Node runtime that
  /// launches it, so the prefix is pinned to the installation we discovered
  /// and verification afterwards checks that same installation.
  Future<CommandResult> _runNpmGlobalInstall({
    required HarnessDefinition definition,
    required String executable,
    required String targetVersion,
  }) {
    final packageName = definition.npmPackage!;
    final npmInstallation = _npmInstallationFor(executable);
    final arguments = <String>['install', '--global'];
    if (npmInstallation != null) {
      arguments.addAll(['--prefix', npmInstallation.prefix]);
    }
    if (definition.npmMinReleaseAgeExempt) {
      // Include the CLI's platform binaries, which ship at the same version.
      // Export explicitly because npm does not pass this option to scripts.
      arguments.addAll([
        '--min-release-age-exclude',
        _releaseAgeExclusions(packageName),
      ]);
    }
    arguments.add('$packageName@$targetVersion');
    return _runner.run(
      npmInstallation?.executable ?? 'npm',
      arguments,
      timeout: const Duration(minutes: 5),
      environment: definition.npmMinReleaseAgeExempt
          ? {
              'npm_config_min_release_age_exclude': _releaseAgeExclusions(
                packageName,
              ),
            }
          : const {},
    );
  }

  /// Brings every npm installation of a harness on PATH up to the exact
  /// version its self-updating background daemon already runs. Codex's
  /// app-server daemon updates itself hourly outside npm, so it regularly
  /// runs ahead of the installed CLI and makes launches prompt about
  /// incompatible feature settings. The daemon's version is already on this
  /// machine, so the npm release-age exemption applies to the sync even when
  /// the release is younger than the 14-day gate.
  Future<HarnessUpdateResult> syncToDaemon(HarnessStatus status) async {
    final definition = status.definition;
    if (!status.installed ||
        definition.daemonVersionArgs == null ||
        !definition.updateWithNpmGlobal ||
        definition.npmPackage == null) {
      return HarnessUpdateResult(
        status: status,
        outcome: HarnessUpdateOutcome.skipped,
        message: 'Skipped: daemon sync is not configured for this harness',
      );
    }

    final daemonVersion = status.daemonVersion;
    if (daemonVersion == null) {
      return HarnessUpdateResult(
        status: status,
        outcome: HarnessUpdateOutcome.skipped,
        message: 'Skipped: background daemon version unavailable',
      );
    }

    final currentVersion = status.currentVersion;
    if (currentVersion == null) {
      return HarnessUpdateResult(
        status: status,
        outcome: HarnessUpdateOutcome.skipped,
        message: 'Skipped: installed version could not be verified',
      );
    }

    final comparison = compareVersions(daemonVersion, currentVersion);
    if (comparison == 0) {
      return HarnessUpdateResult(
        status: status,
        outcome: HarnessUpdateOutcome.upToDate,
        message: 'Already matches the background daemon ($daemonVersion)',
      );
    }
    if (comparison < 0) {
      return HarnessUpdateResult(
        status: status,
        outcome: HarnessUpdateOutcome.skipped,
        message:
            'Skipped: background daemon $daemonVersion is older than the CLI; '
            'its scheduled updater will catch up',
      );
    }

    // A terminal and a desktop app can resolve different npm installations.
    // Sync every installation discovered on PATH, with its own prefix.
    final candidates = <String>[status.executablePath!];
    final seen = <String>{_resolvedPath(status.executablePath!)};
    final paths = await _runner.run(
      Platform.isWindows ? 'where.exe' : 'which',
      [if (!Platform.isWindows) '-a', definition.executable],
    );
    if (paths.succeeded) {
      for (final path
          in _clean(paths.stdout)
              .split('\n')
              .map((line) => line.trim())
              .where((line) => line.isNotEmpty)) {
        if (!seen.add(_resolvedPath(path)) ||
            _npmInstallationFor(path) == null) {
          continue;
        }
        candidates.add(path);
      }
    }

    final outdated = <String>[];
    for (final path in candidates) {
      final result = await _runner.run(path, definition.versionArgs);
      final version = result.succeeded ? _versionFrom(result.stdout) : null;
      if (version == null || compareVersions(version, daemonVersion) < 0) {
        outdated.add(path);
      }
    }
    if (outdated.isEmpty) {
      return HarnessUpdateResult(
        status: status,
        outcome: HarnessUpdateOutcome.upToDate,
        message: 'Already matches the background daemon ($daemonVersion)',
      );
    }

    for (final path in outdated) {
      final result = await _runNpmGlobalInstall(
        definition: definition,
        executable: path,
        targetVersion: daemonVersion,
      );
      if (!result.succeeded) {
        return HarnessUpdateResult(
          status: status,
          outcome: HarnessUpdateOutcome.failed,
          message: _commandFailure(result, prefix: 'Daemon sync'),
          exitCode: result.exitCode,
        );
      }
    }
    for (final path in outdated) {
      final verification = await _runner.run(path, definition.versionArgs);
      final verifiedVersion = verification.succeeded
          ? _versionFrom(verification.stdout)
          : null;
      if (verifiedVersion == null ||
          compareVersions(verifiedVersion, daemonVersion) < 0) {
        final detail = !verification.succeeded
            ? _commandFailure(verification, prefix: 'version verification')
            : 'it still reports $verifiedVersion (expected $daemonVersion)';
        return HarnessUpdateResult(
          status: status,
          outcome: HarnessUpdateOutcome.failed,
          message: 'Sync command finished, but $detail',
        );
      }
    }
    return HarnessUpdateResult(
      status: status,
      outcome: HarnessUpdateOutcome.updated,
      message: 'Synced to background daemon $daemonVersion',
      exitCode: 0,
    );
  }

  Future<CommandResult> _runUpdate(HarnessStatus status, String executable) {
    final definition = status.definition;
    final packageName = definition.npmPackage;
    final targetVersion = status.release?.latestVersion;
    if (definition.updateWithNpmGlobal &&
        definition.updateSource == HarnessUpdateSource.npm &&
        packageName != null &&
        targetVersion != null) {
      return _runNpmGlobalInstall(
        definition: definition,
        executable: executable,
        targetVersion: targetVersion,
      );
    }
    if (definition.updatePackageInPlace &&
        definition.updateSource == HarnessUpdateSource.npm &&
        packageName != null &&
        targetVersion != null) {
      final prefix = _npmPrefixFor(executable);
      if (prefix != null) {
        final arguments = <String>[
          'install',
          '--prefix',
          prefix,
          '--no-save',
          '--no-package-lock',
        ];
        if (definition.npmMinReleaseAgeExempt) {
          // OpenCode's postinstall invokes npm to install its platform binary.
          // Both npm invocations must receive the same scoped exemptions.
          arguments.addAll([
            '--min-release-age-exclude',
            _releaseAgeExclusions(packageName),
          ]);
        }
        arguments.add('$packageName@$targetVersion');
        return _runner.run(
          'npm',
          arguments,
          timeout: const Duration(minutes: 5),
          environment: definition.npmMinReleaseAgeExempt
              ? {
                  'npm_config_min_release_age_exclude': _releaseAgeExclusions(
                    packageName,
                  ),
                }
              : const {},
        );
      }
    }
    return _runner.run(
      executable,
      definition.updateArgs,
      timeout: const Duration(minutes: 5),
    );
  }

  String _resolvedPath(String executable) {
    try {
      return File(executable).resolveSymbolicLinksSync();
    } on Object catch (_) {
      return executable;
    }
  }

  String _releaseAgeExclusions(String packageName) => switch (packageName) {
    '@openai/codex' => '@openai/codex,@openai/codex-*',
    'opencode-ai' => 'opencode-ai,opencode-*',
    _ => packageName,
  };

  _NpmInstallation? _npmInstallationFor(String executable) {
    var resolvedExecutable = executable;
    try {
      resolvedExecutable = File(executable).resolveSymbolicLinksSync();
    } on Object catch (_) {
      // Keep the lexical path when the executable is not a local file.
    }

    final npmName = Platform.isWindows ? 'npm.cmd' : 'npm';
    // Version managers such as nvm install both the CLI and npm directly in
    // the same `bin` directory. Prefer that sibling npm so discovery and
    // updates stay attached to the Node installation that owns the CLI.
    final siblingNpm = p.join(p.dirname(resolvedExecutable), npmName);
    if (File(siblingNpm).existsSync()) {
      final prefix = p.dirname(p.dirname(siblingNpm));
      return _NpmInstallation(executable: siblingNpm, prefix: prefix);
    }

    var directory = p.dirname(resolvedExecutable);
    while (true) {
      if (p.basename(directory) == 'node_modules') {
        final nodeModulesParent = p.dirname(directory);
        final prefix = p.basename(nodeModulesParent) == 'lib'
            ? p.dirname(nodeModulesParent)
            : nodeModulesParent;
        final candidate = p.join(prefix, 'bin', npmName);
        if (File(candidate).existsSync()) {
          return _NpmInstallation(executable: candidate, prefix: prefix);
        }
      }
      final parent = p.dirname(directory);
      if (parent == directory) return null;
      directory = parent;
    }
  }

  String? _npmPrefixFor(String executable) {
    var resolvedExecutable = executable;
    try {
      resolvedExecutable = File(executable).resolveSymbolicLinksSync();
    } on Object catch (_) {
      // Keep the lexical path if the executable disappeared during an update.
    }
    var directory = p.dirname(resolvedExecutable);
    while (true) {
      if (p.basename(directory) == 'node_modules') {
        return p.dirname(directory);
      }
      final parent = p.dirname(directory);
      if (parent == directory) return null;
      directory = parent;
    }
  }

  Future<void> openConfig(HarnessConfigFile config) =>
      _configOpener.open(config.path);

  void dispose() {
    if (_ownsClient) _client.close();
  }

  Future<HarnessStatus> _inspectDefinition(HarnessDefinition definition) async {
    var executablePath = await _findExecutable(definition.executable);
    final configs = _configInspector.inspect(
      definition,
      environment: _environment,
    );
    if (executablePath == null) {
      return HarnessStatus(definition: definition, configs: configs);
    }

    final versionResult = await _runner.run(
      executablePath,
      definition.versionArgs,
    );
    var currentVersion = _versionFrom(versionResult.stdout);
    var releaseLookup = const _ReleaseLookup();
    String? checkError;

    if (!versionResult.succeeded || currentVersion == null) {
      checkError = _commandFailure(versionResult, prefix: 'Version check');
    }

    // Informational only: a daemon that cannot be queried never fails the
    // harness check.
    String? daemonVersion;
    final daemonArgs = definition.daemonVersionArgs;
    if (daemonArgs != null) {
      final daemonResult = await _runner.run(
        executablePath,
        daemonArgs,
        timeout: const Duration(seconds: 15),
      );
      final payload = _decodeJson(daemonResult.stdout);
      if (payload is Map) {
        final reported =
            payload['managedCodexVersion']?.toString() ??
            payload['appServerVersion']?.toString();
        if (reported != null && reported.isNotEmpty) {
          daemonVersion = reported;
        }
      }
    }

    if (definition.updateSource == HarnessUpdateSource.npm) {
      releaseLookup = await _lookupNpmRelease(
        definition,
        executablePath: executablePath,
      );
    } else if (definition.updateSource == HarnessUpdateSource.githubRelease) {
      releaseLookup = await _lookupGithubRelease(definition);
    } else if (definition.checkArgs != null) {
      final checkResult = await _runner.run(
        executablePath,
        definition.checkArgs!,
      );
      final checked = _parseOfficialCheck(checkResult.stdout);
      releaseLookup = checked;
      if (!checkResult.succeeded && checked.error == null) {
        checkError = _commandFailure(checkResult, prefix: 'Update check');
      }
    }

    final additionalExecutablePaths = <String>[];
    if (definition.updateWithNpmGlobal &&
        releaseLookup.release != null &&
        currentVersion != null &&
        versionResult.succeeded) {
      final paths = await _runner.run(
        Platform.isWindows ? 'where.exe' : 'which',
        [if (!Platform.isWindows) '-a', definition.executable],
      );
      final seen = <String>{_resolvedPath(executablePath)};
      final outdated = <String>[];
      if (releaseLookup.release!.isNewerThan(currentVersion)) {
        outdated.add(executablePath);
      }
      if (paths.succeeded) {
        for (final path
            in _clean(paths.stdout)
                .split('\n')
                .map((line) => line.trim())
                .where((line) => line.isNotEmpty)) {
          if (!seen.add(_resolvedPath(path)) ||
              _npmInstallationFor(path) == null) {
            continue;
          }
          final result = await _runner.run(path, definition.versionArgs);
          final version = result.succeeded ? _versionFrom(result.stdout) : null;
          if (version == null || !releaseLookup.release!.isNewerThan(version)) {
            continue;
          }
          outdated.add(path);
          if (compareVersions(version, currentVersion!) < 0) {
            currentVersion = version;
            executablePath = path;
          }
        }
      }
      additionalExecutablePaths.addAll(
        outdated.where((path) => path != executablePath),
      );
    }
    checkError ??= releaseLookup.error;
    return HarnessStatus(
      definition: definition,
      configs: configs,
      executablePath: executablePath,
      additionalExecutablePaths: additionalExecutablePaths,
      currentVersion: currentVersion,
      daemonVersion: daemonVersion,
      release: releaseLookup.release,
      checkError: checkError,
    );
  }

  Future<String?> _findExecutable(String executable) async {
    final locator = Platform.isWindows ? 'where.exe' : 'which';
    final result = await _runner.run(locator, [executable]);
    if (result.succeeded) {
      final path = _firstLine(result.stdout);
      if (path != null && path.isNotEmpty) return path;
    }

    final fallback = p.join(_environment.home, '.local', 'bin', executable);
    if (File(fallback).existsSync()) return fallback;
    if (Platform.isWindows) {
      final windowsFallback = '$fallback.exe';
      if (File(windowsFallback).existsSync()) return windowsFallback;
    }
    return null;
  }

  Future<_ReleaseLookup> _lookupNpmRelease(
    HarnessDefinition definition, {
    String? executablePath,
  }) async {
    final packageNames = definition.packageCandidates;
    if (packageNames.isEmpty) {
      return const _ReleaseLookup(error: 'npm package is not configured');
    }
    final npmExecutable = executablePath == null
        ? null
        : _npmInstallationFor(executablePath)?.executable;
    _ReleaseLookup? lastLookup;
    for (final packageName in packageNames) {
      final result = await _runner.run(npmExecutable ?? 'npm', [
        'view',
        packageName,
        'version',
        'time',
        '--json',
      ], timeout: const Duration(seconds: 20));
      if (!result.succeeded) {
        lastLookup = _ReleaseLookup(
          error: _commandFailure(result, prefix: 'npm check'),
        );
        continue;
      }
      final payload = _decodeJson(result.stdout);
      if (payload is! Map) {
        lastLookup = const _ReleaseLookup(
          error: 'npm returned invalid release metadata',
        );
        continue;
      }
      final version = payload['version']?.toString();
      final times = payload['time'];
      final timestamp = times is Map && version != null
          ? DateTime.tryParse(times[version]?.toString() ?? '')
          : null;
      if (version == null || version.isEmpty) {
        lastLookup = const _ReleaseLookup(
          error: 'npm returned no latest version',
        );
        continue;
      }
      return _ReleaseLookup(
        release: HarnessRelease(
          latestVersion: version,
          publishedAt: timestamp,
          source: HarnessUpdateSource.npm,
        ),
      );
    }
    return lastLookup ??
        const _ReleaseLookup(error: 'npm release check failed');
  }

  Future<_ReleaseLookup> _lookupGithubRelease(
    HarnessDefinition definition,
  ) async {
    final repository = definition.releaseRepository;
    if (repository == null || repository.isEmpty) {
      return const _ReleaseLookup(
        error: 'release repository is not configured',
      );
    }
    try {
      final response = await _client
          .get(
            Uri.https('api.github.com', '/repos/$repository/releases/latest'),
            headers: {
              'Accept': 'application/vnd.github+json',
              'User-Agent': 'fluttAIrbar/1.0',
            },
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        return _ReleaseLookup(
          error: 'GitHub release check failed (${response.statusCode})',
        );
      }
      final payload = _decodeJson(response.body);
      if (payload is! Map) {
        return const _ReleaseLookup(
          error: 'GitHub returned invalid release metadata',
        );
      }
      final version = payload['tag_name']?.toString();
      if (version == null || version.isEmpty) {
        return const _ReleaseLookup(
          error: 'GitHub returned no latest release version',
        );
      }
      return _ReleaseLookup(
        release: HarnessRelease(
          latestVersion: version,
          publishedAt: DateTime.tryParse(
            payload['published_at']?.toString() ?? '',
          ),
          source: HarnessUpdateSource.githubRelease,
        ),
      );
    } on Object catch (_) {
      return const _ReleaseLookup(error: 'GitHub release check unavailable');
    }
  }

  _ReleaseLookup _parseOfficialCheck(String output) {
    final payload = _decodeJson(output);
    if (payload is! Map) {
      return const _ReleaseLookup(
        error: 'update check returned invalid metadata',
      );
    }
    final data = payload['data'];
    final release = data is Map ? data['release'] : null;
    final latest =
        payload['latestVersion']?.toString() ??
        (data is Map ? data['latestVersion']?.toString() : null) ??
        (release is Map ? release['latestVersion']?.toString() : null);
    if (latest == null || latest.isEmpty) {
      return const _ReleaseLookup(
        error: 'update check returned no latest version',
      );
    }
    return _ReleaseLookup(
      release: HarnessRelease(
        latestVersion: latest,
        source: HarnessUpdateSource.officialChannel,
      ),
    );
  }

  dynamic _decodeJson(String output) {
    final trimmed = output.trim();
    if (trimmed.isEmpty) return null;
    try {
      return jsonDecode(trimmed);
    } catch (_) {
      final objectStart = trimmed.indexOf('{');
      final objectEnd = trimmed.lastIndexOf('}');
      if (objectStart < 0 || objectEnd <= objectStart) return null;
      try {
        return jsonDecode(trimmed.substring(objectStart, objectEnd + 1));
      } catch (_) {
        return null;
      }
    }
  }

  String? _firstLine(String output) {
    for (final line in _clean(output).split('\n')) {
      final value = line.trim();
      if (value.isNotEmpty) return value;
    }
    return null;
  }

  String? _versionFrom(String output) {
    final cleaned = _clean(output);
    final match = RegExp(
      r'v?([0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?)',
    ).firstMatch(cleaned);
    if (match != null) return match.group(1);
    return _firstLine(cleaned);
  }

  String _commandFailure(CommandResult result, {String? prefix}) {
    final detail = _firstLine(result.stderr) ?? _firstLine(result.stdout);
    final label = prefix == null ? 'Command failed' : '$prefix failed';
    if (result.exitCode == -2) return '$label: timed out';
    if (detail == null) return '$label (exit ${result.exitCode})';
    return '$label: ${_redact(detail)}';
  }

  String _clean(String value) =>
      value.replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), '');

  String _redact(String value) {
    final redacted = value.replaceAllMapped(
      RegExp(
        r'(token|api[_-]?key|secret|password|authorization)(\s*[:=]\s*)\S+',
        caseSensitive: false,
      ),
      (match) => '${match.group(1)}${match.group(2)}[redacted]',
    );
    return redacted.substring(0, redacted.length > 240 ? 240 : redacted.length);
  }
}

class _ReleaseLookup {
  const _ReleaseLookup({this.release, this.error});

  final HarnessRelease? release;
  final String? error;
}
