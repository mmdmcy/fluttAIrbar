/// The coding agents that read Agent Skills (folders with a SKILL.md,
/// https://agentskills.io) and the settings of `fluttairbar-cli skills`:
/// which collections to link, which skills are off for which agent, the one
/// instructions file every agent should start with, and agents added to the
/// built-in table.
library;

import 'dart:io';

import 'local.dart';
import 'toml_lite.dart';

/// One coding agent that reads SKILL.md folders.
class AgentDef {
  const AgentDef({
    required this.id,
    required this.name,
    required this.dir,
    this.reads = const [],
    this.instructions = '',
    this.history = '',
    this.loaded = '',
    this.ask = const [],
    this.hooks = '',
  });

  /// Short name for `--agent` and the settings.
  final String id;

  /// What people call it.
  final String name;

  /// Where skills are linked for it (home-relative); the agent counts as on
  /// a device when this folder's parent exists.
  final String dir;

  /// Other folders it also reads skills from, so a skill linked there needs
  /// no link of its own (checked, not assumed).
  final List<String> reads;

  /// The file it reads in every session, whatever folder it starts in.
  final String instructions;

  /// Where its sessions are kept, for "used lately".
  final String history;

  /// `grep -E` pattern for a session line that loaded a skill; it ends in
  /// the skill's folder or in /SKILL.md.
  final String loaded;

  /// How to ask it one question in a fresh session with no tools (the
  /// quiz): the command and its arguments, `{question}` for the question,
  /// `{out}` for a file it writes its final answer to.
  final List<String> ask;

  /// Its hook settings (home-relative): a JSON file with a `hooks` object in
  /// Claude Code's shape. Empty: the agent has no hooks (`fluttairbar-cli
  /// hooks` says so and never guesses one).
  final String hooks;

  factory AgentDef.fromToml(Map<String, Object?> table) {
    final id = tomlText(table['id'], 'agent id');
    return AgentDef(
      id: id,
      name: tomlText(table['name'], 'agent $id name'),
      dir: tomlText(table['dir'], 'agent $id dir'),
      reads: tomlStrings(table['reads'], 'agent $id reads'),
      instructions: tomlText(table['instructions'], 'agent $id instructions'),
      history: tomlText(table['history'], 'agent $id history'),
      loaded: tomlText(table['loaded'], 'agent $id loaded'),
      ask: tomlStrings(table['ask'], 'agent $id ask'),
      hooks: tomlText(table['hooks'], 'agent $id hooks'),
    );
  }

  List<String> toToml() => [
    '[[agent]]',
    tomlLine('id', id),
    tomlLine('name', name),
    tomlLine('dir', dir),
    if (reads.isNotEmpty) tomlLine('reads', reads),
    if (instructions.isNotEmpty) tomlLine('instructions', instructions),
    if (history.isNotEmpty) tomlLine('history', history),
    if (ask.isNotEmpty) tomlLine('ask', ask),
    if (loaded.isNotEmpty) tomlLine('loaded', loaded),
    if (hooks.isNotEmpty) tomlLine('hooks', hooks),
  ];
}

/// The built-in table; `[[agent]]` in the settings adds one or replaces one
/// by id.
const builtinAgents = [
  AgentDef(
    id: 'claude',
    name: 'Claude Code',
    dir: '~/.claude/skills',
    instructions: '~/.claude/CLAUDE.md',
    history: '~/.claude/projects',
    ask: [
      'claude',
      '-p',
      '{question}',
      '--max-turns',
      '1',
      '--disallowedTools',
      'Bash,Read,Edit,Write,Grep,Glob,WebFetch,WebSearch,Task',
      // A quiz answer is not a conversation to keep in the history.
      '--no-session-persistence',
    ],
    // Claude Code writes this line into the session when it loads a skill.
    loaded: r'Base directory for this skill: [^"\\]*',
    hooks: '~/.claude/settings.json',
  ),
  AgentDef(
    id: 'codex',
    name: 'Codex',
    dir: '~/.codex/skills',
    instructions: '~/.codex/AGENTS.md',
    history: '~/.codex/sessions',
    ask: [
      'codex',
      'exec',
      // A quiz answer is not a conversation to keep in the history.
      '--ephemeral',
      '--skip-git-repo-check',
      '--sandbox',
      'read-only',
      '--output-last-message',
      '{out}',
      '{question}',
    ],
    // Codex lists every skill in its instructions, so only a command that
    // read the SKILL.md counts.
    loaded:
        r'(sed|cat|head|nl|less|bat|rg|Get-Content)[^"]{0,80}/skills/[A-Za-z0-9._-]+/SKILL\.md',
  ),
  AgentDef(
    id: 'opencode',
    name: 'OpenCode',
    dir: '~/.config/opencode/skills',
    // `opencode debug skill` lists ~/.claude/skills.
    reads: ['~/.claude/skills'],
    instructions: '~/.config/opencode/AGENTS.md',
  ),
  AgentDef(
    id: 'pi',
    name: 'Pi',
    dir: '~/.pi/agent/skills',
    reads: ['~/.agents/skills'],
    instructions: '~/.pi/agent/AGENTS.md',
    history: '~/.pi/agent/sessions',
    // Pi's read tool names the file it opens.
    loaded: r'"path":"[^"]*/skills/[A-Za-z0-9._-]+/SKILL\.md',
  ),
  AgentDef(id: 'cursor', name: 'Cursor Agent', dir: '~/.cursor/skills'),
];

