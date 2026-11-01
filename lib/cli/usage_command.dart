import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/usage_snapshot.dart';
import '../services/usage_fetcher.dart';
import '../services/usage_preferences.dart';
import 'usage_report.dart';

/// `fluttairbar-cli usage [--json]`.
///
/// Reads Codex, Claude and Cursor usage with the sessions already on this
/// device and the tray app's provider preferences. It never rewrites a
/// credentials file, even when the app is allowed to renew Codex, and never
/// prints tokens, emails or account ids. Exit 0 whenever the report was
/// produced, also when a provider is signed out; 64 for an unknown option.
Future<int> runUsageCommand(
  List<String> args, {
  required StringSink out,
  required StringSink err,
  UsageFetcher? fetcher,
  UsagePreferences? preferences,
}) async {
  final unknown = args.where((arg) => arg != '--json').toList();
  if (unknown.isNotEmpty) {
    err.writeln('Unknown option for usage: ${unknown.join(' ')}');
    err.writeln('Usage: fluttairbar-cli usage [--json]');
    return 64;
  }
  final jsonOutput = args.contains('--json');
  final prefs = preferences ?? UsagePreferences();
  final client = fetcher == null ? http.Client() : null;
  final reader = fetcher ?? UsageFetcher(client: client!);
  try {
    // Claude without a stored choice is read, which reports a missing
    // session as signed-out; only an explicit "off" counts as paused.
    final claudePaused = prefs.loadClaudeEnabled() == false;
    final results = await Future.wait<Object?>([
      reader.codex(includeResetCredits: false),
      claudePaused ? Future.value(null) : reader.claude(),
      prefs.loadCursorEnabled() ? reader.cursor() : Future.value(null),
    ]);
    final report = UsageReport.from(
      codex: results[0] as CodexUsage,
      claude: results[1] as ClaudeUsage?,
      cursor: results[2] as CursorUsage?,
    );
    if (jsonOutput) {
      out.writeln(jsonEncode(report.toJson()));
    } else {
      report.toLines().forEach(out.writeln);
    }
    return 0;
  } finally {
    client?.close();
  }
}
