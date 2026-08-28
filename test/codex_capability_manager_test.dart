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
