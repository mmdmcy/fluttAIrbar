/// `fluttairbar-cli hooks`: hooks from registered collections, added to the
/// coding agents' own settings on this device.
///
/// A hook collection is a folder with a `hooks.toml` that declares its
/// hooks: a name, the agent that runs it, the event, the command. The
/// collections are listed home-relative in this tool's own `hooks.toml`
/// settings, so the same list holds on every device. An agent has hooks when
/// the agent table (skill_settings.dart, `[[agent]]` in skills.toml) names
/// its hook settings file, a JSON file with a `hooks` object in Claude Code's
/// shape (event → matcher groups → command hooks); an agent without one has
/// no hooks, and nothing is guessed for it.
///
/// A hook is known in an agent's settings by its command. `install` adds it
/// once, `remove` takes every entry of that command out; both keep a dated
/// copy of the file next to it, change nothing else in it, and refuse to
/// write a result that does not read back as intended.
library;

import 'dart:convert';
import 'dart:io';

import 'local.dart';
import 'skill_settings.dart';
import 'toml_lite.dart';

const hooksSchema = 'fluttairbar.hooks.v1';

/// The file in a collection that declares its hooks.
const hooksFile = 'hooks.toml';

class HooksError implements Exception {
  HooksError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// One hook a collection declares.
class HookDef {
  HookDef({
    required this.collection,
    required this.name,
    required this.agent,
    required this.event,
    required this.command,
    this.matcher = '',
    this.timeout,
    this.description = '',
  });

  final String collection;
  final String name;

  /// The agent id that runs it (`claude`).
  final String agent;

  /// The agent's event name (`Stop`, `PreToolUse`, ...), as the agent spells
  /// it.
  final String event;

  /// The command, `{dir}` already replaced by the collection's folder.
  final String command;

  /// Which tools a tool event applies to; empty for every one.
  final String matcher;

  /// Seconds the agent waits for it; null leaves the agent's default.
  final int? timeout;
  final String description;

  Map<String, Object?> toJson() => {
    'name': name,
    'collection': collection,
    'agent': agent,
    'event': event,
    'matcher': matcher,
    'command': command,
    'timeout': timeout,
    'description': description,
  };
}

/// Reads one collection's hooks.toml text. [dir] is the collection's folder
/// as registered (`~/...`), put in place of `{dir}` in a command.
List<HookDef> parseHooks(String text, String dir) {
  final toml = parseToml(text);
  final unknown = toml.keys.where((key) => key != 'hook');
  if (unknown.isNotEmpty) {
    throw TomlError(
      'unknown setting ${unknown.join(', ')}; hooks are [[hook]] tables',
    );
  }
  final tables = toml['hook'];
  if (tables != null && tables is! List<Map<String, Object?>>) {
    throw TomlError('hook should be [[hook]] tables');
  }
  const known = {
    'name',
    'agent',
    'event',
    'matcher',
    'command',
    'timeout',
    'description',
  };
  final hooks = <HookDef>[];
  for (final table in tables as List<Map<String, Object?>>? ?? []) {
    final name = tomlText(table['name'], 'hook name');
    if (!plainName(name)) {
      throw TomlError('hook "$name" needs a plain name (letters, digits, -_.)');
    }
    final odd = table.keys.where((key) => !known.contains(key));
    if (odd.isNotEmpty) {
      throw TomlError('hook $name: unknown setting ${odd.join(', ')}');
    }
    final agent = tomlText(table['agent'], 'hook $name agent');
    if (!plainName(agent)) {
      throw TomlError('hook $name needs the id of the agent that runs it');
    }
    final event = tomlText(table['event'], 'hook $name event');
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9_]*$').hasMatch(event)) {
      throw TomlError('hook $name needs an event name such as Stop');
    }
    var command = tomlText(table['command'], 'hook $name command').trim();
    if (command.isEmpty || command.contains('\n')) {
      throw TomlError('hook $name needs a command on one line');
    }
    if (command.contains('{dir}')) {
      // Put in as it is, so it must need no quoting.
      if (!RegExp(r'^~/[A-Za-z0-9._/-]+$').hasMatch(dir) ||
          dir.split('/').contains('..')) {
        throw TomlError(
          'hook $name: {dir} needs a folder path without spaces or quotes; write the command in full',
        );
      }
      command = command.replaceAll('{dir}', dir);
    }
    final timeout = table['timeout'];
    if (timeout != null && (timeout is! int || timeout <= 0)) {
      throw TomlError('hook $name: timeout is a number of seconds');
    }
    final matcher = tomlText(table['matcher'], 'hook $name matcher');
    if (matcher.contains('\n')) {
      throw TomlError('hook $name: a matcher on one line');
    }
    hooks.add(
      HookDef(
        collection: dir,
        name: name,
        agent: agent,
        event: event,
        command: command,
        matcher: _matcher(matcher),
        timeout: timeout as int?,
        description: tomlText(table['description'], 'hook $name description'),
      ),
    );
  }
  return hooks;
}

