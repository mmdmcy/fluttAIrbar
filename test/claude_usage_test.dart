import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fluttairbar/api/claude_usage.dart';
import 'package:fluttairbar/auth/claude_auth.dart';
import 'package:fluttairbar/auth/opencode_auth.dart';
import 'package:fluttairbar/models/usage_snapshot.dart';
import 'package:fluttairbar/services/usage_fetcher.dart';

const _credentials = ClaudeCredentials(
  accessToken: 'test-token',
  source: 'test',
  subscriptionType: 'pro',
);

void main() {
  test('reads the documented five_hour and seven_day windows', () {
    final windows = ClaudeUsageClient.parseWindows({
      'five_hour': {
        'utilization': 12.5,
        'resets_at': '2026-11-01T18:00:00.000000+00:00',
      },
      'seven_day': {'utilization': 40, 'resets_at': null},
    });

    expect(windows.map((w) => w.id), ['session', 'weekly']);
    expect(windows.first.label, '5 hours');
    expect(windows.first.usedPercent, 12.5);
    expect(windows.first.resetAt!.toUtc(), DateTime.utc(2026, 11, 1, 18));
    expect(windows.last.label, '7 days');
    expect(windows.last.usedPercent, 40);
    expect(windows.last.resetAt, isNull);
  });

  test('unknown windows, nulls and junk do not break parsing', () {
    final windows = ClaudeUsageClient.parseWindows({
      'five_hour': {'utilization': 2.0, 'resets_at': 'not a date'},
      'seven_day': null,
      'seven_day_opus': {'utilization': 150, 'resets_at': null},
      'seven_day_sonnet': null,
      'iguana_necktie': null,
      'brand_new_window': {'utilization': 7, 'resets_at': null},
      'extra_usage': {'is_enabled': false, 'utilization': null},
      'spend': {'percent': 3, 'enabled': true},
      'limits': 'unexpected',
      'member_dashboard_available': true,
      'weekly_scoped_shares': [],
    });

    expect(windows.map((w) => w.id), [
      'session',
      'weekly-opus',
      'brand-new-window',
    ]);
    expect(windows.first.resetAt, isNull);
    expect(windows[1].label, '7 days · Opus');
    expect(windows[1].usedPercent, 100);
    expect(windows[2].label, 'Brand new window');
  });

  test('model-scoped weekly limits come from the limits list', () {
    final windows = ClaudeUsageClient.parseWindows({
      'five_hour': {'utilization': 3.0, 'resets_at': null},
      'seven_day': {'utilization': 47.0, 'resets_at': null},
      'limits': [
        {'kind': 'session', 'percent': 3, 'resets_at': null, 'scope': null},
        {'kind': 'weekly_all', 'percent': 47, 'resets_at': null},
        {
          'kind': 'weekly_scoped',
          'percent': 86,
          'resets_at': '2026-11-03T08:00:00+00:00',
          'scope': {
            'model': {'id': null, 'display_name': 'Opus'},
            'surface': null,
          },
        },
        {'kind': 'weekly_scoped', 'percent': null},
        {'percent': 10},
        'junk',
      ],
    });

    expect(windows.map((w) => w.id), ['session', 'weekly', 'weekly-opus']);
    expect(windows.last.label, '7 days · Opus');
    expect(windows.last.usedPercent, 86);
    expect(windows.last.resetAt!.toUtc(), DateTime.utc(2026, 11, 3, 8));
  });

  test(
    'fetch sends the Claude Code OAuth headers and keeps the plan',
    () async {
      late http.Request seen;
      final client = MockClient((request) async {
        seen = request;
        return http.Response(
          jsonEncode({
            'five_hour': {'utilization': 1, 'resets_at': null},
          }),
          200,
        );
      });

      final usage = await ClaudeUsageClient(
        client: client,
      ).fetchUsage(_credentials);

      expect(seen.method, 'GET');
      expect(seen.url.toString(), 'https://api.anthropic.com/api/oauth/usage');
      expect(seen.headers['Authorization'], 'Bearer test-token');
      expect(seen.headers['anthropic-beta'], 'oauth-2025-04-20');
      expect(usage.state, UsageState.ok);
      expect(usage.plan, 'pro');
      expect(usage.windows.single.id, 'session');
    },
  );

  test(
    'a rejected session reads as expired without echoing the body',
    () async {
      final client = MockClient(
        (_) async => http.Response('{"error":"test-token invalid"}', 401),
      );

      expect(
        ClaudeUsageClient(client: client).fetchUsage(_credentials),
        throwsA(
          isA<SessionExpiredException>().having(
            (error) => error.message,
            'message',
            allOf(contains('run claude'), isNot(contains('test-token'))),
          ),
        ),
      );
    },
  );

  group('fetcher', () {
    late Directory directory;
    setUp(() {
      directory = Directory.systemTemp.createTempSync('fluttairbar-fetch-');
    });
    tearDown(() => directory.deleteSync(recursive: true));

    UsageFetcher fetcher(http.Client client) => UsageFetcher(
      client: client,
      claudeCredentialsPath: '${directory.path}/.credentials.json',
    );

    final noNetwork = MockClient((request) async {
      fail('expected no request, got ${request.url}');
    });

    test('an expired token is reported, never sent', () async {
      File('${directory.path}/.credentials.json').writeAsStringSync(
        jsonEncode({
          'claudeAiOauth': {
            'accessToken': 'test-token',
            'expiresAt': DateTime.now()
                .subtract(const Duration(hours: 1))
                .millisecondsSinceEpoch,
            'subscriptionType': 'max',
          },
        }),
      );

      final usage = await fetcher(noNetwork).claude();

      expect(usage.state, UsageState.expired);
      expect(usage.error, 'Claude session expired: run claude to renew it.');
      expect(usage.plan, 'max');
    });

    test('no credentials file reads as signed out', () async {
      final usage = await fetcher(noNetwork).claude();

      expect(usage.state, UsageState.signedOut);
      expect(usage.error, contains('run claude to sign in'));
    });

    test('a valid session returns its windows', () async {
      File('${directory.path}/.credentials.json').writeAsStringSync(
        jsonEncode({
          'claudeAiOauth': {
            'accessToken': 'test-token',
            'expiresAt': DateTime.now()
                .add(const Duration(hours: 1))
                .millisecondsSinceEpoch,
          },
        }),
      );
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'seven_day': {'utilization': 50, 'resets_at': null},
          }),
          200,
        ),
      );

      final usage = await fetcher(client).claude();

      expect(usage.state, UsageState.ok);
      expect(usage.headline!.id, 'weekly');
    });
  });
}
