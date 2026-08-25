import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'harness_config.dart';

/// Persists non-secret harness scan preferences for the local user.
class HarnessPreferences {
  HarnessPreferences({HarnessEnvironment? environment})
    : _environment = environment ?? HarnessEnvironment.system();

  static const _schema = 1;
  static const _fileName = 'harnesses.json';

  final HarnessEnvironment _environment;

  String get filePath =>
      p.join(_environment.configHome, 'fluttairbar', _fileName);

  Set<String> loadDisabled() {
    try {
      final file = File(filePath);
      if (!file.existsSync()) return <String>{};
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map || decoded['schema'] != _schema) {
        return <String>{};
      }
      final disabled = decoded['disabled'];
      if (disabled is! List) return <String>{};
      return disabled
          .whereType<String>()
          .where((id) => id.trim().isNotEmpty)
          .toSet();
    } on Object catch (_) {
      // A corrupt or unreadable preference file should not prevent the app
      // from scanning harnesses with the default settings.
      return <String>{};
    }
  }

  void saveDisabled(Set<String> disabled) {
    final file = File(filePath);
    file.parent.createSync(recursive: true);
    final temporary = File('${file.path}.tmp-$pid');
    temporary.writeAsStringSync(
      jsonEncode({'schema': _schema, 'disabled': disabled.toList()..sort()}),
    );
    try {
      temporary.renameSync(file.path);
    } on FileSystemException {
      // Windows cannot replace an existing file with renameSync. Linux and
      // macOS use the first path, while this fallback keeps the store usable
      // on both platforms.
      if (file.existsSync()) file.deleteSync();
      temporary.renameSync(file.path);
    }
  }
}