/// This tool's hooks settings: the registered collections.
class HookSettings {
  HookSettings({List<String>? collections}) : collections = collections ?? [];

  /// Folders with a hooks.toml, home-relative.
  final List<String> collections;

  factory HookSettings.parse(String text) {
    final toml = parseToml(text);
    final unknown = toml.keys.where((key) => key != 'collections');
    if (unknown.isNotEmpty) {
      throw TomlError('unknown setting ${unknown.join(', ')}');
    }
    return HookSettings(
      collections: tomlStrings(toml['collections'], 'collections'),
    );
  }

  String toToml() => [
    '# Collections of agent hooks (folders with a hooks.toml), home-relative so',
    '# the same list holds on every device. `fluttairbar-cli hooks`.',
    tomlLine('collections', collections),
    '',
  ].join('\n');
}

/// One registered collection, as found here.
class HookCollection {
  HookCollection(
    this.path,
    this.state, {
    this.error = '',
    this.hooks = const [],
  });
  final String path;

  /// `ok`, `missing` (no folder), `empty` (no hooks.toml, or no hook in it)
  /// or `error` (a hooks.toml that cannot be read).
  final String state;
  final String error;
  final List<HookDef> hooks;

  Map<String, Object?> toJson() => {
    'path': path,
    'state': state,
    if (error.isNotEmpty) 'error': error,
    'hooks': hooks.map((hook) => hook.name).toList(),
  };
}

/// Reads every registered collection; a name used twice is an error in the
/// later collection.
List<HookCollection> readCollections(Local local, List<String> paths) {
  final found = <HookCollection>[];
  final seen = <String, String>{};
  for (final path in paths) {
    final folder = Directory(local.expand(path));
    if (!folder.existsSync()) {
      found.add(HookCollection(path, 'missing'));
      continue;
    }
    final file = File('${folder.path}/$hooksFile');
    if (!file.existsSync()) {
      found.add(HookCollection(path, 'empty', error: 'no $hooksFile'));
      continue;
    }
    try {
      final hooks = parseHooks(file.readAsStringSync(), local.tilde(path));
      // A hook is known by its name here and by its command in an agent's
      // settings, so both are one of a kind.
      final mine = <String, String>{};
      for (final hook in hooks) {
        for (final key in ['name ${hook.name}', 'command ${hook.command}']) {
          final other = seen[key] ?? mine[key];
          if (other != null) {
            throw TomlError(
              'hook ${hook.name}: its ${key.split(' ').first} is also in ${other == path ? 'this file' : other}',
            );
          }
          mine[key] = path;
        }
      }
      seen.addAll(mine);
      found.add(
        HookCollection(path, hooks.isEmpty ? 'empty' : 'ok', hooks: hooks),
      );
    } on TomlError catch (error) {
      found.add(
        HookCollection(path, 'error', error: '$hooksFile: ${error.message}'),
      );
    } on FileSystemException catch (error) {
      found.add(
        HookCollection(path, 'error', error: '$hooksFile: ${error.message}'),
      );
    }
  }
  return found;
}

