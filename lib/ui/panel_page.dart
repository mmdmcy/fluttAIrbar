import 'package:flutter/material.dart';

import '../models/usage_snapshot.dart';
import '../providers/codex_capability_store.dart';
import '../providers/harness_store.dart';
import '../providers/theme_store.dart';
import '../providers/usage_store.dart';
import 'codex_capability_panel.dart';
import 'harness_panel.dart';
import 'widgets/usage_meter.dart';

enum _PanelView { usage, harnesses, capabilities }

class PanelPage extends StatefulWidget {
  const PanelPage({
    super.key,
    required this.store,
    required this.themeStore,
    required this.harnessStore,
    required this.codexCapabilityStore,
  });

  final UsageStore store;
  final ThemeStore themeStore;
  final HarnessStore harnessStore;
  final CodexCapabilityStore codexCapabilityStore;

  @override
  State<PanelPage> createState() => _PanelPageState();
}

class _PanelPageState extends State<PanelPage> {
  _PanelView _view = _PanelView.usage;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        widget.store,
        widget.themeStore,
        widget.harnessStore,
        widget.codexCapabilityStore,
      ]),
      builder: (context, _) {
        final snap = widget.store.snapshot;
        final theme = Theme.of(context);
        final showingHarnesses = _view == _PanelView.harnesses;
        final showingCapabilities = _view == _PanelView.capabilities;
        final refreshing = showingHarnesses
            ? widget.harnessStore.loading
            : showingCapabilities
            ? widget.codexCapabilityStore.loading
            : widget.store.loading;
        final refreshDisabled = showingHarnesses
            ? widget.harnessStore.loading || widget.harnessStore.updating
            : showingCapabilities
            ? widget.codexCapabilityStore.loading ||
                  widget.codexCapabilityStore.mutating
            : widget.store.loading || widget.store.redeeming;
        final refreshedAt = showingHarnesses
            ? widget.harnessStore.checkedAt
            : showingCapabilities
            ? widget.codexCapabilityStore.checkedAt
            : snap.refreshedAt;
        final statusMessage = showingHarnesses
            ? widget.harnessStore.statusMessage
            : showingCapabilities
            ? widget.codexCapabilityStore.statusMessage
            : widget.store.statusMessage;
        return Scaffold(
          backgroundColor: theme.colorScheme.surface,
          body: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Header(
                  refreshing: refreshing,
                  refreshDisabled: refreshDisabled,
                  refreshedAt: refreshedAt,
                  isDark: widget.themeStore.isDark,
                  view: _view,
                  onRefresh: showingHarnesses
                      ? widget.harnessStore.refresh
                      : showingCapabilities
                      ? widget.codexCapabilityStore.refresh
                      : widget.store.refresh,
                  onToggleTheme: widget.themeStore.toggle,
                  onViewChanged: _setView,
                ),
                if (statusMessage != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    statusMessage,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                if (showingHarnesses)
                  Expanded(child: HarnessPanel(store: widget.harnessStore))
                else if (showingCapabilities)
                  Expanded(
                    child: CodexCapabilityPanel(
                      store: widget.codexCapabilityStore,
                    ),
                  )
                else ...[
                  _CodexBlock(
                    usage: snap.codex,
                    loading: widget.store.loading,
                    redeeming: widget.store.redeeming,
                    onRedeem: (credit) => _confirmRedeem(context, credit),
                  ),
                  const SizedBox(height: 10),
                  _CursorBlock(
                    usage: snap.cursor,
                    loading: widget.store.loading,
                  ),
                  const Spacer(),
                  Text(
                    'Local auth only · resets need double confirm',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  void _setView(_PanelView view) {
    if (_view == view) return;
    setState(() => _view = view);
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

    final result = await widget.store.redeemResetCredit(credit.id);
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

String _viewLabel(_PanelView view) {
  return switch (view) {
    _PanelView.usage => 'Usage',
    _PanelView.harnesses => 'Harnesses',
    _PanelView.capabilities => 'Capabilities',
  };
}

IconData _viewIcon(_PanelView view) {
  return switch (view) {
    _PanelView.usage => Icons.data_usage_outlined,
    _PanelView.harnesses => Icons.developer_mode_outlined,
    _PanelView.capabilities => Icons.extension_outlined,
  };
}

class _Header extends StatelessWidget {
  const _Header({
    required this.refreshing,
    required this.refreshDisabled,
    required this.refreshedAt,
    required this.isDark,
    required this.view,
    required this.onRefresh,
    required this.onToggleTheme,
    required this.onViewChanged,
  });

  final bool refreshing;
  final bool refreshDisabled;
  final DateTime? refreshedAt;
  final bool isDark;
  final _PanelView view;
  final VoidCallback onRefresh;
  final VoidCallback onToggleTheme;
  final ValueChanged<_PanelView> onViewChanged;

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
        PopupMenuButton<_PanelView>(
          tooltip: 'Switch view',
          onSelected: onViewChanged,
          itemBuilder: (context) => [
            for (final option in _PanelView.values)
              PopupMenuItem<_PanelView>(
                value: option,
                child: Row(
                  children: [
                    Icon(_viewIcon(option), size: 18),
                    const SizedBox(width: 8),
                    Text(_viewLabel(option)),
                    if (option == view) ...[
                      const Spacer(),
                      const Icon(Icons.check, size: 17),
                    ],
                  ],
                ),
              ),
          ],
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: theme.colorScheme.secondaryContainer,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(_viewIcon(view), size: 17),
                  const SizedBox(width: 6),
                  Text(_viewLabel(view)),
                  const SizedBox(width: 2),
                  const Icon(Icons.expand_more, size: 16),
                ],
              ),
            ),
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
          tooltip: view == _PanelView.harnesses
              ? 'Refresh harness checks'
              : view == _PanelView.capabilities
              ? 'Scan Codex capabilities'
              : 'Refresh usage',
          onPressed: refreshDisabled ? null : onRefresh,
          icon: refreshing
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
    required this.loading,
    required this.redeeming,
    required this.onRedeem,
  });

  final CodexUsage? usage;
  final bool loading;
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
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        if (usage == null)
          Text(
            loading ? 'Loading…' : 'Press Refresh to load',
            style: theme.textTheme.bodySmall,
          )
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
          _ResetsRow(usage: usage!, redeeming: redeeming, onRedeem: onRedeem),
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
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[d.month - 1]} ${d.day}';
  }
}

class _CursorBlock extends StatelessWidget {
  const _CursorBlock({required this.usage, required this.loading});
  final CursorUsage? usage;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Cursor',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        if (usage == null)
          Text(
            loading ? 'Loading…' : 'Press Refresh to load',
            style: theme.textTheme.bodySmall,
          )
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
