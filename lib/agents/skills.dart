/// `fluttairbar-cli skills`: one collection of agent skills, linked into
/// every coding agent on this device.
///
/// A skill is a folder with a SKILL.md. A collection is a folder of skills,
/// usually a git checkout, listed home-relative in the settings so the same
/// list holds on every device. The report shows the collections (and their
/// commit), their skills, and for each coding agent here (the table in
/// skill_settings.dart, extended by `[[agent]]` in the settings) whether a
/// skill is linked in, seen through another folder the agent reads, a copy,
/// off, or missing; skills that came from elsewhere are listed too.
/// `install` links skills into the agents' folders, so one `git pull` of the
/// collection updates every agent at once. Nothing is overwritten: a folder
/// already there is moved aside only with `--replace`, into
/// `~/.local/share/fluttairbar/retired/`.
library;

import 'dart:io';

import 'local.dart';
import 'skill_settings.dart';

const skillsSchema = 'fluttairbar.skills.v1';

/// How many days of agent history count as "used lately".
const usageDays = 30;

/// Where moved-aside copies go, home-relative.
const retiredDir = '~/.local/share/fluttairbar/retired';

/// A skill folder found in a collection.
class FoundSkill {
  FoundSkill(
    this.collection,
    this.name,
    this.description, [
    this.headerName,
    this.firstLine,
  ]);
  final String collection;
  final String name;
  final String description;

  /// The SKILL.md header's `name:` and its first line; null when not read.
  final String? headerName;
  final String? firstLine;
}

/// What is on the device, read before any verdict.
class Probe {
  String home = '';

  /// Whether the shared instructions file is there; null when none is set.
  bool? sharedPresent;

  /// Collection path → its short commit (`-` outside git), absent: missing.
  final commits = <String, String>{};
  final skills = <FoundSkill>[];

  /// The agents whose folder's parent exists here.
  final present = <String>[];

  /// Agent → `link:TARGET`, `file` or `missing`.
  final instructions = <String, String>{};

  /// Folder → entry name → `link:TARGET` or `copy`.
  final dirs = <String, Map<String, String>>{};

  /// (agent, skill) → sessions of the last [usageDays] days that loaded it.
  final used = <(String, String), int>{};
}

/// Reads this device: collections, skills, the agents here and every skill
/// folder they read. Read-only.
Future<Probe> probeDevice(
  Local local,
  List<String> collections,
  List<AgentDef> agents,
  String shared,
) async {
  final probe = Probe()..home = local.home;
  if (shared.isNotEmpty) {
    probe.sharedPresent = File(local.expand(shared)).existsSync();
  }
  for (final collection in collections) {
    final folder = Directory(local.expand(collection));
    if (!folder.existsSync()) continue;
    probe.commits[collection] = await _commit(folder.path);
    final names =
        folder
            .listSync()
            .map((entry) => entry.path.split('/').last)
            .where((name) => !name.startsWith('.'))
            .toList()
          ..sort();
    for (final name in names) {
      final file = File('${folder.path}/$name/SKILL.md');
      if (!file.existsSync()) continue;
      final lines = file.readAsLinesSync();
      String field(String key) {
        for (final line in lines) {
          final match = RegExp('^$key: *').matchAsPrefix(line);
          if (match != null) return line.substring(match.end);
        }
        return '';
      }

      final description = field('description');
      probe.skills.add(
        FoundSkill(
          collection,
          name,
          description.length > 200
              ? description.substring(0, 200)
              : description,
          field('name').replaceAll('\r', ''),
          lines.isEmpty ? '' : lines.first.replaceAll('\r', ''),
        ),
      );
    }
  }
  final folders = <String>[];
  for (final agent in agents) {
    if (Directory(local.expand(agent.dir)).parent.existsSync()) {
      probe.present.add(agent.id);
    }
    if (agent.instructions.isNotEmpty) {
      final path = local.expand(agent.instructions);
      probe.instructions[agent.id] = FileSystemEntity.isLinkSync(path)
          ? 'link:${_linkTarget(path)}'
          : File(path).existsSync()
          ? 'file'
          : 'missing';
    }
    for (final dir in [agent.dir, ...agent.reads]) {
      if (!folders.contains(dir)) folders.add(dir);
    }
  }
  for (final dir in folders) {
    final folder = Directory(local.expand(dir));
    if (!folder.existsSync()) continue;
    final entries = <String, String>{};
    for (final entry in folder.listSync(followLinks: false)) {
      final name = entry.path.split('/').last;
      if (name.startsWith('.')) continue;
      if (entry is Link) {
        entries[name] = 'link:${_linkTarget(entry.path)}';
      } else if (File('${entry.path}/SKILL.md').existsSync()) {
        entries[name] = 'copy';
      }
    }
    probe.dirs[dir] = _sorted(entries);
  }
  final usage = await runShell(usageScript(agents), home: local.home);
  for (final line in '${usage.stdout}'.split('\n')) {
    if (!line.startsWith('used=')) continue;
    final parts = line.substring(5).split('|');
    final count = parts.length == 3 ? int.tryParse(parts[2].trim()) : null;
    if (count != null) probe.used[(parts[0], parts[1])] = count;
  }
  return probe;
}

