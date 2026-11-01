import 'dart:io';

import '../services/harness_catalog.dart';
import 'harnesses_command.dart';
import 'usage_command.dart';
import 'version.dart';

String get cliHelp {
  final ids = HarnessCatalog.definitions.map((d) => d.id).join(', ');
  return '''
fluttairbar-cli: AI tools on this device, read-only unless you ask.

Usage:
  fluttairbar-cli harnesses [--json] [--only ID,ID] [--update] [--sync-codex-daemon]
  fluttairbar-cli usage [--json]
  fluttairbar-cli version
  fluttairbar-cli --help

Commands:
  harnesses  Allowlisted AI command-line tools: installed version, latest
             release, update source and redacted config files. Nothing is
             changed without a flag. --update installs verified releases
             (npm and GitHub releases must be 14 days old); --sync-codex-daemon
             syncs Codex to its self-updating background daemon.
  usage      Codex, Claude and Cursor usage windows from the sessions already
             on this device. --json prints schema fluttairbar.usage.v1.
             Never prints tokens, emails or account ids, and never rewrites
             a credentials file.
  version    Print the version.

Harness ids: $ids

Exit codes: 0 done (also when a provider is signed out), 1 an update or sync
failed, 64 wrong usage.
''';
}

/// Runs one command and returns the process exit code.
Future<int> runCli(
  List<String> args, {
  StringSink? out,
  StringSink? err,
}) async {
  final output = out ?? stdout;
  final errors = err ?? stderr;
  if (args.isEmpty) {
    errors.write(cliHelp);
    return 64;
  }
  final command = args.first;
  final rest = args.sublist(1);
  if (command == '--help' ||
      command == '-h' ||
      command == 'help' ||
      rest.contains('--help') ||
      rest.contains('-h')) {
    output.write(cliHelp);
    return 0;
  }
  switch (command) {
    case 'harnesses':
      return runHarnessesCommand(rest, out: output, err: errors);
    case 'usage':
      return runUsageCommand(rest, out: output, err: errors);
    case 'version':
    case '--version':
      output.writeln('fluttairbar-cli $fluttairbarVersion');
      return 0;
  }
  errors.writeln('Unknown command: $command');
  errors.write(cliHelp);
  return 64;
}
