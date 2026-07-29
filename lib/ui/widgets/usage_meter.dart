import 'package:flutter/material.dart';

import '../../models/usage_snapshot.dart';

class UsageMeter extends StatelessWidget {
  const UsageMeter({
    super.key,
    required this.label,
    required this.window,
    this.compact = false,
  });

  final String label;
  final RateWindow? window;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final labelWidth = compact ? 56.0 : 72.0;
    if (window == null) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: compact ? 2 : 6),
        child: Row(
          children: [
            SizedBox(
              width: labelWidth,
              child: Text(label, style: theme.textTheme.bodySmall),
            ),
            Text(
              'n/a',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
      );
    }

    final used = window!.usedPercent;
    final left = (100 - used).clamp(0.0, 100.0);
    // Color by how little remains (emptying bar = worse).
    final color = left <= 10
        ? theme.colorScheme.error
        : left <= 30
            ? const Color(0xFFD97706)
            : theme.colorScheme.primary;

    return Padding(
      padding: EdgeInsets.symmetric(vertical: compact ? 3 : 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: labelWidth,
                child: Text(
                  label,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    // Filled = remaining; grey track = already used.
                    value: (left / 100).clamp(0.0, 1.0),
                    minHeight: compact ? 7 : 10,
                    backgroundColor: theme.colorScheme.surfaceContainerHighest,
                    color: color,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: compact ? 64 : 72,
                child: Text(
                  '${left.round()}% left',
                  textAlign: TextAlign.right,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          Padding(
            padding: EdgeInsets.only(left: labelWidth, top: 2),
            child: Text(
              '${used.round()}% used · resets ${window!.resetDescription}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