/// The checkout's short commit, `-` when it is none (or git is missing).
Future<String> _commit(String folder) async {
  try {
    final git = await Process.run('git', [
      '-C',
      folder,
      'rev-parse',
      '--short',
      'HEAD',
    ]);
    final commit = '${git.stdout}'.trim();
    return git.exitCode == 0 && commit.isNotEmpty ? commit : '-';
  } on ProcessException {
    return '-';
  }
}

/// A link's target, resolved where it can be (`readlink -f`), as written
/// otherwise.
String _linkTarget(String path) {
  try {
    return File(path).resolveSymbolicLinksSync();
  } on FileSystemException {
    final target = Link(path).targetSync();
    return target.startsWith('/')
        ? target
        : '${File(path).parent.path}/$target';
  }
}

/// Sessions of the last [usageDays] days that loaded each skill, per agent
/// with a `history` and a `loaded` pattern. One line per session and skill;
/// the names are counted. `find` and `grep` read the history fast.
String usageScript(List<AgentDef> agents) {
  final script = StringBuffer(
    r'''used() { sed -E 's#/SKILL\.md$##; s#^([^:]*):.*/([^/]+)$#\2 \1#' | sort -u | awk '{print $1}' | sort | uniq -c | awk -v a="$1" '{print "used=" a "|" $2 "|" $1}'; }
''',
  );
  for (final agent in agents) {
    if (agent.history.isEmpty || agent.loaded.isEmpty) continue;
    script.writeln(
      'h=${shellPath(agent.history)}; [ -d "\$h" ] && find "\$h" -name \'*.jsonl\' -mtime -$usageDays -print0 2>/dev/null | xargs -0 grep -oHE ${shellQuote(agent.loaded)} 2>/dev/null | used ${agent.id}',
    );
  }
  script.writeln('true');
  return script.toString();
}

/// Why an agent might not see or pick a skill, from its SKILL.md header.
List<String> skillProblems(
  String folder,
  String description,
  String name,
  String first,
) {
  final found = <String>[];
  if (first.trim() != '---') {
    found.add(
      'SKILL.md does not start with a --- header, so agents do not list it',
    );
  }
  if (name.trim().isEmpty) {
    found.add('no name in the header');
  } else if (name.trim() != folder) {
    found.add('its name "${name.trim()}" differs from its folder "$folder"');
  }
  if (description.trim().isEmpty) {
    found.add('no description: an agent cannot tell when to use it');
  }
  return found;
}

