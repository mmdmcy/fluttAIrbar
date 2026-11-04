/// What the agent-management commands need to know about this device: its
/// name, its home and its standard folders, and how to quote a path for the
/// shell. Nothing here reads a credential.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// The folders one run works in; tests give their own.
class Local {
  Local({
    required this.home,
    required this.configHome,
    required this.dataHome,
    required this.stateHome,
    required this.device,
  });

  factory Local.system() {
    final env = Platform.environment;
    final home = env['HOME'] ?? env['USERPROFILE'] ?? '';
    String xdg(String name, String fallback) {
      final value = env[name];
      return value != null && value.isNotEmpty ? value : p.join(home, fallback);
    }

    return Local(
      home: home,
      configHome: xdg('XDG_CONFIG_HOME', '.config'),
      dataHome: xdg('XDG_DATA_HOME', '.local/share'),
      stateHome: xdg('XDG_STATE_HOME', '.local/state'),
      device: deviceName(),
    );
  }

  final String home;
  final String configHome;
  final String dataHome;
  final String stateHome;

  /// This device's short name: `hostname -s`, on macOS its LocalHostName.
  final String device;

  /// `~/x` for a path under this home, also when given absolute.
  String tilde(String path) {
    if (home.isNotEmpty && path.startsWith('$home/')) {
      return '~/${path.substring(home.length + 1)}';
    }
    return path.length > 1 && path.endsWith('/')
        ? path.substring(0, path.length - 1)
        : path;
  }

  /// The absolute path for `~/x`.
  String expand(String path) => path.startsWith('~/') && home.isNotEmpty
      ? p.join(home, path.substring(2))
      : path;
}

/// The device's short name, the one fleet tools use for it.
String deviceName() {
  try {
    final result = Platform.isMacOS
        ? Process.runSync('scutil', ['--get', 'LocalHostName'])
        : Process.runSync('hostname', ['-s']);
    final name = '${result.stdout}'.trim();
    if (result.exitCode == 0 && name.isNotEmpty) return name;
  } on Object {
    // Fall through to the name Dart knows.
  }
  final name = Platform.localHostname.split('.').first;
  return name.isEmpty ? 'local' : name;
}

/// `~/x` for the shell, quoted so only `$HOME` expands.
String shellPath(String path) => path.startsWith('~/')
    ? '"\$HOME"/${shellQuote(path.substring(2))}'
    : shellQuote(path);

/// One shell word.
String shellQuote(String word) => "'${word.replaceAll("'", r"'\''")}'";

/// A name for a skill or an agent: letters, digits, `-_.`, not hidden.
bool plainName(String name) =>
    name.isNotEmpty &&
    name.length <= 64 &&
    !name.startsWith('.') &&
    RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(name);

/// A home-relative folder without `..`: what an agent entry may name.
bool homeFolder(String path) =>
    path.startsWith('~/') &&
    !path.split('/').contains('..') &&
    !path.contains('\n');

/// Today as YYYY-MM-DD (UTC), for the folders moved-aside copies go to.
String civilDate([DateTime? now]) =>
    (now ?? DateTime.now().toUtc()).toIso8601String().substring(0, 10);

/// Seconds since 1970.
int unixNow() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// Runs a POSIX shell script; stdout and stderr come back apart.
Future<ProcessResult> runShell(
  String script, {
  Duration timeout = const Duration(minutes: 1),
  String? workingDirectory,
  String? home,
}) async {
  final process = await Process.start(
    'sh',
    ['-c', script],
    workingDirectory: workingDirectory,
    // The script's `$HOME` is the home this run works in.
    environment: home == null ? null : {'HOME': home},
  );
  await process.stdin.close();
  final stdoutText = process.stdout
      .transform(const Utf8Decoder(allowMalformed: true))
      .join();
  final stderrText = process.stderr
      .transform(const Utf8Decoder(allowMalformed: true))
      .join();
  final code = await process.exitCode.timeout(
    timeout,
    onTimeout: () {
      process.kill();
      return 124;
    },
  );
  return ProcessResult(process.pid, code, await stdoutText, await stderrText);
}

/// Writes [text] to [path] through a temporary file, so a reader never
/// sees half a file.
void writeAtomically(String path, String text) {
  final file = File(path);
  file.parent.createSync(recursive: true);
  final temporary = File('$path.tmp-$pid');
  temporary.writeAsStringSync(text);
  temporary.renameSync(path);
}
