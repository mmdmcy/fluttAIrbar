// Shared usage models for Codex, Claude and Cursor.

/// How far a provider's usage could be read. The JSON names are part of the
/// `fluttairbar.usage.v1` command-line contract.
enum UsageState {
  ok('ok'),
  signedOut('signed-out'),
  expired('expired'),
  stale('stale'),
  paused('paused'),
  error('error');

  const UsageState(this.jsonName);

  final String jsonName;
}

class RateWindow {
  const RateWindow({
    required this.usedPercent,
    this.resetAt,
    this.resetAfterSeconds,
    this.limitWindowSeconds,
    this.label,
    this.id,
  });

  final double usedPercent;
  final DateTime? resetAt;
  final int? resetAfterSeconds;
  final int? limitWindowSeconds;
  final String? label;

  /// Stable machine name such as `session`, `weekly` or `weekly-opus`.
  final String? id;

  String get resetDescription {
    DateTime? at = resetAt;
    Duration? remaining;
    if (resetAfterSeconds != null && resetAfterSeconds! >= 0) {
      remaining = Duration(seconds: resetAfterSeconds!);
      at ??= DateTime.now().add(remaining);
    } else if (resetAt != null) {
      remaining = resetAt!.difference(DateTime.now());
      if (remaining.isNegative) return 'soon';
    } else {
      return '?';
    }

    // Long windows (billing cycles, weekly): prefer calendar date.
    if (remaining.inHours >= 48 && at != null) {
      return _formatDate(at);
    }
    return _formatDuration(remaining);
  }

  static String _formatDate(DateTime d) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final local = d.toLocal();
    final now = DateTime.now();
    final days = local
        .difference(DateTime(now.year, now.month, now.day))
        .inDays;
    final dateLabel =
        '${months[local.month - 1]} ${local.day}${local.year != now.year ? ', ${local.year}' : ''}';
    if (days <= 0) return 'today ($dateLabel)';
    if (days == 1) return 'tomorrow ($dateLabel)';
    return 'in ${days}d · $dateLabel';
  }

  static String _formatDuration(Duration d) {
    final days = d.inDays;
    final h = d.inHours.remainder(24);
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (days >= 2) {
      return h > 0 ? 'in ${days}d ${h}h' : 'in ${days}d';
    }
    if (d.inHours >= 24) {
      return 'in ${d.inHours}h ${m.toString().padLeft(2, '0')}m';
    }
    if (d.inHours > 0) return 'in ${d.inHours}h ${m.toString().padLeft(2, '0')}m';
    if (m > 0) return 'in ${m}m ${s.toString().padLeft(2, '0')}s';
    return 'in ${s}s';
  }

  factory RateWindow.fromJson(Map<String, dynamic>? json, {String? label}) {
    if (json == null) {
      return RateWindow(usedPercent: 0, label: label);
    }
    final used = (json['used_percent'] as num?)?.toDouble() ??
        (json['usedPercent'] as num?)?.toDouble() ??
        0;
    DateTime? resetAt;
    final resetAtRaw = json['reset_at'] ?? json['resetsAt'] ?? json['resetAt'];
    if (resetAtRaw is num) {
      resetAt = DateTime.fromMillisecondsSinceEpoch(
        (resetAtRaw * 1000).round(),
        isUtc: true,
      ).toLocal();
    } else if (resetAtRaw is String) {
      resetAt = DateTime.tryParse(resetAtRaw)?.toLocal();
    }
    final resetAfter = (json['reset_after_seconds'] as num?)?.toInt() ??
        (json['resetAfterSeconds'] as num?)?.toInt();
    final windowSecs = (json['limit_window_seconds'] as num?)?.toInt() ??
        (json['limitWindowSeconds'] as num?)?.toInt();
    return RateWindow(
      usedPercent: used.clamp(0, 100),
      resetAt: resetAt,
      resetAfterSeconds: resetAfter,
      limitWindowSeconds: windowSecs,
      label: label,
    );
  }
}

class ResetCredit {
  const ResetCredit({
    required this.id,
    required this.status,
    this.title,
    this.description,
    this.resetType,
    this.expiresAt,
    this.grantedAt,
  });

  final String id;
  final String status;
  final String? title;
  final String? description;
  final String? resetType;
  final DateTime? expiresAt;
  final DateTime? grantedAt;

  bool get isAvailable {
    if (status.toLowerCase() != 'available') return false;
    if (expiresAt == null) return true;
    return expiresAt!.isAfter(DateTime.now());
  }

  factory ResetCredit.fromJson(Map<String, dynamic> json) {
    DateTime? parseTs(dynamic v) {
      if (v == null) return null;
      if (v is String) return DateTime.tryParse(v)?.toLocal();
      if (v is num) {
        return DateTime.fromMillisecondsSinceEpoch(
          (v * 1000).round(),
          isUtc: true,
        ).toLocal();
      }
      return null;
    }

    return ResetCredit(
      id: json['id']?.toString() ?? '',
      status: json['status']?.toString() ?? '',
      title: json['title']?.toString(),
      description: json['description']?.toString(),
      resetType: json['reset_type']?.toString() ?? json['resetType']?.toString(),
      expiresAt: parseTs(json['expires_at'] ?? json['expiresAt']),
      grantedAt: parseTs(json['granted_at'] ?? json['grantedAt']),
    );
  }
}

