import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../api/chatgpt_wham.dart';
import '../auth/claude_auth.dart';
import '../auth/codex_cli_auth.dart';
import '../auth/opencode_auth.dart';
import '../models/usage_snapshot.dart';
import '../services/usage_fetcher.dart';
import '../services/usage_preferences.dart';

class UsageStore extends ChangeNotifier {
  /// [claudeCredentialsPresent] decides whether Claude is polled before the
  /// user has chosen in Settings; it defaults to checking for a Claude Code
  /// session on this machine.
  factory UsageStore({
    http.Client? client,
    UsagePreferences? preferences,
    bool Function()? claudeCredentialsPresent,
  }) {
    final resolvedPreferences = preferences ?? UsagePreferences();
    final resolvedClient = client ?? http.Client();
    return UsageStore._(
      client: resolvedClient,
      ownsClient: client == null,
      preferences: resolvedPreferences,
      fetcher: UsageFetcher(client: resolvedClient),
      cursorEnabled: resolvedPreferences.loadCursorEnabled(),
      claudeEnabled:
          resolvedPreferences.loadClaudeEnabled() ??
          (claudeCredentialsPresent ?? ClaudeAuthStore.hasCredentials)(),
      codexAuthRefreshEnabled: resolvedPreferences
          .loadCodexAuthRefreshEnabled(),
    );
  }

  UsageStore._({
    required this._client,
    required this._ownsClient,
    required this._preferences,
    required this._fetcher,
    required this._cursorEnabled,
    required this._claudeEnabled,
    required this._codexAuthRefreshEnabled,
  });

  final http.Client _client;
  final bool _ownsClient;
  final UsagePreferences _preferences;
  final UsageFetcher _fetcher;

  AppSnapshot _snapshot = const AppSnapshot();
  bool _loading = false;
  bool _redeeming = false;
  bool _cursorEnabled;
  bool _claudeEnabled;
  bool _codexAuthRefreshEnabled;
  String? _globalError;
  String? _statusMessage;

  AppSnapshot get snapshot => _snapshot;
  bool get loading => _loading;
  bool get redeeming => _redeeming;
  bool get cursorEnabled => _cursorEnabled;

  /// Claude polling: on by default when a Claude Code session exists, and
  /// switchable in Settings like Cursor.
  bool get claudeEnabled => _claudeEnabled;

  /// Whether a stale Codex CLI session may be renewed and written back to
  /// ~/.codex/auth.json. Off by default: the file is then only read.
  bool get codexAuthRefreshEnabled => _codexAuthRefreshEnabled;
  String? get globalError => _globalError;
  String? get statusMessage => _statusMessage;

  RateWindow? get headlineCodexWindow =>
      _snapshot.codex?.secondary ?? _snapshot.codex?.primary;

  /// Enables or pauses Cursor usage polling and display without touching the
  /// locally stored Cursor credentials.
  bool setCursorEnabled(bool enabled) {
    if (_cursorEnabled == enabled) return true;
    try {
      _preferences.saveCursorEnabled(enabled);
    } on Object catch (_) {
      _globalError = 'Could not save the Cursor display preference.';
      _statusMessage = _globalError;
      notifyListeners();
      return false;
    }

    _cursorEnabled = enabled;
    _globalError = null;
    _statusMessage = enabled
        ? 'Cursor enabled. Refreshing usage is available from the header.'
        : 'Cursor paused. Its saved credentials were left untouched.';
    if (!enabled) {
      _snapshot = AppSnapshot(
        codex: _snapshot.codex,
        claude: _snapshot.claude,
        refreshedAt: _snapshot.refreshedAt,
      );
    }
    notifyListeners();
    return true;
  }

  /// Enables or pauses Claude usage polling. The Claude Code session is only
  /// ever read, never changed.
  bool setClaudeEnabled(bool enabled) {
    if (_claudeEnabled == enabled) return true;
    try {
      _preferences.saveClaudeEnabled(enabled);
    } on Object catch (_) {
      _globalError = 'Could not save the Claude display preference.';
      _statusMessage = _globalError;
      notifyListeners();
      return false;
    }

    _claudeEnabled = enabled;
    _globalError = null;
    _statusMessage = enabled
        ? 'Claude enabled. Refreshing usage is available from the header.'
        : 'Claude paused. The Claude Code session was left untouched.';
    if (!enabled) {
      _snapshot = AppSnapshot(
        codex: _snapshot.codex,
        cursor: _snapshot.cursor,
        refreshedAt: _snapshot.refreshedAt,
      );
    }
    notifyListeners();
    return true;
  }

  bool setCodexAuthRefreshEnabled(bool enabled) {
    if (_codexAuthRefreshEnabled == enabled) return true;
    try {
      _preferences.saveCodexAuthRefreshEnabled(enabled);
    } on Object catch (_) {
      _globalError = 'Could not save the Codex auth refresh preference.';
      _statusMessage = _globalError;
      notifyListeners();
      return false;
    }
    _codexAuthRefreshEnabled = enabled;
    _globalError = null;
    _statusMessage = enabled
        ? 'fluttAIrbar may now renew a stale Codex session in auth.json.'
        : 'Codex auth.json is read-only again.';
    notifyListeners();
    return true;
  }

  Future<void> refresh({bool force = false}) async {
    if (_loading && !force) return;
    _loading = true;
    _globalError = null;
    notifyListeners();

    final results = await Future.wait<Object?>([
      _fetcher.codex(refreshAuthFile: _codexAuthRefreshEnabled),
      _claudeEnabled ? _fetcher.claude() : Future.value(null),
      _cursorEnabled ? _fetcher.cursor() : Future.value(null),
    ]);
    final codex = results[0] as CodexUsage;
    if (codex.state == UsageState.stale) {
      _statusMessage =
          'Codex session is older than '
          '${CodexCliAuthStore.staleAfterDays} days; run `codex` to renew '
          'it, or allow refresh in Settings.';
    }

    _snapshot = AppSnapshot(
      codex: codex,
      claude: _claudeEnabled ? results[1] as ClaudeUsage? : null,
      cursor: _cursorEnabled ? results[2] as CursorUsage? : null,
      refreshedAt: DateTime.now(),
    );
    _loading = false;
    notifyListeners();
  }

  /// Redeems a specific reset credit after UI confirmation.
  Future<ConsumeResetResult> redeemResetCredit(String creditId) async {
    if (_redeeming) {
      return const ConsumeResetResult(
        ok: false,
        code: 'busy',
        statusCode: 0,
        redeemRequestId: '',
      );
    }
    final id = creditId.trim();
    if (id.isEmpty) {
      throw AuthException('credit_id is required — refusing to redeem');
    }

    _redeeming = true;
    _statusMessage = null;
    notifyListeners();
    try {
      final creds = await CodexAuthResolver.resolve(
        client: _client,
        refreshAuthFile: _codexAuthRefreshEnabled,
      );
      final wham = ChatGptWhamClient(client: _client);
      final result = await wham.consumeResetCredit(creds, creditId: id);
      if (result.ok) {
        _statusMessage = 'Reset redeemed';
      } else {
        _statusMessage = 'Redeem failed: ${result.code}';
      }
      await refresh(force: true);
      return result;
    } finally {
      _redeeming = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    if (_ownsClient) _client.close();
    super.dispose();
  }
}