/// The verdict on one device, from what [probe] found.
Map<String, Object?> buildReport({
  required String device,
  required List<String> collections,
  required Map<String, List<String>> off,
  required String shared,
  required List<AgentDef> table,
  required Probe probe,
  String settings = '',
}) {
  String expand(String path) => path.startsWith('~/') && probe.home.isNotEmpty
      ? '${probe.home}/${path.substring(2)}'
      : path;
  String tilde(String path) =>
      probe.home.isNotEmpty && path.startsWith('${probe.home}/')
      ? '~/${path.substring(probe.home.length + 1)}'
      : path.endsWith('/') && path.length > 1
      ? path.substring(0, path.length - 1)
      : path;

  // Collections in path order, as a sorted map keeps them.
  final found = <String, Map<String, Object?>>{
    for (final path in [...collections]..sort())
      path: {
        'path': path,
        'state': probe.commits.containsKey(path) ? 'ok' : 'missing',
        'commit': probe.commits[path] ?? '',
        'skills': <Map<String, Object?>>[],
      },
  };
  for (final skill in probe.skills) {
    final collection = found[skill.collection];
    if (collection == null || !plainName(skill.name)) continue;
    (collection['skills'] as List<Map<String, Object?>>).add({
      'name': skill.name,
      'collection': skill.collection,
      'description': skill.description.trim(),
      // Without the header fields there is no verdict.
      'problems': skill.headerName == null || skill.firstLine == null
          ? <String>[]
          : skillProblems(
              skill.name,
              skill.description,
              skill.headerName!,
              skill.firstLine!,
            ),
    });
  }
  for (final collection in found.values) {
    if (collection['state'] == 'ok' && (collection['skills'] as List).isEmpty) {
      collection['state'] = 'empty';
    }
  }
  List<Map<String, Object?>> skillsOf(Map<String, Object?> collection) =>
      collection['skills'] as List<Map<String, Object?>>;

  // The link's target decides: into the collection, or elsewhere.
  final dirs = <String, Map<String, String>>{
    for (final entry in probe.dirs.entries)
      entry.key: {
        for (final item in entry.value.entries)
          item.key: switch (item.value) {
            final kind when kind.startsWith('link:') =>
              found.values.any(
                    (collection) =>
                        skillsOf(
                          collection,
                        ).any((skill) => skill['name'] == item.key) &&
                        _trimSlash(kind.substring(5)) ==
                            '${expand(collection['path'] as String)}/${item.key}',
                  )
                  ? 'linked'
                  : 'link -> ${tilde(kind.substring(5))}',
            final kind => kind,
          },
      },
  };
  final agents = <Map<String, Object?>>[
    for (final agent in table.where((a) => probe.present.contains(a.id)))
      {
        'agent': agent.id,
        'name': agent.name,
        'dir': agent.dir,
        'reads': agent.reads,
        if (agent.ask.isNotEmpty) 'ask': agent.ask,
        'installed': {...?dirs[agent.dir]},
        'instructions': switch (probe.instructions[agent.id]) {
          null => '',
          final state when state.startsWith('link:') =>
            shared.isNotEmpty &&
                    _trimSlash(state.substring(5)) == expand(shared)
                ? 'linked'
                : 'link -> ${tilde(state.substring(5))}',
          final state => state,
        },
      },
  ];
  bool isOff(String agent, String name) => off[agent]?.contains(name) ?? false;
  // A collection skill linked in another folder the agent reads.
  String? via(Map<String, Object?> entry, String name) {
    for (final dir in entry['reads'] as List<String>) {
      if (dirs[dir]?[name] == 'linked') return dir;
    }
    return null;
  }

  final rows = <Map<String, Object?>>[];
  for (final collection in found.values) {
    for (final skill in skillsOf(collection)) {
      final name = skill['name'] as String;
      final states = <String, String>{};
      final counts = <String, int>{};
      for (final entry in agents) {
        final id = entry['agent'] as String;
        final offHere = isOff(id, name);
        final installed = (entry['installed'] as Map<String, String>)[name];
        final through = via(entry, name);
        states[id] = switch ((installed, through)) {
          (final String state, _) when offHere =>
            '$state, but off in skills.toml',
          (final String state, final String dir) => '$state (also via $dir)',
          (final String state, null) => state,
          (null, final String dir) when offHere =>
            'via $dir, off in skills.toml but visible through that folder',
          (null, final String dir) => 'via $dir',
          (null, null) when offHere => 'off',
          (null, null) => 'missing',
        };
        counts[id] = probe.used[(id, name)] ?? 0;
      }
      rows.add({
        'name': name,
        'collection': skill['collection'],
        'description': skill['description'],
        'agents': _sorted(states),
        'used': _sorted(counts),
        'problems': skill['problems'],
      });
    }
  }
  // Skills from elsewhere: in an agent's own folder, or in a folder it reads
  // that is no present agent's own (~/.agents/skills).
  final own = agents.map((entry) => entry['dir']).toList();
  final others = <Map<String, Object?>>[];
  for (final entry in agents) {
    final id = entry['agent'] as String;
    final folders = [
      (entry['dir'] as String, false),
      for (final dir in entry['reads'] as List<String>)
        if (!own.contains(dir)) (dir, true),
    ];
    for (final (dir, through) in folders) {
      final names = (dirs[dir] ?? {}).keys.toList()..sort();
      for (final name in names) {
        if (rows.any((row) => row['name'] == name)) continue;
        final kind = dirs[dir]![name]!;
        others.add({
          'agent': id,
          'name': name,
          'kind': through ? '$kind in $dir' : kind,
          'used': probe.used[(id, name)] ?? 0,
        });
      }
    }
  }
  final inPlace = rows
      .expand((row) => (row['agents'] as Map<String, String>).values)
      .where((state) => state.startsWith('linked') || state.startsWith('via '))
      .length;
  final wanted = rows.length * agents.length;
  final present = found.values.where((c) => c['state'] != 'missing').length;
  return {
    'schema_version': skillsSchema,
    'device': device,
    'status': 'ok',
    'detail':
        '$present collection(s), ${rows.length} skill(s); ${agents.length} agent(s) here (${agents.map((a) => a['name']).join(', ')}); $inPlace of $wanted in place${others.isEmpty ? '' : '; ${others.length} skill(s) from elsewhere'}',
    'collections': found.values.toList(),
    'agents': agents,
    'skills': rows,
    'others': others,
    'usage_days': usageDays,
    if (shared.isNotEmpty) 'instructions_file': shared,
    if (probe.sharedPresent == false) 'instructions_file_missing': true,
    if (settings.isNotEmpty) 'settings': settings,
  };
}

