import 'dart:convert';

import 'package:http/http.dart' as http;

import '../auth/claude_auth.dart';
import '../auth/opencode_auth.dart';
import '../models/usage_snapshot.dart';

/// Reads Claude subscription usage from the endpoint Claude Code's own
/// `/usage` view uses. The response is unofficial and grows new keys over
/// time, so parsing keeps every window it recognises and skips the rest.
class ClaudeUsageClient {
  ClaudeUsageClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const usageUrl = 'https://api.anthropic.com/api/oauth/usage';
  static const betaHeader = 'oauth-2025-04-20';

  Future<ClaudeUsage> fetchUsage(ClaudeCredentials creds) async {
    final response = await _client.get(
      Uri.parse(usageUrl),
      headers: {
        'Authorization': 'Bearer ${creds.accessToken}',
        'anthropic-beta': betaHeader,
        'Accept': 'application/json',
        'User-Agent': 'fluttAIrbar/1.0',
      },
    );

    // Response bodies are not quoted in errors: they can carry account data.
    if (response.statusCode == 401) {
      throw SessionExpiredException(
        'Claude rejected the saved session (401): run claude to renew it.',
      );
    }
    if (response.statusCode == 403) {
      throw AuthException(
        'Claude usage is not available for this session (403).',
      );
    }
    if (response.statusCode == 429) {
      throw AuthException('Rate limited by Claude: retry shortly.');
    }
    if (response.statusCode != 200) {
      throw AuthException('Claude usage answered HTTP ${response.statusCode}.');
    }

    Object? data;
    try {
      data = jsonDecode(response.body);
    } on FormatException {
      data = null;
    }
    if (data is! Map) {
      throw AuthException('Claude usage returned an unexpected answer.');
    }
    return ClaudeUsage(
      plan: creds.subscriptionType,
      windows: parseWindows(Map<String, dynamic>.from(data)),
      fetchedAt: DateTime.now(),
    );
  }

  /// Turns a usage response into rate windows.
  ///
  /// Two shapes are read. Top-level keys such as `five_hour`, `seven_day`
  /// and `seven_day_opus` hold `{utilization, resets_at}`; any other
  /// top-level object with a numeric `utilization` is kept as an extra
  /// window. The newer `limits` list holds `{kind, percent, resets_at,
  /// scope}` and is where model-scoped weekly limits appear. A window found
  /// in both is reported once, from the top-level key.
  static List<RateWindow> parseWindows(Map<String, dynamic> data) {
    final windows = <String, RateWindow>{};

    for (final entry in data.entries) {
      final value = entry.value;
      if (value is! Map) continue;
      final utilization = value['utilization'];
      if (utilization is! num) continue;
      final named = _namedWindow(entry.key);
      windows.putIfAbsent(
        named.id,
        () => _window(named, utilization, value['resets_at']),
      );
    }

    final limits = data['limits'];
    if (limits is List) {
      for (final item in limits) {
        if (item is! Map) continue;
        final percent = item['percent'] ?? item['utilization'];
        final kind = item['kind'];
        if (percent is! num || kind is! String || kind.isEmpty) continue;
        final named = _limitWindow(kind, _scopeName(item['scope']));
        windows.putIfAbsent(
          named.id,
          () => _window(named, percent, item['resets_at']),
        );
      }
    }
    return windows.values.toList();
  }

  static RateWindow _window(
    ({String id, String label, int? seconds}) named,
    num percent,
    Object? resetsAt,
  ) {
    return RateWindow(
      id: named.id,
      label: named.label,
      usedPercent: percent.toDouble().clamp(0, 100).toDouble(),
      resetAt: resetsAt is String
          ? DateTime.tryParse(resetsAt)?.toLocal()
          : null,
      limitWindowSeconds: named.seconds,
    );
  }

  static const _sessionSeconds = 5 * 3600;
  static const _weekSeconds = 7 * 86400;

  static ({String id, String label, int? seconds}) _namedWindow(String key) {
    if (key == 'five_hour') {
      return (id: 'session', label: '5 hours', seconds: _sessionSeconds);
    }
    if (key == 'seven_day') {
      return (id: 'weekly', label: '7 days', seconds: _weekSeconds);
    }
    const weeklyPrefix = 'seven_day_';
    if (key.startsWith(weeklyPrefix)) {
      final scope = key.substring(weeklyPrefix.length);
      return (
        id: 'weekly-${_slug(scope)}',
        label: '7 days · ${_humanize(scope)}',
        seconds: _weekSeconds,
      );
    }
    return (id: _slug(key), label: _humanize(key), seconds: null);
  }

  static ({String id, String label, int? seconds}) _limitWindow(
    String kind,
    String? scope,
  ) {
    switch (kind) {
      case 'session':
        return _namedWindow('five_hour');
      case 'weekly_all':
        return _namedWindow('seven_day');
      case 'weekly_scoped':
        final name = scope ?? 'scoped';
        return (
          id: 'weekly-${_slug(name)}',
          label: '7 days · $name',
          seconds: _weekSeconds,
        );
    }
    final label = _humanize(kind);
    return (
      id: scope == null ? _slug(kind) : '${_slug(kind)}-${_slug(scope)}',
      label: scope == null ? label : '$label · $scope',
      seconds: null,
    );
  }

  /// The model (or product surface) a scoped limit applies to, such as
  /// "Opus". These are product names, never account data.
  static String? _scopeName(Object? scope) {
    if (scope is! Map) return null;
    final model = scope['model'];
    if (model is Map) {
      final name = model['display_name'] ?? model['id'];
      if (name is String && name.trim().isNotEmpty) return name.trim();
    }
    final surface = scope['surface'];
    if (surface is String && surface.trim().isNotEmpty) return surface.trim();
    return null;
  }

  static String _slug(String value) {
    final slug = value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return slug.isEmpty ? 'window' : slug;
  }

  static String _humanize(String value) {
    final words = value.replaceAll(RegExp(r'[_\s]+'), ' ').trim();
    if (words.isEmpty) return 'Window';
    return '${words[0].toUpperCase()}${words.substring(1)}';
  }

  void close() => _client.close();
}