/// One hook as an agent's settings hold it.
class FoundHook {
  FoundHook(this.event, this.matcher, this.type, this.command, this.timeout);
  final String event;
  final String matcher;
  final String type;
  final String command;
  final Object? timeout;
}

/// No matcher, `""` and `*` all mean every tool.
String _matcher(Object? value) => value == null || value == '*' ? '' : '$value';

/// What is wrong with a settings `hooks` value for this tool to change it
/// safely, or null when nothing is.
String? hooksShapeProblem(Object? hooks) {
  if (hooks == null) return null;
  if (hooks is! Map) return 'its hooks are not an object';
  for (final entry in hooks.entries) {
    final groups = entry.value;
    if (groups is! List) return 'hooks.${entry.key} is not a list';
    for (final group in groups) {
      if (group is! Map || group['hooks'] is! List) {
        return 'hooks.${entry.key} has an entry without a hooks list';
      }
      if ((group['hooks'] as List).any((hook) => hook is! Map)) {
        return 'hooks.${entry.key} has a hook that is not an object';
      }
    }
  }
  return null;
}

/// Every hook in an agent's settings, in order.
List<FoundHook> foundHooks(Map<String, Object?> settings) {
  final hooks = settings['hooks'];
  if (hooks is! Map || hooksShapeProblem(hooks) != null) return [];
  return [
    for (final entry in hooks.entries)
      for (final group in entry.value as List)
        for (final hook in (group as Map)['hooks'] as List)
          FoundHook(
            '${entry.key}',
            _matcher(group['matcher']),
            '${(hook as Map)['type'] ?? ''}',
            hook['command'] is String ? hook['command'] as String : '',
            hook['timeout'],
          ),
  ];
}

/// `installed` (its command at its event and matcher, with its timeout),
/// `different` (its command elsewhere or with another timeout) or
/// `missing`.
String hookState(HookDef hook, List<FoundHook> found) {
  final same = found.where(
    (entry) => entry.type == 'command' && entry.command == hook.command,
  );
  if (same.any(
    (entry) =>
        entry.event == hook.event &&
        entry.matcher == hook.matcher &&
        entry.timeout == hook.timeout,
  )) {
    return 'installed';
  }
  return same.isEmpty ? 'missing' : 'different';
}

Map<String, Object?> _copy(Map<String, Object?> settings) =>
    jsonDecode(jsonEncode(settings)) as Map<String, Object?>;

/// The settings without any command hook running [command]. A matcher group
/// or an event left empty by that goes too; nothing else changes.
Map<String, Object?> withoutHook(
  Map<String, Object?> settings,
  String command,
) {
  final copy = _copy(settings);
  final hooks = copy['hooks'];
  if (hooks is! Map<String, Object?>) return copy;
  for (final event in hooks.keys.toList()) {
    final groups = hooks[event] as List;
    final kept = <Object?>[];
    var removed = false;
    for (final group in groups) {
      final entries = (group as Map<String, Object?>)['hooks'] as List;
      final left = entries
          .where(
            (hook) =>
                !(hook is Map &&
                    hook['type'] == 'command' &&
                    hook['command'] == command),
          )
          .toList();
      if (left.length == entries.length) {
        kept.add(group);
        continue;
      }
      removed = true;
      if (left.isNotEmpty) kept.add({...group, 'hooks': left});
    }
    if (!removed) continue;
    if (kept.isEmpty) {
      hooks.remove(event);
    } else {
      hooks[event] = kept;
    }
  }
  return copy;
}