String _trimSlash(String path) =>
    path.endsWith('/') ? path.substring(0, path.length - 1) : path;

Map<String, T> _sorted<T>(Map<String, T> map) => {
  for (final key in map.keys.toList()..sort()) key: map[key] as T,
};

/// One link to make (or a copy to move aside first).
class Step {
  Step(this.agent, this.skill, this.action, this.target, this.command);
  final String agent;
  final String skill;

  /// `link` or `replace`.
  final String action;
  final String target;
  final String command;

  Map<String, Object?> toJson() => {
    'agent': agent,
    'skill': skill,
    'action': action,
    'target': target,
    'command': command,
  };
}

class Plan {
  Plan({
    required this.device,
    required this.skills,
    required this.agents,
    required this.steps,
    required this.inPlace,
    required this.refused,
  });
  final String device;
  final int skills;
  final int agents;
  final List<Step> steps;

  /// Already linked: nothing to do.
  final List<String> inPlace;

  /// Not done and why (a copy in the way without `--replace`).
  final List<String> refused;

  int get replaced => steps.where((step) => step.action == 'replace').length;

  String get script => steps.isEmpty
      ? ''
      : 'set -eu\n${steps.map((step) => step.command).join('\n')}\necho done\n';

  /// The one question before the links are made: the count the list shows,
  /// replacements named.
  String get question =>
      'Make ${steps.length} link(s) on $device${replaced == 0 ? '' : ', $replaced of them in place of a copy (moved to $retiredDir)'}?';

  Map<String, Object?> toJson() => {
    'schema_version': skillsSchema,
    'device': device,
    'skills': skills,
    'agents': agents,
    'steps': steps.map((step) => step.toJson()).toList(),
    'in_place': inPlace,
    'refused': refused,
    'script': script,
    'question': question,
  };
}

class SkillsError implements Exception {
  SkillsError(this.message);
  final String message;
  @override
  String toString() => message;
}

String _missingCollections(String hint) => 'no collection registered: $hint';

