import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../api/chatgpt_wham.dart';
import '../api/cursor_api.dart';
import '../auth/codex_cli_auth.dart';
import '../auth/cursor_auth.dart';
import '../auth/opencode_auth.dart';
import '../models/usage_snapshot.dart';

class UsageStore extends ChangeNotifier {
  UsageStore({http.Client? client})
      : _client = client ?? http.Client(),
        _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;

  AppSnapshot _snapshot = const AppSnapshot();
  bool _loading = false;
  bool _redeeming = false;
  String? _globalError;
  String? _statusMessage;

  AppSnapshot get snapshot => _snapshot;
  bool get loading => _loading;
  bool get redeeming => _redeeming;
  String? get globalError => _globalError;
  String? get statusMessage => _statusMessage;

  RateWindow? get headlineCodexWindow =>
      _snapshot.codex?.secondary ?? _snapshot.codex?.primary;

  Future<void> refresh({bool force = false}) async {
    if (_loading && !force) return;
    _loading = true;
    _globalError = null;
    notifyListeners();

    CodexUsage? codex;
    CursorUsage? cursor;

    try {
      final creds = await CodexAuthResolver.resolve(client: _client);
      final wham = ChatGptWhamClient(client: _client);
      codex = await wham.fetchUsage(creds);
      try {
        final resets = await wham.fetchResetCredits(creds);
        codex = codex.copyWith(
          resetCredits: resets.credits,
          availableResetCount: resets.availableCount,
        );
      } catch (_) {}
    } on AuthException catch (e) {
      codex = CodexUsage(
        email: '?',
        accountId: '',
        authSource: 'none',
        error: e.message,
        fetchedAt: DateTime.now(),
      );
    } catch (e) {
      codex = CodexUsage(
        email: '?',
        accountId: '',
        authSource: 'none',
        error: e.toString(),
        fetchedAt: DateTime.now(),
      );
    }

    try {
      final creds = CursorAuthStore.require();
      final api = CursorApiClient(client: _client);
      cursor = await api.fetchUsage(creds);
    } on AuthException catch (e) {
      cursor = CursorUsage(
        authSource: 'none',
        error: e.message,
        fetchedAt: DateTime.now(),
      );
    } catch (e) {
      cursor = CursorUsage(
        authSource: 'none',
        error: e.toString(),
        fetchedAt: DateTime.now(),
      );
    }

    _snapshot = AppSnapshot(
      codex: codex,
      cursor: cursor,
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
      final creds = await CodexAuthResolver.resolve(client: _client);
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
