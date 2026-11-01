import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'opencode_auth.dart';

/// The parts of a Claude Code OAuth session that fluttAIrbar uses. The
/// refresh token, account and organization ids are never read into memory.
class ClaudeCredentials {
  const ClaudeCredentials({
    required this.accessToken,
    required this.source,
    this.subscriptionType,
    this.expiresAt,
  });

  final String accessToken;
  final String source;

  /// Plan name as Claude Code stores it, such as `pro` or `max`.
  final String? subscriptionType;
  final DateTime? expiresAt;

  bool isExpiredAt(DateTime now) {
    final expires = expiresAt;
    return expires != null && !now.toUtc().isBefore(expires.toUtc());
  }

  bool get isExpired => isExpiredAt(DateTime.now());
}

/// Reads the Claude Code session: `~/.claude/.credentials.json` on Linux and
/// Windows (inside `$CLAUDE_CONFIG_DIR` when set), and the Keychain item
/// "Claude Code-credentials" on macOS, falling back to the file there too.
///
/// Read-only: fluttAIrbar never refreshes the token or writes the session
/// back. An expired token is reported so the user can run `claude` to renew
/// it, because a concurrent refresh by Claude Code could otherwise race and
/// sign it out.
class ClaudeAuthStore {
  static const keychainService = 'Claude Code-credentials';
  static const _securityTool = '/usr/bin/security';

  static String defaultPath() {
    final variables = Platform.environment;
    final configDir = variables['CLAUDE_CONFIG_DIR'];
    if (configDir != null && configDir.isNotEmpty) {
      return p.join(configDir, '.credentials.json');
    }
    final home = variables['HOME'] ?? variables['USERPROFILE'] ?? '';
    return p.join(home, '.claude', '.credentials.json');
  }

  /// Returns null when there is no session. Errors never include the
  /// credential contents.
  static Future<ClaudeCredentials?> load({String? path}) async {
    if (path == null && Platform.isMacOS) {
      final secret = await _readKeychain();
      if (secret != null) return parse(secret, source: 'claude-code-keychain');
    }
    final file = File(path ?? defaultPath());
    if (!file.existsSync()) return null;
    final String contents;
    try {
      contents = file.readAsStringSync();
    } on Object catch (_) {
      throw AuthException(
        'Claude Code credentials could not be read. Run claude to sign in '
        'again.',
      );
    }
    return parse(contents, source: 'claude-code');
  }

  /// Whether a session exists, without reading the secret. On macOS this
  /// asks the Keychain for the item's attributes only, which does not unlock
  /// it or show an access prompt.
  static bool hasCredentials({String? path}) {
    if (path == null && Platform.isMacOS) {
      try {
        final result = Process.runSync(_securityTool, [
          'find-generic-password',
          '-s',
          keychainService,
        ]);
        if (result.exitCode == 0) return true;
      } on Object catch (_) {
        // Fall through to the file Claude Code uses without a Keychain.
      }
    }
    return File(path ?? defaultPath()).existsSync();
  }

  /// Parses the JSON Claude Code stores. Returns null when it holds no
  /// Claude.ai OAuth session (for example an API-key-only setup).
  static ClaudeCredentials? parse(String contents, {required String source}) {
    Object? decoded;
    try {
      decoded = jsonDecode(contents);
    } on FormatException {
      // FormatException quotes the input, which would leak the token.
      decoded = null;
    }
    if (decoded is! Map) {
      throw AuthException(
        'Claude Code credentials are not valid JSON. Run claude to sign in '
        'again.',
      );
    }
    final oauth = decoded['claudeAiOauth'];
    if (oauth is! Map) return null;
    final token = oauth['accessToken'];
    if (token is! String || token.trim().isEmpty) return null;
    final plan = oauth['subscriptionType'];
    return ClaudeCredentials(
      accessToken: token,
      source: source,
      subscriptionType: plan is String && plan.isNotEmpty ? plan : null,
      expiresAt: _parseExpiry(oauth['expiresAt']),
    );
  }

  static DateTime? _parseExpiry(Object? value) {
    if (value is num) {
      // Claude Code stores milliseconds since the epoch.
      return DateTime.fromMillisecondsSinceEpoch(value.toInt(), isUtc: true);
    }
    if (value is String) return DateTime.tryParse(value)?.toUtc();
    return null;
  }

  static Future<String?> _readKeychain() async {
    try {
      final result = await Process.run(_securityTool, [
        'find-generic-password',
        '-s',
        keychainService,
        '-w',
      ]);
      if (result.exitCode != 0) return null;
      final secret = (result.stdout as String).trim();
      return secret.isEmpty ? null : secret;
    } on Object catch (_) {
      return null;
    }
  }
}