/// What `install` would do here: one link per missing skill per agent.
Plan installPlan({
  required String device,
  required Map<String, Object?> report,
  required SkillSettings settings,
  required List<AgentDef> table,
  required List<String> names,
  required bool all,
  String? agent,
  bool replace = false,
  String? today,
}) {
  if (!all && names.isEmpty) {
    throw SkillsError(
      'name the skills to link, or --all for every skill in every collection',
    );
  }
  if (agent != null) checkAgent(table, agent);
  if (settings.collections.isEmpty) {
    throw SkillsError(
      _missingCollections('fluttairbar-cli skills add ~/PATH (or a git URL)'),
    );
  }
  final rows = (report['skills'] as List).cast<Map<String, Object?>>();
  final chosen = rows
      .where((row) => all || names.contains(row['name']))
      .toList();
  for (final name in names) {
    if (!rows.any((row) => row['name'] == name)) {
      throw SkillsError(
        'no skill "$name" in the collections on $device; there: ${rows.map((row) => row['name']).join(', ')}',
      );
    }
  }
  final agents = (report['agents'] as List)
      .cast<Map<String, Object?>>()
      .where((entry) => agent == null || entry['agent'] == agent)
      .toList();
  if (agents.isEmpty) {
    throw SkillsError(
      'no agent that reads skills is on $device${agent == null ? '' : ' (asked for $agent)'}',
    );
  }
  final date = today ?? civilDate();
  final steps = <Step>[];
  final inPlace = <String>[];
  final refused = <String>[];
  String retiredFolder(String path) =>
      shellPath(path.substring(0, path.lastIndexOf('/')));
  // Links this plan makes, as (folder, skill): an agent that also reads that
  // folder (OpenCode reads Claude Code's) needs no link of its own.
  final planned = <(String, String)>[];
  for (final row in chosen) {
    final name = row['name'] as String;
    for (final entry in agents) {
      final id = entry['agent'] as String;
      final dir = entry['dir'] as String;
      final state =
          (row['agents'] as Map<String, Object?>)[id] as String? ?? 'missing';
      final through = (entry['reads'] as List).cast<String>().where(
        (folder) => planned.contains((folder, name)),
      );
      if (state == 'missing' && through.isNotEmpty) {
        inPlace.add('$id: $name via ${through.first}');
        continue;
      }
      final target = '${row['collection']}/$name';
      final link = '$dir/$name';
      final ln =
          'mkdir -p ${shellPath(dir)} && ln -s ${shellPath(target)} ${shellPath(link)}';
      if (state.startsWith('linked')) {
        inPlace.add('$id: $name');
      } else if (state.startsWith('via ')) {
        inPlace.add('$id: $name $state');
      } else if (state == 'off') {
        if (!all) {
          refused.add(
            '$id: $name is switched off; fluttairbar-cli skills on $name --agent $id',
          );
        }
      } else if (state == 'missing') {
        planned.add((dir, name));
        steps.add(Step(id, name, 'link', target, ln));
      } else if (replace) {
        final retired = '$retiredDir/skills-$date/$id-$name';
        steps.add(
          Step(
            id,
            name,
            'replace',
            target,
            'mkdir -p ${retiredFolder(retired)} && mv ${shellPath(link)} ${shellPath(retired)} && $ln',
          ),
        );
      } else {
        refused.add(
          '$id: $name is already there as a $state; add --replace to move it to $retiredDir and link the collection\'s',
        );
      }
    }
  }
  // The shared instructions file, linked as every agent's own, once it is on
  // the device: a link to nothing would leave every agent without rules.
  final shared = settings.instructions;
  if (shared.isNotEmpty && all && report['instructions_file_missing'] == true) {
    refused.add(
      'the shared instructions $shared are not on $device: put that repository there first (git clone), then install again',
    );
  } else if (shared.isNotEmpty && all) {
    for (final entry in agents) {
      final id = entry['agent'] as String;
      final def = table.where((d) => d.id == id).firstOrNull;
      if (def == null || def.instructions.isEmpty) continue;
      final slash = def.instructions.lastIndexOf('/');
      final folder = slash > 0 ? def.instructions.substring(0, slash) : '~';
      final ln =
          'mkdir -p ${shellPath(folder)} && ln -s ${shellPath(shared)} ${shellPath(def.instructions)}';
      final state = entry['instructions'] as String;
      if (state == 'linked') {
        inPlace.add('$id: instructions');
      } else if (state == 'missing') {
        steps.add(Step(id, '(instructions)', 'link', shared, ln));
      } else if (replace) {
        final retired =
            '$retiredDir/instructions-$date/$id-${def.instructions.split('/').last}';
        steps.add(
          Step(
            id,
            '(instructions)',
            'replace',
            shared,
            'mkdir -p ${retiredFolder(retired)} && mv ${shellPath(def.instructions)} ${shellPath(retired)} && $ln',
          ),
        );
      } else {
        refused.add(
          '$id: its instructions ${def.instructions} are a $state; add --replace to move them to $retiredDir and link $shared',
        );
      }
    }
  }
  return Plan(
    device: device,
    skills: chosen.length,
    agents: agents.length,
    steps: steps,
    inPlace: inPlace,
    refused: refused,
  );
}

