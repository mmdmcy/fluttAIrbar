import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/codex_capability.dart';
import 'harness_config.dart';
import 'harness_manager.dart';

class CodexCapabilityChange {
  const CodexCapabilityChange({
    required this.configPath,
    required this.backupPath,
    required this.table,
    required this.enabled,
    required this.changed,
  });

  final String configPath;
  final String backupPath;
  final String table;
  final bool enabled;
  final bool changed;
}

class CodexCapabilityConfigEditor {
  const CodexCapabilityConfigEditor();

  String setBooleanInTable(
    String contents, {
    required String table,
    required String key,
    required bool value,
  }) {
    if (!RegExp(r'^[A-Za-z0-9_.@"-]+$').hasMatch(table)) {
      throw ArgumentError.value(
        table,
        'table',
        'contains unsupported characters',
      );
    }
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(key)) {
      throw ArgumentError.value(key, 'key', 'contains unsupported characters');
    }

    final newline = contents.contains('\r\n') ? '\r\n' : '\n';
    final hadTrailingNewline = contents.endsWith('\n');
    final lines = contents.split(RegExp(r'\r?\n'));
    if (hadTrailingNewline && lines.isNotEmpty && lines.last.isEmpty) {
      lines.removeLast();
    }
    if (lines.length == 1 && lines.single.isEmpty) lines.clear();

    final header = '[$table]';
    final headerIndex = lines.indexWhere((line) => line.trim() == header);
    final renderedValue = value ? 'true' : 'false';
    var addedTable = false;

    if (headerIndex == -1) {
      if (lines.isNotEmpty && lines.last.trim().isNotEmpty) {
        lines.add('');
      }
      lines
        ..add(header)
        ..add('$key = $renderedValue');
      addedTable = true;
    } else {
      var sectionEnd = lines.length;
      for (var index = headerIndex + 1; index < lines.length; index++) {
        if (lines[index].trimLeft().startsWith('[')) {
          sectionEnd = index;
          break;
        }
      }

      final keyPattern = RegExp(
        '^((?:\\s*${RegExp.escape(key)}\\s*=\\s*))(true|false)(\\s*(?:#.*)?)\$',
      );
      final keyIndexes = <int>[];
      for (var index = headerIndex + 1; index < sectionEnd; index++) {
        if (keyPattern.hasMatch(lines[index])) keyIndexes.add(index);
      }
      if (keyIndexes.length > 1) {
        throw StateError('Codex config has duplicate $key keys in $header');
      }

      if (keyIndexes.isEmpty) {
        lines.insert(headerIndex + 1, '$key = $renderedValue');
      } else {
        final index = keyIndexes.single;
        lines[index] = lines[index].replaceFirstMapped(
          keyPattern,
          (match) => '${match.group(1)}$renderedValue${match.group(3) ?? ''}',
        );
      }
    }

    var result = lines.join(newline);
    if (hadTrailingNewline || addedTable) result += newline;
    return result;
  }
}

class CodexCapabilityManager {
  CodexCapabilityManager({
    CommandRunner? runner,
    HarnessEnvironment? environment,
    CodexCapabilityConfigEditor? configEditor,
  }) : _runner = runner ?? const LocalCommandRunner(),
       _environment = environment ?? HarnessEnvironment.system(),
       _configEditor = configEditor ?? const CodexCapabilityConfigEditor();

  static final _safePluginId = RegExp(r'^[A-Za-z0-9._@-]+$');
  static final _safeServerName = RegExp(r'^[A-Za-z0-9_-]+$');

  final CommandRunner _runner;
  final HarnessEnvironment _environment;
  final CodexCapabilityConfigEditor _configEditor;

  String get configPath => p.join(_environment.codexHome, 'config.toml');

