import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'harness_config.dart';

/// Persists local display preferences for usage providers.
///
/// Provider credentials are never changed by this store. A disabled provider
/// is simply skipped by the usage poller and hidden from the tray/panel until
/// the user enables it again.
class UsagePreferences {
  UsagePreferences({HarnessEnvironment? environment})
    : _environment = environment ?? HarnessEnvironment.system();

  static const _schema = 1;
  static const _fileName = 'usage.json';

  final HarnessEnvironment _environment;

  String get filePath =>
      p.join(_environment.configHome, 'fluttairbar', _fileName);

  /// Cursor is opt-in so an old/stale Cursor session cannot appear by
  /// surprise. The local preference can be switched back on from the UI.
  bool loadCursorEnabled() {
    try {
      final file = File(filePath);
      if (!file.existsSync()) return false;
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map || decoded['schema'] != _schema) return false;
      return decoded['cursorEnabled'] == true;
    } on Object catch (_) {
      // A corrupt or unreadable preference file should not prevent the app
      // from starting; fall back to the safe disabled default.
      return false;
    }
  }

  void saveCursorEnabled(bool enabled) {
    final file = File(filePath);
    file.parent.createSync(recursive: true);
    final temporary = File('${file.path}.tmp-$pid');
    temporary.writeAsStringSync(
      JsonEncoder.withIndent(
        '  ',
      ).convert(<String, Object>{'schema': _schema, 'cursorEnabled': enabled}),
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
