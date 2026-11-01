import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fluttairbar/auth/claude_auth.dart';
import 'package:fluttairbar/auth/opencode_auth.dart';

String _credentials({Object? expiresAt, String? plan = 'max'}) => jsonEncode({
  'claudeAiOauth': {
    'accessToken': 'test-token',
    'refreshToken': 'test-refresh-token',
    'expiresAt': expiresAt,
    'scopes': ['user:inference', 'user:profile'],
    'subscriptionType': ?plan,
  },
});

void main() {
  test('parses the Claude Code OAuth session without the refresh token', () {
    final expires = DateTime.utc(2030, 1, 1);
    final credentials = ClaudeAuthStore.parse(
      _credentials(expiresAt: expires.millisecondsSinceEpoch),
      source: 'test',
    )!;

    expect(credentials.accessToken, 'test-token');
    expect(credentials.subscriptionType, 'max');
    expect(credentials.expiresAt, expires);
    expect(credentials.isExpiredAt(DateTime.utc(2029, 12, 31)), isFalse);
    expect(credentials.isExpiredAt(DateTime.utc(2030, 1, 1)), isTrue);
  });

  test('an expiry in the past is reported as expired', () {
    final credentials = ClaudeAuthStore.parse(
      _credentials(
        expiresAt: DateTime.now()
            .subtract(const Duration(minutes: 5))
            .millisecondsSinceEpoch,
      ),
      source: 'test',
    )!;

    expect(credentials.isExpired, isTrue);
  });

  test('a missing expiry or plan is tolerated', () {
    final credentials = ClaudeAuthStore.parse(
      _credentials(plan: null),
      source: 'test',
    )!;

    expect(credentials.expiresAt, isNull);
    expect(credentials.isExpired, isFalse);
    expect(credentials.subscriptionType, isNull);
  });

  test('a file without a Claude.ai session reads as signed out', () {
    expect(ClaudeAuthStore.parse('{}', source: 'test'), isNull);
    expect(
      ClaudeAuthStore.parse(
        jsonEncode({
          'claudeAiOauth': {'accessToken': ''},
        }),
        source: 'test',
      ),
      isNull,
    );
  });

  test('broken JSON fails without quoting the file contents', () {
    expect(
      () => ClaudeAuthStore.parse('{"claudeAiOauth": test-token', source: 't'),
      throwsA(
        isA<AuthException>().having(
          (error) => error.message,
          'message',
          isNot(contains('test-token')),
        ),
      ),
    );
  });

  test('load reads the file and never rewrites it', () async {
    final directory = Directory.systemTemp.createTempSync(
      'fluttairbar-claude-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}/.credentials.json';
    final original = _credentials(
      expiresAt: DateTime.now()
          .subtract(const Duration(days: 1))
          .millisecondsSinceEpoch,
    );
    File(path).writeAsStringSync(original);
    final modified = File(path).lastModifiedSync();

    final credentials = await ClaudeAuthStore.load(path: path);

    expect(credentials!.accessToken, 'test-token');
    expect(credentials.isExpired, isTrue);
    expect(File(path).readAsStringSync(), original);
    expect(File(path).lastModifiedSync(), modified);
    expect(ClaudeAuthStore.hasCredentials(path: path), isTrue);
  });

  test('a missing file means no session', () async {
    final directory = Directory.systemTemp.createTempSync(
      'fluttairbar-claude-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}/.credentials.json';

    expect(await ClaudeAuthStore.load(path: path), isNull);
    expect(ClaudeAuthStore.hasCredentials(path: path), isFalse);
  });
}