  Future<CodexCapabilitySnapshot> discover() async {
    final pluginFuture = _runner.run('codex', ['plugin', 'list', '--json']);
    final mcpDefinitions = [
      for (final pack in CodexCapabilityCatalog.packs)
        for (final component in pack.components)
          if (component.kind == CodexCapabilityComponentKind.mcp) component,
    ];
    final mcpListFuture = _runner.run('codex', ['mcp', 'list']);
    final mcpFutures = <Future<CommandResult>>[
      for (final component in mcpDefinitions)
        _runner.run('codex', ['mcp', 'get', component.mcpServerName!]),
    ];

    final pluginResult = await pluginFuture;
    final mcpListResult = await mcpListFuture;
    final mcpResults = await Future.wait(mcpFutures);
    var pluginRecords = const <_CodexPluginRecord>[];
    var pluginError = pluginResult.succeeded
        ? null
        : _discoveryError(pluginResult);
    if (pluginResult.succeeded) {
      try {
        pluginRecords = _parsePlugins(pluginResult.stdout);
      } on FormatException {
        pluginError = 'Codex plugin discovery returned unreadable metadata.';
      } on Object {
        pluginError = 'Codex plugin discovery returned unreadable metadata.';
      }
    }

    final listedMcpNames = mcpListResult.succeeded
        ? _parseMcpNames(mcpListResult.stdout)
        : const <String>{};
    final knownMcpNames = mcpDefinitions
        .map((definition) => definition.mcpServerName!)
        .toSet();
    final dynamicMcpDefinitions = [
      for (final name in listedMcpNames)
        if (!knownMcpNames.contains(name))
          CodexCapabilityComponentDefinition(
            id: 'mcp-$name',
            packId: 'other-mcp',
            displayName: name,
            description: 'Configured MCP server.',
            kind: CodexCapabilityComponentKind.mcp,
            mcpServerName: name,
          ),
    ];
    final knownPluginNames = CodexCapabilityCatalog.packs
        .expand((pack) => pack.components)
        .where(
          (component) => component.kind == CodexCapabilityComponentKind.plugin,
        )
        .map((component) => component.pluginName!)
        .toSet();
    final dynamicPluginRecords = pluginRecords
        .where((record) => !knownPluginNames.contains(record.name))
        .toList();
    final definitions = <CodexCapabilityPackDefinition>[
      ...CodexCapabilityCatalog.packs,
      if (dynamicPluginRecords.isNotEmpty)
        CodexCapabilityPackDefinition(
          id: 'other-plugins',
          displayName: 'Other installed plugins',
          description:
              'Installed Codex plugins not yet included in a curated fluttAIrbar pack.',
          components: [
            for (final record in dynamicPluginRecords)
              CodexCapabilityComponentDefinition(
                id: 'plugin-${record.pluginId}',
                packId: 'other-plugins',
                displayName: record.name,
                description: 'Installed Codex plugin.',
                kind: CodexCapabilityComponentKind.plugin,
                pluginName: record.name,
              ),
          ],
        ),
      if (dynamicMcpDefinitions.isNotEmpty)
        CodexCapabilityPackDefinition(
          id: 'other-mcp',
          displayName: 'Other MCP servers',
          description:
              'Configured MCP servers not yet included in a curated fluttAIrbar pack.',
          components: dynamicMcpDefinitions,
        ),
    ];

    final mcpById = <String, CommandResult>{};
    for (var index = 0; index < mcpDefinitions.length; index++) {
      mcpById[mcpDefinitions[index].mcpServerName!] = mcpResults[index];
    }
    for (final definition in dynamicMcpDefinitions) {
      final result = await _runner.run('codex', [
        'mcp',
        'get',
        definition.mcpServerName!,
      ]);
      mcpById[definition.mcpServerName!] = result;
    }

    final packs = <CodexCapabilityPackStatus>[];
    for (final pack in definitions) {
      final components = <CodexCapabilityComponentStatus>[];
      for (final definition in pack.components) {
        if (definition.kind == CodexCapabilityComponentKind.plugin) {
          components.add(_pluginStatus(definition, pluginRecords, pluginError));
        } else {
          components.add(
            _mcpStatus(
              definition,
              mcpById[definition.mcpServerName!],
              listed: listedMcpNames.contains(definition.mcpServerName),
            ),
          );
        }
      }
      packs.add(
        CodexCapabilityPackStatus(definition: pack, components: components),
      );
    }

    return CodexCapabilitySnapshot(
      packs: packs,
      configPath: configPath,
      checkedAt: DateTime.now(),
      error:
          pluginError ??
          (mcpListResult.succeeded ? null : _mcpListError(mcpListResult)),
    );
  }

  Future<CodexCapabilityChange> setEnabled(
    CodexCapabilityComponentStatus component,
    bool enabled,
  ) async {
    if (!component.toggleable) {
      throw StateError(
        '${component.definition.displayName} is not available to toggle',
      );
    }
    final table = _tableFor(component);
    final file = File(configPath);
    if (!file.existsSync()) {
      throw StateError('Codex config.toml was not found');
    }

    final original = file.readAsStringSync();
    final updated = _configEditor.setBooleanInTable(
      original,
      table: table,
      key: 'enabled',
      value: enabled,
    );
    if (updated == original) {
      return CodexCapabilityChange(
        configPath: configPath,
        backupPath: '$configPath.fluttairbar.bak',
        table: table,
        enabled: enabled,
        changed: false,
      );
    }

    final latest = file.readAsStringSync();
    if (latest != original) {
      throw StateError(
        'Codex config changed while fluttAIrbar was editing it; refresh and retry',
      );
    }
    final backupPath = '$configPath.fluttairbar.bak';
    file.copySync(backupPath);
    _writeAtomically(file, updated);
    return CodexCapabilityChange(
      configPath: configPath,
      backupPath: backupPath,
      table: table,
      enabled: enabled,
      changed: true,
    );
  }

  String _tableFor(CodexCapabilityComponentStatus component) {
    final observedId = component.observedId!;
    if (component.definition.kind == CodexCapabilityComponentKind.plugin) {
      if (!_safePluginId.hasMatch(observedId)) {
        throw StateError('Codex returned an unsupported plugin identifier');
      }
      return 'plugins."$observedId"';
    }
    if (!_safeServerName.hasMatch(observedId)) {
      throw StateError('Codex returned an unsupported MCP server identifier');
    }
    return 'mcp_servers.$observedId';
  }

