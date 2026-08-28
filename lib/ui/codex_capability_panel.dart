import 'package:flutter/material.dart';

import '../models/codex_capability.dart';
import '../providers/codex_capability_store.dart';

class CodexCapabilityPanel extends StatelessWidget {
  const CodexCapabilityPanel({super.key, required this.store});

  final CodexCapabilityStore store;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final snapshot = store.snapshot;
    final scanned = snapshot.checkedAt != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Codex capabilities',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            OutlinedButton.icon(
              onPressed: store.loading || store.mutating ? null : store.refresh,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Scan'),
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 9),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Installed packs stay available without being selected for every task. '
          'Only change these controls while Codex is idle. fluttAIrbar edits '
          'config.toml and never restarts or interrupts Codex.',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.62),
          ),
        ),
        const SizedBox(height: 8),
        if (!scanned && store.loading)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else if (!scanned)
          Expanded(
            child: Center(
              child: Text(
                'Press Scan to inspect installed Codex plugins and MCP servers.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
            ),
          )
        else
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.only(bottom: 4),
              itemCount: snapshot.packs.length + 1,
              separatorBuilder: (_, index) =>
                  SizedBox(height: index == snapshot.packs.length - 1 ? 8 : 6),
              itemBuilder: (context, index) {
                if (index == snapshot.packs.length) {
                  return _RestartNotice(store: store);
                }
                return _PackCard(store: store, pack: snapshot.packs[index]);
              },
            ),
          ),
      ],
    );
  }
}

class _PackCard extends StatelessWidget {
  const _PackCard({required this.store, required this.pack});

  final CodexCapabilityStore store;
  final CodexCapabilityPackStatus pack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final toggleable = pack.toggleableComponents;
    final targetEnabled = !pack.fullyEnabled;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 9, 8, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    pack.definition.displayName,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                _PackState(pack: pack),
                const SizedBox(width: 4),
                TextButton(
                  onPressed:
                      toggleable.isEmpty || store.loading || store.mutating
                      ? null
                      : () => _confirmPackToggle(context, targetEnabled),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 7),
                    minimumSize: const Size(0, 28),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(targetEnabled ? 'Enable all' : 'Disable all'),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(pack.definition.description, style: theme.textTheme.bodySmall),
            const SizedBox(height: 4),
            for (final component in pack.components)
              _ComponentTile(store: store, component: component),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmPackToggle(BuildContext context, bool enabled) async {
    final installed = pack.toggleableComponents;
    final confirmed = await _confirm(
      context,
      title:
          '${enabled ? 'Enable' : 'Disable'} ${pack.definition.displayName}?',
      content:
          'This updates ${installed.length} Codex setting${installed.length == 1 ? '' : 's'} in ${store.snapshot.configPath}. Do this only while Codex is idle. fluttAIrbar will not restart it. You must restart Codex manually after the change.',
    );
    if (confirmed != true || !context.mounted) return;
    for (final component in installed) {
      final alreadyRequested = component.pendingEnabled ?? component.enabled;
      if (alreadyRequested == enabled) {
        continue;
      }
      await store.setEnabled(component.definition.id, enabled);
    }
  }
}

class _ComponentTile extends StatelessWidget {
  const _ComponentTile({required this.store, required this.component});

  final CodexCapabilityStore store;
  final CodexCapabilityComponentStatus component;

  @override
  Widget build(BuildContext context) {
    final definition = component.definition;
    final details = <String>[
      if (definition.skillCount > 0) '${definition.skillCount} skills',
      if (definition.categorySummary != null) definition.categorySummary!,
      if (component.version != null) 'v${component.version}',
      component.error ??
          (component.installed
              ? definition.description
              : 'Not installed in Codex'),
      if (component.restartPending) 'Restart required',
    ].join(' · ');
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      visualDensity: VisualDensity.compact,
      title: Text(definition.displayName),
      subtitle: Text(details, maxLines: 2, overflow: TextOverflow.ellipsis),
      secondary: Icon(
        definition.kind == CodexCapabilityComponentKind.mcp
            ? Icons.hub_outlined
            : Icons.extension_outlined,
        size: 19,
      ),
      value: component.pendingEnabled ?? component.enabled,
      onChanged: component.toggleable && !store.loading && !store.mutating
          ? (enabled) => _confirmToggle(context, enabled)
          : null,
    );
  }

  Future<void> _confirmToggle(BuildContext context, bool enabled) async {
    final confirmed = await _confirm(
      context,
      title:
          '${enabled ? 'Enable' : 'Disable'} ${component.definition.displayName}?',
      content:
          'This edits ${store.snapshot.configPath}. Only do it while Codex is idle. fluttAIrbar will not restart or interrupt Codex. Restart Codex manually after saving the change.',
    );
    if (confirmed != true || !context.mounted) return;
    await store.setEnabled(component.definition.id, enabled);
  }
}

class _PackState extends StatelessWidget {
  const _PackState({required this.pack});

  final CodexCapabilityPackStatus pack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = !pack.installed
        ? 'Not installed'
        : !pack.stateKnown
        ? 'State unavailable'
        : pack.mixed
        ? 'Mixed'
        : pack.fullyEnabled
        ? 'Enabled'
        : '${pack.enabledCount}/${pack.installedCount} on';
    final color = !pack.installed
        ? theme.colorScheme.onSurface.withValues(alpha: 0.5)
        : pack.fullyEnabled
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurface.withValues(alpha: 0.65);
    return Text(
      label,
      style: theme.textTheme.labelSmall?.copyWith(
        color: color,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

class _RestartNotice extends StatelessWidget {
  const _RestartNotice({required this.store});

  final CodexCapabilityStore store;

  @override
  Widget build(BuildContext context) {
    if (!store.restartRequired) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.tertiaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.restart_alt, size: 18, color: theme.colorScheme.tertiary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Saved to config.toml. Restart Codex manually when it is idle, then mark this reminder clear.',
              style: theme.textTheme.labelSmall,
            ),
          ),
          TextButton(
            onPressed: store.markRestarted,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              minimumSize: const Size(0, 28),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }
}

Future<bool?> _confirm(
  BuildContext context, {
  required String title,
  required String content,
}) {
  return showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(content),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Save'),
        ),
      ],
    ),
  );
}