/// The settings with [hook] added as a matcher group of its own at the end
/// of its event.
Map<String, Object?> withHook(Map<String, Object?> settings, HookDef hook) {
  final copy = _copy(settings);
  final hooks = (copy['hooks'] ??= <String, Object?>{}) as Map<String, Object?>;
  final groups = (hooks[hook.event] ??= <Object?>[]) as List;
  groups.add({
    if (hook.matcher.isNotEmpty) 'matcher': hook.matcher,
    'hooks': [
      {
        'type': 'command',
        'command': hook.command,
        if (hook.timeout != null) 'timeout': hook.timeout,
      },
    ],
  });
  return copy;
}

/// One agent here and its hook settings, as read.
class AgentHooks {
  AgentHooks(this.agent, {required this.present});
  final AgentDef agent;

  /// Whether the agent is on this device (its skills folder's parent is).
  final bool present;

  /// The file as read; empty when there is none.
  String text = '';
  bool exists = false;
  Map<String, Object?> settings = {};

  /// Why the file cannot be changed safely; empty when it can.
  String error = '';

  bool get hasHooks => agent.hooks.isNotEmpty;

  /// `none` (the agent has no hooks), `ok`, or `error`.
  String get state => !hasHooks
      ? 'none'
      : error.isNotEmpty
      ? 'error'
      : 'ok';
}

/// Reads the hook settings of every agent in [table]. Read-only.
List<AgentHooks> readAgents(Local local, List<AgentDef> table) {
  final agents = <AgentHooks>[];
  for (final def in table) {
    final present = Directory(local.expand(def.dir)).parent.existsSync();
    final entry = AgentHooks(def, present: present);
    agents.add(entry);
    if (!present || !entry.hasHooks) continue;
    final file = File(local.expand(def.hooks));
    if (!file.existsSync()) continue;
    try {
      entry
        ..exists = true
        ..text = file.readAsStringSync();
      final parsed = jsonDecode(entry.text);
      if (parsed is! Map<String, Object?>) {
        entry.error = '${def.hooks} is not a JSON object';
        continue;
      }
      entry.settings = parsed;
      final problem = hooksShapeProblem(parsed['hooks']);
      if (problem != null) entry.error = '${def.hooks}: $problem';
    } on FormatException catch (error) {
      entry.error = '${def.hooks} is not valid JSON (${error.message})';
    } on FileSystemException catch (error) {
      entry.error = '${def.hooks}: ${error.message}';
    }
  }
  return agents;
}

/// What is on the device: collections and agents.
class HooksProbe {
  HooksProbe(this.device, this.collections, this.agents);
  final String device;
  final List<HookCollection> collections;
  final List<AgentHooks> agents;

  List<HookDef> get hooks => [
    for (final collection in collections) ...collection.hooks,
  ];

  AgentHooks? agentOf(HookDef hook) =>
      agents.where((entry) => entry.agent.id == hook.agent).firstOrNull;

  /// `installed`, `different`, `missing`, `no hooks` (the agent has none),
  /// `not here` (the agent is not on this device), `unknown agent`, or
  /// `unreadable` (its settings cannot be read).
  String stateOf(HookDef hook) {
    final entry = agentOf(hook);
    if (entry == null) return 'unknown agent';
    if (!entry.hasHooks) return 'no hooks';
    if (!entry.present) return 'not here';
    if (entry.error.isNotEmpty) return 'unreadable';
    return hookState(hook, foundHooks(entry.settings));
  }
}

HooksProbe probeHooks(
  Local local,
  HookSettings settings,
  List<AgentDef> table,
) => HooksProbe(
  local.device,
  readCollections(local, settings.collections),
  readAgents(local, table),
);