/// `unknown agent X; these read skills: ...` for a mistyped --agent.
void checkAgent(List<AgentDef> table, String agent) {
  if (table.any((known) => known.id == agent)) return;
  throw SkillsError(
    'unknown agent "$agent"; these read skills: ${table.map((known) => known.id).join(', ')} (add one with [[agent]] in the settings)',
  );
}

/// Runs an approved plan here.
Future<Map<String, Object?>> runPlan(Local local, Plan plan) async {
  final result = await runShell(plan.script, home: local.home);
  final output = '${result.stdout}${result.stderr}'.trim();
  if (result.exitCode != 0) {
    throw SkillsError('${plan.device}: linking failed:\n$output');
  }
  return {
    'schema_version': skillsSchema,
    'device': plan.device,
    'linked': plan.steps.where((step) => step.action == 'link').length,
    'replaced': plan.replaced,
    'output': output,
  };
}

/// `skills on|off NAME [--agent A]`: off removes the agent's link into the
/// collection (a copy is left alone) and records the choice so `install
/// --all` keeps it out; on clears that and links it again. The skill and its
/// collection are never touched. Without an agent it acts on every agent
/// here.
Future<Map<String, Object?>> switchSkill({
  required Local local,
  required SettingsStore store,
  required SkillSettings settings,
  required Map<String, Object?> report,
  required String name,
  String? agent,
  required bool on,
  required Future<Map<String, Object?>> Function() freshReport,
}) async {
  if (!plainName(name)) throw SkillsError('"$name" is not a skill name');
  final table = settings.agentTable();
  if (agent != null) checkAgent(table, agent);
  final rows = (report['skills'] as List).cast<Map<String, Object?>>();
  final row = rows.where((row) => row['name'] == name).firstOrNull;
  if (row == null) {
    throw SkillsError(
      'no skill "$name" in the registered collections (${settings.collections.join(', ')}); fluttairbar-cli skills lists them',
    );
  }
  final present = (report['agents'] as List).cast<Map<String, Object?>>();
  final agents = agent != null
      ? [agent]
      : present.map((entry) => entry['agent'] as String).toList();
  for (final id in agents) {
    final list = settings.off.putIfAbsent(id, () => []);
    list.remove(name);
    if (!on) {
      list
        ..add(name)
        ..sort();
    }
  }
  settings.off.removeWhere((_, names) => names.isEmpty);
  store.write(settings.toToml());
  final lines = <String>[];
  if (on) {
    final plan = installPlan(
      device: local.device,
      report: await freshReport(),
      settings: settings,
      table: table,
      names: [name],
      all: false,
      agent: agent,
    );
    lines.addAll(plan.refused);
    if (plan.steps.isEmpty) {
      lines.add('$name: on, already in place for ${agents.join(', ')}');
    } else {
      final done = await runPlan(local, plan);
      lines.add('$name: switched on and linked (${done['linked']} link(s))');
    }
  } else {
    for (final id in agents) {
      final def = table.where((d) => d.id == id).firstOrNull;
      if (def == null) continue;
      final link = '${local.expand(def.dir)}/$name';
      final state =
          (row['agents'] as Map<String, Object?>)[id] as String? ?? 'missing';
      if (state.startsWith('linked') && FileSystemEntity.isLinkSync(link)) {
        Link(link).deleteSync();
        lines.add(
          '$id: $name off, link removed (the skill stays in ${local.tilde(row['collection'] as String)})',
        );
      } else if (state.startsWith('copy')) {
        lines.add(
          '$id: $name off in skills.toml; a copy (not a link) is in ${local.tilde(link)}, left alone',
        );
      } else {
        lines.add('$id: $name off');
      }
      // Still visible through a folder another agent's link lives in?
      for (final dir in def.reads) {
        final holder = present.where(
          (other) =>
              other['dir'] == dir &&
              (other['installed'] as Map)[name] == 'linked' &&
              !agents.contains(other['agent']),
        );
        if (holder.isEmpty) continue;
        final owner =
            table.where((other) => other.dir == dir).firstOrNull?.id ??
            'another agent';
        lines.add(
          '$id: ${def.name} also reads $dir, where $name is linked for $owner; it stays visible until it is off there too (fluttairbar-cli skills off $name --agent $owner)',
        );
        break;
      }
    }
  }
  return {
    'schema_version': skillsSchema,
    'device': local.device,
    'skill': name,
    'on': on,
    'agents': agents,
    'lines': lines,
  };
}

