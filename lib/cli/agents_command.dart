import 'dart:convert';
import 'dart:io';

import '../agents/conversations.dart' as conversations;
import '../agents/local.dart';
import '../agents/quiz.dart';
import '../agents/skill_settings.dart';
import '../agents/skills.dart';
import '../agents/toml_lite.dart';

/// The flags the agent-management commands share. The grammar is the one
/// fleet tools use: `--format json` (or `--json`, `-o json`), `-y` approves a
/// change, `-n` shows its plan and changes nothing; without `-y` and without
/// a terminal to ask on, a change says what it would do and exits 3.
class AgentOptions {
  bool json = false;
  bool withText = false;
  bool yes = false;
  bool dryRun = false;
  bool all = false;
  bool replace = false;
  String? agent;
  String? settings;
  int? bwlimit;
  final rsh = <String, String>{};
  final hosts = <String, String>{};
  final words = <String>[];
}

/// A command that ends with an exit code: 1 failed, 3 needs approval, 64
/// wrong usage; 0 for a dry run that said what it would do.
class CliFailure implements Exception {
  CliFailure(this.exit, this.message, {this.hint});
  final int exit;
  final String message;
  final String? hint;
}

const _needsApprovalHint =
    'add -y to do it, or run it in a terminal to be asked';

AgentOptions parseAgentOptions(List<String> args) {
  final opts = AgentOptions();
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    String value() {
      if (i + 1 >= args.length) throw CliFailure(64, '$arg needs a value');
      return args[++i];
    }

    (String, String) pair() {
      final text = value();
      final at = text.indexOf('=');
      if (at <= 0 || !plainName(text.substring(0, at))) {
        throw CliFailure(64, '$arg takes NAME=VALUE');
      }
      return (text.substring(0, at), text.substring(at + 1));
    }

    switch (arg) {
      case '--json' || '-ojson' || '--format=json':
        opts.json = true;
      case '--format' || '-o':
        final format = value();
        if (format != 'json' && format != 'text') {
          throw CliFailure(64, '$arg takes json or text');
        }
        opts.json = format == 'json';
      case '--format=text':
        opts.json = false;
      case '--with-text':
        opts.withText = true;
      case '-y' || '--yes':
        opts.yes = true;
      case '-n' || '--dry-run':
        opts.dryRun = true;
      case '--all':
        opts.all = true;
      case '--replace':
        opts.replace = true;
      case '--agent':
        opts.agent = value();
        if (!plainName(opts.agent!)) {
          throw CliFailure(64, '"${opts.agent}" is not an agent id');
        }
      case '--settings':
        opts.settings = value();
      case '--bwlimit':
        final limit = int.tryParse(value());
        if (limit == null || limit < 0) {
          throw CliFailure(64, '--bwlimit takes KB/s (0 = none)');
        }
        opts.bwlimit = limit;
      case '--rsh':
        final (name, command) = pair();
        opts.rsh[name] = command;
      case '--host':
        final (name, host) = pair();
        if (host.isEmpty || RegExp('[\\s:\'"]').hasMatch(host)) {
          throw CliFailure(64, '--host $name takes USER@HOST or HOST');
        }
        opts.hosts[name] = host;
      default:
        if (arg.startsWith('-') && arg.length > 1) {
          throw CliFailure(64, 'unknown option $arg');
        }
        opts.words.add(arg);
    }
  }
  return opts;
}

/// Whether a person can be asked here.
typedef Asker = Future<bool> Function(String question);

Future<bool> _askInTerminal(String question) async {
  if (!stdin.hasTerminal || !stderr.hasTerminal) {
    throw CliFailure(
      3,
      'not done: it needs approval',
      hint: _needsApprovalHint,
    );
  }
  stderr.write('$question [y/N] ');
  final answer = (stdin.readLineSync() ?? '').trim().toLowerCase();
  return ['y', 'yes', 'j', 'ja'].contains(answer);
}

/// The one question before a change: `-n` says what it would do (and the
/// command ends with exit 0), `-y` answers yes, a terminal is asked, and
/// without one the command says what it would do and ends with exit 3.
Future<void> approve(
  AgentOptions opts,
  String question,
  StringSink err,
  Asker ask,
) async {
  final plan = question.split('?').first.trim();
  if (opts.dryRun) {
    err.writeln('dry run, would: $plan');
    throw CliFailure(0, 'dry run: nothing changed');
  }
  if (opts.yes) return;
  try {
    if (await ask(question)) return;
  } on CliFailure {
    err.writeln('needs approval: $plan');
    rethrow;
  }
  throw CliFailure(1, 'nothing changed');
}

