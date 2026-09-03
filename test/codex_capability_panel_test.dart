import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fluttairbar/providers/codex_capability_store.dart';
import 'package:fluttairbar/services/codex_capability_manager.dart';
import 'package:fluttairbar/services/harness_config.dart';
import 'package:fluttairbar/services/harness_manager.dart';
import 'package:fluttairbar/ui/codex_capability_panel.dart';

void main() {
  testWidgets('standalone skill switch saves an exact disabled override', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final directory = Directory.systemTemp.createTempSync(
      'fluttairbar-skill-panel-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final skillPath = _writeSkill(directory.path, 'widget-skill');
    final config = File('${directory.path}/config.toml')
      ..writeAsStringSync('model = "gpt-5"\n');
    final store = CodexCapabilityStore(
      manager: CodexCapabilityManager(
        runner: _emptyCapabilityRunner(),
        environment: _environment(directory.path),
      ),
    );

    await tester.runAsync(
      () => store.refresh().timeout(const Duration(seconds: 5)),
    );
    await tester.pumpWidget(_testApp(store));
    await _pumpUi(tester);

    expect(find.text('Standalone user skills'), findsOneWidget);
    expect(find.text('widget-skill'), findsOneWidget);
    expect(find.textContaining('Can activate automatically'), findsOneWidget);

    await tester.tap(find.widgetWithText(SwitchListTile, 'widget-skill'));
    await _pumpUi(tester);
    expect(find.text('Disable widget-skill?'), findsOneWidget);
    expect(find.textContaining('[[skills.config]]'), findsOneWidget);

    await tester.tap(find.text('Save'));
    await _pumpUi(tester);

    expect(
      const CodexCapabilityConfigEditor().skillStates(
        config.readAsStringSync(),
      ),
      {skillPath: false},
    );
    final tile = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, 'widget-skill'),
    );
    expect(tile.value, isFalse);
    expect(find.textContaining('Restart required'), findsWidgets);
  });

  testWidgets('standalone skill pack can disable all discovered skills', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final directory = Directory.systemTemp.createTempSync(
      'fluttairbar-skill-pack-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final firstPath = _writeSkill(directory.path, 'first-skill');
    final secondPath = _writeSkill(directory.path, 'second-skill');
    final config = File('${directory.path}/config.toml')
      ..writeAsStringSync('model = "gpt-5"\n');
    final store = CodexCapabilityStore(
      manager: CodexCapabilityManager(
        runner: _emptyCapabilityRunner(),
        environment: _environment(directory.path),
      ),
    );

    await tester.runAsync(
      () => store.refresh().timeout(const Duration(seconds: 5)),
    );
    await tester.pumpWidget(_testApp(store));
    await _pumpUi(tester);

    expect(find.text('Disable all'), findsOneWidget);
    await tester.tap(find.text('Disable all'));
    await _pumpUi(tester);
    expect(find.text('Disable Standalone user skills?'), findsOneWidget);

    await tester.tap(find.text('Save'));
    await _pumpUi(tester);

    expect(
      const CodexCapabilityConfigEditor().skillStates(
        config.readAsStringSync(),
      ),
      {firstPath: false, secondPath: false},
    );
  });
}

Widget _testApp(CodexCapabilityStore store) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 500,
        height: 900,
        child: AnimatedBuilder(
          animation: store,
          builder: (context, _) => CodexCapabilityPanel(store: store),
        ),
      ),
    ),
  );
}

Future<void> _pumpUi(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

String _writeSkill(String home, String name) {
  final directory = Directory('$home/.agents/skills/$name')
    ..createSync(recursive: true);
  final skillPath = '${directory.path}/SKILL.md';
  File(skillPath).writeAsStringSync(
    '---\n'
    'name: $name\n'
    'description: A skill used by the capability panel widget test.\n'
    '---\n',
  );
  return skillPath;
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