/// The status report (`hooks`), schema [hooksSchema].
Map<String, Object?> hooksReport(HooksProbe probe, {String settings = ''}) {
  final hooks = probe.hooks;
  final known = hooks.map((hook) => hook.command).toSet();
  final here = probe.agents.where((entry) => entry.present).toList();
  final rows = [
    for (final hook in hooks)
      {
        ...hook.toJson(),
        'state': probe.stateOf(hook),
        'found': [
          for (final found in foundHooks(
            probe.agentOf(hook)?.settings ?? const {},
          ))
            if (found.type == 'command' && found.command == hook.command)
              {
                'event': found.event,
                'matcher': found.matcher,
                'timeout': found.timeout,
              },
        ],
      },
  ];
  final others = [
    for (final entry in here)
      for (final found in foundHooks(entry.settings))
        if (!known.contains(found.command))
          {
            'agent': entry.agent.id,
            'event': found.event,
            'matcher': found.matcher,
            'type': found.type,
            'command': found.command,
          },
  ];
  final installed = rows.where((row) => row['state'] == 'installed').length;
  final none = here.where((entry) => !entry.hasHooks).map((e) => e.agent.name);
  return {
    'schema_version': hooksSchema,
    'device': probe.device,
    'status': 'ok',
    'detail':
        '${probe.collections.where((c) => c.state == 'ok').length} collection(s), ${hooks.length} hook(s); $installed of ${hooks.length} installed${others.isEmpty ? '' : '; ${others.length} hook(s) from elsewhere'}${none.isEmpty ? '' : '; no hooks: ${none.join(', ')}'}',
    'collections': probe.collections.map((c) => c.toJson()).toList(),
    'agents': [
      for (final entry in here)
        {
          'agent': entry.agent.id,
          'name': entry.agent.name,
          'hooks_file': entry.agent.hooks,
          'state': entry.state,
          if (entry.hasHooks) 'exists': entry.exists,
          if (entry.error.isNotEmpty) 'error': entry.error,
        },
    ],
    'hooks': rows,
    'others': others,
    if (settings.isNotEmpty) 'settings': settings,
  };
}

/// One change to an agent's hook settings.
class HookStep {
  HookStep(this.hook, this.action);
  final HookDef hook;

  /// `add`, `replace` (take out its entries, then add) or `remove`.
  final String action;

  Map<String, Object?> toJson(String file) => {
    'hook': hook.name,
    'agent': hook.agent,
    'file': file,
    'action': action,
    'event': hook.event,
    'matcher': hook.matcher,
    'command': hook.command,
    'timeout': hook.timeout,
  };
}

class HookPlan {
  HookPlan({
    required this.device,
    required this.remove,
    required this.steps,
    required this.inPlace,
    required this.refused,
    required this.files,
  });
  final String device;
  final bool remove;
  final List<HookStep> steps;

  /// Already as asked: nothing to do.
  final List<String> inPlace;

  /// Not done and why.
  final List<String> refused;

  /// Agent id → its hook settings file (home-relative), for the steps.
  final Map<String, String> files;

  String get question {
    final touched = steps.map((step) => files[step.hook.agent]).toSet();
    return '${remove ? 'Take ${steps.length} hook(s) out of' : 'Add ${steps.length} hook(s) to'} ${touched.join(', ')} on $device (a dated copy is kept next to it)?';
  }

  Map<String, Object?> toJson() => {
    'schema_version': hooksSchema,
    'device': device,
    'action': remove ? 'remove' : 'install',
    'steps': [
      for (final step in steps) step.toJson(files[step.hook.agent] ?? ''),
    ],
    'in_place': inPlace,
    'refused': refused,
    'question': question,
  };
}

