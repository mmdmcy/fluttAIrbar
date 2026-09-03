import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fluttairbar/auth/codex_cli_auth.dart';
import 'package:fluttairbar/auth/opencode_auth.dart';

void main() {
  test('Codex CLI auth is the sole auth source', () async {
    final directory = Directory.systemTemp.createTempSync(
      'fluttairbar-auth-resolution-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final codexPath = '${directory.path}/codex-auth.json';

    File(codexPath).writeAsStringSync(
      jsonEncode({
        'tokens': {
          'access_token': 'codex-cli-token',
          'account_id': 'codex-account',
        },
      }),
    );
    final credentials = await CodexAuthResolver.resolve(codexPath: codexPath);

    expect(credentials.source, 'codex-cli');
    expect(credentials.accountId, 'codex-account');
    expect(credentials.accessToken, 'codex-cli-token');
  });

  test('a broken Codex CLI auth file produces an actionable error', () async {
    final directory = Directory.systemTemp.createTempSync(
      'fluttairbar-auth-resolution-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final codexPath = '${directory.path}/codex-auth.json';
    File(codexPath).writeAsStringSync('{not json');

    expect(
      CodexAuthResolver.resolve(codexPath: codexPath),
      throwsA(isA<AuthException>()),
    );
  });
}
