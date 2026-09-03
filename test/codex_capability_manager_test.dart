import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fluttairbar/models/codex_capability.dart';
import 'package:fluttairbar/services/codex_capability_manager.dart';
import 'package:fluttairbar/services/harness_config.dart';
import 'package:fluttairbar/services/harness_manager.dart';

void main() {
  test(
    'config editor changes one boolean and preserves neighboring tables',
    () {
      const contents =
          '[mcp_servers.stripe]\n'
          'url = "https://mcp.stripe.com"\n'
          'enabled = true # user choice\n\n'
          '[projects."/tmp/example"]\n'
          'trust_level = "trusted"\n';

      final updated = const CodexCapabilityConfigEditor().setBooleanInTable(
        contents,
        table: 'mcp_servers.stripe',
        key: 'enabled',
        value: false,
      );

      expect(updated, contains('enabled = false # user choice'));
      expect(updated, contains('url = "https://mcp.stripe.com"'));
      expect(updated, contains('trust_level = "trusted"'));
      expect(updated, isNot(contains('enabled = true # user choice')));
    },
  );

  test('config editor adds a missing key to an existing table', () {
    const contents = '[plugins."pstack@fluttairbar-local"]\n';

    final updated = const CodexCapabilityConfigEditor().setBooleanInTable(
      contents,
      table: 'plugins."pstack@fluttairbar-local"',
      key: 'enabled',
      value: false,
    );

    expect(updated, '[plugins."pstack@fluttairbar-local"]\nenabled = false\n');
  });

  test('config editor can create the first table in an empty config', () {
    final updated = const CodexCapabilityConfigEditor().setBooleanInTable(
      '',
      table: 'mcp_servers.stripe',
      key: 'enabled',
      value: false,
    );

    expect(updated, '[mcp_servers.stripe]\nenabled = false\n');
  });

  test('config editor rejects duplicate target keys', () {
    expect(
      () => const CodexCapabilityConfigEditor().setBooleanInTable(
        '[mcp_servers.stripe]\nenabled = true\nenabled = false\n',
        table: 'mcp_servers.stripe',
        key: 'enabled',
        value: true,
      ),
      throwsStateError,
    );
  });

  test(
    'config editor appends and reads an exact standalone skill override',
    () {
      const skillPath = '/tmp/skills/stripe-docs/SKILL.md';
      const contents =
          'model = "gpt-5"\n\n'
          '[mcp_servers.stripe]\n'
          'enabled = true\n';

      final editor = const CodexCapabilityConfigEditor();
      final updated = editor.setSkillEnabled(
        contents,
        path: skillPath,
        value: false,
      );

      expect(updated, contains('[[skills.config]]\n'));
      expect(updated, contains('path = "$skillPath"\nenabled = false'));
      expect(updated, contains('[mcp_servers.stripe]\nenabled = true'));
      expect(editor.skillStates(updated), {skillPath: false});
    },
  );

  test('config editor escapes and reads a quoted skill path', () {
    const skillPath = '/tmp/skills/quoted "name"/SKILL.md';
    const contents = 'model = "gpt-5"\n';

    final editor = const CodexCapabilityConfigEditor();
    final updated = editor.setSkillEnabled(
      contents,
      path: skillPath,
      value: false,
    );

    expect(editor.skillStates(updated), {skillPath: false});
  });

  test('config editor leaves an unlisted enabled skill at Codex default', () {
    const skillPath = '/tmp/skills/not-listed/SKILL.md';
    const contents = 'model = "gpt-5"\n';

    final updated = const CodexCapabilityConfigEditor().setSkillEnabled(
      contents,
      path: skillPath,
      value: true,
    );

    expect(updated, contents);
  });

  test('config editor updates only the matching standalone skill entry', () {
    const firstPath = '/tmp/skills/first/SKILL.md';
    const secondPath = '/tmp/skills/second/SKILL.md';
    const contents =
        '[[skills.config]]\n'
        'path = "$firstPath"\n'
        'enabled = false # keep this note\n\n'
        '[[skills.config]]\n'
        'path = "$secondPath"\n'
        'enabled = false\n';

    final editor = const CodexCapabilityConfigEditor();
    final updated = editor.setSkillEnabled(
      contents,
      path: firstPath,
      value: true,
    );

    expect(updated, contains('enabled = true # keep this note'));
    expect(editor.skillStates(updated), {firstPath: true, secondPath: false});
  });

  test('config editor rejects duplicate standalone skill entries', () {
    const skillPath = '/tmp/skills/duplicate/SKILL.md';
    const contents =
        '[[skills.config]]\n'
        'path = "$skillPath"\n'
        'enabled = false\n\n'
        '[[skills.config]]\n'
        'path = "$skillPath"\n'
        'enabled = true\n';

    expect(
      () => const CodexCapabilityConfigEditor().skillStates(contents),
      throwsStateError,
    );
  });

  test('discovery maps installed plugin and MCP state independently', () async {
    final directory = Directory.systemTemp.createTempSync('unused-');
    try {
      final runner = _FakeCommandRunner()
        ..responses['codex plugin list --json'] = const CommandResult(
          exitCode: 0,
          stdout:
              '{"installed":[{"pluginId":"stripe@openai-curated","name":"stripe","version":"11.74.0","enabled":true,"source":{"path":"/tmp/stripe"}}],"available":[]}',
          stderr: '',
        )
        ..responses['codex mcp get stripe'] = const CommandResult(
          exitCode: 0,
          stdout: 'stripe\n  enabled: false\n  transport: streamable_http\n',
          stderr: '',
        );
      final manager = CodexCapabilityManager(
        runner: runner,
        environment: _environment(directory.path),
      );

      final snapshot = await manager.discover();
      final stripe = snapshot.pack('stripe');

      expect(stripe.component('stripe-plugin').enabled, isTrue);
      expect(stripe.component('stripe-plugin').version, '11.74.0');
      expect(stripe.component('stripe-mcp').enabled, isFalse);
      expect(snapshot.pack('pstack').installed, isFalse);
    } finally {
      directory.deleteSync(recursive: true);
    }
  });

  test(
    'discovery maps standalone skill state and implicit invocation policy',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'fluttairbar-skills-',
      );
      try {
        final automaticPath = _writeSkill(
          directory.path,
          'automatic-skill',
          description: 'May activate when a task matches.',
        );
        final explicitPath = _writeSkill(
          directory.path,
          'explicit-skill',
          description: 'Only runs when selected.',
          allowImplicitInvocation: false,
        );
        File('${directory.path}/config.toml').writeAsStringSync(
          '[[skills.config]]\n'
          'path = "$automaticPath"\n'
          'enabled = false\n',
        );
        final manager = CodexCapabilityManager(
          runner: _emptyCapabilityRunner(),
          environment: _environment(directory.path),
        );

        final snapshot = await manager.discover();
        final skills = snapshot.pack('user-skills');
        final automatic = skills.components.firstWhere(
          (component) => component.definition.displayName == 'automatic-skill',
        );
        final explicit = skills.components.firstWhere(
          (component) => component.definition.displayName == 'explicit-skill',
        );

        expect(skills.components, hasLength(2));
        expect(automatic.enabled, isFalse);
        expect(automatic.sourcePath, automaticPath);
        expect(automatic.definition.allowsImplicitInvocation, isTrue);
        expect(explicit.enabled, isTrue);
        expect(explicit.sourcePath, explicitPath);
        expect(explicit.definition.allowsImplicitInvocation, isFalse);
      } finally {
        directory.deleteSync(recursive: true);
      }
    },
  );

  test('setEnabled writes the exact standalone skill path', () async {
    final directory = Directory.systemTemp.createTempSync(
      'fluttairbar-skill-toggle-',
    );
    try {
      final skillPath = _writeSkill(directory.path, 'toggle-me');
      final config = File('${directory.path}/config.toml')
        ..writeAsStringSync('model = "gpt-5"\n');
      final manager = CodexCapabilityManager(
        runner: _emptyCapabilityRunner(),
        environment: _environment(directory.path),
      );
      final snapshot = await manager.discover();
      final skill = snapshot
          .pack('user-skills')
          .components
          .singleWhere(
            (component) => component.definition.displayName == 'toggle-me',
          );

      final change = await manager.setEnabled(skill, false);

      expect(change.changed, isTrue);
      expect(change.table, 'skills.config');
      expect(
        const CodexCapabilityConfigEditor().skillStates(
          config.readAsStringSync(),
        ),
        {skillPath: false},
      );
      expect(File(change.backupPath).readAsStringSync(), 'model = "gpt-5"\n');
    } finally {
      directory.deleteSync(recursive: true);
    }
  });

  test(
    'setEnabled backs up config and edits only the requested component',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'fluttairbar-capability-',
      );
      try {
        final config = File('${directory.path}/config.toml')
          ..writeAsStringSync(
            'model = "gpt-5"\n\n'
            '[mcp_servers.stripe]\n'
            'url = "https://mcp.stripe.com"\n'
            'enabled = true\n\n'
            '[plugins."stripe@openai-curated"]\n'
            'enabled = true\n',
          );
        final runner = _FakeCommandRunner()
          ..responses['codex plugin list --json'] = const CommandResult(
            exitCode: 0,
            stdout:
                '{"installed":[{"pluginId":"stripe@openai-curated","name":"stripe","enabled":true}],"available":[]}',
            stderr: '',
          )
          ..responses['codex mcp get stripe'] = const CommandResult(
            exitCode: 0,
            stdout: 'stripe\n  enabled: true\n',
            stderr: '',
          );
        final manager = CodexCapabilityManager(
          runner: runner,
          environment: _environment(directory.path),
        );
        final snapshot = await manager.discover();

        final change = await manager.setEnabled(
          snapshot.component('stripe-mcp'),
          false,
        );

        expect(change.changed, isTrue);
        final updated = config.readAsStringSync();
        expect(
          updated,
          contains(
            '[mcp_servers.stripe]\nurl = "https://mcp.stripe.com"\nenabled = false',
          ),
        );
        expect(
          updated,
          contains('[plugins."stripe@openai-curated"]\nenabled = true'),
        );
        expect(updated, contains('model = "gpt-5"'));
        expect(
          File(change.backupPath).readAsStringSync(),
          contains('enabled = true'),
        );
      } finally {
        directory.deleteSync(recursive: true);
      }
    },
  );
}

