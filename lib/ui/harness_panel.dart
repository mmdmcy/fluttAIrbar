import 'package:flutter/material.dart';

import '../models/harness.dart';
import '../providers/harness_store.dart';

class HarnessPanel extends StatelessWidget {
  const HarnessPanel({super.key, required this.store});

  final HarnessStore store;

  @override
  Widget build(BuildContext context) {
    final installedCount = store.allStatuses
        .where((status) => status.installed)
        .length;
    final updateCount = store.statuses.where(_hasUpdateAction).length;
    final disabledCount = store.disabledCount;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'AI harnesses',
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            IconButton(
              onPressed: store.loading || store.updating
                  ? null
                  : () => _showSettings(context),
              tooltip: 'Manage harness scans',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.tune, size: 19),
            ),
            FilledButton.icon(
              onPressed: store.loading || store.updating || updateCount == 0
                  ? null
                  : () => _confirmUpdateAll(context),
              icon: store.updating
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.system_update_alt, size: 17),
              label: Text(
                store.updating
                    ? store.updateCompleted >= store.updateTotal
                          ? 'Finishing…'
                          : 'Updating ${store.updateCompleted + 1}/'
                                '${store.updateTotal}'
                    : updateCount > 0
                    ? 'Update $updateCount'
                    : 'Update all',
              ),
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '$installedCount installed · $updateCount ready to update'
          '${disabledCount == 0 ? '' : ' · $disabledCount paused'}',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.55),
          ),
        ),
        if (store.updating) ...[
          const SizedBox(height: 2),
          Text(
            _progressText(),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ],
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.all(9),
          decoration: BoxDecoration(
            color: Theme.of(
              context,
            ).colorScheme.primaryContainer.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            'Refresh is manual; opening Harnesses does not scan. Tap a harness '
            'to inspect its config files. '
            'Update one card or use Update all. Early releases require explicit '
            'confirmation; config previews never show credentials.',
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ),
        const SizedBox(height: 8),
        if (store.loading && store.statuses.isEmpty)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else if (store.statuses.isEmpty)
          Expanded(
            child: Center(
              child: Text(
                store.disabledCount == store.definitions.length
                    ? 'All harness scans are paused. Use the tune button to '
                          'enable one.'
                    : 'Press Refresh to scan installed harnesses.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          )
        else
          Expanded(
            child: _HarnessStatusList(statuses: store.statuses, store: store),
          ),
      ],
    );
  }

  Future<void> _showSettings(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (_) => _HarnessSettingsDialog(store: store),
    );
  }

  bool _hasUpdateAction(HarnessStatus status) {
    return status.updateCandidate;
  }

  String _progressText() {
    if (store.updateCompleted >= store.updateTotal) {
      return 'Finishing and refreshing results…';
    }
    final current = store.updateCompleted + 1;
    final total = store.updateTotal;
    final active = store.activeUpdateName;
    if (active == null) {
      return 'Preparing update $current of $total…';
    }
    return 'Updating $current of $total · $active…';
  }

  Future<void> _confirmUpdateAll(BuildContext context) async {
    final candidates = store.statuses.where(_hasUpdateAction).toList();
    if (candidates.isEmpty) {
      return;
    }
    final earlyCount = candidates.where(_isEarlyUpdate).length;
    final earlyNotice = earlyCount == 0
        ? ''
        : ' $earlyCount release${earlyCount == 1 ? '' : 's'} younger than '
              '14 days will be installed because you confirmed this action.';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Update AI harnesses?'),
        content: Text(
          'This checks and updates the ${candidates.length} harnesses with '
          'verified newer releases using their built-in commands. npm and GitHub releases '
          'still require verified metadata.$earlyNotice No other packages are '
          'changed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Update'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await store.updateAll(allowEarlyRelease: true);
  }

  bool _isEarlyUpdate(HarnessStatus status) {
    return _hasUpdateAction(status) &&
        status.definition.requiresReleaseAge &&
        !status.ageGateSatisfied();
  }
}

class _HarnessStatusList extends StatelessWidget {
  const _HarnessStatusList({required this.statuses, required this.store});

  final List<HarnessStatus> statuses;
  final HarnessStore store;

