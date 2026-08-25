import 'package:flutter/foundation.dart';

import '../models/harness.dart';
import '../services/harness_manager.dart';
import '../services/harness_preferences.dart';

class HarnessStore extends ChangeNotifier {
  HarnessStore({HarnessManager? manager, HarnessPreferences? preferences})
    : _manager = manager ?? HarnessManager(),
      _preferences = preferences ?? HarnessPreferences() {
    _disabledIds = _preferences.loadDisabled();
  }

  final HarnessManager _manager;
  final HarnessPreferences _preferences;
  Set<String> _disabledIds = <String>{};
  List<HarnessStatus> _allStatuses = const [];
  List<HarnessStatus> _statuses = const [];
  bool _loading = false;
  bool _updating = false;
  String? _statusMessage;
  DateTime? _checkedAt;
  final Map<String, HarnessUpdatePhase> _updatePhases = {};
  final Map<String, String> _updateMessages = {};
  int _updateTotal = 0;
  int _updateCompleted = 0;
  String? _activeUpdateId;
  String? _activeUpdateName;

  List<HarnessStatus> get statuses => _statuses;
  List<HarnessStatus> get allStatuses => _allStatuses;
  List<HarnessDefinition> get definitions => _manager.definitions;
  int get disabledCount => _disabledIds.length;
  bool get loading => _loading;
  bool get updating => _updating;
  String? get statusMessage => _statusMessage;
  DateTime? get checkedAt => _checkedAt;
  int get updateTotal => _updateTotal;
  int get updateCompleted => _updateCompleted;
  String? get activeUpdateName => _activeUpdateName;

  bool isDisabled(String id) => _disabledIds.contains(id);

  HarnessUpdatePhase updatePhaseFor(HarnessStatus status) =>
      _updatePhases[status.definition.id] ?? HarnessUpdatePhase.idle;

  String? updateMessageFor(HarnessStatus status) =>
      _updateMessages[status.definition.id];

