import 'dart:io';

import '../services/harness_catalog.dart';
import 'agents_command.dart';
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
  fluttairbar-cli skills [settings] [--json]
  fluttairbar-cli skills install (SKILL... | --all) [--agent ID] [--replace] [-y|-n]
  fluttairbar-cli skills add ~/PATH|URL [-y|-n]
  fluttairbar-cli skills remove ~/PATH [-y|-n]
  fluttairbar-cli skills on|off SKILL [--agent ID] [-y|-n]
  fluttairbar-cli hooks [--json]
  fluttairbar-cli hooks install (HOOK... | --all) [--replace] [-y|-n]
  fluttairbar-cli hooks remove HOOK... [-y|-n]
  fluttairbar-cli hooks add ~/PATH [-y|-n]
  fluttairbar-cli quiz [--agent ID] [--json]
  fluttairbar-cli conversations [pack | copy [-n]] [--json]
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
  skills     Agent skills (folders with a SKILL.md) from collections listed
             in ~/.config/fluttairbar/skills.toml, linked into every coding
             agent here (Claude Code, Codex, OpenCode, Pi, Cursor Agent, more
             with [[agent]]): per skill and agent linked, via another folder
             the agent reads, a copy, off or missing, and how often each
             agent loaded it in the last 30 days. `instructions` in the
             settings names one file linked as every agent's global
             instructions. install links (a folder in the way is moved to
             ~/.local/share/fluttairbar/retired only with --replace), add
             registers a folder or clones a git URL into ~/Documents/github,
             remove unregisters (folders and links stay), off removes one
             agent's link and keeps the skill out of install --all, on
             links it again. settings prints the settings in use;
             --settings FILE (- for standard input) reads others, read
             only for -.
  hooks      Agent hooks declared in a hooks.toml in each folder listed in
             ~/.config/fluttairbar/hooks.toml, per agent here: installed,
             missing, different (its command with another event, matcher
             or timeout) or no hooks (an agent without hook settings).
             install adds a hook to its agent's settings once (Claude Code:
             ~/.claude/settings.json), remove takes it out; both keep a
             dated copy (FILE.bak-DATE), change nothing else and refuse a
             result that does not read back as intended. --replace puts a
             different one as hooks.toml says. add registers a folder.
  quiz       Asks every agent here with an ask line the questions in
             quiz.txt beside the shared instructions, in a fresh session
             from an empty folder with no tools, and checks the answers.
             Uses the agents' own subscriptions: run it when you mean it.
  conversations
             Claude Code and Codex history, kept: pack writes a slim copy to
             ~/Backups/conversations/DEVICE (every word, screenshots left
             out, gzip, only changed files, never deletes); copy packs both
             devices of each [[pair]] in ~/.config/fluttairbar/
             conversations.toml and rsyncs each side to the other over SSH,
             never --delete (--rsh NAME=COMMAND and --host NAME=USER@HOST
             say how to reach a device, --pack NAME=COMMAND what packs
             there when fluttairbar-cli is not installed on it, --bwlimit
             KBPS caps it when the settings set none).
  version    Print the version.

JSON: --json, --format json or -o json. A change asks first: -y approves it,
-n shows what it would do and changes nothing, and without a terminal to ask
on it stops with exit 3. --with-text adds the text view to the JSON.

Harness ids: $ids

Exit codes: 0 done (also when a provider is signed out), 1 failed (an update,
a sync, a change, or a quiz answer not as expected), 3 needs approval, 64
wrong usage.
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
  // `--format json` and `-o json` mean `--json` for every command.
  final rest = <String>[];
  for (var i = 1; i < args.length; i++) {
    final arg = args[i];
    if ((arg == '--format' || arg == '-o') &&
        i + 1 < args.length &&
        args[i + 1] == 'json') {
      rest.add('--json');
      i++;
    } else if (arg == '--format=json' || arg == '-ojson') {
      rest.add('--json');
    } else {
      rest.add(arg);
    }
  }
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
    case 'skills':
      return runSkillsCommand(rest, out: output, err: errors);
    case 'hooks':
      return runHooksCommand(rest, out: output, err: errors);
    case 'quiz':
      return runQuizCommand(rest, out: output, err: errors);
    case 'conversations':
      return runConversationsCommand(rest, out: output, err: errors);
    case 'version':
    case '--version':
      output.writeln('fluttairbar-cli $fluttairbarVersion');
      return 0;
  }
  errors.writeln('Unknown command: $command');
  errors.write(cliHelp);
  return 64;
}
