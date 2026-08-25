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
  });
}

class LocalCommandRunner implements CommandRunner {
  const LocalCommandRunner();

  @override
  Future<CommandResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    late Process process;
    try {
      process = await Process.start(
        executable,
        arguments,
        runInShell: false,
        environment: _childEnvironment(),
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
    for (final status in statuses.where((status) => status.updateCandidate)) {
      onStart?.call(status);
      final result = await update(status, allowEarlyRelease: allowEarlyRelease);
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
    final result = await _runUpdate(status, executable);
    if (result.succeeded) {
      final verification = await _runner.run(
        executable,
        status.definition.versionArgs,
      );
      final verifiedVersion = _versionFrom(verification.stdout);
      if (status.updateAvailable &&
          (verifiedVersion == null ||
              compareVersions(verifiedVersion, status.currentVersion!) <= 0)) {
        final detail = verifiedVersion == null
            ? 'the installed version could not be verified'
            : 'it still reports $verifiedVersion';
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
        message: verifiedVersion == null
            ? 'Update command completed'
            : 'Updated to $verifiedVersion',
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

  Future<CommandResult> _runUpdate(HarnessStatus status, String executable) {
    final definition = status.definition;
    final packageName = definition.npmPackage;
    final targetVersion = status.release?.latestVersion;
    if (definition.updatePackageInPlace &&
        definition.updateSource == HarnessUpdateSource.npm &&
        packageName != null &&
        targetVersion != null) {
      final prefix = _npmPrefixFor(executable);
      if (prefix != null) {
        return _runner.run('npm', [
          'install',
          '--prefix',
          prefix,
          '--no-save',
          '--no-package-lock',
          '$packageName@$targetVersion',
        ], timeout: const Duration(minutes: 5));
      }
    }
    return _runner.run(
      executable,
      definition.updateArgs,
      timeout: const Duration(minutes: 5),
    );
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
    final executablePath = await _findExecutable(definition.executable);
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
    final currentVersion = _versionFrom(versionResult.stdout);
    var releaseLookup = const _ReleaseLookup();
    String? checkError;

    if (!versionResult.succeeded || currentVersion == null) {
      checkError = _commandFailure(versionResult, prefix: 'Version check');
    }

    if (definition.updateSource == HarnessUpdateSource.npm) {
      releaseLookup = await _lookupNpmRelease(definition);
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

    checkError ??= releaseLookup.error;
    return HarnessStatus(
      definition: definition,
      configs: configs,
      executablePath: executablePath,
      currentVersion: currentVersion,
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

  Future<_ReleaseLookup> _lookupNpmRelease(HarnessDefinition definition) async {
    final packageNames = definition.packageCandidates;
    if (packageNames.isEmpty) {
      return const _ReleaseLookup(error: 'npm package is not configured');
    }
    _ReleaseLookup? lastLookup;
    for (final packageName in packageNames) {
      final result = await _runner.run('npm', [
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
