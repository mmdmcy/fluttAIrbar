import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

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

  Map<String, bool> skillStates(String contents) {
    final lines = contents.split(RegExp(r'\r?\n'));
    final states = <String, bool>{};
    for (final block in _skillConfigBlocks(lines)) {
      if (states.containsKey(block.path)) {
        throw StateError(
          'Codex config has duplicate skills.config entries for ${block.path}',
        );
      }
      states[block.path] = block.enabled ?? true;
    }
    return states;
  }

  String setSkillEnabled(
    String contents, {
    required String path,
    required bool value,
  }) {
    if (!p.isAbsolute(path) || p.basename(path) != 'SKILL.md') {
      throw ArgumentError.value(
        path,
        'path',
        'must be an absolute SKILL.md path',
      );
    }

    final newline = contents.contains('\r\n') ? '\r\n' : '\n';
    final hadTrailingNewline = contents.endsWith('\n');
    final lines = contents.split(RegExp(r'\r?\n'));
    if (hadTrailingNewline && lines.isNotEmpty && lines.last.isEmpty) {
      lines.removeLast();
    }
    if (lines.length == 1 && lines.single.isEmpty) lines.clear();

    final matches = _skillConfigBlocks(
      lines,
    ).where((block) => block.path == path).toList();
    if (matches.length > 1) {
      throw StateError(
        'Codex config has duplicate skills.config entries for $path',
      );
    }

    if (matches.isEmpty) {
      if (value) return contents;
      if (lines.isNotEmpty && lines.last.trim().isNotEmpty) lines.add('');
      lines
        ..add('[[skills.config]]')
        ..add('path = ${jsonEncode(path)}')
        ..add('enabled = false');
      return '${lines.join(newline)}$newline';
    }

    final block = matches.single;
    final renderedValue = value ? 'true' : 'false';
    if (block.enabledLine == null) {
      lines.insert(block.pathLine + 1, 'enabled = $renderedValue');
    } else {
      final keyPattern = RegExp(
        r'^(\s*enabled\s*=\s*)(true|false)(\s*(?:#.*)?)$',
      );
      final index = block.enabledLine!;
      lines[index] = lines[index].replaceFirstMapped(
        keyPattern,
        (match) => '${match.group(1)}$renderedValue${match.group(3) ?? ''}',
      );
    }

    var result = lines.join(newline);
    if (hadTrailingNewline) result += newline;
    return result;
  }

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

  List<_SkillConfigBlock> _skillConfigBlocks(List<String> lines) {
    final blocks = <_SkillConfigBlock>[];
    for (var index = 0; index < lines.length; index++) {
      if (lines[index].trim() != '[[skills.config]]') continue;
      var end = lines.length;
      for (var candidate = index + 1; candidate < lines.length; candidate++) {
        if (lines[candidate].trimLeft().startsWith('[')) {
          end = candidate;
          break;
        }
      }

      final pathLines = <int>[];
      final enabledLines = <int>[];
      for (var candidate = index + 1; candidate < end; candidate++) {
        if (RegExp(r'^\s*path\s*=').hasMatch(lines[candidate])) {
          pathLines.add(candidate);
        }
        if (RegExp(r'^\s*enabled\s*=').hasMatch(lines[candidate])) {
          enabledLines.add(candidate);
        }
      }
      if (pathLines.length != 1 || enabledLines.length > 1) {
        throw StateError(
          'Codex config has an unreadable [[skills.config]] entry',
        );
      }

      final pathLine = pathLines.single;
      final pathValue = lines[pathLine].replaceFirst(
        RegExp(r'^\s*path\s*=\s*'),
        '',
      );
      final parsedPath = _parseTomlString(pathValue);
      if (parsedPath == null) {
        throw StateError('Codex config has an unreadable skills.config path');
      }

      bool? enabled;
      if (enabledLines.isNotEmpty) {
        final enabledValue = lines[enabledLines.single].replaceFirst(
          RegExp(r'^\s*enabled\s*=\s*'),
          '',
        );
        final match = RegExp(
          r'^(true|false)\s*(?:#.*)?$',
        ).firstMatch(enabledValue);
        if (match == null) {
          throw StateError(
            'Codex config has an unreadable skills.config enabled value',
          );
        }
        enabled = match.group(1) == 'true';
      }
      blocks.add(
        _SkillConfigBlock(
          path: parsedPath,
          pathLine: pathLine,
          enabledLine: enabledLines.firstOrNull,
          enabled: enabled,
        ),
      );
      index = end - 1;
    }
    return blocks;
  }

  String? _parseTomlString(String value) {
    final trimmed = value.trimLeft();
    if (trimmed.startsWith("'")) {
      final end = trimmed.indexOf("'", 1);
      if (end == -1 || !_onlyCommentAfter(trimmed, end + 1)) return null;
      return trimmed.substring(1, end);
    }
    if (!trimmed.startsWith('"')) return null;

    var escaped = false;
    for (var index = 1; index < trimmed.length; index++) {
      final character = trimmed[index];
      if (escaped) {
        escaped = false;
      } else if (character == r'\') {
        escaped = true;
      } else if (character == '"') {
        if (!_onlyCommentAfter(trimmed, index + 1)) return null;
        try {
          final decoded = jsonDecode(trimmed.substring(0, index + 1));
          return decoded is String ? decoded : null;
        } on FormatException {
          return null;
        }
      }
    }
    return null;
  }

  bool _onlyCommentAfter(String value, int start) {
    final remainder = value.substring(start).trimLeft();
    return remainder.isEmpty || remainder.startsWith('#');
  }
}

