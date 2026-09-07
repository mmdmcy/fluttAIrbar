import 'package:flutter/foundation.dart';

import '../models/codex_capability.dart';
import '../services/codex_capability_manager.dart';

class CodexCapabilityStore extends ChangeNotifier {
  factory CodexCapabilityStore({CodexCapabilityManager? manager}) {
    return CodexCapabilityStore._(manager ?? CodexCapabilityManager());
  }

  CodexCapabilityStore._(this._manager)
    : _snapshot = CodexCapabilitySnapshot.empty(
        configPath: _manager.configPath,
      );

  final CodexCapabilityManager _manager;
  CodexCapabilitySnapshot _snapshot;
  final Map<String, bool> _restartPending = <String, bool>{};
  bool _loading = false;
  bool _mutating = false;
  bool _installing = false;
  String? _statusMessage;

  CodexCapabilitySnapshot get snapshot => _snapshot;
  bool get loading => _loading;
  bool get mutating => _mutating;
  bool get installing => _installing;
  bool get busy => _loading || _mutating || _installing;
  String? get statusMessage => _statusMessage;
  DateTime? get checkedAt => _snapshot.checkedAt;
  bool get restartRequired => _restartPending.isNotEmpty;

  Future<void> refresh() async {
    if (busy) return;
    _loading = true;
    _statusMessage = null;
    notifyListeners();
    try {
      final discovered = await _manager.discover();
      _snapshot = _applyPending(discovered);
      if (discovered.error != null) _statusMessage = discovered.error;
    } on Object catch (_) {
      _statusMessage =
          'Capability scan failed. Confirm the Codex CLI is available and refresh.';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<bool> setEnabled(String componentId, bool enabled) async {
    if (busy) return false;
    final component = _snapshot.component(componentId);
    if (!component.toggleable) {
      _statusMessage =
          '${component.definition.displayName} is not installed or its state is unavailable.';
      notifyListeners();
      return false;
    }

    _mutating = true;
    _statusMessage = null;
    notifyListeners();
    try {
      final change = await _manager.setEnabled(component, enabled);
      if (change.changed) {
        _restartPending[componentId] = enabled;
      }
      _snapshot = _applyPending(_snapshot);
      _statusMessage = change.changed
          ? '${component.definition.displayName} saved. Restart Codex manually when it is idle.'
          : '${component.definition.displayName} is already set that way. No config change was needed.';
      return true;
    } on Object catch (_) {
      _statusMessage =
          'Could not update ${component.definition.displayName}. Refresh and retry.';
      return false;
    } finally {
      _mutating = false;
      notifyListeners();
    }
  }

  Future<bool> installSkill(String componentId) async {
    if (busy) return false;
    final component = _snapshot.component(componentId);
    final installation = component.definition.installation;
    if (installation == null) {
      _statusMessage =
          '${component.definition.displayName} is not available from an approved installer.';
      notifyListeners();
      return false;
    }
    if (component.installed) {
      _statusMessage =
          '${component.definition.displayName} is already installed. Scan to verify its current state.';
      notifyListeners();
      return false;
    }
    if (!component.stateKnown) {
      _statusMessage =
          'Scan could not determine whether ${component.definition.displayName} is already installed.';
      notifyListeners();
      return false;
    }

    _installing = true;
    _statusMessage = null;
    notifyListeners();
    try {
      final result = await _manager.installSkill(installation);
      if (!result.succeeded) {
        _statusMessage =
            result.error ??
            'Could not install ${component.definition.displayName}.';
        return false;
      }

      final discovered = await _manager.discover();
      _snapshot = _applyPending(discovered);
      final installed = _snapshot.component(componentId);
      if (!installed.installed) {
        _statusMessage =
            'The installer finished, but ${component.definition.displayName} was not found in the Codex skill folders. Scan again to verify.';
        return false;
      }

      _restartPending[componentId] = true;
      _snapshot = _applyPending(_snapshot);
      _statusMessage =
          '${component.definition.displayName} installed. Restart Codex manually when it is idle.';
      return true;
    } on Object catch (_) {
      _statusMessage =
          'Could not install ${component.definition.displayName}. Check the installer and refresh.';
      return false;
    } finally {
      _installing = false;
      notifyListeners();
    }
  }

  void markRestarted() {
    if (_restartPending.isEmpty) return;
    _restartPending.clear();
    _snapshot = _withoutPending(_snapshot);
    _statusMessage = 'Restart reminder cleared. Refresh to verify Codex state.';
    notifyListeners();
  }

  CodexCapabilitySnapshot _applyPending(CodexCapabilitySnapshot snapshot) {
    final packs = <CodexCapabilityPackStatus>[];
    for (final pack in snapshot.packs) {
      final components = [
        for (final component in pack.components)
          _restartPending.containsKey(component.definition.id)
              ? component.withPending(_restartPending[component.definition.id])
              : component,
      ];
      packs.add(
        CodexCapabilityPackStatus(
          definition: pack.definition,
          components: components,
        ),
      );
    }
    return CodexCapabilitySnapshot(
      packs: packs,
      configPath: snapshot.configPath,
      checkedAt: snapshot.checkedAt,
      error: snapshot.error,
    );
  }

  CodexCapabilitySnapshot _withoutPending(CodexCapabilitySnapshot snapshot) {
    final packs = [
      for (final pack in snapshot.packs)
        CodexCapabilityPackStatus(
          definition: pack.definition,
          components: [
            for (final component in pack.components)
              component.withPending(null),
          ],
        ),
    ];
    return CodexCapabilitySnapshot(
      packs: packs,
      configPath: snapshot.configPath,
      checkedAt: snapshot.checkedAt,
      error: snapshot.error,
    );
  }
}
