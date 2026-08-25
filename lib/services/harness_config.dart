import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/harness.dart';

class HarnessEnvironment {
  const HarnessEnvironment({
    required this.home,
    required this.configHome,
    required this.dataHome,
    required this.piDirectory,
    required this.codexHome,
    required this.grokConfigPath,
    required this.appData,
    required this.localAppData,
    required this.isWindows,
    required this.isMacOS,
  });

  factory HarnessEnvironment.system() {
    final variables = Platform.environment;
    final home =
        variables['HOME'] ??
        variables['USERPROFILE'] ??
        ((variables['HOMEDRIVE'] != null && variables['HOMEPATH'] != null)
            ? '${variables['HOMEDRIVE']}${variables['HOMEPATH']}'
            : '');
    final windows = Platform.isWindows;
    final appData = variables['APPDATA'];
    final localAppData = variables['LOCALAPPDATA'];
    final configHome =
        variables['XDG_CONFIG_HOME'] ??
        (windows ? appData : p.join(home, '.config')) ??
        p.join(home, '.config');
    final dataHome =
        variables['XDG_DATA_HOME'] ??
        (windows ? localAppData : p.join(home, '.local', 'share')) ??
        p.join(home, '.local', 'share');

    return HarnessEnvironment(
      home: home,
      configHome: configHome,
      dataHome: dataHome,
      piDirectory:
          variables['PI_CODING_AGENT_DIR'] ?? p.join(home, '.pi', 'agent'),
      codexHome: variables['CODEX_HOME'] ?? p.join(home, '.codex'),
      grokConfigPath: variables['GROK_CONFIG_PATH'],
      appData: appData ?? (windows ? p.join(home, 'AppData', 'Roaming') : null),
      localAppData:
          localAppData ?? (windows ? p.join(home, 'AppData', 'Local') : null),
      isWindows: windows,
      isMacOS: Platform.isMacOS,
    );
  }

  final String home;
  final String configHome;
  final String dataHome;
  final String piDirectory;
  final String codexHome;
  final String? grokConfigPath;
  final String? appData;
  final String? localAppData;
  final bool isWindows;
  final bool isMacOS;

  String? resolve(String template) {
    final values = <String, String?>{
      'home': home,
      'configHome': configHome,
      'dataHome': dataHome,
      'piDir': piDirectory,
      'codexHome': codexHome,
      'grokConfigPath': grokConfigPath,
      'appData': appData,
      'localAppData': localAppData,
    };
    var result = template;
    for (final entry in values.entries) {
      final value = entry.value;
      if (value == null || value.isEmpty) {
        if (template.contains('{${entry.key}}')) return null;
        continue;
      }
      result = result.replaceAll('{${entry.key}}', value);
    }
    if (result.contains('{')) return null;
    if (result.startsWith('~/')) {
      result = p.join(home, result.substring(2));
    }
    return p.normalize(result);
  }
}

class HarnessConfigInspector {
  const HarnessConfigInspector();

  List<HarnessConfigFile> inspect(
    HarnessDefinition definition, {
    HarnessEnvironment? environment,
  }) {
    final env = environment ?? HarnessEnvironment.system();
    final seen = <String>{};
    final files = <HarnessConfigFile>[];
    for (final spec in definition.configs) {
      final path = env.resolve(spec.pathTemplate);
      if (path == null || !seen.add(path)) continue;
      files.add(_inspectFile(spec, path));
    }
    return files;
  }

  HarnessConfigFile _inspectFile(HarnessConfigSpec spec, String path) {
    final file = File(path);
    final exists = file.existsSync();
    if (!exists) {
      return HarnessConfigFile(
        label: spec.label,
        path: path,
        sensitive: spec.sensitive,
        exists: false,
      );
    }
    if (spec.sensitive) {
      return HarnessConfigFile(
        label: spec.label,
        path: path,
        sensitive: true,
        exists: true,
        summary: 'Present · contents hidden',
      );
    }

    try {
      final size = file.lengthSync();
      if (size > 256 * 1024) {
        return HarnessConfigFile(
          label: spec.label,
          path: path,
          sensitive: false,
          exists: true,
          summary: 'Present · preview skipped for large file',
        );
      }
      return HarnessConfigFile(
        label: spec.label,
        path: path,
        sensitive: false,
        exists: true,
        summary: _summarize(file.readAsStringSync()),
      );
    } catch (_) {
      return HarnessConfigFile(
        label: spec.label,
        path: path,
        sensitive: false,
        exists: true,
        summary: 'Present · could not inspect',
      );
    }
  }

  String _summarize(String contents) {
    final lower = contents.toLowerCase();
    final parts = <String>[];
    if (lower.contains('openrouter')) {
      parts.add('OpenRouter referenced');
    }
    if (lower.contains('stealth/ox-alpha')) {
      parts.add('Ox Alpha selected');
    }
    if (lower.contains('thinkingmachines/inkling-small:free')) {
      parts.add('Inkling Small :free selected');
    }
    if (lower.contains('thinkingmachines/inkling:free')) {
      parts.add('Inkling :free selected');
    }
    if (lower.contains('openrouter') && lower.contains(':free')) {
      parts.add('agentic harness required for some :free routes');
    }

    final settingPattern = RegExp(
      r'''["']?(provider|defaultProvider|model|defaultModel|modelId|baseUrl|base_url)["']?\s*[:=]\s*["']?([^"'\s,}]+)''',
      caseSensitive: false,
      multiLine: true,
    );
    final seenSettings = <String>{};
    for (final match in settingPattern.allMatches(contents)) {
      final key = match.group(1)!;
      final value = match.group(2)!;
      if (value == '{' || value == '[') {
        continue;
      }
      final item = '$key: ${_safeValue(value)}';
      if (seenSettings.add(item.toLowerCase())) {
        parts.add(item);
      }
      if (parts.length >= 5) {
        break;
      }
    }
    return parts.isEmpty ? 'Present' : parts.join(' · ');
  }

  String _safeValue(String value) {
    final normalized = value.trim();
    if (RegExp(
      r'(token|api[_-]?key|secret|password)=',
      caseSensitive: false,
    ).hasMatch(normalized)) {
      return '[redacted]';
    }
    if (normalized.length > 80) {
      return '${normalized.substring(0, 77)}…';
    }
    return normalized;
  }
}

class ConfigOpener {
  const ConfigOpener();

  Future<void> open(String path) async {
    if (!File(path).existsSync()) {
      throw StateError('Config file no longer exists');
    }
    final executable = Platform.isWindows
        ? 'explorer.exe'
        : Platform.isMacOS
        ? 'open'
        : 'xdg-open';
    await Process.start(executable, [path], mode: ProcessStartMode.detached);
  }
}
