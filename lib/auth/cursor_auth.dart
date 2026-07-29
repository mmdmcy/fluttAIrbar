import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'opencode_auth.dart';

class CursorCredentials {
  const CursorCredentials({
    required this.accessToken,
    required this.userId,
    required this.cookieHeader,
    required this.source,
  });

  final String accessToken;
  final String userId;
  final String cookieHeader;
  final String source;
}

class CursorAuthStore {
  static List<String> candidateDbPaths() {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    final paths = <String>[];

    if (Platform.isMacOS) {
      paths.add(
        p.join(
          home,
          'Library',
          'Application Support',
          'Cursor',
          'User',
          'globalStorage',
          'state.vscdb',
        ),
      );
    } else if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'];
      if (appData != null) {
        paths.add(
          p.join(appData, 'Cursor', 'User', 'globalStorage', 'state.vscdb'),
        );
      }
    } else {
      final xdg = Platform.environment['XDG_CONFIG_HOME'];
      final configBase =
          (xdg != null && xdg.isNotEmpty) ? xdg : p.join(home, '.config');
      // Cursor may use Cursor or cursor casing
      paths.add(
        p.join(configBase, 'Cursor', 'User', 'globalStorage', 'state.vscdb'),
      );
      paths.add(
        p.join(configBase, 'cursor', 'User', 'globalStorage', 'state.vscdb'),
      );
    }
    return paths;
  }

  static String? authJsonPath() {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'];
      if (appData != null) {
        return p.join(appData, 'cursor', 'auth.json');
      }
    }
    final xdg = Platform.environment['XDG_CONFIG_HOME'];
    final configBase =
        (xdg != null && xdg.isNotEmpty) ? xdg : p.join(home, '.config');
    final a = p.join(configBase, 'cursor', 'auth.json');
    final b = p.join(configBase, 'Cursor', 'auth.json');
    if (File(a).existsSync()) return a;
    if (File(b).existsSync()) return b;
    return a;
  }

  static CursorCredentials? load() {
    for (final dbPath in candidateDbPaths()) {
      final creds = _fromVscdb(dbPath);
      if (creds != null) return creds;
    }
    return _fromAuthJson();
  }

  static CursorCredentials? _fromVscdb(String dbPath) {
    final file = File(dbPath);
    if (!file.existsSync()) return null;
    try {
      final db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
      try {
        final result = db.select(
          'SELECT value FROM ItemTable WHERE key = ? LIMIT 1',
          ['cursorAuth/accessToken'],
        );
        if (result.isEmpty) return null;
        final token = result.first['value']?.toString();
        if (token == null || token.trim().isEmpty) return null;
        return _fromAccessToken(token, 'cursor-app:$dbPath');
      } finally {
        db.close();
      }
    } catch (_) {
      return null;
    }
  }

  static CursorCredentials? _fromAuthJson() {
    final path = authJsonPath();
    if (path == null) return null;
    final file = File(path);
    if (!file.existsSync()) return null;
    try {
      final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final token =
          (data['accessToken'] ?? data['access_token'])?.toString();
      if (token == null || token.trim().isEmpty) return null;
      return _fromAccessToken(token, 'cursor-auth.json');
    } catch (_) {
      return null;
    }
  }

  static CursorCredentials _fromAccessToken(String token, String source) {
    final payload = decodeJwtPayload(token);
    final exp = payload['exp'];
    if (exp is num) {
      final expires =
          DateTime.fromMillisecondsSinceEpoch((exp * 1000).round(), isUtc: true);
      if (expires.isBefore(DateTime.now().toUtc().add(const Duration(seconds: 60)))) {
        throw AuthException(
          'Cursor access token expired. Open Cursor (or Cursor CLI) and sign in again.',
        );
      }
    }

    final sub = payload['sub']?.toString();
    if (sub == null || sub.isEmpty) {
      throw AuthException('Cursor token missing sub claim');
    }
    final userId = sub.split('|').last;
    if (userId.isEmpty) {
      throw AuthException('Cursor token missing user id');
    }

    // Match CodexBar: userId%3A%3A + raw JWT (do not URI-encode the token).
    final cookieHeader = 'WorkosCursorSessionToken=$userId%3A%3A$token';

    return CursorCredentials(
      accessToken: token,
      userId: userId,
      cookieHeader: cookieHeader,
      source: source,
    );
  }

  static CursorCredentials require() {
    final creds = load();
    if (creds != null) return creds;
    throw AuthException(
      'No Cursor credentials found.\n'
      'Sign in to the Cursor app (writes state.vscdb) or ensure '
      '~/.config/cursor/auth.json exists.',
    );
  }
}