  Future<void> refresh() async {
    if (_loading || _updating) return;
    _loading = true;
    _statusMessage = null;
    _clearUpdateProgress();
    notifyListeners();
    try {
      final discovered = await _manager.discover(excludedIds: _disabledIds);
      _replaceStatuses(discovered);
      _checkedAt = DateTime.now();
    } catch (error) {
      _statusMessage = 'Harness scan failed: $error';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<HarnessUpdateReport?> updateAll({
    bool allowEarlyRelease = false,
  }) async {
    if (_loading || _updating) return null;
    final candidates = _statuses
        .where((status) => status.updateCandidate)
        .toList();
    if (candidates.isEmpty) return const HarnessUpdateReport([]);

    _updating = true;
    _statusMessage = null;
    _beginUpdateProgress(candidates);
    notifyListeners();
    try {
      final report = await _manager.updateAll(
        candidates,
        allowEarlyRelease: allowEarlyRelease,
        onStart: (status) {
          _activeUpdateId = status.definition.id;
          _activeUpdateName = status.definition.displayName;
          _setUpdatePhase(status, HarnessUpdatePhase.updating);
          notifyListeners();
        },
        onComplete: (result) {
          _updateCompleted++;
          _activeUpdateId = null;
          _activeUpdateName = null;
          _setUpdateResult(result);
          notifyListeners();
        },
      );
      final updatedStatuses = await _manager.discover(
        excludedIds: _disabledIds,
      );
      _replaceStatuses(updatedStatuses);
      _checkedAt = DateTime.now();
      _statusMessage = _reportMessage(report);
      return report;
    } catch (error) {
      _markActiveUpdateFailed(error);
      _statusMessage = 'Harness update failed: $error';
      return null;
    } finally {
      _activeUpdateId = null;
      _activeUpdateName = null;
      _updating = false;
      notifyListeners();
    }
  }

  Future<HarnessUpdateResult?> updateOne(
    HarnessStatus status, {
    bool allowEarlyRelease = false,
  }) async {
    if (_loading || _updating) return null;
    _updating = true;
    _statusMessage = null;
    _beginUpdateProgress([status]);
    _activeUpdateId = status.definition.id;
    _activeUpdateName = status.definition.displayName;
    _setUpdatePhase(status, HarnessUpdatePhase.updating);
    notifyListeners();
    try {
      final result = await _manager.update(
        status,
        allowEarlyRelease: allowEarlyRelease,
      );
      _updateCompleted = 1;
      _activeUpdateId = null;
      _activeUpdateName = null;
      _setUpdateResult(result);
      final updatedStatuses = await _manager.discover(
        excludedIds: _disabledIds,
      );
      _replaceStatuses(updatedStatuses);
      _checkedAt = DateTime.now();
      _statusMessage = '${status.definition.displayName}: ${result.message}';
      return result;
    } catch (error) {
      _markActiveUpdateFailed(error);
      _statusMessage = 'Harness update failed: $error';
      return null;
    } finally {
      _activeUpdateId = null;
      _activeUpdateName = null;
      _updating = false;
      notifyListeners();
    }
  }

  Future<void> openConfig(HarnessConfigFile config) async {
    try {
      await _manager.openConfig(config);
      _statusMessage = 'Opened ${config.label}';
    } catch (error) {
      _statusMessage = 'Could not open config: $error';
    }
    notifyListeners();
  }

  void setDisabled(String id, bool disabled) {
    if (_loading || _updating || !_manager.definitions.any((d) => d.id == id)) {
      return;
    }
    final previous = Set<String>.of(_disabledIds);
    if (disabled) {
      _disabledIds.add(id);
    } else {
      _disabledIds.remove(id);
    }
    try {
      _preferences.saveDisabled(_disabledIds);
    } on Object catch (error) {
      _disabledIds = previous;
      _statusMessage = 'Could not save harness settings: $error';
      notifyListeners();
      return;
    }
    if (!disabled) {
      _allStatuses = _allStatuses
          .where((status) => status.definition.id != id)
          .toList(growable: false);
    }
    _statuses = _visibleStatuses(_allStatuses);
    _clearUpdateProgress();
    final definition = _manager.definitions.firstWhere((d) => d.id == id);
    _statusMessage = disabled
        ? '${definition.displayName} paused; it will be skipped by Refresh.'
        : '${definition.displayName} enabled; press Refresh to check it.';
    notifyListeners();
  }

  @override
  void dispose() {
    _manager.dispose();
    super.dispose();
  }

  String _reportMessage(HarnessUpdateReport report) {
    final pieces = <String>[];
    if (report.updatedCount > 0) {
      pieces.add('${report.updatedCount} updated');
    }
    if (report.upToDateCount > 0) {
      pieces.add('${report.upToDateCount} already current');
    }
    if (report.skippedCount > 0) {
      pieces.add('${report.skippedCount} skipped');
    }
    if (report.failedCount > 0) {
      pieces.add('${report.failedCount} failed');
    }
    return pieces.isEmpty
        ? 'No verified harness updates available'
        : pieces.join(' · ');
  }

  void _beginUpdateProgress(List<HarnessStatus> candidates) {
    _updatePhases
      ..clear()
      ..addEntries(
        candidates.map(
          (status) => MapEntry(status.definition.id, HarnessUpdatePhase.queued),
        ),
      );
    _updateMessages.clear();
    _updateTotal = candidates.length;
    _updateCompleted = 0;
    _activeUpdateId = null;
    _activeUpdateName = null;
  }

  void _clearUpdateProgress() {
    _updatePhases.clear();
    _updateMessages.clear();
    _updateTotal = 0;
    _updateCompleted = 0;
    _activeUpdateId = null;
    _activeUpdateName = null;
  }

  void _setUpdatePhase(HarnessStatus status, HarnessUpdatePhase phase) {
    _updatePhases[status.definition.id] = phase;
    _updateMessages.remove(status.definition.id);
  }

  void _setUpdateResult(HarnessUpdateResult result) {
    final phase = switch (result.outcome) {
      HarnessUpdateOutcome.updated => HarnessUpdatePhase.updated,
      HarnessUpdateOutcome.upToDate => HarnessUpdatePhase.upToDate,
      HarnessUpdateOutcome.skipped => HarnessUpdatePhase.skipped,
      HarnessUpdateOutcome.failed => HarnessUpdatePhase.failed,
    };
    _updatePhases[result.status.definition.id] = phase;
    _updateMessages[result.status.definition.id] = result.message;
  }

  void _markActiveUpdateFailed(Object error) {
    final id = _activeUpdateId;
    if (id == null) return;
    _updatePhases[id] = HarnessUpdatePhase.failed;
    _updateMessages[id] = 'Update failed: $error';
  }

  void _replaceStatuses(List<HarnessStatus> discovered) {
    final byId = <String, HarnessStatus>{
      for (final status in discovered) status.definition.id: status,
    };
    for (final status in _allStatuses) {
      if (_disabledIds.contains(status.definition.id)) {
        byId.putIfAbsent(status.definition.id, () => status);
      }
    }
    _allStatuses = byId.values.toList(growable: false);
    _statuses = _visibleStatuses(_allStatuses);
  }

  List<HarnessStatus> _visibleStatuses(List<HarnessStatus> statuses) {
    return statuses
        .where((status) => !_disabledIds.contains(status.definition.id))
        .toList(growable: false);
  }
}