bool isUrl(String source) =>
    source.contains('://') || source.startsWith('git@');

/// Where `add` puts a collection: a folder as given (home-relative), a git
/// URL cloned into `~/Documents/github/NAME` first.
({String path, String? url}) addTarget(Local local, String source) {
  if (isUrl(source)) {
    if (RegExp('[\\s\'"]').hasMatch(source)) {
      throw SkillsError('a git URL has no spaces or quotes');
    }
    var name = source.replaceAll(RegExp(r'/+$'), '').split(RegExp('[/:]')).last;
    if (name.endsWith('.git')) name = name.substring(0, name.length - 4);
    if (!plainName(name)) {
      throw SkillsError(
        'cannot name a folder after "$source"; clone it yourself and add the folder',
      );
    }
    return (path: '~/Documents/github/$name', url: source);
  }
  final path = local.tilde(source);
  if (!path.startsWith('~/') || path.contains('/../') || path.endsWith('/..')) {
    throw SkillsError(
      'a collection is a folder under your home, given as ~/PATH, the same on every device',
    );
  }
  return (path: path, url: null);
}

/// The question before `add`.
String addQuestion(String device, ({String path, String? url}) target) =>
    target.url != null
    ? 'Clone ${target.url} into ${target.path} on $device?'
    : 'Register ${target.path} as a skill collection on $device?';

/// Clones when there is a URL, then registers the folder. A folder that is
/// here must hold a skill; one that is not here yet is registered with a
/// note (the settings can serve other devices).
Future<Map<String, Object?>> addCollection({
  required Local local,
  required SettingsStore store,
  required SkillSettings settings,
  required ({String path, String? url}) target,
}) async {
  final notes = <String>[];
  final folder = Directory(local.expand(target.path));
  if (target.url != null) {
    if (folder.existsSync()) {
      notes.add('already there: ${target.path}');
    } else {
      folder.parent.createSync(recursive: true);
      final clone = await Process.run('git', [
        'clone',
        '--quiet',
        target.url!,
        folder.path,
      ]);
      if (clone.exitCode != 0) {
        throw SkillsError('clone failed:\n${'${clone.stderr}'.trim()}');
      }
      notes.add('cloned ${target.path}');
    }
  } else if (folder.existsSync()) {
    final hasSkill = folder.listSync().any(
      (entry) => File('${entry.path}/SKILL.md').existsSync(),
    );
    if (!hasSkill) {
      throw SkillsError(
        '${folder.path} holds no skill (a folder with a SKILL.md inside)',
      );
    }
  } else {
    notes.add('${target.path} is not on ${local.device} (yet)');
  }
  final already = settings.collections.contains(target.path);
  if (!already) {
    settings.collections.add(target.path);
    store.write(settings.toToml());
  }
  notes.add(
    already
        ? '${target.path} was already registered'
        : '${target.path} registered in ${store.fromStdin ? 'the settings' : store.given ?? store.ownPath}; link its skills with fluttairbar-cli skills install --all',
  );
  return {
    'schema_version': skillsSchema,
    'device': local.device,
    'path': target.path,
    'url': target.url,
    'registered': !already,
    'detail': notes.join('; '),
  };
}