class CodexUsage {
  const CodexUsage({
    required this.email,
    required this.accountId,
    required this.authSource,
    this.planType,
    this.primary,
    this.secondary,
    this.creditsBalance,
    this.creditsUnlimited = false,
    this.hasCredits = false,
    this.limitReached = false,
    this.allowed = true,
    this.resetCredits = const [],
    this.availableResetCount = 0,
    this.fetchedAt,
    this.error,
    this.state = UsageState.ok,
  });

  final String email;
  final String accountId;
  final String authSource;
  final String? planType;
  final RateWindow? primary;
  final RateWindow? secondary;
  final String? creditsBalance;
  final bool creditsUnlimited;
  final bool hasCredits;
  final bool limitReached;
  final bool allowed;
  final List<ResetCredit> resetCredits;
  final int availableResetCount;
  final DateTime? fetchedAt;
  final String? error;
  final UsageState state;

  bool get hasError => error != null;

  CodexUsage copyWith({
    List<ResetCredit>? resetCredits,
    int? availableResetCount,
    String? error,
    UsageState? state,
  }) {
    return CodexUsage(
      email: email,
      accountId: accountId,
      authSource: authSource,
      planType: planType,
      primary: primary,
      secondary: secondary,
      creditsBalance: creditsBalance,
      creditsUnlimited: creditsUnlimited,
      hasCredits: hasCredits,
      limitReached: limitReached,
      allowed: allowed,
      resetCredits: resetCredits ?? this.resetCredits,
      availableResetCount: availableResetCount ?? this.availableResetCount,
      fetchedAt: fetchedAt,
      error: error,
      state: state ?? this.state,
    );
  }
}

/// Claude Code subscription usage windows, read with the local Claude Code
/// session. Only the plan name is kept from the credentials.
class ClaudeUsage {
  const ClaudeUsage({
    this.plan,
    this.windows = const [],
    this.fetchedAt,
    this.error,
    this.state = UsageState.ok,
  });

  final String? plan;
  final List<RateWindow> windows;
  final DateTime? fetchedAt;
  final String? error;
  final UsageState state;

  bool get hasError => error != null;

  RateWindow? window(String id) {
    for (final candidate in windows) {
      if (candidate.id == id) return candidate;
    }
    return null;
  }

  /// The window shown in the tray: weekly first, like Codex.
  RateWindow? get headline =>
      window('weekly') ??
      window('session') ??
      (windows.isEmpty ? null : windows.first);
}

class CursorUsage {
  const CursorUsage({
    required this.authSource,
    this.email,
    this.planName,
    this.usedPercent,
    this.billingCycleEnd,
    this.fetchedAt,
    this.error,
    this.state = UsageState.ok,
  });

  final String authSource;
  final String? email;
  final String? planName;
  final double? usedPercent;
  final DateTime? billingCycleEnd;
  final DateTime? fetchedAt;
  final String? error;
  final UsageState state;

  bool get hasError => error != null;
}

class AppSnapshot {
  const AppSnapshot({
    this.codex,
    this.claude,
    this.cursor,
    this.refreshedAt,
  });

  final CodexUsage? codex;
  final ClaudeUsage? claude;
  final CursorUsage? cursor;
  final DateTime? refreshedAt;

  String get trayTooltip {
    final parts = <String>[];
    final codexWindow = codex?.secondary ?? codex?.primary;
    if (codexWindow != null) {
      final label = codexWindow.label ?? 'Codex';
      final left = (100 - codexWindow.usedPercent).clamp(0, 100).round();
      parts.add('$label $left% left');
    } else if (codex?.error != null) {
      parts.add('Codex: —');
    }
    final claudeWindow = claude?.headline;
    if (claudeWindow != null) {
      final left = (100 - claudeWindow.usedPercent).clamp(0, 100).round();
      parts.add('Claude $left% left');
    } else if (claude?.error != null) {
      parts.add('Claude: —');
    }
    if (cursor?.usedPercent != null) {
      final left = (100 - cursor!.usedPercent!).clamp(0, 100).round();
      parts.add('Cursor $left% left');
    } else if (cursor?.error != null) {
      parts.add('Cursor: —');
    }
    if (parts.isEmpty) return 'fluttAIrbar';
    return 'fluttAIrbar · ${parts.join(' · ')}';
  }

  String get trayTitle {
    final w = codex?.secondary ?? codex?.primary;
    if (w != null) {
      return '${(100 - w.usedPercent).clamp(0, 100).round()}%';
    }
    final c = claude?.headline;
    if (c != null) {
      return '${(100 - c.usedPercent).clamp(0, 100).round()}%';
    }
    final u = cursor?.usedPercent;
    if (u != null) return '${(100 - u).clamp(0, 100).round()}%';
    return 'AI';
  }
}