  @override
  Widget build(BuildContext context) {
    final updates = statuses.where(_hasUpdateAction).toList();
    final updateIds = updates.map((status) => status.definition.id).toSet();
    final attention = statuses
        .where(
          (status) =>
              !updateIds.contains(status.definition.id) &&
              (status.updateAvailable ||
                  status.checkError != null ||
                  (status.installed && !status.definition.supportsUpdate)),
        )
        .toList();
    final attentionIds = attention
        .map((status) => status.definition.id)
        .toSet();
    final current = statuses
        .where(
          (status) =>
              !updateIds.contains(status.definition.id) &&
              !attentionIds.contains(status.definition.id) &&
              status.installed &&
              status.release != null &&
              !status.updateAvailable &&
              status.checkError == null,
        )
        .toList();
    final currentIds = current.map((status) => status.definition.id).toSet();
    final other = statuses
        .where(
          (status) =>
              !updateIds.contains(status.definition.id) &&
              !attentionIds.contains(status.definition.id) &&
              !currentIds.contains(status.definition.id),
        )
        .toList();

    final sections = [
      (title: 'Updates available', statuses: updates, emphasized: true),
      (title: 'Manual / attention', statuses: attention, emphasized: false),
      (title: 'Up to date', statuses: current, emphasized: false),
      (
        title: 'Not installed / not verified',
        statuses: other,
        emphasized: false,
      ),
    ];
    final children = <Widget>[];
    var sectionIndex = 0;
    for (final section in sections) {
      if (section.statuses.isEmpty) continue;
      children.add(
        _HarnessSectionHeader(
          title: section.title,
          count: section.statuses.length,
          emphasized: section.emphasized,
          first: sectionIndex == 0,
        ),
      );
      sectionIndex++;
      for (final status in section.statuses) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: _HarnessCard(status: status, store: store),
          ),
        );
      }
    }
    return ListView(children: children);
  }

  bool _hasUpdateAction(HarnessStatus status) => status.updateCandidate;
}

class _HarnessSectionHeader extends StatelessWidget {
  const _HarnessSectionHeader({
    required this.title,
    required this.count,
    required this.emphasized,
    required this.first,
  });

  final String title;
  final int count;
  final bool emphasized;
  final bool first;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = emphasized
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurface.withValues(alpha: 0.55);
    return Padding(
      padding: EdgeInsets.only(top: first ? 0 : 8, bottom: 5),
      child: Row(
        children: [
          Expanded(child: Divider(color: color.withValues(alpha: 0.35))),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 7),
            child: Text(
              '$title · $count',
              style: theme.textTheme.labelSmall?.copyWith(
                color: color,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(child: Divider(color: color.withValues(alpha: 0.35))),
        ],
      ),
    );
  }
}

class _HarnessSettingsDialog extends StatelessWidget {
  const _HarnessSettingsDialog({required this.store});

  final HarnessStore store;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Harness refresh settings'),
      content: SizedBox(
        width: double.maxFinite,
        child: AnimatedBuilder(
          animation: store,
          builder: (context, _) {
            final definitions = List<HarnessDefinition>.of(store.definitions)
              ..sort(
                (left, right) => left.displayName.compareTo(right.displayName),
              );
            final statusById = {
              for (final status in store.allStatuses)
                status.definition.id: status,
            };
            final busy = store.loading || store.updating;
            return ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 330),
              child: ListView(
                shrinkWrap: true,
                children: [
                  Text(
                    'Unchecked harnesses are skipped by manual Refresh and '
                    'Update all. Re-enable one, then press Refresh to check it.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  for (final definition in definitions)
                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: !store.isDisabled(definition.id),
                      onChanged: busy
                          ? null
                          : (enabled) {
                              if (enabled != null) {
                                store.setDisabled(definition.id, !enabled);
                              }
                            },
                      title: Text(definition.displayName),
                      subtitle: Text(
                        _details(
                          definition,
                          statusById[definition.id],
                          store.isDisabled(definition.id),
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }

  String _details(
    HarnessDefinition definition,
    HarnessStatus? status,
    bool disabled,
  ) {
    final state = status == null
        ? 'Not checked yet'
        : status.installed
        ? status.currentVersion ?? 'Installed · version unknown'
        : 'Not installed';
    if (disabled) return 'Paused · $state';
    if (!definition.supportsUpdate) return '$state · manual updates';
    return state;
  }
}

class _HarnessCard extends StatelessWidget {
  const _HarnessCard({required this.status, required this.store});

  final HarnessStatus status;
  final HarnessStore store;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final phase = store.updatePhaseFor(status);
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        key: ValueKey(status.definition.id),
        tilePadding: const EdgeInsets.symmetric(horizontal: 10),
        childrenPadding: const EdgeInsets.only(bottom: 4),
        leading: _PhaseIcon(
          status: status,
          phase: phase,
          color: _statusColor(theme, phase),
        ),
        title: Text(
          status.definition.displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          _statusText(phase),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: _statusColor(theme, phase)),
        ),
        trailing: _UpdateButton(status: status, store: store),
        children: [
          if (status.definition.description != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  status.definition.description!,
                  style: theme.textTheme.labelSmall,
                ),
              ),
            ),
          if (status.checkError != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  status.checkError!,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            ),
          for (final config in status.configs)
            _ConfigRow(config: config, store: store),
        ],
      ),
    );
  }