HarnessEnvironment _environment(String directory) {
  return HarnessEnvironment(
    home: directory,
    configHome: directory,
    dataHome: directory,
    piDirectory: directory,
    codexHome: directory,
    grokConfigPath: null,
    appData: null,
    localAppData: null,
    isWindows: false,
    isMacOS: false,
  );
}

String _writeSkill(
  String home,
  String name, {
  String description = 'QA skill.',
  bool? allowImplicitInvocation,
}) {
  final directory = Directory('$home/.agents/skills/$name')
    ..createSync(recursive: true);
  final skillPath = '${directory.path}/SKILL.md';
  File(skillPath).writeAsStringSync(
    '---\n'
    'name: $name\n'
    'description: $description\n'
    '---\n\n'
    '# $name\n',
  );
  if (allowImplicitInvocation != null) {
    File('${directory.path}/agents/openai.yaml')
      ..createSync(recursive: true)
      ..writeAsStringSync(
        'policy:\n'
        '  allow_implicit_invocation: $allowImplicitInvocation\n',
      );
  }
  return skillPath;
}

_FakeCommandRunner _emptyCapabilityRunner() {
  return _FakeCommandRunner()
    ..responses['codex plugin list --json'] = const CommandResult(
      exitCode: 0,
      stdout: '{"installed":[],"available":[]}',
      stderr: '',
    )
    ..responses['codex mcp list'] = const CommandResult(
      exitCode: 0,
      stdout: 'No MCP servers configured.\n',
      stderr: '',
    )
    ..responses['codex mcp get stripe'] = const CommandResult(
      exitCode: 1,
      stdout: '',
      stderr: 'not configured',
    );
}

class _FakeCommandRunner implements CommandRunner {
  final Map<String, CommandResult> responses = <String, CommandResult>{};

  @override
  Future<CommandResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    return responses['$executable ${arguments.join(' ')}'] ??
        const CommandResult(exitCode: 1, stdout: '', stderr: 'not configured');
  }
}

extension on CodexCapabilityPackStatus {
  CodexCapabilityComponentStatus component(String id) {
    return components.firstWhere((component) => component.definition.id == id);
  }
}