/// What `install` (or `remove`) would do here.
HookPlan hooksPlan({
  required HooksProbe probe,
  required HookSettings settings,
  required List<String> names,
  required bool all,
  bool remove = false,
  bool replace = false,
}) {
  if (!all && names.isEmpty) {
    throw HooksError(
      remove
          ? 'name the hook to take out'
          : 'name the hooks to install, or --all for every hook in every collection',
    );
  }
  if (settings.collections.isEmpty) {
    throw HooksError(
      'no hook collection registered: fluttairbar-cli hooks add ~/PATH (a folder with a $hooksFile)',
    );
  }
  final broken = probe.collections.where((c) => c.state == 'error');
  final hooks = probe.hooks;
  for (final name in names) {
    if (!plainName(name) || !hooks.any((hook) => hook.name == name)) {
      throw HooksError(
        'no hook "$name" in the collections on ${probe.device}; there: ${hooks.isEmpty ? 'none' : hooks.map((hook) => hook.name).join(', ')}${broken.isEmpty ? '' : ' (unreadable: ${broken.map((c) => '${c.path}: ${c.error}').join('; ')})'}',
      );
    }
  }
  final steps = <HookStep>[];
  final inPlace = <String>[];
  final refused = [
    for (final collection in broken) '${collection.path}: ${collection.error}',
  ];
  final files = <String, String>{};
  for (final hook in hooks.where((h) => all || names.contains(h.name))) {
    final state = probe.stateOf(hook);
    final entry = probe.agentOf(hook);
    final who = '${hook.agent}: ${hook.name}';
    switch (state) {
      case 'unknown agent':
        refused.add(
          '$who names an agent this tool does not know (add it with [[agent]] in skills.toml)',
        );
        continue;
      case 'no hooks':
        refused.add('$who: ${entry!.agent.name} has no hooks');
        continue;
      case 'not here':
        refused.add('$who: ${entry!.agent.name} is not on ${probe.device}');
        continue;
      case 'unreadable':
        refused.add('$who: ${entry!.error}; nothing changed in it');
        continue;
    }
    files[hook.agent] = entry!.agent.hooks;
    if (remove) {
      if (state == 'missing') {
        inPlace.add('$who is not in ${entry.agent.hooks}');
      } else {
        steps.add(HookStep(hook, 'remove'));
      }
    } else if (state == 'installed') {
      inPlace.add(who);
    } else if (state == 'missing') {
      steps.add(HookStep(hook, 'add'));
    } else if (replace) {
      steps.add(HookStep(hook, 'replace'));
    } else {
      refused.add(
        '$who: its command is in ${entry.agent.hooks} with another event, matcher or timeout; add --replace to put it as $hooksFile says',
      );
    }
  }
  return HookPlan(
    device: probe.device,
    remove: remove,
    steps: steps,
    inPlace: inPlace,
    refused: refused,
    files: files,
  );
}

/// `FILE.bak-DATE`, or `-2`, `-3`, ... when that is taken: every change
/// keeps the file as it was before it.
String backupPath(String path, String date) {
  var candidate = '$path.bak-$date';
  for (
    var n = 2;
    FileSystemEntity.typeSync(candidate, followLinks: false) !=
        FileSystemEntityType.notFound;
    n++
  ) {
    candidate = '$path.bak-$date-$n';
  }
  return candidate;
}

/// Runs an approved plan: per settings file, check it is still as read,
/// apply the steps, check the result, keep a copy, write it in one go.
Map<String, Object?> runHooksPlan(
  Local local,
  HooksProbe probe,
  HookPlan plan, {
  String? today,
}) {
  final date = today ?? civilDate();
  final changed = <Map<String, Object?>>[];
  for (final agentId in plan.files.keys) {
    final steps = plan.steps.where((s) => s.hook.agent == agentId).toList();
    if (steps.isEmpty) continue;
    final entry = probe.agents.firstWhere((a) => a.agent.id == agentId);
    final shown = entry.agent.hooks;
    final path = local.expand(shown);
    final file = File(path);
    final now = file.existsSync() ? file.readAsStringSync() : '';
    if (file.existsSync() != entry.exists || now != entry.text) {
      throw HooksError(
        '$shown changed while this ran; nothing changed, run it again',
      );
    }
    var next = entry.settings;
    for (final step in steps) {
      next = switch (step.action) {
        'add' => withHook(next, step.hook),
        'replace' => withHook(withoutHook(next, step.hook.command), step.hook),
        _ => withoutHook(next, step.hook.command),
      };
    }
    final text = '${const JsonEncoder.withIndent('  ').convert(next)}\n';
    final problem = _checkResult(entry.settings, text, steps);
    if (problem != null) {
      throw HooksError(
        '$shown: refused, the result would be wrong ($problem); nothing changed',
      );
    }
    String? backup;
    final mode = entry.exists ? file.statSync().mode & 0x1ff : null;
    if (entry.exists) {
      backup = backupPath(path, date);
      file.copySync(backup);
      _chmod(backup, mode!);
    }
    _writeInPlaceOf(path, text, mode);
    if (File(path).readAsStringSync() != text) {
      throw HooksError(
        '$shown does not read back as written; the copy before is ${backup == null ? 'none (it was new)' : local.tilde(backup)}',
      );
    }
    changed.add({
      'agent': agentId,
      'file': shown,
      'backup': backup == null ? null : local.tilde(backup),
      'steps': steps.map((s) => s.toJson(shown)).toList(),
    });
  }
  int count(String action) =>
      plan.steps.where((step) => step.action == action).length;
  return {
    'schema_version': hooksSchema,
    'device': plan.device,
    'added': count('add'),
    'replaced': count('replace'),
    'removed': count('remove'),
    'files': changed,
  };
}