void _emit(
  AgentOptions opts,
  StringSink out,
  Map<String, Object?> json,
  String text,
) {
  if (opts.json) {
    out.writeln(
      const JsonEncoder.withIndent(
        '  ',
      ).convert(opts.withText ? {...json, 'text': text} : json),
    );
  } else if (text.isNotEmpty) {
    out.writeln(text);
  }
}

/// Runs one agent-management command and turns its failure into the exit
/// code and, with `--format json`, `{"error": {...}}` on stdout.
Future<int> _guard(
  List<String> args,
  StringSink out,
  StringSink err,
  Future<void> Function(AgentOptions opts) body,
) async {
  AgentOptions? opts;
  try {
    opts = parseAgentOptions(args);
    await body(opts);
    return 0;
  } on Object catch (error) {
    final failure = switch (error) {
      CliFailure failure => failure,
      SkillsError(:final message) ||
      QuizError(:final message) ||
      conversations.ConversationsError(:final message) ||
      TomlError(:final message) => CliFailure(1, message),
      StateError(:final message) => CliFailure(1, message),
      FileSystemException(:final message, :final path) => CliFailure(
        1,
        '${path ?? ''}: $message',
      ),
      _ => CliFailure(1, '$error'),
    };
    if (failure.exit == 0) return 0;
    final json = opts?.json ?? wantsJson(args);
    if (json) {
      out.writeln(
        jsonEncode({
          'error': {
            'code': switch (failure.exit) {
              3 => 'needs-approval',
              64 => 'usage',
              _ => 'failed',
            },
            'exit': failure.exit,
            'message': failure.message,
            'hint': failure.hint,
          },
        }),
      );
    } else if (failure.exit == 3) {
      err.writeln('not done: ${failure.hint ?? failure.message}');
    } else {
      err.writeln('error: ${failure.message}');
    }
    return failure.exit;
  }
}

/// Whether the words ask for JSON, also when they could not be read.
bool wantsJson(List<String> args) {
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--json' || arg == '-ojson' || arg == '--format=json') {
      return true;
    }
    if ((arg == '--format' || arg == '-o') &&
        i + 1 < args.length &&
        args[i + 1] == 'json') {
      return true;
    }
  }
  return false;
}

SkillSettings _loadSkills(SettingsStore store) {
  try {
    return SkillSettings.parse(store.read());
  } on TomlError catch (error) {
    throw CliFailure(1, '${store.path}: ${error.message}');
  }
}

/// `fluttairbar-cli skills ...`.
Future<int> runSkillsCommand(
  List<String> args, {
  required StringSink out,
  required StringSink err,
  Local? local,
  Asker? ask,
}) => _guard(args, out, err, (opts) async {
  final here = local ?? Local.system();
  final asker = ask ?? _askInTerminal;
  if (Platform.isWindows) {
    throw CliFailure(
      1,
      'agent skill folders are read on Linux and macOS devices',
    );
  }
  final store = SettingsStore(here, given: opts.settings);
  final settings = _loadSkills(store);
  final List<AgentDef> table;
  try {
    table = settings.agentTable();
  } on TomlError catch (error) {
    throw CliFailure(1, '${store.path}: ${error.message}');
  }
  Future<Map<String, Object?>> report() async => buildReport(
    device: here.device,
    collections: settings.collections,
    off: settings.off,
    shared: settings.instructions,
    table: table,
    probe: await probeDevice(
      here,
      settings.collections,
      table,
      settings.instructions,
    ),
    settings: store.fromStdin ? '-' : store.path,
  );
  final words = opts.words;
  final command = words.isEmpty ? 'status' : words.first;
  final rest = words.skip(1).toList();
  void expectWords(int count, String usage) {
    if (rest.length != count) throw CliFailure(64, 'usage: $usage');
  }

  switch (command) {
    case 'status':
      expectWords(0, 'fluttairbar-cli skills [--format json]');
      final shown = await report();
      _emit(opts, out, shown, textReport(shown));
    case 'settings':
      expectWords(0, 'fluttairbar-cli skills settings [--format json]');
      final content = store.read();
      _emit(
        opts,
        out,
        {
          'schema_version': skillsSchema,
          'path': store.fromStdin ? '-' : store.path,
          'exists': store.exists,
          'own': store.fromStdin ? '-' : store.given ?? store.ownPath,
          'content': content,
        },
        content.isEmpty
            ? '# no settings yet; they go in ${store.given ?? store.ownPath}'
            : content.trimRight(),
      );
    case 'install':
      final plan = installPlan(
        device: here.device,
        report: await report(),
        settings: settings,
        table: table,
        names: rest,
        all: opts.all,
        agent: opts.agent,
        replace: opts.replace,
      );
      if (plan.steps.isEmpty) {
        _emit(opts, out, plan.toJson(), textPlan(plan));
        return;
      }
      if (!opts.json) out.writeln(textPlan(plan));
      try {
        await approve(opts, plan.question, err, asker);
      } on CliFailure catch (failure) {
        if (failure.exit == 0 && opts.json) {
          _emit(opts, out, plan.toJson(), textPlan(plan));
        }
        rethrow;
      }
      final done = await runPlan(here, plan);
      _emit(opts, out, done, textDone(done));
    case 'add':
      expectWords(1, 'fluttairbar-cli skills add ~/PATH|URL');
      final target = addTarget(here, rest.first);
      await approve(opts, addQuestion(here.device, target), err, asker);
      final added = await addCollection(
        local: here,
        store: store,
        settings: settings,
        target: target,
      );
      _emit(opts, out, added, added['detail'] as String);
    case 'remove':
      expectWords(1, 'fluttairbar-cli skills remove ~/PATH');
      await approve(
        opts,
        'Unregister the skill collection ${here.tilde(rest.first)} (its skills and links stay)?',
        err,
        asker,
      );
      final removed = removeCollection(
        local: here,
        store: store,
        settings: settings,
        source: rest.first,
      );
      _emit(opts, out, removed, removed['detail'] as String);
    case 'on' || 'off':
      expectWords(1, 'fluttairbar-cli skills $command SKILL [--agent ID]');
      final on = command == 'on';
      final who = opts.agent ?? 'every agent';
      await approve(
        opts,
        on
            ? 'Switch skill ${rest.first} on for $who on this device and link it?'
            : 'Switch skill ${rest.first} off for $who on this device (its link goes, the skill stays)?',
        err,
        asker,
      );
      final switched = await switchSkill(
        local: here,
        store: store,
        settings: settings,
        report: await report(),
        name: rest.first,
        agent: opts.agent,
        on: on,
        freshReport: report,
      );
      _emit(opts, out, switched, (switched['lines'] as List).join('\n'));
    default:
      throw CliFailure(
        64,
        'unknown skills command "$command": status, settings, install, add, remove, on, off',
      );
  }
});