  String _statusText(HarnessUpdatePhase phase) {
    final operationMessage = store.updateMessageFor(status);
    switch (phase) {
      case HarnessUpdatePhase.queued:
        return 'Queued · waiting for earlier updates';
      case HarnessUpdatePhase.updating:
        return 'Updating…';
      case HarnessUpdatePhase.updated:
        return 'Updated successfully';
      case HarnessUpdatePhase.upToDate:
        return 'Already up to date';
      case HarnessUpdatePhase.skipped:
        return operationMessage ?? 'Skipped';
      case HarnessUpdatePhase.failed:
        return operationMessage ?? 'Update failed';
      case HarnessUpdatePhase.idle:
        break;
    }
    if (!status.installed) return 'Not installed';
    final current = status.currentVersion ?? 'version unknown';
    if (!status.definition.supportsUpdate) return '$current · update manually';
    final release = status.release;
    if (status.updateAvailable && release != null) {
      if (status.definition.requiresReleaseAge && !status.ageGateSatisfied()) {
        return '$current → ${release.latestVersion} available · early release '
            '(${release.ageLabel})';
      }
      return '$current → ${release.latestVersion} available';
    }
    if (release != null) return '$current · current';
    return '$current · official update channel';
  }

  Color _statusColor(ThemeData theme, HarnessUpdatePhase phase) {
    switch (phase) {
      case HarnessUpdatePhase.queued:
      case HarnessUpdatePhase.updating:
        return theme.colorScheme.primary;
      case HarnessUpdatePhase.updated:
      case HarnessUpdatePhase.upToDate:
        return theme.colorScheme.tertiary;
      case HarnessUpdatePhase.skipped:
        return const Color(0xFFD97706);
      case HarnessUpdatePhase.failed:
        return theme.colorScheme.error;
      case HarnessUpdatePhase.idle:
        break;
    }
    if (!status.installed) {
      return theme.colorScheme.onSurface.withValues(alpha: 0.5);
    }
    if (status.updateAvailable &&
        status.definition.requiresReleaseAge &&
        !status.ageGateSatisfied()) {
      return const Color(0xFFD97706);
    }
    return theme.colorScheme.onSurface.withValues(alpha: 0.62);
  }
}

class _PhaseIcon extends StatelessWidget {
  const _PhaseIcon({
    required this.status,
    required this.phase,
    required this.color,
  });

  final HarnessStatus status;
  final HarnessUpdatePhase phase;
  final Color color;

  @override
  Widget build(BuildContext context) {
    switch (phase) {
      case HarnessUpdatePhase.updating:
        return SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2, color: color),
        );
      case HarnessUpdatePhase.queued:
        return Icon(Icons.schedule_outlined, color: color);
      case HarnessUpdatePhase.updated:
      case HarnessUpdatePhase.upToDate:
        return Icon(Icons.check_circle_outline, color: color);
      case HarnessUpdatePhase.skipped:
        return Icon(Icons.remove_circle_outline, color: color);
      case HarnessUpdatePhase.failed:
        return Icon(Icons.error_outline, color: color);
      case HarnessUpdatePhase.idle:
        return Icon(
          status.installed
              ? Icons.check_circle_outline
              : Icons.radio_button_unchecked,
          color: color,
        );
    }
  }
}