/// Why [text] is not what the steps should make of [before], or null.
String? _checkResult(
  Map<String, Object?> before,
  String text,
  List<HookStep> steps,
) {
  final Object? after;
  try {
    after = jsonDecode(text);
  } on FormatException {
    return 'not valid JSON';
  }
  if (after is! Map<String, Object?>) return 'not a JSON object';
  String rest(Map<String, Object?> map) =>
      jsonEncode({...map}..remove('hooks'));
  if (rest(after) != rest(before)) return 'a setting other than hooks changed';
  final problem = hooksShapeProblem(after['hooks']);
  if (problem != null) return problem;
  final found = foundHooks(after);
  for (final step in steps) {
    final state = hookState(step.hook, found);
    if (step.action == 'remove' ? state != 'missing' : state != 'installed') {
      return '${step.hook.name} would be $state';
    }
  }
  // Hooks of other commands stay as they were.
  final mine = steps.map((step) => step.hook.command).toSet();
  String others(Map<String, Object?> map) => foundHooks(map)
      .where((h) => !mine.contains(h.command))
      .map((h) => '${h.event}|${h.matcher}|${h.type}|${h.command}|${h.timeout}')
      .join('\n');
  if (others(after) != others(before)) return 'another hook changed';
  return null;
}

void _chmod(String path, int mode) {
  final result = Process.runSync('chmod', [mode.toRadixString(8), path]);
  if (result.exitCode != 0) {
    throw HooksError('chmod $path: ${'${result.stderr}'.trim()}');
  }
}

/// Writes [text] where [path] points (through a link, to its target) via a
/// temporary file with the file's own permissions, so a reader never sees
/// half a file.
void _writeInPlaceOf(String path, String text, int? mode) {
  final target = File(path).existsSync()
      ? File(path).resolveSymbolicLinksSync()
      : path;
  File(target).parent.createSync(recursive: true);
  final temporary = File('$target.tmp-$pid');
  temporary.writeAsStringSync(text);
  try {
    if (mode != null) _chmod(temporary.path, mode);
    temporary.renameSync(target);
  } on Object {
    if (temporary.existsSync()) temporary.deleteSync();
    rethrow;
  }
}

