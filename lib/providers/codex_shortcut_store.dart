import 'package:flutter/foundation.dart';

import '../models/codex_shortcut.dart';
import '../services/codex_shortcut_installer.dart';

class CodexShortcutStore extends ChangeNotifier {
  factory CodexShortcutStore({CodexShortcutInstaller? installer}) {
    return CodexShortcutStore._(installer ?? CodexShortcutInstaller());
  }

  CodexShortcutStore._(this._installer) : _status = _installer.inspect();

  final CodexShortcutInstaller _installer;
  CodexShortcutStatus _status;
  bool _busy = false;
  String? _statusMessage;

  CodexShortcutStatus get status => _status;
  bool get busy => _busy;
  String? get statusMessage => _statusMessage;

  Future<void> refresh() async {
    if (_busy) return;
    _status = _installer.inspect();
    _statusMessage = null;
    notifyListeners();
  }

  Future<CodexShortcutOperationResult?> install() async {
    if (_busy) return null;
    return _run(_installer.install);
  }

  Future<CodexShortcutOperationResult?> uninstall() async {
    if (_busy) return null;
    return _run(_installer.uninstall);
  }

  Future<CodexShortcutOperationResult> _run(
    Future<CodexShortcutOperationResult> Function() operation,
  ) async {
    _busy = true;
    _statusMessage = null;
    notifyListeners();
    try {
      final result = await operation();
      _status = result.status;
      _statusMessage = result.message;
      return result;
    } catch (error) {
      _status = _installer.inspect();
      _statusMessage = 'Shortcut operation failed: $error';
      return CodexShortcutOperationResult(
        ok: false,
        message: _statusMessage!,
        status: _status,
      );
    } finally {
      _busy = false;
      notifyListeners();
    }
  }
}
