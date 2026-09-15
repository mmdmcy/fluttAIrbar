import 'dart:async';

import 'package:flutter/material.dart';

import '../models/codex_shortcut.dart';
import '../providers/codex_shortcut_store.dart';
import '../providers/usage_store.dart';

/// Settings for optional usage providers.
class UsageSettingsPanel extends StatelessWidget {
  const UsageSettingsPanel({
    super.key,
    required this.store,
    required this.codexShortcutStore,
  });

  final UsageStore store;
  final CodexShortcutStore codexShortcutStore;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Settings',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Choose which optional providers fluttAIrbar reads. Changes are '
            'saved locally.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 18),
          Text(
            'Usage providers',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Cursor usage'),
            subtitle: Text(
              store.cursorEnabled
                  ? 'Included in the usage panel and tray.'
                  : 'Paused by default. Credentials stay untouched.',
            ),
            value: store.cursorEnabled,
            onChanged: (enabled) {
              if (!store.setCursorEnabled(enabled)) return;
              if (enabled) {
                unawaited(store.refresh(force: true));
              }
            },
          ),
          const Divider(height: 24),
          Text(
            'Codex authentication',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Uses the existing Codex CLI session from ~/.codex/auth.json. '
            'fluttAIrbar never starts a login flow.',
            style: theme.textTheme.bodySmall,
          ),
          const Divider(height: 28),
          _CodexShortcutSection(store: codexShortcutStore),
        ],
      ),
    );
  }
}

class _CodexShortcutSection extends StatelessWidget {
  const _CodexShortcutSection({required this.store});

  final CodexShortcutStore store;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = store.status;
    final statusColor = _statusColor(theme, status);
    final statusLabel = _statusLabel(status);
    final statusDetail = _statusDetail(status);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Codex terminal shortcuts',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: 'Refresh shortcut status',
              onPressed: store.busy ? null : () => unawaited(store.refresh()),
              icon: const Icon(Icons.refresh, size: 18),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Optional command shims for this machine’s Codex workflow. '
          'Nothing is installed until you choose it.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 10),
        DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: statusColor.withValues(alpha: 0.45)),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 9, 10, 9),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(_statusIcon(status), size: 18, color: statusColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        statusLabel,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: statusColor,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(statusDetail, style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 4),
          title: const Text('Commands'),
          subtitle: Text(status.installDirectory),
          children: [
            for (final definition in codexShortcutDefinitions)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      definition.name,
                      style: theme.textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    SelectableText(
                      definition.commandPreview,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
        if (status.error != null && !status.supported)
          Text(
            status.error!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        if (status.hasConflicts)
          Text(
            'Existing files were not changed. Move them or remove them '
            'manually, then try again.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            if (status.supported && !status.hasConflicts)
              FilledButton.icon(
                onPressed: store.busy ? null : () => _confirmInstall(context),
                icon: Icon(
                  status.allInstalled
                      ? Icons.build_outlined
                      : Icons.download_outlined,
                ),
                label: Text(
                  status.allInstalled ? 'Repair' : 'Install shortcuts',
                ),
              ),
            if (status.allInstalled) ...[
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: store.busy ? null : () => _confirmUninstall(context),
                icon: const Icon(Icons.delete_outline),
                label: const Text('Uninstall'),
              ),
            ],
            if (store.busy) ...[
              const SizedBox(width: 10),
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ],
          ],
        ),
        if (store.statusMessage != null) ...[
          const SizedBox(height: 4),
          Text(
            store.statusMessage!,
            style: theme.textTheme.labelSmall?.copyWith(
              color: status.hasConflicts
                  ? theme.colorScheme.error
                  : theme.colorScheme.primary,
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _confirmInstall(BuildContext context) async {
    final status = store.status;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Install Codex shortcuts?'),
        content: Text(
          'This writes two executable files to ${status.installDirectory}. '
          'If needed, it adds a marked PATH entry to ${status.pathConfigPath}. '
          'It does not run Codex, change Codex settings, or touch credentials.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Install'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await store.install();
  }

  Future<void> _confirmUninstall(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Uninstall Codex shortcuts?'),
        content: const Text(
          'This removes only the shortcut files managed by fluttAIrbar and '
          'its own PATH block. Codex and your credentials are not changed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Uninstall'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await store.uninstall();
  }

  Color _statusColor(ThemeData theme, CodexShortcutStatus status) {
    if (!status.supported || status.hasConflicts) {
      return theme.colorScheme.error;
    }
    if (status.ready) return theme.colorScheme.primary;
    return theme.colorScheme.secondary;
  }

  IconData _statusIcon(CodexShortcutStatus status) {
    if (!status.supported || status.hasConflicts) {
      return Icons.warning_amber_outlined;
    }
    if (status.ready) return Icons.check_circle_outline;
    return Icons.install_desktop_outlined;
  }

  String _statusLabel(CodexShortcutStatus status) {
    if (!status.supported) return 'Not available on this platform';
    if (status.hasConflicts) return 'Needs attention';
    if (!status.allInstalled) return 'Not installed';
    if (status.pathAvailable) return 'Installed · PATH is ready';
    if (status.pathConfigured) return 'Installed · open a new terminal';
    return 'Installed · PATH needs setup';
  }

  String _statusDetail(CodexShortcutStatus status) {
    if (!status.supported) {
      return 'The installer currently supports macOS and Linux.';
    }
    if (status.hasConflicts) {
      final names = status.files
          .where((file) => file.conflict)
          .map((file) => file.definition.name)
          .join(', ');
      return 'A different file already exists for $names.';
    }
    if (!status.allInstalled) {
      final missing = status.files
          .where((file) => !file.installed)
          .map((file) => file.definition.name)
          .join(', ');
      return 'Missing: $missing.';
    }
    if (status.pathAvailable) {
      return 'Commands are available through ${status.installDirectory}.';
    }
    if (status.pathConfigured) {
      return 'PATH is configured in ${status.pathConfigPath}.';
    }
    return 'Install will configure PATH in ${status.pathConfigPath}.';
  }
}
