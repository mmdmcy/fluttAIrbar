import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

class OAuthCredentials {
  const OAuthCredentials({
    required this.accessToken,
    required this.accountId,
    required this.email,
    required this.source,
    this.refreshToken,
    this.expiresAt,
  });

  final String accessToken;
  final String accountId;
  final String email;
  final String source;
  final String? refreshToken;
  final DateTime? expiresAt;

  bool get isExpired {
    if (expiresAt == null) return false;
    return DateTime.now().isAfter(expiresAt!);
  }
}

class AuthException implements Exception {
  AuthException(this.message);
  final String message;
  @override
  String toString() => message;
}

Map<String, dynamic> decodeJwtPayload(String token) {
  final parts = token.split('.');
  if (parts.length < 2) {
    throw AuthException('Invalid JWT');
  }
  var payload = parts[1].replaceAll('-', '+').replaceAll('_', '/');
  switch (payload.length % 4) {
    case 2:
      payload += '==';
      break;
    case 3:
      payload += '=';
      break;
  }
  final decoded = utf8.decode(base64.decode(payload));
  return jsonDecode(decoded) as Map<String, dynamic>;
}

(String accountId, String email) identityFromOpenAiJwt(String token) {
  final payload = decodeJwtPayload(token);
  final auth = payload['https://api.openai.com/auth'];
  final profile = payload['https://api.openai.com/profile'];
  String? accountId;
  if (auth is Map) {
    accountId = auth['chatgpt_account_id']?.toString();
  }
  accountId ??= payload['account_id']?.toString();
  String email = '?';
  if (profile is Map && profile['email'] != null) {
    email = profile['email'].toString();
  } else if (payload['email'] != null) {
    email = payload['email'].toString();
  }
  if (accountId == null || accountId.isEmpty) {
    throw AuthException(
      'JWT missing chatgpt_account_id — re-login with ChatGPT Plus/Pro OAuth',
    );
  }
  return (accountId, email);
}

/// Reads ChatGPT/Codex OAuth from OpenCode: ~/.local/share/opencode/auth.json
class OpenCodeAuthStore {
  static const providerKeys = ['openai', 'codex', 'chatgpt', 'opencode'];

  static String defaultPath() {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    final xdg = Platform.environment['XDG_DATA_HOME'];
    if (xdg != null && xdg.isNotEmpty) {
      return p.join(xdg, 'opencode', 'auth.json');
    }
    if (Platform.isWindows) {
      final local = Platform.environment['LOCALAPPDATA'];
      if (local != null) return p.join(local, 'opencode', 'auth.json');
    }
    return p.join(home, '.local', 'share', 'opencode', 'auth.json');
  }

  static OAuthCredentials? load({String? path}) {
    final file = File(path ?? defaultPath());
    if (!file.existsSync()) return null;

    final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    String? lastSkip;

    for (final key in providerKeys) {
      final entry = data[key];
      if (entry is! Map) continue;
      final type = entry['type']?.toString();
      if (type != null && type != 'oauth') {
        lastSkip = '$key: not oauth (type=$type)';
        continue;
      }
      final token = (entry['access'] ?? entry['accessToken'] ?? entry['token'])
          ?.toString();
      if (token == null || token.trim().isEmpty) {
        lastSkip = '$key: empty token';
        continue;
      }

      final expiresRaw = entry['expires'];
      DateTime? expiresAt;
      if (expiresRaw is num) {
        // OpenCode stores ms epoch
        expiresAt = DateTime.fromMillisecondsSinceEpoch(expiresRaw.toInt());
      }

      if (expiresAt != null && DateTime.now().isAfter(expiresAt)) {
        throw AuthException(
          'OpenCode $key token expired. Run: opencode providers login',
        );
      }

      final (accountId, email) = identityFromOpenAiJwt(token);
      return OAuthCredentials(
        accessToken: token,
        accountId: entry['accountId']?.toString() ?? accountId,
        email: email,
        source: 'opencode:$key',
        refreshToken: entry['refresh']?.toString(),
        expiresAt: expiresAt,
      );
    }

    if (lastSkip != null) {
      throw AuthException(
        'No usable ChatGPT OAuth in OpenCode ($lastSkip). '
        'Run: opencode providers login',
      );
    }
    return null;
  }
}