  CodexCapabilityComponentStatus _pluginStatus(
    CodexCapabilityComponentDefinition definition,
    List<_CodexPluginRecord> records,
    String? discoveryError,
  ) {
    _CodexPluginRecord? record;
    for (final candidate in records) {
      if (candidate.matches(definition.pluginName!)) {
        record = candidate;
        break;
      }
    }
    if (record == null) {
      return CodexCapabilityComponentStatus(
        definition: definition,
        installed: false,
        enabled: false,
        stateKnown: discoveryError == null,
        error: discoveryError,
      );
    }
    return CodexCapabilityComponentStatus(
      definition: definition,
      installed: true,
      enabled: record.enabled,
      stateKnown: record.enabledKnown,
      observedId: record.pluginId,
      version: record.version,
      sourcePath: record.sourcePath,
      error: record.enabledKnown
          ? null
          : 'Codex did not report this plugin\'s enabled state.',
    );
  }

  CodexCapabilityComponentStatus _mcpStatus(
    CodexCapabilityComponentDefinition definition,
    CommandResult? result, {
    required bool listed,
  }) {
    if (result == null || !result.succeeded) {
      return CodexCapabilityComponentStatus(
        definition: definition,
        installed: listed,
        enabled: false,
        stateKnown: false,
        observedId: listed ? definition.mcpServerName : null,
        error: listed ? 'Codex returned no readable MCP status.' : null,
      );
    }
    final enabledMatch = RegExp(
      r'^\s*enabled:\s*(true|false)\s*$',
      multiLine: true,
    ).firstMatch(result.stdout);
    if (enabledMatch == null) {
      return CodexCapabilityComponentStatus(
        definition: definition,
        installed: true,
        enabled: false,
        stateKnown: false,
        observedId: definition.mcpServerName,
        error: 'Codex returned an unreadable MCP status',
      );
    }
    return CodexCapabilityComponentStatus(
      definition: definition,
      installed: true,
      enabled: enabledMatch.group(1) == 'true',
      stateKnown: true,
      observedId: definition.mcpServerName,
    );
  }

  List<_CodexPluginRecord> _parsePlugins(String stdout) {
    final decoded = jsonDecode(stdout);
    if (decoded is! Map) {
      throw const FormatException('plugin list is not an object');
    }
    final installed = decoded['installed'];
    if (installed is! List) {
      throw const FormatException('plugin list has no installed array');
    }
    return [
      for (final item in installed)
        if (item is Map) _CodexPluginRecord.fromJson(item),
    ];
  }

  Set<String> _parseMcpNames(String stdout) {
    final names = <String>{};
    for (final line in stdout.split(RegExp(r'\r?\n'))) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.toLowerCase().startsWith('no mcp')) {
        continue;
      }
      final match = RegExp(r'^([A-Za-z0-9_-]+)(?:\s|$)').firstMatch(trimmed);
      final name = match?.group(1);
      if (name != null && name != 'Name') names.add(name);
    }
    return names;
  }

  String _mcpListError(CommandResult result) {
    if (result.exitCode == -1) {
      return 'Codex CLI was not found while checking MCP servers.';
    }
    if (result.exitCode == -2) return 'Codex MCP discovery timed out.';
    return 'Codex MCP discovery failed. Check the Codex CLI and refresh.';
  }

  String? _discoveryError(CommandResult result) {
    if (result.exitCode == -1) {
      return 'Codex CLI was not found. Install Codex or make it visible to fluttAIrbar.';
    }
    if (result.exitCode == -2) return 'Codex plugin discovery timed out.';
    return 'Codex plugin discovery failed. Check the Codex CLI and refresh.';
  }

  void _writeAtomically(File target, String contents) {
    final temporary = File(
      '${target.path}.fluttairbar.tmp.$pid.${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      temporary.writeAsStringSync(contents, flush: true);
      if (Platform.isWindows && target.existsSync()) target.deleteSync();
      temporary.renameSync(target.path);
    } finally {
      if (temporary.existsSync()) temporary.deleteSync();
    }
  }
}

class _CodexPluginRecord {
  const _CodexPluginRecord({
    required this.pluginId,
    required this.name,
    required this.enabled,
    required this.enabledKnown,
    this.version,
    this.sourcePath,
  });

  factory _CodexPluginRecord.fromJson(Map<dynamic, dynamic> json) {
    final pluginId = json['pluginId']?.toString();
    final name = json['name']?.toString();
    if (pluginId == null || pluginId.isEmpty || name == null || name.isEmpty) {
      throw const FormatException('plugin list contains an invalid plugin');
    }
    return _CodexPluginRecord(
      pluginId: pluginId,
      name: name,
      enabled: json['enabled'] is bool ? json['enabled'] as bool : false,
      enabledKnown: json['enabled'] is bool,
      version: json['version']?.toString(),
      sourcePath: (json['source'] is Map)
          ? (json['source'] as Map)['path']?.toString()
          : null,
    );
  }

  final String pluginId;
  final String name;
  final bool enabled;
  final bool enabledKnown;
  final String? version;
  final String? sourcePath;

  bool matches(String expectedName) {
    return name == expectedName || pluginId.split('@').first == expectedName;
  }
}
