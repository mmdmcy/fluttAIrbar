import 'dart:convert';

import 'package:http/http.dart' as http;

import '../auth/cursor_auth.dart';
import '../auth/opencode_auth.dart';
import '../models/usage_snapshot.dart';

class CursorApiClient {
  CursorApiClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  static const base = 'https://cursor.com';

  Future<CursorUsage> fetchUsage(CursorCredentials creds) async {
    final response = await _client.get(
      Uri.parse('$base/api/usage-summary'),
      headers: {
        'Accept': 'application/json',
        'Cookie': creds.cookieHeader,
        'User-Agent': 'fluttAIrbar/1.0',
      },
    );

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw AuthException(
        'Cursor auth failed (${response.statusCode}). Sign in to Cursor again.',
      );
    }
    if (response.statusCode != 200) {
      throw AuthException(
        'Cursor usage-summary HTTP ${response.statusCode}',
      );
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    String? email;
    try {
      final me = await _client.get(
        Uri.parse('$base/api/auth/me'),
        headers: {
          'Accept': 'application/json',
          'Cookie': creds.cookieHeader,
          'User-Agent': 'fluttAIrbar/1.0',
        },
      );
      if (me.statusCode == 200) {
        final body = jsonDecode(me.body) as Map<String, dynamic>;
        email = body['email']?.toString() ?? body['name']?.toString();
      }
    } catch (_) {}

    final individual = data['individualUsage'] as Map<String, dynamic>?;
    final plan = individual?['plan'] as Map<String, dynamic>?;
    final overall = individual?['overall'] as Map<String, dynamic>?;
    final team = data['teamUsage'] as Map<String, dynamic>?;
    final pooled = team?['pooled'] as Map<String, dynamic>?;

    double? usedPercent;
    final totalPct = (plan?['totalPercentUsed'] as num?)?.toDouble();
    if (totalPct != null) {
      usedPercent = totalPct.clamp(0, 100);
    } else {
      final auto = (plan?['autoPercentUsed'] as num?)?.toDouble();
      final api = (plan?['apiPercentUsed'] as num?)?.toDouble();
      if (auto != null && api != null) {
        usedPercent = ((auto + api) / 2).clamp(0, 100);
      } else if (auto != null) {
        usedPercent = auto.clamp(0, 100);
      } else if (api != null) {
        usedPercent = api.clamp(0, 100);
      } else if (plan != null) {
        final used = (plan['used'] as num?)?.toDouble() ?? 0;
        final limit = (plan['limit'] as num?)?.toDouble() ?? 0;
        if (limit > 0) usedPercent = ((used / limit) * 100).clamp(0, 100);
      } else if (overall != null) {
        final used = (overall['used'] as num?)?.toDouble() ?? 0;
        final limit = (overall['limit'] as num?)?.toDouble() ?? 0;
        if (limit > 0) usedPercent = ((used / limit) * 100).clamp(0, 100);
      } else if (pooled != null) {
        final used = (pooled['used'] as num?)?.toDouble() ?? 0;
        final limit = (pooled['limit'] as num?)?.toDouble() ?? 0;
        if (limit > 0) usedPercent = ((used / limit) * 100).clamp(0, 100);
      }
    }

    DateTime? cycleEnd;
    final endRaw = data['billingCycleEnd']?.toString();
    if (endRaw != null) {
      cycleEnd = DateTime.tryParse(endRaw)?.toLocal();
    }

    return CursorUsage(
      authSource: creds.source,
      email: email,
      planName: data['membershipType']?.toString() ??
          data['planName']?.toString() ??
          plan?['name']?.toString(),
      usedPercent: usedPercent,
      billingCycleEnd: cycleEnd,
      fetchedAt: DateTime.now(),
    );
  }

  void close() => _client.close();
}
