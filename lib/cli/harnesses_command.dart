import 'dart:convert';

import '../models/harness.dart';
import '../services/harness_catalog.dart';
import '../services/harness_manager.dart';

/// `fluttairbar-cli harnesses` and `dart run tool/update_harnesses.dart`.
///
/// Read-only unless `--update` or `--sync-codex-daemon` is given. Returns the
/// process exit code: 0 done, 1 an update or sync failed, 64 unknown id.
Future<int> runHarnessesCommand(
  List<String> args, {
  required StringSink out,
  required StringSink err,
  HarnessManager Function(List<HarnessDefinition>? definitions)? managerFor,
}) async {
  final update = args.contains('--update');
  final syncDaemon = args.contains('--sync-codex-daemon');
  final jsonOutput = args.contains('--json');
  final only = _onlyIds(args);
  final knownIds = HarnessCatalog.definitions
      .map((definition) => definition.id)
      .toSet();
  final unknownIds = only.where((id) => !knownIds.contains(id)).toList();
  if (unknownIds.isNotEmpty) {
    err.writeln('Unknown harness id(s): ${unknownIds.join(', ')}');
    err.writeln('Known ids: ${knownIds.join(', ')}');
    return 64;
  }

  final definitions = only.isEmpty
      ? null
      : HarnessCatalog.definitions
            .where((definition) => only.contains(definition.id))
            .toList();
  final manager =
      managerFor?.call(definitions) ?? HarnessManager(definitions: definitions);
  try {
    final statuses = await manager.discover();
    if (syncDaemon && !update) {
      final syncable = statuses.where((status) => status.daemonSyncCandidate);
      final results = <HarnessUpdateResult>[];
      for (final status in syncable) {
        final result = await manager.syncToDaemon(status);
        results.add(result);
        if (jsonOutput) {
          out.writeln(jsonEncode(harnessResultJson(result)));
        } else {
          out.writeln(
            '${status.definition.id}: ${result.outcome.name} · ${result.message}',
          );
        }
      }
      if (!jsonOutput && results.isEmpty) {
        out.writeln(
          'No harness has a background daemon ahead of its installed CLI.',
        );
      }
      return results.any(
            (result) => result.outcome == HarnessUpdateOutcome.failed,
          )
          ? 1
          : 0;
    }
    if (!update) {
      if (jsonOutput) {
        out.writeln(jsonEncode(statuses.map(harnessStatusJson).toList()));
      } else {
        _printStatuses(out, statuses);
        out.writeln(
          '\nCheck only. Add --update after reviewing the list, or '
          '--sync-codex-daemon to sync a CLI that its background daemon has '
          'outrun.',
        );
      }
      return 0;
    }

    final report = await manager.updateAll(statuses);
    if (jsonOutput) {
      out.writeln(jsonEncode(report.results.map(harnessResultJson).toList()));
    } else {
      for (final result in report.results) {
        out.writeln(
          '${result.status.definition.id}: ${result.outcome.name} · ${result.message}',
        );
      }
      out.writeln(
        '\n${report.updatedCount} updated · ${report.skippedCount} skipped · '
        '${report.failedCount} failed',
      );
    }
    return report.failedCount > 0 ? 1 : 0;
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

void _printStatuses(StringSink out, List<HarnessStatus> statuses) {
  for (final status in statuses) {
    final version = status.currentVersion ?? 'not installed';
    final latest = status.release?.latestVersion;
    final release = latest == null ? '' : ' · latest $latest';
    final daemon = status.daemonAhead
        ? ' · daemon ${status.daemonVersion} ahead'
        : '';
    final error = status.checkError == null ? '' : ' · ${status.checkError}';
    out.writeln('${status.definition.id}: $version$release$daemon$error');
  }
}

Map<String, Object?> harnessStatusJson(HarnessStatus status) {
  return {
    'id': status.definition.id,
    'name': status.definition.displayName,
    'installed': status.installed,
    'path': status.executablePath,
    'currentVersion': status.currentVersion,
    'latestVersion': status.release?.latestVersion,
    'daemonVersion': status.daemonVersion,
    'daemonAhead': status.daemonAhead,
    'publishedAt': status.release?.publishedAt?.toUtc().toIso8601String(),
    'updateAvailable': status.updateAvailable,
    'ageGateSatisfied': status.ageGateSatisfied(),
    'updateSource': status.updateSource.name,
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

Map<String, Object?> harnessResultJson(HarnessUpdateResult result) {
  return {
    'id': result.status.definition.id,
    'outcome': result.outcome.name,
    'message': result.message,
    'exitCode': result.exitCode,
  };
}
