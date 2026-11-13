import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fluttairbar/agents/conversations.dart';
import 'package:fluttairbar/agents/hooks.dart';
import 'package:fluttairbar/agents/local.dart';
import 'package:fluttairbar/agents/quiz.dart';
import 'package:fluttairbar/agents/skill_settings.dart';
import 'package:fluttairbar/agents/skills.dart';
import 'package:fluttairbar/agents/toml_lite.dart';
import 'package:fluttairbar/cli/agents_command.dart';

const _collections = ['~/Documents/github/myskills', '~/Documents/team/skills'];

/// The probe's findings written as `key=value` lines, the way the tests of
/// the shell probe this replaces gave them.
Probe probeFrom(String text) {
  final probe = Probe();
  for (final line in text.split('\n')) {
    final at = line.indexOf('=');
    if (at < 0) continue;
    final key = line.substring(0, at).trim();
    final value = line.substring(at + 1);
    final parts = value.split('|');
    switch (key) {
      case 'home':
        probe.home = value.trim();
      case 'shared':
        probe.sharedPresent = value == 'present';
      case 'collection' when parts[1] != 'missing':
        probe.commits[parts[0]] = parts[1];
      case 'skill':
        final slash = parts[0].lastIndexOf('/');
        probe.skills.add(
          FoundSkill(
            parts[0].substring(0, slash),
            parts[0].substring(slash + 1),
            parts.length > 1 ? parts[1] : '',
            parts.length > 2 ? parts[2] : null,
            parts.length > 3 ? parts[3] : null,
          ),
        );
      case 'used':
        probe.used[(parts[0], parts[1])] = int.parse(parts[2]);
      case 'agent':
        probe.present.add(parts[0]);
      case 'instructions':
        probe.instructions[parts[0]] = parts[1];
      case 'entry':
        probe.dirs.putIfAbsent(parts[0], () => {})[parts[1]] = parts[2];
    }
  }
  return probe;
}

Map<String, Object?> report(
  String text, {
  List<String> collections = _collections,
  Map<String, List<String>> off = const {},
  String shared = '',
}) => buildReport(
  device: 'a',
  collections: collections,
  off: off,
  shared: shared,
  table: SkillSettings().agentTable(),
  probe: probeFrom(text),
);

Map<String, Object?> row(Map<String, Object?> report, String name) =>
    (report['skills'] as List).cast<Map<String, Object?>>().firstWhere(
      (row) => row['name'] == name,
    );

/// A home of its own for one test, with a device name.
Local tempLocal(Directory root) => Local(
  home: root.path,
  configHome: '${root.path}/.config',
  dataHome: '${root.path}/.local/share',
  stateHome: '${root.path}/.local/state',
  device: 'testbox',
);

const _workId = '11111111-2222-3333-4444-555555555555';
const _ownId = '66666666-7777-8888-9999-000000000000';
const _workSession =
    '.codex/sessions/2026/11/01/rollout-2026-11-01T10-00-00-$_workId.jsonl';

/// A made-up history in [home]: a Claude project and a Codex session of a
/// work project and of an own one, and the history files naming both.
void writeHistory(String home) {
  void write(String path, String text) => File('$home/$path')
    ..createSync(recursive: true)
    ..writeAsStringSync(text);
  write(
    '.claude/projects/-home-u-Documents-acme-app/c1.jsonl',
    '{"text":"work words"}\n',
  );
  write(
    '.claude/projects/-home-u-Documents-acme-app/c1/subagents/a.jsonl',
    '{"text":"work words of a subagent"}\n',
  );
  write('.claude/projects/-home-u-own/c2.jsonl', '{"text":"own words"}\n');
  write(
    '.claude/history.jsonl',
    '{"display":"work prompt","project":"/home/u/Documents/acme-app"}\n'
        '{"display":"own prompt","project":"/home/u/own"}\n',
  );
  write(
    _workSession,
    '{"type":"session_meta","payload":{"id":"$_workId","instructions":"say \\"cwd\\":\\"/elsewhere\\"","cwd":"/home/u/Documents/acme-app"}}\n'
    '{"type":"message","text":"work words"}\n',
  );
  write(
    '.codex/sessions/2026/11/01/rollout-2026-11-01T11-00-00-$_ownId.jsonl',
    '{"type":"session_meta","payload":{"id":"$_ownId","cwd":"/home/u/own"}}\n',
  );
  write(
    '.codex/history.jsonl',
    '{"session_id":"$_workId","ts":1,"text":"work prompt"}\n'
        '{"session_id":"$_ownId","ts":2,"text":"own prompt"}\n',
  );
  write(
    '.codex/session_index.jsonl',
    '{"id":"$_workId","thread_name":"work thread"}\n'
        '{"id":"$_ownId","thread_name":"own thread"}\n',
  );
}

String gunzipped(String path) =>
    utf8.decode(gzip.decode(File(path).readAsBytesSync()));

void writeSkill(String folder, String name, {String? description}) {
  File('$folder/$name/SKILL.md')
    ..createSync(recursive: true)
    ..writeAsStringSync(
      '---\nname: $name\ndescription: ${description ?? 'Does $name'}\n---\n',
    );
}