/// The settings file, as read.
class SkillSettings {
  SkillSettings({
    List<String>? collections,
    Map<String, List<String>>? off,
    this.instructions = '',
    List<AgentDef>? agents,
  }) : collections = collections ?? [],
       off = off ?? {},
       agents = agents ?? [];

  /// Folders of skills, home-relative so the same list holds on every
  /// device.
  final List<String> collections;

  /// Per agent, the collection skills switched off for it: not linked by
  /// `install`, shown as `off`.
  final Map<String, List<String>> off;

  /// One instructions file for every agent (home-relative), linked as each
  /// agent's own by `install --all`.
  String instructions;

  /// Agents added to the built-in table, or replacing one by id.
  final List<AgentDef> agents;

  factory SkillSettings.parse(String text) {
    final toml = parseToml(text);
    final known = {'collections', 'off', 'instructions', 'agent'};
    final unknown = toml.keys.where((key) => !known.contains(key));
    if (unknown.isNotEmpty) {
      throw TomlError('unknown setting ${unknown.join(', ')}');
    }
    final off = <String, List<String>>{};
    final table = toml['off'];
    if (table != null && table is! Map<String, Object?>) {
      throw TomlError('off should be a table: [off] AGENT = ["SKILL"]');
    }
    for (final entry in (table as Map<String, Object?>? ?? {}).entries) {
      off[entry.key] = tomlStrings(entry.value, 'off.${entry.key}');
    }
    final agents = toml['agent'];
    if (agents != null && agents is! List<Map<String, Object?>>) {
      throw TomlError('agent should be [[agent]] tables');
    }
    return SkillSettings(
      collections: tomlStrings(toml['collections'], 'collections'),
      off: off,
      instructions: tomlText(toml['instructions'], 'instructions'),
      agents: [
        for (final agent in agents as List<Map<String, Object?>>? ?? [])
          AgentDef.fromToml(agent),
      ],
    );
  }

  String toToml() {
    final lines = [
      '# Collections of agent skills (folders of SKILL.md folders), home-relative so',
      '# the same list holds on every device. `fluttairbar-cli skills`.',
      tomlLine('collections', collections),
      if (instructions.isNotEmpty) tomlLine('instructions', instructions),
    ];
    final offEntries = off.entries.where((entry) => entry.value.isNotEmpty);
    if (offEntries.isNotEmpty) {
      lines
        ..add('')
        ..add('[off]');
      for (final entry in offEntries) {
        lines.add(tomlLine(entry.key, entry.value));
      }
    }
    for (final agent in agents) {
      lines
        ..add('')
        ..addAll(agent.toToml());
    }
    return '${lines.join('\n')}\n';
  }

  /// The agent table: the built-in one, then these settings' entries (the
  /// same id replaces). Entries naming odd ids or folders are refused.
  List<AgentDef> agentTable() {
    final table = [...builtinAgents];
    for (final extra in agents) {
      if (!plainName(extra.id) ||
          !homeFolder(extra.dir) ||
          extra.reads.any((dir) => !homeFolder(dir)) ||
          (extra.history.isNotEmpty && !homeFolder(extra.history)) ||
          (extra.hooks.isNotEmpty && !homeFolder(extra.hooks)) ||
          (extra.instructions.isNotEmpty && !homeFolder(extra.instructions))) {
        throw TomlError(
          'agent "${extra.id}" needs a plain id and home-relative folders (~/...)',
        );
      }
      final at = table.indexWhere((agent) => agent.id == extra.id);
      if (at >= 0) {
        table[at] = extra;
      } else {
        table.add(extra);
      }
    }
    return table;
  }
}

/// Where the settings come from: this tool's own file, or standard input
/// (`--settings -`, read only: a caller applies another device's settings
/// here).
class SettingsStore {
  SettingsStore(this.local, {this.given, this.name = 'skills.toml'});

  final Local local;

  /// `--settings FILE`, `-` for standard input.
  final String? given;
  final String name;
  String? _stdin;

  String get ownPath => '${local.configHome}/fluttairbar/$name';

  bool get fromStdin => given == '-';

  /// The file read now: the one given, or this tool's own.
  String get path => given ?? ownPath;

  /// The settings text, empty when there is no file.
  String read() {
    if (fromStdin) return _stdin ??= _readStdin();
    final file = File(path);
    if (!file.existsSync()) return '';
    return file.readAsStringSync();
  }

  bool get exists => fromStdin || File(path).existsSync();

  /// Writes this tool's own file (or the one given).
  void write(String text) {
    if (fromStdin) {
      throw StateError(
        'these settings came from standard input; change them on the device they belong to',
      );
    }
    writeAtomically(given ?? ownPath, text);
  }

  static String _readStdin() {
    final lines = <String>[];
    String? line;
    while ((line = stdin.readLineSync()) != null) {
      lines.add(line!);
    }
    return lines.join('\n');
  }
}
