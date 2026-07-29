import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'opencode_auth.dart';

/// Reads Codex CLI OAuth from ~/.codex/auth.json (or $CODEX_HOME/auth.json).
class CodexCliAuthStore {
  static const oauthClientId = 'app_EMoamEEZ73f0CkXaXp7hrann';
  static const tokenUrl = 'https://auth.openai.com/oauth/token';

  static String defaultPath() {
    final codexHome = Platform.environment['CODEX_HOME'];
    if (codexHome != null && codexHome.isNotEmpty) {
      return p.join(codexHome, 'auth.json');
    }
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    return p.join(home, '.codex', 'auth.json');
  }

  static Future<OAuthCredentials?> load({
    String? path,
    http.Client? client,
  }) async {
    final file = File(path ?? defaultPath());
    if (!file.existsSync()) return null;

    final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final tokens = data['tokens'];
    String? access;
    String? refresh;
    String? accountId;

    if (tokens is Map) {
      access = (tokens['access_token'] ?? tokens['accessToken'])?.toString();
      refresh = (tokens['refresh_token'] ?? tokens['refreshToken'])?.toString();
      accountId = (tokens['account_id'] ?? tokens['accountId'])?.toString();
    }

    access ??= data['OPENAI_API_KEY']?.toString();
    if (access == null || access.trim().isEmpty) return null;

    final lastRefreshRaw = data['last_refresh']?.toString();
    DateTime? lastRefresh =
        lastRefreshRaw != null ? DateTime.tryParse(lastRefreshRaw) : null;

    // Refresh when last_refresh older than ~8 days (CodexBar policy).
    final refreshTokenForRefresh = refresh;
    if (refreshTokenForRefresh != null &&
        refreshTokenForRefresh.isNotEmpty &&
        (lastRefresh == null ||
            DateTime.now().difference(lastRefresh).inDays >= 8)) {
      final httpClient = client ?? http.Client();
      try {
        final refreshed = await _refresh(httpClient, refreshTokenForRefresh);
        access = refreshed.$1;
        refresh = refreshed.$2 ?? refreshTokenForRefresh;
        lastRefresh = DateTime.now().toUtc();
        final newTokens = Map<String, dynamic>.from(
          tokens is Map ? Map<String, dynamic>.from(tokens) : {},
        );
        newTokens['access_token'] = access;
        newTokens['refresh_token'] = refresh;
        data['tokens'] = newTokens;
        data['last_refresh'] = lastRefresh.toIso8601String();
        file.writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(data),
        );
      } catch (_) {
        // Keep existing access token; caller may still succeed or get 401.
      } finally {
        if (client == null) httpClient.close();
      }
    }

    final accessToken = access as String;
    String email = '?';
    String resolvedAccountId = accountId ?? '';
    try {
      final id = identityFromOpenAiJwt(accessToken);
      if (resolvedAccountId.isEmpty) resolvedAccountId = id.$1;
      email = id.$2;
    } catch (_) {
      if (resolvedAccountId.isEmpty) {
        throw AuthException(
          'Codex auth.json missing account id. Re-run: codex login',
        );
      }
    }

    return OAuthCredentials(
      accessToken: accessToken,
      accountId: resolvedAccountId,
      email: email,
      source: 'codex-cli',
      refreshToken: refresh,
      expiresAt: null,
    );
  }

  static Future<(String access, String? refresh)> _refresh(
    http.Client client,
    String refreshToken,
  ) async {
    final response = await client.post(
      Uri.parse(tokenUrl),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'client_id': oauthClientId,
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
        'scope': 'openid profile email',
      },
    );
    if (response.statusCode != 200) {
      throw AuthException('Token refresh failed (${response.statusCode})');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final access = body['access_token']?.toString();
    if (access == null || access.isEmpty) {
      throw AuthException('Token refresh missing access_token');
    }
    return (access, body['refresh_token']?.toString());
  }
}

/// Resolves Codex credentials: OpenCode first, then Codex CLI.
class CodexAuthResolver {
  static Future<OAuthCredentials> resolve({http.Client? client}) async {
    try {
      final oc = OpenCodeAuthStore.load();
      if (oc != null) return oc;
    } on AuthException {
      rethrow;
    }

    final cli = await CodexCliAuthStore.load(client: client);
    if (cli != null) return cli;

    throw AuthException(
      'No ChatGPT/Codex credentials found.\n'
      '• OpenCode: run `opencode providers login` (ChatGPT/Codex OAuth)\n'
      '• Or Codex CLI: run `codex login` (writes ~/.codex/auth.json)',
    );
  }
}