class _SkillConfigBlock {
  const _SkillConfigBlock({
    required this.path,
    required this.pathLine,
    required this.enabledLine,
    required this.enabled,
  });

  final String path;
  final int pathLine;
  final int? enabledLine;
  final bool? enabled;
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
    final skillFuture = Future<_SkillDiscovery>(_discoverSkills);
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
    final skillDiscovery = await skillFuture;
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
      if (skillDiscovery.records.isNotEmpty)
        CodexCapabilityPackDefinition(
          id: 'user-skills',
          displayName: 'Standalone user skills',
          description:
              'Skills discovered in your user-level Codex skill folders. These switches control each exact SKILL.md independently of plugins.',
          components: [
            for (final record in skillDiscovery.records)
              CodexCapabilityComponentDefinition(
                id: 'skill:${record.path}',
                packId: 'user-skills',
                displayName: record.name,
                description: record.description,
                kind: CodexCapabilityComponentKind.skill,
                skillPath: record.path,
                skillScope: record.scope,
                allowsImplicitInvocation: record.allowsImplicitInvocation,
              ),
          ],
        ),
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
        } else if (definition.kind == CodexCapabilityComponentKind.mcp) {
          components.add(
            _mcpStatus(
              definition,
              mcpById[definition.mcpServerName!],
              listed: listedMcpNames.contains(definition.mcpServerName),
            ),
          );
        } else {
          components.add(
            _skillStatus(
              definition,
              skillDiscovery.states,
              skillDiscovery.error,
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
          (mcpListResult.succeeded ? null : _mcpListError(mcpListResult)) ??
          skillDiscovery.error,
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
    final table =
        component.definition.kind == CodexCapabilityComponentKind.skill
        ? 'skills.config'
        : _tableFor(component);
    final file = File(configPath);
    if (!file.existsSync()) {
      throw StateError('Codex config.toml was not found');
    }

    final original = file.readAsStringSync();
    final updated =
        component.definition.kind == CodexCapabilityComponentKind.skill
        ? _configEditor.setSkillEnabled(
            original,
            path: _validatedSkillPath(component),
            value: enabled,
          )
        : _configEditor.setBooleanInTable(
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

  String _validatedSkillPath(CodexCapabilityComponentStatus component) {
    final path = component.observedId!;
    final normalized = p.normalize(path);
    if (!p.isAbsolute(normalized) || p.basename(normalized) != 'SKILL.md') {
      throw StateError('Codex returned an unsupported skill path');
    }
    final managed = _skillRoots().any(
      (root) => p.isWithin(p.normalize(root.path), normalized),
    );
    if (!managed || !File(normalized).existsSync()) {
      throw StateError('Codex skill is outside the managed user folders');
    }
    return normalized;
  }

  CodexCapabilityComponentStatus _skillStatus(
    CodexCapabilityComponentDefinition definition,
    Map<String, bool> states,
    String? discoveryError,
  ) {
    final path = definition.skillPath!;
    return CodexCapabilityComponentStatus(
      definition: definition,
      installed: true,
      enabled: states[_pathKey(path)] ?? true,
      stateKnown: discoveryError == null,
      observedId: path,
      sourcePath: path,
      error: discoveryError,
    );
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

  _SkillDiscovery _discoverSkills() {
    final records = <_SkillRecord>[];
    final seenPaths = <String>{};
    String? error;
    for (final root in _skillRoots()) {
      final directory = Directory(root.path);
      if (!directory.existsSync()) continue;
      try {
        for (final entity in directory.listSync(followLinks: false)) {
          final directoryName = p.basename(entity.path);
          if (directoryName.startsWith('.')) continue;
          final skillPath = p.normalize(p.join(entity.path, 'SKILL.md'));
          final skillFile = File(skillPath);
          if (!skillFile.existsSync() || !seenPaths.add(_pathKey(skillPath))) {
            continue;
          }
          records.add(_readSkillRecord(skillFile, root.scope));
        }
      } on Object {
        error ??= 'Some user skill folders could not be read.';
      }
    }

    final states = <String, bool>{};
    final config = File(configPath);
    if (config.existsSync()) {
      try {
        final parsed = _configEditor.skillStates(config.readAsStringSync());
        for (final entry in parsed.entries) {
          states[_pathKey(entry.key)] = entry.value;
        }
      } on Object {
        error ??=
            'Codex skill settings in config.toml could not be read safely.';
      }
    } else if (records.isNotEmpty) {
      error ??= 'Codex config.toml was not found.';
    }

    records.sort((left, right) {
      final byName = left.name.toLowerCase().compareTo(
        right.name.toLowerCase(),
      );
      return byName != 0 ? byName : left.path.compareTo(right.path);
    });
    return _SkillDiscovery(records: records, states: states, error: error);
  }

  List<_SkillRoot> _skillRoots() {
    final roots = <_SkillRoot>[];
    if (_environment.home.isNotEmpty) {
      roots.add(
        _SkillRoot(
          path: p.normalize(p.join(_environment.home, '.agents', 'skills')),
          scope: 'User · ~/.agents/skills',
        ),
      );
    }
    if (_environment.codexHome.isNotEmpty) {
      roots.add(
        _SkillRoot(
          path: p.normalize(p.join(_environment.codexHome, 'skills')),
          scope: 'User · Codex home',
        ),
      );
    }
    final seen = <String>{};
    return [
      for (final root in roots)
        if (seen.add(_pathKey(root.path))) root,
    ];
  }

  _SkillRecord _readSkillRecord(File file, String scope) {
    var name = p.basename(p.dirname(file.path));
    var description = 'Standalone Codex skill.';
    var allowsImplicitInvocation = true;
    try {
      if (file.lengthSync() <= 1024 * 1024) {
        final contents = file.readAsStringSync();
        final frontmatter = _yamlFrontmatter(contents);
        final metadata = frontmatter == null ? null : loadYaml(frontmatter);
        if (metadata is YamlMap) {
          final parsedName = metadata['name']?.toString().trim();
          final parsedDescription = metadata['description']?.toString().trim();
          if (parsedName != null && parsedName.isNotEmpty) name = parsedName;
          if (parsedDescription != null && parsedDescription.isNotEmpty) {
            description = parsedDescription.replaceAll(RegExp(r'\s+'), ' ');
          }
        }
      }

      final agentMetadata = File(
        p.join(p.dirname(file.path), 'agents', 'openai.yaml'),
      );
      if (agentMetadata.existsSync() &&
          agentMetadata.lengthSync() <= 256 * 1024) {
        final decoded = loadYaml(agentMetadata.readAsStringSync());
        if (decoded is YamlMap && decoded['policy'] is YamlMap) {
          final implicit =
              (decoded['policy'] as YamlMap)['allow_implicit_invocation'];
          if (implicit is bool) allowsImplicitInvocation = implicit;
        }
      }
    } on Object {
      description = 'Standalone Codex skill; metadata could not be read.';
    }
    return _SkillRecord(
      path: p.normalize(file.path),
      name: name,
      description: description,
      scope: scope,
      allowsImplicitInvocation: allowsImplicitInvocation,
    );
  }

  String? _yamlFrontmatter(String contents) {
    final lines = contents.split(RegExp(r'\r?\n'));
    if (lines.isEmpty || lines.first.trim() != '---') return null;
    for (var index = 1; index < lines.length; index++) {
      if (lines[index].trim() == '---') {
        return lines.sublist(1, index).join('\n');
      }
    }
    return null;
  }

  String _pathKey(String path) {
    final normalized = p.normalize(path);
    return _environment.isWindows ? normalized.toLowerCase() : normalized;
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

class _SkillRoot {
  const _SkillRoot({required this.path, required this.scope});

  final String path;
  final String scope;
}

class _SkillRecord {
  const _SkillRecord({
    required this.path,
    required this.name,
    required this.description,
    required this.scope,
    required this.allowsImplicitInvocation,
  });

  final String path;
  final String name;
  final String description;
  final String scope;
  final bool allowsImplicitInvocation;
}

class _SkillDiscovery {
  const _SkillDiscovery({
    required this.records,
    required this.states,
    required this.error,
  });

  final List<_SkillRecord> records;
  final Map<String, bool> states;
  final String? error;
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
