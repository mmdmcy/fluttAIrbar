import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../auth/opencode_auth.dart';
import '../models/usage_snapshot.dart';

class ChatGptWhamClient {
  ChatGptWhamClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const usageUrl = 'https://chatgpt.com/backend-api/wham/usage';
  static const resetCreditsUrl =
      'https://chatgpt.com/backend-api/wham/rate-limit-reset-credits';
  static const consumeResetCreditsUrl =
      'https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume';

  Map<String, String> _headers(OAuthCredentials creds, {bool jsonBody = false}) {
    return {
      'Authorization': 'Bearer ${creds.accessToken}',
      'ChatGPT-Account-Id': creds.accountId,
      'ChatGPT-Account-ID': creds.accountId,
      'OpenAI-Beta': 'codex-1',
      'originator': 'Codex Desktop',
      'User-Agent': 'fluttAIrbar/1.0',
      'Accept': 'application/json',
      if (jsonBody) 'Content-Type': 'application/json',
    };
  }

  Future<CodexUsage> fetchUsage(OAuthCredentials creds) async {
    final response = await _client.get(
      Uri.parse(usageUrl),
      headers: _headers(creds),
    );

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw AuthException(
        'ChatGPT auth failed (${response.statusCode}). '
        'Re-login via OpenCode or Codex CLI.',
      );
    }
    if (response.statusCode == 429) {
      throw AuthException('Rate limited by ChatGPT — retry shortly.');
    }
    if (response.statusCode != 200) {
      throw AuthException(
        'wham/usage HTTP ${response.statusCode}: '
        '${response.body.length > 200 ? response.body.substring(0, 200) : response.body}',
      );
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final rateLimit = data['rate_limit'] as Map<String, dynamic>? ?? {};
    final credits = data['credits'] as Map<String, dynamic>? ?? {};

    final primaryRaw = rateLimit['primary_window'] as Map<String, dynamic>?;
    final secondaryRaw = rateLimit['secondary_window'] as Map<String, dynamic>?;

    RateWindow? session;
    RateWindow? weekly;
    final parsed = <RateWindow>[];
    if (primaryRaw != null) {
      parsed.add(RateWindow.fromJson(primaryRaw, label: _labelFor(primaryRaw)));
    }
    if (secondaryRaw != null) {
      parsed.add(
        RateWindow.fromJson(secondaryRaw, label: _labelFor(secondaryRaw)),
      );
    }
    for (final w in parsed) {
      final secs = w.limitWindowSeconds ?? 0;
      if (secs > 0 && secs <= 50000) {
        session ??= w;
      } else if (secs >= 200000) {
        weekly ??= w;
      }
    }
    // Weekly-only plans (no 5h window): primary is the week meter.
    if (weekly == null && session == null && parsed.isNotEmpty) {
      final only = parsed.first;
      if ((only.limitWindowSeconds ?? 0) >= 200000 || parsed.length == 1) {
        weekly = only;
      } else {
        session = only;
      }
    }

    return CodexUsage(
      email: creds.email,
      accountId: creds.accountId,
      authSource: creds.source,
      planType: data['plan_type']?.toString(),
      primary: session,
      secondary: weekly,
      creditsBalance: credits['balance']?.toString(),
      creditsUnlimited: credits['unlimited'] == true,
      hasCredits: credits['has_credits'] == true,
      limitReached: rateLimit['limit_reached'] == true,
      allowed: rateLimit['allowed'] != false,
      fetchedAt: DateTime.now(),
    );
  }

  Future<({List<ResetCredit> credits, int availableCount})> fetchResetCredits(
    OAuthCredentials creds,
  ) async {
    final response = await _client.get(
      Uri.parse(resetCreditsUrl),
      headers: _headers(creds),
    );

    if (response.statusCode != 200) {
      return (credits: <ResetCredit>[], availableCount: 0);
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final raw = data['credits'];
    final list = <ResetCredit>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map<String, dynamic>) {
          list.add(ResetCredit.fromJson(item));
        } else if (item is Map) {
          list.add(ResetCredit.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }

    final available = list.where((c) => c.isAvailable).toList()
      ..sort((a, b) {
        final ae = a.expiresAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final be = b.expiresAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return ae.compareTo(be);
      });

    final count =
        (data['available_count'] as num?)?.toInt() ?? available.length;
    return (credits: available, availableCount: count);
  }

  /// Consume one banked reset. [creditId] is required — omitting it lets the
  /// server auto-pick and spend a credit.
  Future<ConsumeResetResult> consumeResetCredit(
    OAuthCredentials creds, {
    required String creditId,
    String? redeemRequestId,
  }) async {
    final id = creditId.trim();
    if (id.isEmpty) {
      throw AuthException('credit_id is required — refusing to redeem');
    }
    final requestId = redeemRequestId ?? _uuidV4();
    final response = await _client.post(
      Uri.parse(consumeResetCreditsUrl),
      headers: _headers(creds, jsonBody: true),
      body: jsonEncode({
        'credit_id': id,
        'redeem_request_id': requestId,
      }),
    );

    Map<String, dynamic>? body;
    try {
      body = jsonDecode(response.body) as Map<String, dynamic>?;
    } catch (_) {}

    final code = body?['code']?.toString() ??
        (response.statusCode == 200 ? 'reset' : 'http_${response.statusCode}');
    return ConsumeResetResult(
      ok: code == 'reset',
      code: code,
      statusCode: response.statusCode,
      redeemRequestId: requestId,
      raw: body,
    );
  }

  static String _uuidV4() {
    final r = Random.secure();
    final bytes = List<int>.generate(16, (_) => r.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    String hex(int b) => b.toRadixString(16).padLeft(2, '0');
    final h = bytes.map(hex).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-'
        '${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }

  static String _labelFor(Map<String, dynamic> window) {
    final secs = (window['limit_window_seconds'] as num?)?.toInt();
    if (secs == null) return 'Window';
    if (secs <= 50000) return '5h';
    if (secs >= 200000) return 'Weekly';
    return '${(secs / 3600).round()}h';
  }

  void close() => _client.close();
}

class ConsumeResetResult {
  const ConsumeResetResult({
    required this.ok,
    required this.code,
    required this.statusCode,
    required this.redeemRequestId,
    this.raw,
  });

  final bool ok;
  final String code;
  final int statusCode;
  final String redeemRequestId;
  final Map<String, dynamic>? raw;
}
