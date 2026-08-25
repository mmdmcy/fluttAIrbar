import 'dart:convert';
import 'dart:io';

import 'package:fluttairbar/models/harness.dart';
import 'package:fluttairbar/services/harness_catalog.dart';
import 'package:fluttairbar/services/harness_manager.dart';

Future<void> main(List<String> args) async {
  final update = args.contains('--update');
  final jsonOutput = args.contains('--json');
  final only = _onlyIds(args);
  final knownIds = HarnessCatalog.definitions
      .map((definition) => definition.id)
      .toSet();
  final unknownIds = only.where((id) => !knownIds.contains(id)).toList();
  if (unknownIds.isNotEmpty) {
    stderr.writeln('Unknown harness id(s): ${unknownIds.join(', ')}');
    stderr.writeln('Known ids: ${knownIds.join(', ')}');
    exitCode = 64;
    return;
  }

  final definitions = only.isEmpty
      ? null
      : HarnessCatalog.definitions
            .where((definition) => only.contains(definition.id))
            .toList();
  final manager = HarnessManager(definitions: definitions);
  try {
    final statuses = await manager.discover();
    if (!update) {
      if (jsonOutput) {
        stdout.writeln(jsonEncode(statuses.map(_statusJson).toList()));
      } else {
        _printStatuses(statuses);
        stdout.writeln('\nCheck only. Add --update after reviewing the list.');
      }
      return;
    }

    final report = await manager.updateAll(statuses);
    if (jsonOutput) {
      stdout.writeln(jsonEncode(report.results.map(_resultJson).toList()));
    } else {
      for (final result in report.results) {
        stdout.writeln(
          '${result.status.definition.id}: ${result.outcome.name} · ${result.message}',
        );
      }
      stdout.writeln(
        '\n${report.updatedCount} updated · ${report.skippedCount} skipped · '
        '${report.failedCount} failed',
      );
    }
    if (report.failedCount > 0) exitCode = 1;
  } finally {
    manager.dispose();
  }
}

List<String> _onlyIds(List<String> args) {
  for (var index = 0; index < args.length; index++) {
    final argument = args[index];
    if (argument.startsWith('--only=')) {
      return argument
          .substring('--only='.length)
          .split(',')
          .map((id) => id.trim())
          .where((id) => id.isNotEmpty)
          .toList();
    }
    if (argument == '--only' && index + 1 < args.length) {
      return args[index + 1]
          .split(',')
          .map((id) => id.trim())
          .where((id) => id.isNotEmpty)
          .toList();
    }
  }
  return const [];
}

void _printStatuses(List<HarnessStatus> statuses) {
  for (final status in statuses) {
    final version = status.currentVersion ?? 'not installed';
    final latest = status.release?.latestVersion;
    final release = latest == null ? '' : ' · latest $latest';
    final error = status.checkError == null ? '' : ' · ${status.checkError}';
    stdout.writeln('${status.definition.id}: $version$release$error');
  }
}

Map<String, Object?> _statusJson(HarnessStatus status) {
  return {
    'id': status.definition.id,
    'name': status.definition.displayName,
    'installed': status.installed,
    'path': status.executablePath,
    'currentVersion': status.currentVersion,
    'latestVersion': status.release?.latestVersion,
    'publishedAt': status.release?.publishedAt?.toUtc().toIso8601String(),
    'updateAvailable': status.updateAvailable,
    'ageGateSatisfied': status.ageGateSatisfied(),
    'checkError': status.checkError,
    'configs': status.configs
        .map(
          (config) => {
            'label': config.label,
            'path': config.path,
            'exists': config.exists,
            'sensitive': config.sensitive,
            'summary': config.summary,
          },
        )
        .toList(),
  };
}

Map<String, Object?> _resultJson(HarnessUpdateResult result) {
  return {
    'id': result.status.definition.id,
    'outcome': result.outcome.name,
    'message': result.message,
    'exitCode': result.exitCode,
  };
}