/// `fluttairbar-cli quiz [--agent ID]`.
Future<int> runQuizCommand(
  List<String> args, {
  required StringSink out,
  required StringSink err,
  Local? local,
}) => _guard(args, out, err, (opts) async {
  if (opts.words.isNotEmpty) {
    throw CliFailure(64, 'usage: fluttairbar-cli quiz [--agent ID]');
  }
  final here = local ?? Local.system();
  final store = SettingsStore(here, given: opts.settings);
  final report = await runQuiz(
    local: here,
    settings: _loadSkills(store),
    only: opts.agent,
  );
  _emit(opts, out, report, textQuiz(report));
  final failed = report['failed'] as int;
  if (failed > 0) {
    throw CliFailure(
      1,
      '$failed answer(s) not as expected: the instructions file is missing something, or an agent does not read it',
    );
  }
});

/// `fluttairbar-cli conversations [pack|copy]`.
Future<int> runConversationsCommand(
  List<String> args, {
  required StringSink out,
  required StringSink err,
  Local? local,
}) => _guard(args, out, err, (opts) async {
  final here = local ?? Local.system();
  final store = SettingsStore(
    here,
    given: opts.settings,
    name: 'conversations.toml',
  );
  final settings = conversations.loadConversationSettings(store);
  final command = opts.words.isEmpty ? 'status' : opts.words.first;
  if (opts.words.length > 1) {
    throw CliFailure(64, 'usage: fluttairbar-cli conversations [pack|copy]');
  }
  switch (command) {
    case 'status':
      final report = conversations.status(here, settings);
      report['settings'] = store.fromStdin ? '-' : store.path;
      _emit(opts, out, report, conversations.textStatus(report));
    case 'pack':
      if (opts.dryRun) {
        err.writeln('dry run, would: pack this device\'s history');
        return;
      }
      final report = await conversations.pack(here, settings);
      _emit(opts, out, report, conversations.textPack(report));
    case 'copy':
      final names = {...opts.rsh.keys, ...opts.hosts.keys};
      final report = await conversations.copy(
        local: here,
        settings: settings,
        execute: !opts.dryRun,
        bwlimit: opts.bwlimit,
        reach: {
          for (final name in names)
            name: conversations.Reach(
              opts.rsh[name] ?? conversations.defaultRsh,
              opts.hosts[name] ?? name,
            ),
        },
      );
      _emit(opts, out, report, conversations.textCopy(report));
    default:
      throw CliFailure(
        64,
        'unknown conversations command "$command": status, pack, copy',
      );
  }
});