class _UpdateButton extends StatelessWidget {
  const _UpdateButton({required this.status, required this.store});

  final HarnessStatus status;
  final HarnessStore store;

  @override
  Widget build(BuildContext context) {
    if (!status.installed) return const SizedBox.shrink();
    final phase = store.updatePhaseFor(status);
    var retry = false;
    switch (phase) {
      case HarnessUpdatePhase.queued:
        return const _OperationLabel(label: 'Queued');
      case HarnessUpdatePhase.updating:
        return const _OperationLabel(label: 'Updating', loading: true);
      case HarnessUpdatePhase.updated:
        return const _OperationLabel(label: 'Updated');
      case HarnessUpdatePhase.upToDate:
        return const _OperationLabel(label: 'Current');
      case HarnessUpdatePhase.skipped:
        return const _OperationLabel(label: 'Skipped');
      case HarnessUpdatePhase.failed:
        if (!status.updateCandidate || store.loading || store.updating) {
          return const _OperationLabel(label: 'Failed');
        }
        retry = true;
      case HarnessUpdatePhase.idle:
        break;
    }
    if (!status.definition.supportsUpdate) {
      return const Padding(
        padding: EdgeInsets.only(right: 10),
        child: Text('Manual'),
      );
    }
    if (!status.updateCandidate) return const SizedBox.shrink();
    final blocked =
        status.definition.requiresReleaseAge &&
        status.updateAvailable &&
        !status.ageGateSatisfied();
    final releaseVerified =
        !status.definition.requiresReleaseAge ||
        status.release?.publishedAt != null;
    final checkFailed = status.checkError != null;
    final canUpdate =
        status.updateCandidate &&
        releaseVerified &&
        !checkFailed &&
        !store.loading &&
        !store.updating;
    return TextButton(
      onPressed: canUpdate ? () => _update(context, blocked) : null,
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 7),
        minimumSize: const Size(0, 30),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(
        retry
            ? 'Retry'
            : blocked
            ? 'Update now'
            : 'Update',
      ),
    );
  }

  Future<void> _update(BuildContext context, bool allowEarlyRelease) async {
    if (allowEarlyRelease) {
      final release = status.release!;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('Update ${status.definition.displayName} now?'),
          content: Text(
            'The newer ${release.latestVersion} release is ${release.ageLabel} '
            'and has not reached the normal 14-day safety window. Install it '
            'now anyway?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Update now'),
            ),
          ],
        ),
      );
      if (confirmed != true || !context.mounted) return;
    }
    await store.updateOne(status, allowEarlyRelease: allowEarlyRelease);
  }
}

class _OperationLabel extends StatelessWidget {
  const _OperationLabel({required this.label, this.loading = false});

  final String label;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: 0.6);
    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (loading) ...[
            SizedBox(
              width: 13,
              height: 13,
              child: CircularProgressIndicator(strokeWidth: 2, color: color),
            ),
            const SizedBox(width: 5),
          ],
          Text(label, style: TextStyle(color: color)),
        ],
      ),
    );
  }
}

class _ConfigRow extends StatelessWidget {
  const _ConfigRow({required this.config, required this.store});

  final HarnessConfigFile config;
  final HarnessStore store;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 8, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              config.exists ? Icons.description_outlined : Icons.remove,
              size: 16,
              color: config.exists
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurface.withValues(alpha: 0.35),
            ),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${config.label} · ${config.exists ? 'found' : 'not found'}',
                  style: theme.textTheme.labelMedium,
                ),
                Text(
                  config.path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.48),
                  ),
                ),
                if (config.summary != null)
                  Text(
                    config.summary!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.62,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (config.exists)
            IconButton(
              tooltip: config.sensitive
                  ? 'Open credential file'
                  : 'Open config',
              visualDensity: VisualDensity.compact,
              onPressed: () => store.openConfig(config),
              icon: const Icon(Icons.open_in_new, size: 17),
            ),
        ],
      ),
    );
  }
}