/// `hooks add ~/PATH`: registers a folder; one that is here must hold a
/// readable hooks.toml.
Map<String, Object?> addHookCollection({
  required Local local,
  required SettingsStore store,
  required HookSettings settings,
  required String path,
}) {
  final folder = Directory(local.expand(path));
  final notes = <String>[];
  if (folder.existsSync()) {
    final file = File('${folder.path}/$hooksFile');
    if (!file.existsSync()) {
      throw HooksError('${folder.path} has no $hooksFile');
    }
    try {
      final hooks = parseHooks(file.readAsStringSync(), path);
      notes.add(
        '${hooks.length} hook(s): ${hooks.map((h) => h.name).join(', ')}',
      );
    } on TomlError catch (error) {
      throw HooksError('$path/$hooksFile: ${error.message}');
    }
  } else {
    notes.add('$path is not on ${local.device} (yet)');
  }
  final already = settings.collections.contains(path);
  if (!already) {
    settings.collections.add(path);
    store.write(settings.toToml());
  }
  notes.add(
    already
        ? '$path was already registered'
        : '$path registered in ${store.given ?? store.ownPath}; install its hooks with fluttairbar-cli hooks install --all',
  );
  return {
    'schema_version': hooksSchema,
    'device': local.device,
    'path': path,
    'registered': !already,
    'detail': notes.join('; '),
  };
}

// ---------------------------------------------------------------- text

String textHooksReport(Map<String, Object?> report) {
  final lines = ['${report['device']}: ${report['detail']}'];
  final rows = (report['hooks'] as List).cast<Map<String, Object?>>();
  for (final collection
      in (report['collections'] as List).cast<Map<String, Object?>>()) {
    final error = collection['error'] as String?;
    lines.add(
      '  ${collection['path']} (${collection['state']}${error == null ? '' : ': $error'})',
    );
    for (final row in rows.where(
      (r) => r['collection'] == collection['path'],
    )) {
      final where = [
        row['agent'],
        row['event'],
        if ((row['matcher'] as String).isNotEmpty) '[${row['matcher']}]',
      ].join(' ');
      final description = row['description'] as String;
      lines.add(
        '    ${'${row['name']}'.padRight(20)} ${where.padRight(22)} ${'${row['state']}'.padRight(10)} ${description.length > 60 ? description.substring(0, 60) : description}',
      );
    }
  }
  for (final agent in (report['agents'] as List).cast<Map<String, Object?>>()) {
    if (agent['state'] == 'none') continue;
    lines.add(
      '  ${agent['agent']}: ${agent['hooks_file']}${agent['exists'] == true ? '' : ' (not there yet)'}${agent['error'] == null ? '' : ' - ${agent['error']}'}',
    );
  }
  final others = (report['others'] as List).cast<Map<String, Object?>>();
  if (others.isNotEmpty) {
    lines.add('  from elsewhere:');
    for (final other in others) {
      lines.add(
        '    ${'${other['agent']}'.padRight(8)} ${'${other['event']}'.padRight(18)} ${other['command']}',
      );
    }
  }
  if ((report['collections'] as List).isEmpty) {
    lines.add(
      '  no hook collection registered: fluttairbar-cli hooks add ~/PATH (a folder with a $hooksFile)',
    );
  }
  return lines.join('\n');
}

String textHooksPlan(HookPlan plan) {
  final lines = <String>[
    if (plan.steps.isEmpty)
      '${plan.device}: nothing to ${plan.remove ? 'take out' : 'add'}'
    else
      '${plan.device}: ${plan.steps.length} hook(s) to ${plan.remove ? 'take out' : 'add'}',
    for (final step in plan.steps)
      '  ${step.action.padRight(7)} ${step.hook.agent.padRight(8)} ${step.hook.name.padRight(20)} ${step.hook.event} in ${plan.files[step.hook.agent]}',
    if (plan.inPlace.isNotEmpty) '  already so: ${plan.inPlace.join(', ')}',
    for (final refused in plan.refused) '  not done: $refused',
  ];
  return lines.join('\n');
}

String textHooksDone(Map<String, Object?> done) {
  final files = (done['files'] as List).cast<Map<String, Object?>>();
  return [
    '${done['device']}: ${done['added']} added, ${done['replaced']} replaced, ${done['removed']} taken out',
    for (final file in files)
      '  ${file['file']}${file['backup'] == null ? ' (new)' : ', copy before: ${file['backup']}'}',
  ].join('\n');
}
