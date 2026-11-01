import 'dart:async';

import 'package:http/http.dart' as http;

import '../api/chatgpt_wham.dart';
import '../api/claude_usage.dart';
import '../api/cursor_api.dart';
import '../auth/claude_auth.dart';
import '../auth/codex_cli_auth.dart';
import '../auth/cursor_auth.dart';
import '../auth/opencode_auth.dart';
import '../models/usage_snapshot.dart';

/// Reads each provider's usage with the session already on this machine and
/// turns every failure into a [UsageState] with a plain message. It has no
/// Flutter dependency, so the tray app and `fluttairbar-cli` share it.
class UsageFetcher {
  UsageFetcher({
    required this._client,
    this.codexAuthPath,
    this.claudeCredentialsPath,
    this.timeout = const Duration(seconds: 20),
  });

  final http.Client _client;
  final String? codexAuthPath;
  final String? claudeCredentialsPath;
  final Duration timeout;

  static String get codexStaleMessage =>
      'Codex session is older than ${CodexCliAuthStore.staleAfterDays} days: '
      'run codex to renew it.';

  static const claudeExpiredMessage =
      'Claude session expired: run claude to renew it.';

  static const claudeSignedOutMessage =
      'No Claude Code session found: run claude to sign in.';

  Future<CodexUsage> codex({
    bool refreshAuthFile = false,
    bool includeResetCredits = true,
  }) async {
    var stale = false;
    try {
      final creds = await CodexAuthResolver.resolve(
        client: _client,
        codexPath: codexAuthPath,
        refreshAuthFile: refreshAuthFile,
      );
      stale = creds.stale;
      final wham = ChatGptWhamClient(client: _client);
      var usage = await wham.fetchUsage(creds).timeout(timeout);
      if (includeResetCredits) {
        try {
          final resets = await wham.fetchResetCredits(creds).timeout(timeout);
          usage = usage.copyWith(
            resetCredits: resets.credits,
            availableResetCount: resets.availableCount,
          );
        } catch (_) {}
      }
      return stale ? usage.copyWith(state: UsageState.stale) : usage;
    } on Object catch (error) {
      final (state, message) = stale
          ? (UsageState.stale, codexStaleMessage)
          : _failure(error, 'Codex');
      return CodexUsage(
        email: '?',
        accountId: '',
        authSource: 'none',
        error: message,
        state: state,
        fetchedAt: DateTime.now(),
      );
    }
  }

  Future<ClaudeUsage> claude() async {
    try {
      final creds = await ClaudeAuthStore.load(path: claudeCredentialsPath);
      if (creds == null) {
        return ClaudeUsage(
          state: UsageState.signedOut,
          error: claudeSignedOutMessage,
          fetchedAt: DateTime.now(),
        );
      }
      if (creds.isExpired) {
        return ClaudeUsage(
          plan: creds.subscriptionType,
          state: UsageState.expired,
          error: claudeExpiredMessage,
          fetchedAt: DateTime.now(),
        );
      }
      return await ClaudeUsageClient(
        client: _client,
      ).fetchUsage(creds).timeout(timeout);
    } on Object catch (error) {
      final (state, message) = _failure(error, 'Claude');
      return ClaudeUsage(
        state: state,
        error: message,
        fetchedAt: DateTime.now(),
      );
    }
  }

  Future<CursorUsage> cursor() async {
    try {
      final creds = CursorAuthStore.require();
      return await CursorApiClient(
        client: _client,
      ).fetchUsage(creds).timeout(timeout);
    } on Object catch (error) {
      final (state, message) = _failure(error, 'Cursor');
      return CursorUsage(
        authSource: 'none',
        error: message,
        state: state,
        fetchedAt: DateTime.now(),
      );
    }
  }

  (UsageState, String) _failure(Object error, String provider) {
    return switch (error) {
      SignedOutException(:final message) => (UsageState.signedOut, message),
      SessionExpiredException(:final message) => (UsageState.expired, message),
      AuthException(:final message) => (UsageState.error, message),
      TimeoutException() => (
        UsageState.error,
        '$provider usage did not answer within ${timeout.inSeconds} seconds.',
      ),
      _ => (UsageState.error, error.toString()),
    };
  }
}