/// `skills remove ~/PATH`: unregisters; folders and links stay.
Map<String, Object?> removeCollection({
  required Local local,
  required SettingsStore store,
  required SkillSettings settings,
  required String source,
}) {
  final path = local.tilde(source);
  if (!settings.collections.remove(path)) {
    throw SkillsError(
      '$path is not a registered collection; these are: ${settings.collections.isEmpty ? 'none' : settings.collections.join(', ')}',
    );
  }
  store.write(settings.toToml());
  return {
    'schema_version': skillsSchema,
    'device': local.device,
    'path': path,
    'detail':
        '$path unregistered; its folder and the agents\' links are untouched',
  };
}

// ---------------------------------------------------------------- text

String textReport(Map<String, Object?> report) {
  final device = report['device'];
  if (report['status'] != 'ok') {
    return '$device: ${report['status']} - ${report['detail']}';
  }
  final lines = ['$device: ${report['detail']}'];
  final rows = (report['skills'] as List).cast<Map<String, Object?>>();
  for (final collection
      in (report['collections'] as List).cast<Map<String, Object?>>()) {
    lines.add(
      '  ${collection['path']} (${collection['state'] == 'ok' ? collection['commit'] : collection['state']})',
    );
    for (final skill
        in (collection['skills'] as List).cast<Map<String, Object?>>()) {
      final row = rows.where((row) => row['name'] == skill['name']).firstOrNull;
      final states = row == null
          ? ''
          : (row['agents'] as Map<String, Object?>).entries
                .map(
                  (entry) =>
                      '${entry.key} ${entry.value} (used ${(row['used'] as Map)[entry.key] ?? 0})',
                )
                .join(', ');
      final description = skill['description'] as String;
      lines.add(
        '    ${'${skill['name']}'.padRight(20)} ${states.padRight(52)} ${description.length > 60 ? description.substring(0, 60) : description}',
      );
      for (final problem in skill['problems'] as List) {
        lines.add('    ${''.padRight(20)} ! $problem');
      }
    }
  }
  final instructions = (report['agents'] as List)
      .cast<Map<String, Object?>>()
      .where((entry) => (entry['instructions'] as String).isNotEmpty)
      .map((entry) => '${entry['agent']} ${entry['instructions']}');
  if (instructions.isNotEmpty) {
    lines.add(
      '  instructions (read in every session): ${instructions.join(', ')}',
    );
  }
  final others = (report['others'] as List).cast<Map<String, Object?>>();
  if (others.isNotEmpty) {
    lines.add('  from elsewhere:');
    for (final other in others) {
      lines.add(
        '    ${'${other['agent']}'.padRight(8)} ${'${other['name']}'.padRight(20)} ${other['kind']} (used ${other['used']})',
      );
    }
  }
  lines.add(
    '  via = linked in another folder that agent reads. used = sessions of the last ${report['usage_days']} days that loaded the skill (from each agent\'s history on this device, where it keeps one). Off for one agent: fluttairbar-cli skills off NAME --agent ID',
  );
  if ((report['collections'] as List).isEmpty) {
    lines.add(
      '  ${_missingCollections('fluttairbar-cli skills add ~/PATH (or a git URL)')}',
    );
  }
  return lines.join('\n');
}

String textPlan(Plan plan) {
  final lines = <String>[
    if (plan.steps.isEmpty)
      '${plan.device}: nothing to link (${plan.skills} skill(s), ${plan.agents} agent(s))'
    else
      '${plan.device}: ${plan.steps.length} link(s) to make for ${plan.skills} skill(s) and ${plan.agents} agent(s)',
    for (final step in plan.steps)
      '  ${step.action.padRight(7)} ${step.agent.padRight(8)} ${step.skill.padRight(20)} -> ${step.target}',
    if (plan.inPlace.isNotEmpty) '  already linked: ${plan.inPlace.join(', ')}',
    for (final refused in plan.refused) '  not done: $refused',
  ];
  return lines.join('\n');
}

String textDone(Map<String, Object?> done) {
  final replaced = done['replaced'] as int;
  return '${done['device']}: ${(done['linked'] as int) + replaced} skill link(s) made${replaced > 0 ? ', $replaced folder(s) moved to $retiredDir' : ''}';
}
