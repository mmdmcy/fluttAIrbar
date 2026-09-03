import 'dart:async';

import 'package:flutter/material.dart';

import '../providers/usage_store.dart';

/// Settings for optional usage providers.
class UsageSettingsPanel extends StatelessWidget {
  const UsageSettingsPanel({super.key, required this.store});

  final UsageStore store;

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
        ],
      ),
    );
  }
}
