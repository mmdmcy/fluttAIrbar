import '../models/usage_snapshot.dart';
import '../services/usage_fetcher.dart';

/// One usage window in the `fluttairbar.usage.v1` contract.
class UsageWindowReport {
  const UsageWindowReport({
    required this.id,
    required this.label,
    required this.usedPercent,
    this.resetsAt,
    this.resetDescription,
  });

  final String id;
  final String label;
  final double usedPercent;
  final DateTime? resetsAt;

  /// Human text for the terminal ("in 2h 03m"); not part of the JSON.
  final String? resetDescription;

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'used_percent': double.parse(usedPercent.toStringAsFixed(2)),
    'resets_at': resetsAt?.toUtc().toIso8601String(),
  };
}

/// One provider in the `fluttairbar.usage.v1` contract. It is built only
/// from states, plan names, percentages and reset times, so tokens, emails
/// and account ids cannot reach it.
class ProviderUsageReport {
  ProviderUsageReport({
    required this.id,
    required this.state,
    required String detail,
    String? plan,
    this.windows = const [],
  }) : detail = plainSentence(detail),
       plan = plan ?? '';

  final String id;
  final UsageState state;
  final String detail;
  final String plan;
  final List<UsageWindowReport> windows;

  Map<String, Object?> toJson() => {
    'id': id,
    'state': state.jsonName,
    'detail': detail,
    'plan': plan,
    'windows': windows.map((window) => window.toJson()).toList(),
  };

  String toLine() {
    final parts = <String>[state.jsonName];
    if (state != UsageState.ok) parts.add(detail);
    if (plan.isNotEmpty) parts.add(plan);
    for (final window in windows) {
      final reset = window.resetDescription;
      parts.add(
        '${window.label} ${window.usedPercent.round()}% used'
        '${reset == null || reset == '?' ? '' : ', resets $reset'}',
      );
    }
    return '${id.padRight(7)}${parts.join(' · ')}';
  }

  /// Collapses a message to one line and removes anything that looks like
  /// an email address, a bearer token or a long opaque id, in case an
  /// upstream error ever echoes one.
  static String plainSentence(String text) {
    var line = text
        .split('\n')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .join(' ');
    line = line
        .replaceAll(RegExp(r'[\w.+-]+@[\w-]+(\.[\w-]+)+'), '[email]')
        .replaceAll(
          RegExp(r'bearer\s+\S+', caseSensitive: false),
          'Bearer [redacted]',
        )
        .replaceAll(RegExp(r'[A-Za-z0-9_\-]{32,}(\.[A-Za-z0-9_\-]+)*'), '[id]');
    return line.length > 240 ? '${line.substring(0, 237)}...' : line;
  }
}

class UsageReport {
  const UsageReport(this.providers);

  static const schema = 'fluttairbar.usage.v1';

  final List<ProviderUsageReport> providers;

  /// [claude] or [cursor] null means the user paused that provider.
  factory UsageReport.from({
    required CodexUsage codex,
    ClaudeUsage? claude,
    CursorUsage? cursor,
  }) {
    return UsageReport([
      _codex(codex),
      claude == null
          ? ProviderUsageReport(
              id: 'claude',
              state: UsageState.paused,
              detail: 'Claude usage is paused in fluttAIrbar Settings.',
            )
          : _claude(claude),
      cursor == null
          ? ProviderUsageReport(
              id: 'cursor',
              state: UsageState.paused,
              detail: 'Cursor usage is paused in fluttAIrbar Settings.',
            )
          : _cursor(cursor),
    ]);
  }

  Map<String, Object?> toJson() => {
    'schema': schema,
    'providers': providers.map((provider) => provider.toJson()).toList(),
  };

  List<String> toLines() =>
      providers.map((provider) => provider.toLine()).toList();

  static ProviderUsageReport _codex(CodexUsage usage) {
    final windows = usage.hasError
        ? const <UsageWindowReport>[]
        : [
            if (usage.primary != null)
              _window(
                usage.primary!,
                'session',
                _durationLabel(usage.primary!.limitWindowSeconds) ?? '5 hours',
                usage.fetchedAt,
              ),
            if (usage.secondary != null)
              _window(
                usage.secondary!,
                'weekly',
                _durationLabel(usage.secondary!.limitWindowSeconds) ?? '7 days',
                usage.fetchedAt,
              ),
          ];
    return ProviderUsageReport(
      id: 'codex',
      state: usage.state,
      detail: switch (usage.state) {
        UsageState.ok => 'Read from the Codex CLI session.',
        UsageState.stale => UsageFetcher.codexStaleMessage,
        _ => usage.error ?? 'Codex usage could not be read.',
      },
      plan: usage.hasError ? null : usage.planType,
      windows: windows,
    );
  }

  static ProviderUsageReport _claude(ClaudeUsage usage) {
    return ProviderUsageReport(
      id: 'claude',
      state: usage.state,
      detail: usage.state == UsageState.ok
          ? 'Read from the Claude Code session.'
          : usage.error ?? 'Claude usage could not be read.',
      plan: usage.plan,
      windows: usage.hasError
          ? const []
          : [
              for (final window in usage.windows)
                _window(
                  window,
                  window.id ?? 'window',
                  window.label ?? 'Window',
                  usage.fetchedAt,
                ),
            ],
    );
  }

  static ProviderUsageReport _cursor(CursorUsage usage) {
    final percent = usage.usedPercent;
    return ProviderUsageReport(
      id: 'cursor',
      state: usage.state,
      detail: usage.state == UsageState.ok
          ? 'Read from the Cursor session.'
          : usage.error ?? 'Cursor usage could not be read.',
      plan: usage.hasError ? null : usage.planName,
      windows: usage.hasError || percent == null
          ? const []
          : [
              _window(
                RateWindow(
                  usedPercent: percent,
                  resetAt: usage.billingCycleEnd,
                ),
                'plan',
                'Billing cycle',
                usage.fetchedAt,
              ),
            ],
    );
  }

  static UsageWindowReport _window(
    RateWindow window,
    String id,
    String label,
    DateTime? fetchedAt,
  ) {
    var resetsAt = window.resetAt;
    final after = window.resetAfterSeconds;
    if (resetsAt == null && after != null && after >= 0) {
      resetsAt = (fetchedAt ?? DateTime.now()).add(Duration(seconds: after));
    }
    return UsageWindowReport(
      id: id,
      label: label,
      usedPercent: window.usedPercent,
      resetsAt: resetsAt,
      resetDescription: window.resetDescription,
    );
  }

  /// "5 hours" or "7 days" from a window length; null when unknown.
  static String? _durationLabel(int? seconds) {
    if (seconds == null || seconds <= 0) return null;
    if (seconds % 86400 == 0) {
      final days = seconds ~/ 86400;
      return days == 1 ? '1 day' : '$days days';
    }
    if (seconds % 3600 == 0) {
      final hours = seconds ~/ 3600;
      return hours == 1 ? '1 hour' : '$hours hours';
    }
    return null;
  }
}
