import 'package:flutter/material.dart';

import '../models/usage_snapshot.dart';
import '../providers/theme_store.dart';
import '../providers/usage_store.dart';
import 'widgets/usage_meter.dart';

class PanelPage extends StatelessWidget {
  const PanelPage({
    super.key,
    required this.store,
    required this.themeStore,
  });

  final UsageStore store;
  final ThemeStore themeStore;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([store, themeStore]),
      builder: (context, _) {
        final snap = store.snapshot;
        final theme = Theme.of(context);
        return Scaffold(
          backgroundColor: theme.colorScheme.surface,
          body: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Header(
                  loading: store.loading || store.redeeming,
                  refreshedAt: snap.refreshedAt,
                  isDark: themeStore.isDark,
                  onRefresh: store.refresh,
                  onToggleTheme: themeStore.toggle,
                ),
                if (store.statusMessage != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    store.statusMessage!,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                _CodexBlock(
                  usage: snap.codex,
                  redeeming: store.redeeming,
                  onRedeem: (credit) => _confirmRedeem(context, credit),
                ),
                const SizedBox(height: 10),
                _CursorBlock(usage: snap.cursor),
                const Spacer(),
                Text(
                  'Local auth only · resets need double confirm',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _confirmRedeem(BuildContext context, ResetCredit credit) async {
    final theme = Theme.of(context);
    final expiry = credit.expiresAt == null
        ? 'unknown expiry'
        : '${credit.expiresAt!.year}-'
            '${credit.expiresAt!.month.toString().padLeft(2, '0')}-'
            '${credit.expiresAt!.day.toString().padLeft(2, '0')}';

    final first = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Use a reset?'),
        content: Text(
          'This spends one banked Codex reset '
          '(${credit.title ?? 'Full reset'}, expires $expiry).\n\n'
          'Your usage window will reset immediately. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (first != true || !context.mounted) return;

    final second = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          'Confirm redeem',
          style: TextStyle(color: theme.colorScheme.error),
        ),
        content: const Text(
          'Really redeem this reset credit now?\n\n'
          'Tap Redeem only if you mean it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Redeem'),
          ),
        ],
      ),
    );
    if (second != true || !context.mounted) return;

    final result = await store.redeemResetCredit(credit.id);
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          result.ok
              ? 'Reset redeemed · usage refreshed'
              : 'Redeem failed: ${result.code}',
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.loading,
    required this.refreshedAt,
    required this.isDark,
    required this.onRefresh,
    required this.onToggleTheme,
  });

  final bool loading;
  final DateTime? refreshedAt;
  final bool isDark;
  final VoidCallback onRefresh;
  final VoidCallback onToggleTheme;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    String updated = '';
    if (refreshedAt != null) {
      final t = refreshedAt!;
      updated =
          '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    }
    return Row(
      children: [
        Expanded(
          child: Row(
            children: [
              Text(
                'fluttAIrbar',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3,
                ),
              ),
              if (updated.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text(
                  updated,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
              ],
            ],
          ),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: isDark ? 'Light mode' : 'Dark mode',
          onPressed: onToggleTheme,
          icon: Icon(
            isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
            size: 20,
          ),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: 'Refresh',
          onPressed: loading ? null : onRefresh,
          icon: loading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh, size: 20),
        ),
      ],
    );
  }
}

class _CodexBlock extends StatelessWidget {
  const _CodexBlock({
    required this.usage,
    required this.redeeming,
    required this.onRedeem,
  });

  final CodexUsage? usage;
  final bool redeeming;
  final ValueChanged<ResetCredit> onRedeem;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Codex',
          style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        if (usage == null)
          Text('Loading…', style: theme.textTheme.bodySmall)
        else if (usage!.hasError)
          _ErrorLine(message: usage!.error!)
        else ...[
          Text(
            '${usage!.planType ?? '?'} · ${usage!.email}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
            ),
          ),
          // Show only windows that exist (weekly-only plans skip 5h).
          if (usage!.primary != null)
            UsageMeter(
              label: usage!.primary!.label ?? '5h',
              window: usage!.primary,
              compact: true,
            ),
          if (usage!.secondary != null)
            UsageMeter(
              label: usage!.secondary!.label ?? 'Weekly',
              window: usage!.secondary,
              compact: true,
            ),
          if (usage!.primary == null && usage!.secondary == null)
            Text(
              'No rate windows',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          const SizedBox(height: 6),
          _ResetsRow(
            usage: usage!,
            redeeming: redeeming,
            onRedeem: onRedeem,
          ),
        ],
      ],
    );
  }
}

class _ResetsRow extends StatelessWidget {
  const _ResetsRow({
    required this.usage,
    required this.redeeming,
    required this.onRedeem,
  });

  final CodexUsage usage;
  final bool redeeming;
  final ValueChanged<ResetCredit> onRedeem;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final credits = usage.resetCredits;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
      decoration: BoxDecoration(
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.55),
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Resets · ${usage.availableResetCount} available',
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          if (credits.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'None banked',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                ),
              ),
            )
          else
            for (final c in credits)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${c.title ?? 'Reset'}'
                        '${c.expiresAt != null ? ' · ${_fmt(c.expiresAt!)}' : ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    TextButton(
                      onPressed: redeeming ? null : () => onRedeem(c),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(0, 28),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text('Use'),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }

  String _fmt(DateTime d) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${months[d.month - 1]} ${d.day}';
  }
}

class _CursorBlock extends StatelessWidget {
  const _CursorBlock({required this.usage});
  final CursorUsage? usage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Cursor',
          style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        if (usage == null)
          Text('Loading…', style: theme.textTheme.bodySmall)
        else if (usage!.hasError)
          _ErrorLine(message: usage!.error!)
        else ...[
          if (usage!.planName != null || usage!.email != null)
            Text(
              [
                if (usage!.planName != null) usage!.planName!,
                if (usage!.email != null) usage!.email!,
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
              ),
            ),
          UsageMeter(
            label: 'Plan',
            compact: true,
            window: usage!.usedPercent != null
                ? RateWindow(
                    usedPercent: usage!.usedPercent!,
                    resetAt: usage!.billingCycleEnd,
                    label: 'Plan',
                  )
                : null,
          ),
        ],
      ],
    );
  }
}

class _ErrorLine extends StatelessWidget {
  const _ErrorLine({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      message,
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.error,
      ),
    );
  }
}