void main() {
  group('skills report', () {
    test('a probe answer becomes rows per agent', () {
      final shown = report(
        'home=/home/u\n'
        'collection=~/Documents/github/myskills|d29a621\n'
        'skill=~/Documents/github/myskills/notetaker|Durable project memory\n'
        'skill=~/Documents/github/myskills/safe-yeet|Commit and push with a privacy gate\n'
        'agent=claude|~/.claude/skills\n'
        'entry=~/.claude/skills|notetaker|link:/home/u/Documents/github/myskills/notetaker\n'
        'entry=~/.claude/skills|safe-yeet|copy\n'
        'entry=~/.claude/skills|lean|copy\n'
        'entry=~/.claude/skills|old|link:/srv/elsewhere/old\n'
        'agent=codex|~/.codex/skills\n',
      );
      expect(shown['status'], 'ok');
      expect((row(shown, 'notetaker')['agents'] as Map)['claude'], 'linked');
      expect((row(shown, 'notetaker')['agents'] as Map)['codex'], 'missing');
      expect((row(shown, 'safe-yeet')['agents'] as Map)['claude'], 'copy');
      final others = (shown['others'] as List).cast<Map<String, Object?>>();
      expect(others.length, 2);
      expect(others[1]['kind'], 'link -> /srv/elsewhere/old');
      final collections = (shown['collections'] as List).cast<Map>();
      expect(collections[0]['state'], 'ok');
      expect(collections[1]['state'], 'missing');
      expect(shown['detail'], contains('1 of 4 in place'));
      expect(shown['detail'], contains('Claude Code, Codex'));
    });

    test('an agent that reads another folder sees its links', () {
      // OpenCode reads ~/.claude/skills; Pi reads ~/.agents/skills.
      final shown = report(
        'home=/home/u\n'
        'collection=~/Documents/github/myskills|d29a621\n'
        'skill=~/Documents/github/myskills/notetaker|Durable project memory\n'
        'skill=~/Documents/github/myskills/safe-yeet|Publish safely\n'
        'agent=claude|~/.claude/skills\n'
        'agent=opencode|~/.config/opencode/skills\n'
        'agent=pi|~/.pi/agent/skills\n'
        'entry=~/.claude/skills|notetaker|link:/home/u/Documents/github/myskills/notetaker\n'
        'entry=~/.claude/skills|safe-yeet|link:/home/u/Documents/github/myskills/safe-yeet\n'
        'entry=~/.config/opencode/skills|safe-yeet|copy\n'
        'entry=~/.agents/skills|stripe-docs|copy\n'
        'used=pi|notetaker|2\n',
        off: {
          'opencode': ['notetaker'],
        },
      );
      expect(
        (row(shown, 'notetaker')['agents'] as Map)['opencode'],
        'via ~/.claude/skills, off in skills.toml but visible through that folder',
      );
      expect(
        (row(shown, 'safe-yeet')['agents'] as Map)['opencode'],
        'copy (also via ~/.claude/skills)',
      );
      expect((row(shown, 'notetaker')['agents'] as Map)['pi'], 'missing');
      expect((row(shown, 'notetaker')['used'] as Map)['pi'], 2);
      expect(
        (shown['agents'] as List).map((a) => (a as Map)['agent']),
        ['claude', 'opencode', 'pi'],
        reason: 'only the agents on the device, in the table\'s order',
      );
      final stripe = (shown['others'] as List).cast<Map>().firstWhere(
        (o) => o['name'] == 'stripe-docs',
      );
      expect(
        [stripe['agent'], stripe['kind']],
        ['pi', 'copy in ~/.agents/skills'],
      );
      expect(shown['detail'], contains('3 of 6 in place'));
    });

    test('a shared instructions file the device lacks is noticed', () {
      final missing = report(
        'home=/home/u\nshared=missing\n',
        collections: [],
        shared: '~/f/AGENTS.md',
      );
      expect(missing['instructions_file_missing'], true);
      final present = report(
        'home=/home/u\nshared=present\n',
        collections: [],
        shared: '~/f/AGENTS.md',
      );
      expect(present.containsKey('instructions_file_missing'), false);
    });

    test('every agent reports its instructions file', () {
      const text =
          'home=/home/u\n'
          'agent=claude|~/.claude/skills\n'
          'instructions=claude|link:/home/u/fleet/agents/AGENTS.md\n'
          'agent=codex|~/.codex/skills\n'
          'instructions=codex|file\n'
          'agent=pi|~/.pi/agent/skills\n'
          'instructions=pi|missing\n';
      String state(Map<String, Object?> shown, String id) =>
          (shown['agents'] as List).cast<Map>().firstWhere(
                (a) => a['agent'] == id,
              )['instructions']
              as String;
      final shown = report(
        text,
        collections: [],
        shared: '~/fleet/agents/AGENTS.md',
      );
      expect(state(shown, 'claude'), 'linked');
      expect(state(shown, 'codex'), 'file');
      expect(state(shown, 'pi'), 'missing');
      final elsewhere = report(text, collections: [], shared: '~/other.md');
      expect(state(elsewhere, 'claude'), 'link -> ~/fleet/agents/AGENTS.md');
    });

    test('a SKILL.md an agent cannot see or choose is flagged', () {
      expect(skillProblems('x', 'Does x', 'x', '---'), isEmpty);
      expect(skillProblems('x', '', 'y', '# x'), hasLength(3));
    });

    test('the usage script quotes each agent\'s pattern', () {
      final script = usageScript(SkillSettings().agentTable());
      expect(script, contains('used claude'));
      expect(script, contains('used codex'));
      expect(script, contains('used pi'));
      expect(
        script,
        isNot(contains('used opencode')),
        reason: 'no history kept for OpenCode',
      );
      expect(
        script,
        contains(r"""'"path":"[^"]*/skills/[A-Za-z0-9._-]+/SKILL\.md'"""),
      );
      for (final word in ['rm ', 'mv ', 'ln ', '> ']) {
        expect(script, isNot(contains(word)));
      }
    });

    test('paths are quoted for the shell, only HOME expands', () {
      expect(shellPath("~/Documents/it's"), "\"\$HOME\"/'Documents/it'\\''s'");
      expect(shellPath('/abs/x'), "'/abs/x'");
    });
  });

  group('skills settings', () {
    test('the settings add or replace agents, but only home folders', () {
      final settings = SkillSettings.parse('''
collections = ["~/a", "~/b"]

[[agent]]
id = "gemini"
name = "Gemini CLI"
dir = "~/.gemini/skills"
reads = ["~/.agents/skills"]

[[agent]]
id = "cursor"
name = "Cursor"
dir = "~/.cursor/skills"
reads = ["~/.claude/skills"]
''');
      final table = settings.agentTable();
      expect(table.any((a) => a.id == 'gemini'), true);
      expect(table.where((a) => a.id == 'cursor').length, 1);
      expect(table.firstWhere((a) => a.id == 'cursor').reads, [
        '~/.claude/skills',
      ]);
      expect(() => checkAgent(table, 'gemini'), returnsNormally);
      expect(() => checkAgent(table, 'gpt'), throwsA(isA<SkillsError>()));
      for (final bad in ['/etc/skills', '~/../x', 'skills']) {
        final settings = SkillSettings(
          agents: [AgentDef(id: 'x', name: 'X', dir: bad)],
        );
        expect(settings.agentTable, throwsA(isA<TomlError>()), reason: bad);
      }
    });

    test('a settings file reads the same, and writes back', () {
      const text = r'''
# Collections of agent skills (folders of SKILL.md folders), home-relative so
# the same list holds on every device. `fluttairbar-cli skills`.
collections = ["~/Documents/github/team/skills", "~/Documents/github/myskills"]
instructions = "~/Documents/github/team/agents/AGENTS.md"

[off]
pi = ["safe-yeet"]

[[agent]]
id = "x"
name = "X agent"
dir = "~/.x/skills"
loaded = 'Base directory for this skill: [^"\\]*'
''';
      final settings = SkillSettings.parse(text);
      expect(settings.collections, hasLength(2));
      expect(settings.instructions, endsWith('AGENTS.md'));
      expect(settings.off['pi'], ['safe-yeet']);
      expect(
        settings.agents.single.loaded,
        r'Base directory for this skill: [^"\\]*',
      );
      final again = SkillSettings.parse(settings.toToml());
      expect(again.toToml(), settings.toToml());
      expect(again.agents.single.loaded, settings.agents.single.loaded);
    });

    test('broken settings are refused with the line', () {
      expect(
        () => SkillSettings.parse('collections = ["~/a"\ninstructions = 3\n'),
        throwsA(isA<TomlError>()),
      );
      expect(
        () => SkillSettings.parse('colections = ["~/a"]\n'),
        throwsA(isA<TomlError>()),
      );
      expect(() => parseToml('a = "x\n'), throwsA(isA<TomlError>()));
    });

    test('the tool reads and writes only its own file', () {
      final root = Directory.systemTemp.createTempSync('fab-settings-');
      addTearDown(() => root.deleteSync(recursive: true));
      final local = tempLocal(root);
      final store = SettingsStore(local);
      expect(store.path, store.ownPath);
      expect(store.exists, isFalse);
      expect(store.read(), '');
      store.write(SkillSettings(collections: ['~/a', '~/b']).toToml());
      expect(SkillSettings.parse(store.read()).collections, ['~/a', '~/b']);
      expect(
        () => SettingsStore(local, given: '-').write(''),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('skills on a device', () {
    late Directory root;
    late Local local;
    late SettingsStore store;
    late String collection;

    setUp(() {
      root = Directory.systemTemp.createTempSync('fab-skills-');
      local = tempLocal(root);
      store = SettingsStore(local);
      collection = '${root.path}/Documents/team/skills';
      writeSkill(collection, 'notetaker');
      writeSkill(collection, 'safe-yeet');
      // Claude Code and Codex are here; a copy of safe-yeet is in Claude's
      // folder already.
      writeSkill(
        '${root.path}/.claude/skills',
        'safe-yeet',
        description: 'old',
      );
      Directory('${root.path}/.codex').createSync();
      File('${root.path}/Documents/team/agents/AGENTS.md')
        ..createSync(recursive: true)
        ..writeAsStringSync('rules\n');
      store.write(
        SkillSettings(
          collections: ['~/Documents/team/skills'],
          instructions: '~/Documents/team/agents/AGENTS.md',
        ).toToml(),
      );
    });
    tearDown(() => root.deleteSync(recursive: true));

    Future<(int, Map<String, Object?>)> cli(List<String> args) async {
      final out = StringBuffer();
      final code = await runSkillsCommand(
        [...args, '--format', 'json'],
        out: out,
        err: StringBuffer(),
        local: local,
        ask: (_) async => throw CliFailure(3, 'not done: it needs approval'),
      );
      return (
        code,
        out.isEmpty
            ? <String, Object?>{}
            : jsonDecode(out.toString()) as Map<String, Object?>,
      );
    }

    test(
      'install links, refuses a copy in the way, and moves it only with --replace',
      () async {
        final (planned, plan) = await cli(['install', '--all', '-n']);
        expect(planned, 0);
        final steps = (plan['steps'] as List).cast<Map>();
        expect(steps.map((s) => '${s['agent']} ${s['skill']}'), [
          'claude notetaker',
          'codex notetaker',
          'codex safe-yeet',
          'claude (instructions)',
          'codex (instructions)',
        ]);
        expect(plan['refused'], [
          contains('claude: safe-yeet is already there as a copy'),
        ]);
        expect(plan['question'], 'Make 5 link(s) on testbox?');

        final (asked, error) = await cli(['install', '--all']);
        expect(asked, 3, reason: 'no terminal and no -y');
        expect((error['error'] as Map)['code'], 'needs-approval');
        expect(
          Link('${root.path}/.claude/skills/notetaker').existsSync(),
          false,
        );

        final (done, made) = await cli(['install', '--all', '-y']);
        expect(done, 0);
        expect(made['linked'], 5);
        expect(
          Link('${root.path}/.claude/skills/notetaker').targetSync(),
          '$collection/notetaker',
        );
        expect(
          Link('${root.path}/.codex/AGENTS.md').targetSync(),
          '${root.path}/Documents/team/agents/AGENTS.md',
        );

        final (replaced, moved) = await cli([
          'install',
          '--all',
          '--replace',
          '-y',
        ]);
        expect(replaced, 0);
        expect(moved['replaced'], 1);
        final retired = Directory(
          '${root.path}/.local/share/fluttairbar/retired/skills-${civilDate()}/claude-safe-yeet',
        );
        expect(
          File('${retired.path}/SKILL.md').readAsStringSync(),
          contains('old'),
          reason: 'the copy is kept, not deleted',
        );
        final (_, after) = await cli([]);
        expect(after['detail'], contains('4 of 4 in place'));
      },
    );

    test(
      'install refuses to link instructions that are not on the device',
      () async {
        File('${root.path}/Documents/team/agents/AGENTS.md').deleteSync();
        final (_, plan) = await cli(['install', '--all', '-n']);
        expect(plan['refused'], contains(contains('are not on testbox')));
        expect(
          (plan['steps'] as List).cast<Map>().where(
            (s) => s['skill'] == '(instructions)',
          ),
          isEmpty,
        );
      },
    );

    test(
      'off removes only the link and keeps the skill out; on links it again',
      () async {
        await cli(['install', 'notetaker', '-y']);
        final (offCode, off) = await cli([
          'off',
          'notetaker',
          '--agent',
          'claude',
          '-y',
        ]);
        expect(offCode, 0);
        expect(off['lines'], [contains('claude: notetaker off, link removed')]);
        expect(
          FileSystemEntity.typeSync(
            '${root.path}/.claude/skills/notetaker',
            followLinks: false,
          ),
          FileSystemEntityType.notFound,
        );
        expect(File('$collection/notetaker/SKILL.md').existsSync(), true);
        expect(SkillSettings.parse(store.read()).off['claude'], ['notetaker']);
        final (_, plan) = await cli(['install', '--all', '-n']);
        expect(
          (plan['steps'] as List).cast<Map>().where(
            (s) => s['agent'] == 'claude' && s['skill'] == 'notetaker',
          ),
          isEmpty,
        );
        final (onCode, on) = await cli([
          'on',
          'notetaker',
          '--agent',
          'claude',
          '-y',
        ]);
        expect(onCode, 0);
        expect(on['lines'], [contains('switched on and linked (1 link(s))')]);
        expect(SkillSettings.parse(store.read()).off, isEmpty);
      },
    );

    test(
      'add registers a folder with skills, refuses one without, and remove keeps it',
      () async {
        Directory('${root.path}/empty').createSync();
        final (refused, _) = await cli(['add', '~/empty', '-y']);
        expect(refused, 1);
        writeSkill('${root.path}/more', 'extra');
        final (added, add) = await cli(['add', '~/more', '-y']);
        expect(added, 0);
        expect(add['registered'], true);
        expect(
          SkillSettings.parse(store.read()).collections,
          contains('~/more'),
        );
        final (removed, _) = await cli(['remove', '~/more', '-y']);
        expect(removed, 0);
        expect(File('${root.path}/more/extra/SKILL.md').existsSync(), true);
        final (unknown, error) = await cli(['remove', '~/more', '-y']);
        expect(unknown, 1);
        expect(
          (error['error'] as Map)['message'],
          contains('not a registered collection'),
        );
      },
    );

    test('add tells a folder from a git URL', () {
      final url = addTarget(local, 'https://github.com/you/skills.git');
      expect(url.path, '~/Documents/github/skills');
      expect(url.url, isNotNull);
      expect(
        () => addTarget(local, '/etc/skills'),
        throwsA(isA<SkillsError>()),
      );
      expect(() => addTarget(local, '~/x/../y'), throwsA(isA<SkillsError>()));
      expect(
        () => addTarget(local, "https://x/y'z"),
        throwsA(isA<SkillsError>()),
      );
      expect(addTarget(local, '${root.path}/a').path, '~/a');
      expect(plainName('.hidden'), false);
      expect(plainName('safe-yeet'), true);
    });

    test('usage errors exit 64', () async {
      final (code, error) = await cli(['frobnicate']);
      expect(code, 64);
      expect((error['error'] as Map)['code'], 'usage');
    });
  });

  group('hooks', () {
    const check = 'python3 -I ~/hooks/promise-check.py';
    const declared = '''
# hooks in this folder
[[hook]]
name = "promise-check"
agent = "claude"
event = "Stop"
command = "python3 -I {dir}/promise-check.py"
timeout = 10
description = "Sends a promise back once"

[[hook]]
name = "codex-note"
agent = "codex"
event = "Stop"
command = "sh {dir}/note.sh"
''';
    const original = {
      'permissions': {
        'allow': ['Bash(ls:*)'],
      },
      'hooks': {
        'UserPromptSubmit': [
          {
            'hooks': [
              {'type': 'command', 'command': 'sh ~/draft/prompt-trigger.sh'},
            ],
          },
        ],
      },
      'model': 'opus',
    };

    late Directory root;
    late Local local;
    late File settingsJson;

    setUp(() {
      root = Directory.systemTemp.createTempSync('fab-hooks-');
      local = tempLocal(root);
      File('${root.path}/hooks/hooks.toml')
        ..createSync(recursive: true)
        ..writeAsStringSync(declared);
      settingsJson = File('${root.path}/.claude/settings.json')
        ..createSync(recursive: true)
        ..writeAsStringSync(
          '${const JsonEncoder.withIndent('  ').convert(original)}\n',
        );
      Process.runSync('chmod', ['600', settingsJson.path]);
      Directory('${root.path}/.codex').createSync();
      SettingsStore(
        local,
        name: 'hooks.toml',
      ).write(HookSettings(collections: ['~/hooks']).toToml());
    });
    tearDown(() => root.deleteSync(recursive: true));

    Future<(int, Map<String, Object?>)> cli(List<String> args) async {
      final out = StringBuffer();
      final code = await runHooksCommand(
        [...args, '--format', 'json'],
        out: out,
        err: StringBuffer(),
        local: local,
        ask: (_) async => throw CliFailure(3, 'not done: it needs approval'),
      );
      return (
        code,
        out.isEmpty
            ? <String, Object?>{}
            : jsonDecode(out.toString()) as Map<String, Object?>,
      );
    }

    Map<String, Object?> hookRow(Map<String, Object?> shown, String name) =>
        (shown['hooks'] as List).cast<Map<String, Object?>>().firstWhere(
          (row) => row['name'] == name,
        );
    List<String> backups() =>
        Directory('${root.path}/.claude')
            .listSync()
            .map((entry) => entry.path.split('/').last)
            .where((name) => name.contains('.bak-'))
            .toList()
          ..sort();
    Map<String, Object?> current() =>
        jsonDecode(settingsJson.readAsStringSync()) as Map<String, Object?>;
    List<String> registered() => HookSettings.parse(
      SettingsStore(local, name: 'hooks.toml').read(),
    ).collections;

    test('hooks.toml reads its hooks and refuses what it cannot', () {
      final hooks = parseHooks(declared, '~/hooks');
      expect(hooks.map((h) => h.name), ['promise-check', 'codex-note']);
      expect(hooks.first.command, check);
      expect(hooks.first.timeout, 10);
      expect(hooks.last.timeout, isNull);
      const good = 'name = "x"\nagent = "claude"\nevent = "Stop"\n';
      for (final bad in [
        'hooks = 1\n',
        '[[hook]]\n${good}command = "a"\nwhen = "now"\n',
        '[[hook]]\nname = "../x"\nagent = "claude"\nevent = "Stop"\ncommand = "a"\n',
        '[[hook]]\nname = "x"\nagent = "claude"\nevent = "on stop"\ncommand = "a"\n',
        '[[hook]]\n$good',
        '[[hook]]\n${good}command = "a"\ntimeout = "10"\n',
        '[[hook]]\n${good}command = "a"\ntimeout = 0\n',
      ]) {
        expect(
          () => parseHooks(bad, '~/hooks'),
          throwsA(isA<TomlError>()),
          reason: bad,
        );
      }
      expect(
        () =>
            parseHooks('[[hook]]\n${good}command = "{dir}/a"\n', '~/my hooks'),
        throwsA(isA<TomlError>()),
        reason: '{dir} is put in unquoted, so it must need no quoting',
      );
      expect(
        HookSettings.parse(
          HookSettings(collections: ['~/a']).toToml(),
        ).collections,
        ['~/a'],
      );
      expect(
        () => HookSettings.parse('colections = []\n'),
        throwsA(isA<TomlError>()),
      );
    });

    test('status: per agent installed, missing, or no hooks', () async {
      final (code, shown) = await cli([]);
      expect(code, 0);
      expect(shown['schema_version'], hooksSchema);
      expect(hookRow(shown, 'promise-check')['state'], 'missing');
      expect(hookRow(shown, 'codex-note')['state'], 'no hooks');
      final agents = (shown['agents'] as List).cast<Map>();
      expect(agents.map((a) => '${a['agent']} ${a['state']}'), [
        'claude ok',
        'codex none',
      ]);
      expect((shown['others'] as List).single, {
        'agent': 'claude',
        'event': 'UserPromptSubmit',
        'matcher': '',
        'type': 'command',
        'command': 'sh ~/draft/prompt-trigger.sh',
      });
      expect(shown['detail'], contains('0 of 2 installed'));
      expect(shown['detail'], contains('no hooks: Codex'));
    });

    test(
      'install adds once with a dated copy, changes nothing else, and remove takes it out',
      () async {
        final before = settingsJson.readAsStringSync();
        final (planned, plan) = await cli(['install', '--all', '-n']);
        expect(planned, 0);
        expect((plan['steps'] as List).cast<Map>().map((s) => s['hook']), [
          'promise-check',
        ]);
        expect(plan['refused'], [contains('Codex has no hooks')]);
        expect(settingsJson.readAsStringSync(), before);

        final (asked, error) = await cli(['install', '--all']);
        expect(asked, 3, reason: 'no terminal and no -y');
        expect((error['error'] as Map)['code'], 'needs-approval');
        expect(settingsJson.readAsStringSync(), before);
        expect(backups(), isEmpty);

        final (done, made) = await cli(['install', '--all', '-y']);
        expect(done, 0);
        expect(made['added'], 1);
        final date = civilDate();
        expect(backups(), ['settings.json.bak-$date']);
        expect(
          File(
            '${root.path}/.claude/settings.json.bak-$date',
          ).readAsStringSync(),
          before,
          reason: 'the copy is the file as it was',
        );
        final after = current();
        expect(after['permissions'], original['permissions']);
        expect(after['model'], 'opus');
        expect(
          (after['hooks'] as Map)['UserPromptSubmit'],
          (original['hooks'] as Map)['UserPromptSubmit'],
        );
        expect((after['hooks'] as Map)['Stop'], [
          {
            'hooks': [
              {'type': 'command', 'command': check, 'timeout': 10},
            ],
          },
        ]);
        expect(
          settingsJson.statSync().mode & 0x1ff,
          0x180,
          reason: 'the file keeps its permissions (600)',
        );
        final (_, shown) = await cli([]);
        expect(hookRow(shown, 'promise-check')['state'], 'installed');

        final written = settingsJson.readAsStringSync();
        final (again, twice) = await cli(['install', '--all', '-y']);
        expect(again, 0);
        expect(twice['steps'], isEmpty);
        expect(twice['in_place'], ['claude: promise-check']);
        expect(settingsJson.readAsStringSync(), written);
        expect(backups(), hasLength(1), reason: 'no change, no copy');

        final (removed, out) = await cli(['remove', 'promise-check', '-y']);
        expect(removed, 0);
        expect(out['removed'], 1);
        expect(backups(), [
          'settings.json.bak-$date',
          'settings.json.bak-$date-2',
        ]);
        expect(
          File(
            '${root.path}/.claude/settings.json.bak-$date-2',
          ).readAsStringSync(),
          written,
        );
        expect(current(), original);
        final (gone, nothing) = await cli(['remove', 'promise-check', '-y']);
        expect(gone, 0);
        expect(nothing['steps'], isEmpty);
        expect(nothing['in_place'], [contains('is not in')]);
        expect(backups(), hasLength(2));
      },
    );

    test(
      'a different entry is refused, and put right with --replace',
      () async {
        settingsJson.writeAsStringSync(
          jsonEncode({
            'hooks': {
              'Stop': [
                {
                  'hooks': [
                    {'type': 'command', 'command': check, 'timeout': 5},
                    {'type': 'command', 'command': 'sh ~/other.sh'},
                  ],
                },
              ],
            },
          }),
        );
        final (_, shown) = await cli([]);
        expect(hookRow(shown, 'promise-check')['state'], 'different');
        expect(hookRow(shown, 'promise-check')['found'], [
          {'event': 'Stop', 'matcher': '', 'timeout': 5},
        ]);
        final (refusedCode, refused) = await cli([
          'install',
          'promise-check',
          '-y',
        ]);
        expect(refusedCode, 0);
        expect(refused['steps'], isEmpty);
        expect(refused['refused'], [contains('add --replace')]);
        final (code, done) = await cli([
          'install',
          'promise-check',
          '--replace',
          '-y',
        ]);
        expect(code, 0);
        expect(done['replaced'], 1);
        expect((current()['hooks'] as Map)['Stop'], [
          {
            'hooks': [
              {'type': 'command', 'command': 'sh ~/other.sh'},
            ],
          },
          {
            'hooks': [
              {'type': 'command', 'command': check, 'timeout': 10},
            ],
          },
        ]);
      },
    );

    test('refused input changes nothing', () async {
      settingsJson.writeAsStringSync('{"hooks": {"Stop": ');
      final (code, plan) = await cli(['install', '--all', '-y']);
      expect(code, 0);
      expect(plan['steps'], isEmpty);
      expect(plan['refused'], contains(contains('is not valid JSON')));
      expect(settingsJson.readAsStringSync(), '{"hooks": {"Stop": ');
      settingsJson.writeAsStringSync('{"hooks": {"Stop": {"command": "x"}}}');
      final (_, shape) = await cli(['install', '--all', '-y']);
      expect(shape['refused'], contains(contains('hooks.Stop is not a list')));
      expect(backups(), isEmpty);

      final (unknown, error) = await cli(['install', 'nope', '-y']);
      expect(unknown, 1);
      expect((error['error'] as Map)['message'], contains('no hook "nope"'));
      final (bare, _) = await cli(['install', '-y']);
      expect(bare, 1);
      final (agent, _) = await cli(['install', '--all', '--agent', 'claude']);
      expect(agent, 64);
      final (verb, _) = await cli(['frobnicate']);
      expect(verb, 64);

      Directory('${root.path}/empty').createSync();
      final (noFile, _) = await cli(['add', '~/empty', '-y']);
      expect(noFile, 1);
      File('${root.path}/broken/hooks.toml')
        ..createSync(recursive: true)
        ..writeAsStringSync('[[hook]]\nname = "x"\n');
      final (broken, _) = await cli(['add', '~/broken', '-y']);
      expect(broken, 1);
      final (outside, _) = await cli(['add', '/etc', '-y']);
      expect(outside, 1);
      expect(registered(), ['~/hooks']);

      // A hook is known by its command: two with one command are refused.
      File('${root.path}/hooks/hooks.toml').writeAsStringSync(
        '$declared\n[[hook]]\nname = "again"\nagent = "claude"\nevent = "SubagentStop"\ncommand = "python3 -I {dir}/promise-check.py"\n',
      );
      final (_, twice) = await cli([]);
      expect(
        (twice['collections'] as List).cast<Map>().single['error'],
        contains('its command is also in this file'),
      );
      final (_, same) = await cli(['install', '--all', '-y']);
      expect(same['steps'], isEmpty);
      expect(same['refused'], [contains('its command is also in this file')]);
      expect(backups(), isEmpty);
    });

    test('add registers a folder with a hooks.toml', () async {
      File('${root.path}/more/hooks.toml')
        ..createSync(recursive: true)
        ..writeAsStringSync(
          '[[hook]]\nname = "more"\nagent = "claude"\nevent = "PreToolUse"\nmatcher = "Bash"\ncommand = "sh {dir}/more.sh"\n',
        );
      final (planned, _) = await cli(['add', '~/more', '-n']);
      expect(planned, 0);
      expect(registered(), ['~/hooks'], reason: 'a dry run writes nothing');
      final (code, added) = await cli(['add', '~/more', '-y']);
      expect(code, 0);
      expect(added['registered'], true);
      expect(registered(), ['~/hooks', '~/more']);
      final (_, made) = await cli(['install', 'more', '-y']);
      expect(made['added'], 1);
      expect((current()['hooks'] as Map)['PreToolUse'], [
        {
          'matcher': 'Bash',
          'hooks': [
            {'type': 'command', 'command': 'sh ~/more/more.sh'},
          ],
        },
      ]);
    });

    test('a settings file behind a link is written where it points', () async {
      final real = File('${root.path}/dotfiles/claude-settings.json')
        ..createSync(recursive: true)
        ..writeAsStringSync('{}\n');
      settingsJson.deleteSync();
      Link(settingsJson.path).createSync(real.path);
      final (code, _) = await cli(['install', 'promise-check', '-y']);
      expect(code, 0);
      expect(FileSystemEntity.isLinkSync(settingsJson.path), true);
      expect(
        (jsonDecode(real.readAsStringSync()) as Map)['hooks'],
        contains('Stop'),
      );
    });

    test('an agent with no settings file gets one', () async {
      settingsJson.deleteSync();
      final (code, done) = await cli(['install', 'promise-check', '-y']);
      expect(code, 0);
      expect((done['files'] as List).cast<Map>().single['backup'], isNull);
      expect(current().keys, ['hooks']);
    });
  });

  group('quiz', () {
    test('quiz.txt reads questions and answers, and refuses bad ones', () {
      final quiz = parseQuiz(
        '# what every agent knows\n? What shows what needs attention?\n= tool attention\n\n? Which command reaches devices?\n= tool\n= fleet exec\n',
      );
      expect(quiz, hasLength(2));
      expect(quiz[1].accept, hasLength(2));
      for (final text in [
        '= tool\n? Q?\n= x\n',
        '? Q?\n',
        '? Q?\n= x\nhello\n',
        '? Do you use tool attention?\n= tool attention\n',
        '# nothing\n',
      ]) {
        expect(() => parseQuiz(text), throwsA(isA<QuizError>()), reason: text);
      }
    });

    test('an answer passes on any accepted text, ignoring case', () {
      expect(passes('Run `TOOL ATTENTION` first.', ['tool attention']), true);
      expect(
        passes('tool fleet status', ['tool attention', 'attention --fleet']),
        false,
      );
    });

    test('the ask template gets the question and the answer file', () {
      final args = askArgs(
        ['codex', 'exec', '--output-last-message', '{out}', '{question}'],
        'Who is the author?',
        '/tmp/q/answer.txt',
      );
      expect(args[3], '/tmp/q/answer.txt');
      expect(args[4], startsWith(quizPrefix));
      expect(args[4], endsWith('Who is the author?'));
    });

    test('the quiz asks the agents here and counts what failed', () async {
      final root = Directory.systemTemp.createTempSync('fab-quiz-');
      addTearDown(() => root.deleteSync(recursive: true));
      final local = tempLocal(root);
      Directory('${root.path}/.claude').createSync();
      File('${root.path}/rules/quiz.txt')
        ..createSync(recursive: true)
        ..writeAsStringSync('? Who decides?\n= the owner\n');
      final report = await runQuiz(
        local: local,
        settings: SkillSettings(instructions: '~/rules/AGENTS.md'),
        ask: (agent, q) async => {
          'agent': agent.id,
          'question': q.question,
          'passed': false,
          'answer': 'nobody',
        },
      );
      expect((report['results'] as List).map((r) => (r as Map)['agent']), [
        'claude',
      ]);
      expect(report['failed'], 1);
      expect(textQuiz(report), contains('0 of 1 answered as expected'));
    });
  });

  group('conversations', () {
    test('screenshots leave and words stay', () {
      final count = [0];
      final claude = utf8.encode(
        '{"message":{"content":[{"type":"text","text":"look at this base64 thing"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk"}}]}}',
      );
      final out = utf8.decode(slimLine(claude, count));
      expect(count[0], 1);
      expect(out, contains('look at this base64 thing'));
      expect(out, contains('screenshot left out'));
      expect(out, isNot(contains('iVBORw0KGgo')));

      final codex = utf8.encode(
        '{"payload":{"content":[{"type":"input_image","image_url":"data:image/png;base64,${'A' * 400}"}]}}',
      );
      expect(utf8.decode(slimLine(codex, count)), isNot(contains('AAAA')));
      expect(count[0], 2);

      final plain = utf8.encode('{"text":"no pictures here"}');
      expect(slimLine(plain, count), plain);
      final broken = utf8.encode('{not json base64');
      expect(slimLine(broken, count), broken);
      expect(count[0], 2);
    });

    test('copies keep their names', () {
      expect(
        copyName('codex/sessions/a.jsonl', 'a.jsonl'),
        'codex/sessions/a.jsonl.gz',
      );
      expect(copyName('extra/x/s.tar.zst', 's.tar.zst'), 'extra/x/s.tar.zst');
      expect(
        extraName('/srv/backups/old-sessions'),
        'srv-backups-old-sessions',
      );
    });

    test(
      'pack keeps every word, never deletes, and repacks only what changed',
      () async {
        final root = Directory.systemTemp.createTempSync('fab-conv-');
        addTearDown(() => root.deleteSync(recursive: true));
        final local = tempLocal(root);
        final session = File('${root.path}/.codex/sessions/2026/s.jsonl')
          ..createSync(recursive: true)
          ..writeAsStringSync(
            '{"a":1}\n{"b":"data:image/png;base64,${'Q' * 300}"}\n{"c":"last line without a newline"}',
          );
        final settings = ConversationSettings();
        final first = await pack(local, settings);
        expect(first['packed'], 1);
        expect(first['sessions'], 1);
        expect(first['images_left_out'], 1);
        final copy = File(
          '${root.path}/Backups/conversations/testbox/codex/sessions/2026/s.jsonl.gz',
        );
        final text = utf8.decode(gzip.decode(copy.readAsBytesSync()));
        expect(text, startsWith('{"a":1}\n'));
        expect(text, contains('screenshot left out'));
        expect(text, isNot(contains('QQQQ')));
        expect(text, endsWith('"last line without a newline"}'));
        final again = await pack(local, settings);
        expect([again['packed'], again['unchanged']], [0, 1]);
        // A session removed here stays in the copy.
        session.deleteSync();
        await pack(local, settings);
        expect(copy.existsSync(), true);
        final shown = status(local, settings);
        expect(
          (shown['copies'] as List).single,
          containsPair('device', 'testbox'),
        );
        expect(shown['sessions'], 0);
      },
    );

    test('a manifest written before keeps its files unchanged', () async {
      final root = Directory.systemTemp.createTempSync('fab-manifest-');
      addTearDown(() => root.deleteSync(recursive: true));
      final local = tempLocal(root);
      final session = File('${root.path}/.claude/history.jsonl')
        ..createSync(recursive: true)
        ..writeAsStringSync('{"x":1}\n');
      final folder = '${root.path}/Backups/conversations/testbox';
      final (size, mtime) = fileState(session.path)!;
      File('$folder/claude/history.jsonl.gz')
        ..createSync(recursive: true)
        ..writeAsBytesSync(gzip.encode(utf8.encode('{"x":1}\n')));
      File('$folder/.manifest.json').writeAsStringSync(
        jsonEncode({
          'claude/history.jsonl': [size, mtime],
        }),
      );
      final report = await pack(local, ConversationSettings());
      expect([report['packed'], report['unchanged']], [0, 1]);
    });

    test(
      'a copy without a pair says how to add one; a dry run plans both ways',
      () async {
        final root = Directory.systemTemp.createTempSync('fab-copy-');
        addTearDown(() => root.deleteSync(recursive: true));
        final local = tempLocal(root);
        expect(
          () => copy(
            local: local,
            settings: ConversationSettings(),
            execute: false,
          ),
          throwsA(isA<ConversationsError>()),
        );
        final planned = await copy(
          local: local,
          settings: ConversationSettings.parse(
            '[[pair]]\ndevices = ["testbox", "other"]\n',
          ),
          execute: false,
        );
        expect(
          (planned['runs'] as List).map(
            (r) => '${(r as Map)['from']}>${r['to']} ${r['result']}',
          ),
          ['other>testbox planned', 'testbox>other planned'],
        );
      },
    );

    test('a direction that keeps failing counts its days', () {
      final root = Directory.systemTemp.createTempSync('fab-behind-');
      addTearDown(() => root.deleteSync(recursive: true));
      final local = tempLocal(root);
      final now = unixNow();
      CopyState(local).write([
        {
          'from': 'other',
          'to': 'testbox',
          'result': 'failed',
          'detail': 'offline',
          'at_unix_seconds': now,
          'failing_since_unix_seconds': now - 4 * 86400,
        },
        {
          'from': 'testbox',
          'to': 'other',
          'result': 'ok',
          'detail': '',
          'at_unix_seconds': now,
          'failing_since_unix_seconds': 0,
        },
      ]);
      final behind = (status(local, ConversationSettings())['behind'] as List)
          .cast<Map>();
      expect(behind.single['from'], 'other');
      expect(behind.single['days'], 4);
    });

    test('the settings name pairs of two devices', () {
      expect(
        () => ConversationSettings.parse('[[pair]]\ndevices = ["a"]\n'),
        throwsA(isA<TomlError>()),
      );
      final settings = ConversationSettings.parse(
        'bwlimit_kbps = 500\n\n[[pair]]\ndevices = ["a", "b"]\n\n[[extra]]\ndevice = "a"\npath = "/srv/x"\n',
      );
      expect(settings.pairs.single, ('a', 'b'));
      expect(settings.extras.single, ('a', '/srv/x'));
      expect(settings.bwlimitKbps, 500);
    });

    test('the other side\'s CLI is found or named as missing', () {
      expect(
        remoteCli('conversations pack --format json'),
        contains('exec "\$f" conversations pack'),
      );
      expect(
        remoteCli('x'),
        contains('fluttairbar-cli is not installed there'),
      );
      // Where it is not installed, what packs there instead.
      final otherwise = remoteCli('x', otherwise: 'other-packer --json');
      expect(otherwise, endsWith('done; other-packer --json'));
      expect(otherwise, isNot(contains('not installed there')));
    });

    test('--pack names what packs on a device without this CLI', () {
      final opts = parseAgentOptions([
        'copy',
        '--pack',
        'mac=other-packer --json',
      ]);
      expect(opts.pack, {'mac': 'other-packer --json'});
      expect(
        () => parseAgentOptions(['copy', '--pack', 'mac= ']),
        throwsA(isA<CliFailure>().having((f) => f.exit, 'exit', 64)),
      );
      expect(
        () => parseAgentOptions(['copy', '--pack', 'nothing']),
        throwsA(isA<CliFailure>()),
      );
    });

    test(
      'a device without this CLI is packed by --pack and copied both ways',
      () async {
        final root = Directory.systemTemp.createTempSync('fab-pack-');
        addTearDown(() => root.deleteSync(recursive: true));
        final local = tempLocal(Directory('${root.path}/here')..createSync());
        File('${local.home}/.claude/history.jsonl')
          ..createSync(recursive: true)
          ..writeAsStringSync('{"display":"here"}\n');
        final peer = '${root.path}/peer';
        // The other device's own packer: the same slim copy, a report.
        File('$peer/bin/other-packer')
          ..createSync(recursive: true)
          ..writeAsStringSync(
            '#!/bin/sh\nset -e\nmkdir -p "\$HOME/Backups/conversations/other/claude"\n'
            'printf \'{"display":"there"}\\n\' | gzip > "\$HOME/Backups/conversations/other/claude/history.jsonl.gz"\n'
            'echo \'{"schema_version":"other.pack.v1","packed":1}\'\n',
          );
        // ssh to "other" is a shell in the peer's home, without this CLI
        // on its PATH.
        File('$peer/bin/fake-rsh')
          ..createSync(recursive: true)
          ..writeAsStringSync(
            '#!/bin/sh\nshift\ncd "$peer" && HOME="$peer" PATH=/usr/bin:/bin exec sh -c "\$*"\n',
          );
        await Process.run('chmod', [
          '+x',
          '$peer/bin/other-packer',
          '$peer/bin/fake-rsh',
        ]);
        final report = await copy(
          local: local,
          settings: ConversationSettings.parse(
            '[[pair]]\ndevices = ["testbox", "other"]\n',
          ),
          execute: true,
          reach: {
            'other': Reach(
              '$peer/bin/fake-rsh',
              'other',
              pack: '"\$HOME/bin/other-packer"',
            ),
          },
        );
        expect(
          (report['runs'] as List).map(
            (r) => '${(r as Map)['from']}>${r['to']} ${r['result']}',
          ),
          ['other>testbox ok', 'testbox>other ok'],
        );
        final pulled = File(
          '${local.home}/Backups/conversations/other/claude/history.jsonl.gz',
        );
        expect(
          utf8.decode(gzip.decode(pulled.readAsBytesSync())),
          '{"display":"there"}\n',
        );
        expect(
          File(
            '$peer/Backups/conversations/testbox/claude/history.jsonl.gz',
          ).existsSync(),
          isTrue,
        );
      },
    );

    group('exclude', () {
      late Directory root;
      late Local local;
      late String folder;
      setUp(() {
        root = Directory.systemTemp.createTempSync('fab-exclude-');
        local = tempLocal(root);
        folder = '${root.path}/Backups/conversations/testbox';
        writeHistory(root.path);
      });
      tearDown(() => root.deleteSync(recursive: true));

      test('the settings and --exclude name parts of a path', () {
        final settings = ConversationSettings.parse(
          'exclude = ["/Documents/acme", "acme-intern", "/Documents/acme"]\n',
        );
        expect(settings.exclude, ['/Documents/acme', 'acme-intern']);
        expect(ConversationSettings().exclude, isEmpty);
        expect(settings.excluding(['x1', 'acme-intern']).exclude, [
          '/Documents/acme',
          'acme-intern',
          'x1',
        ]);
        // `/` alone would leave out everything: refused.
        expect(
          () => ConversationSettings.parse('exclude = ["/"]\n'),
          throwsA(isA<TomlError>()),
        );
        expect(parseAgentOptions(['pack', '--exclude', 'acme']).exclude, [
          'acme',
        ]);
        expect(
          () => parseAgentOptions(['pack', '--exclude', '//']),
          throwsA(isA<CliFailure>().having((f) => f.exit, 'exit', 64)),
        );
      });

      test('a Claude project is never packed, nor its history lines', () async {
        final report = await pack(
          local,
          ConversationSettings.parse('exclude = ["/Documents/acme"]\n'),
        );
        expect(
          Directory(
            '$folder/claude/projects/-home-u-Documents-acme-app',
          ).existsSync(),
          isFalse,
        );
        expect(
          File('$folder/claude/projects/-home-u-own/c2.jsonl.gz').existsSync(),
          isTrue,
        );
        final history = gunzipped('$folder/claude/history.jsonl.gz');
        expect(history, contains('own prompt'));
        expect(history, isNot(contains('work prompt')));
        expect(
          report['excluded_paths'],
          contains('claude/projects/-home-u-Documents-acme-app/'),
        );
        expect(report['exclude'], ['/Documents/acme']);
      });

      test('a Codex session is left out by the folder it ran in', () async {
        final settings = ConversationSettings.parse('exclude = ["acme-app"]\n');
        final report = await pack(local, settings);
        final copy = '$folder/codex/sessions/2026/11/01';
        expect(
          File(
            '$copy/rollout-2026-11-01T10-00-00-$_workId.jsonl.gz',
          ).existsSync(),
          isFalse,
        );
        expect(
          File(
            '$copy/rollout-2026-11-01T11-00-00-$_ownId.jsonl.gz',
          ).existsSync(),
          isTrue,
        );
        for (final name in ['history', 'session_index']) {
          final text = gunzipped('$folder/codex/$name.jsonl.gz');
          expect(text, contains('own'));
          expect(text, isNot(contains('work')));
        }
        // Claude's history line, Codex's history line and its index line.
        expect(report['history_lines_left_out'], 3);
        expect(
          sessionCwd('${root.path}/$_workSession'),
          '/home/u/Documents/acme-app',
        );
      });

      test(
        'a copy made before stays, is not updated, and is named to stay',
        () async {
          await pack(local, ConversationSettings());
          final copy = '$folder/${_workSession.substring(1)}.gz';
          expect(File(copy).existsSync(), isTrue);
          File(
            '${root.path}/$_workSession',
          ).writeAsStringSync('{"text":"later work"}\n', mode: FileMode.append);
          final settings = ConversationSettings.parse(
            'exclude = ["/Documents/acme"]\n',
          );
          final report = await pack(local, settings);
          expect(File(copy).existsSync(), isTrue);
          expect(gunzipped(copy), isNot(contains('later work')));
          final named = copy.substring(folder.length + 1);
          expect(report['excluded_paths'], contains(named));
          // Its session gone here, the copy itself says where it ran.
          File('${root.path}/$_workSession').deleteSync();
          expect(
            (await pack(local, settings))['excluded_paths'],
            contains(named),
          );
        },
      );

      test('a Codex session names its folder, also in older forms', () {
        String? cwdOf(String text, {bool gzipped = false}) {
          final file = File(
            '${root.path}/cwd-test.jsonl${gzipped ? '.gz' : ''}',
          );
          if (gzipped) {
            file.writeAsBytesSync(gzip.encode(utf8.encode(text)));
          } else {
            file.writeAsStringSync(text);
          }
          return sessionCwd(file.path);
        }

        // Before session_meta named it: the environment context.
        expect(
          cwdOf(
            '{"type":"message","content":[{"text":"<environment_context>\\n  <cwd>/home/u/old\\\\acme</cwd>\\n</environment_context>"}]}\n',
          ),
          r'/home/u/old\acme',
        );
        // The key cut by the end of the first read, and through gzip.
        const head = '{"payload":{"instructions":"';
        final far =
            '$head${'x' * (65536 - 3 - head.length - 2)}","cwd":"/home/u/far"}}\n';
        expect(cwdOf(far), '/home/u/far');
        expect(cwdOf(far, gzipped: true), '/home/u/far');
        expect(cwdOf('{"type":"message","text":"no folder"}\n'), isNull);
      });

      test('nothing is left out with an empty list', () async {
        final report = await pack(local, ConversationSettings());
        expect(report['exclude'], isEmpty);
        expect(report['excluded'], isEmpty);
        expect(report['excluded_paths'], isEmpty);
        expect(report['history_lines_left_out'], 0);
        expect(
          File(
            '$folder/claude/projects/-home-u-Documents-acme-app/c1.jsonl.gz',
          ).existsSync(),
          isTrue,
        );
        expect(
          gunzipped('$folder/codex/history.jsonl.gz'),
          contains('work prompt'),
        );
        expect(status(local, ConversationSettings())['excluded'], isEmpty);
      });

      test('status counts the projects each entry leaves out, and why', () {
        final report = status(
          local,
          ConversationSettings.parse(
            'exclude = ["/documents/ACME", "nothing-here"]\n',
          ),
        );
        // The Claude project and the Codex session are one project: two
        // Claude transcripts and one Codex session. Case does not matter.
        expect(report['excluded'], [
          {'match': '/documents/ACME', 'projects': 1, 'sessions': 3},
          {'match': 'nothing-here', 'projects': 0, 'sessions': 0},
        ]);
        expect(report['exclude'], ['/documents/ACME', 'nothing-here']);
        // Still every session on this device: the originals are untouched.
        expect(report['sessions'], 8);
        expect(
          textStatus(report),
          contains(
            'left out: 1 project (3 sessions) whose path contains "/documents/ACME"',
          ),
        );
      });

      test('a copy leaves excluded projects out in both directions', () async {
        // Packed here before the exclude existed: stays, but is not sent.
        await pack(local, ConversationSettings());
        final peer = '${root.path}/peer';
        File('$peer/bin/new-packer')
          ..createSync(recursive: true)
          ..writeAsStringSync(
            '#!/bin/sh\nset -e\nprintf "%s\\n" "\$@" > "\$HOME/args"\n'
            'for p in -x-acme -x-own; do\n'
            '  mkdir -p "\$HOME/Backups/conversations/other/claude/projects/\$p"\n'
            '  echo "{}" | gzip > "\$HOME/Backups/conversations/other/claude/projects/\$p/s.jsonl.gz"\n'
            'done\n'
            'echo \'{"schema_version":"x","exclude":["acme"],"excluded_paths":["claude/projects/-x-acme/"]}\'\n',
          );
        File('$peer/bin/old-packer').writeAsStringSync(
          '#!/bin/sh\necho \'{"schema_version":"x","packed":1}\'\n',
        );
        File('$peer/bin/fake-rsh').writeAsStringSync(
          '#!/bin/sh\nshift\ncd "$peer" && HOME="$peer" PATH=/usr/bin:/bin exec sh -c "\$*"\n',
        );
        await Process.run('chmod', [
          '+x',
          '$peer/bin/new-packer',
          '$peer/bin/old-packer',
          '$peer/bin/fake-rsh',
        ]);
        final settings = ConversationSettings.parse(
          'exclude = ["acme"]\n\n[[pair]]\ndevices = ["testbox", "other"]\n',
        );
        Future<List<String>> run(String packer) async {
          final report = await copy(
            local: local,
            settings: settings,
            execute: true,
            reach: {
              'other': Reach(
                '$peer/bin/fake-rsh',
                'other',
                pack: '"\$HOME/bin/$packer"',
              ),
            },
          );
          return [
            for (final r in (report['runs'] as List).cast<Map>())
              '${r['from']}>${r['to']} ${r['result']} ${r['detail']}',
          ];
        }

        final runs = await run('new-packer');
        expect(runs.map((r) => r.split(' ').take(2).join(' ')), [
          'other>testbox ok',
          'testbox>other ok',
        ]);
        // The other side was asked to leave the same projects out.
        expect(
          File('$peer/args').readAsLinesSync(),
          containsAllInOrder(['--exclude', 'acme']),
        );
        final here =
            '${local.home}/Backups/conversations/other/claude/projects';
        expect(Directory('$here/-x-own').existsSync(), isTrue);
        expect(Directory('$here/-x-acme').existsSync(), isFalse);
        final there = '$peer/Backups/conversations/testbox';
        expect(
          File('$there/claude/projects/-home-u-own/c2.jsonl.gz').existsSync(),
          isTrue,
        );
        expect(
          Directory(
            '$there/claude/projects/-home-u-Documents-acme-app',
          ).existsSync(),
          isFalse,
        );
        expect(
          Directory(
            '$there/codex/sessions/2026/11/01',
          ).listSync().map((e) => e.path.split('/').last),
          ['rollout-2026-11-01T11-00-00-$_ownId.jsonl.gz'],
        );
        // A packer that does not say it applied the list is not copied from.
        final refused = await run('old-packer');
        expect(refused.first, startsWith('other>testbox failed'));
        expect(refused.first, contains('did not apply exclude "acme"'));
        expect(refused.last, startsWith('testbox>other ok'));
      });
    });
  });
}
