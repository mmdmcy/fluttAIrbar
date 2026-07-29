// Headless smoke test: fetch Codex usage + reset credits via OpenCode auth.
// ignore_for_file: avoid_print

import 'package:fluttairbar/api/chatgpt_wham.dart';
import 'package:fluttairbar/auth/codex_cli_auth.dart';

Future<void> main() async {
  final creds = await CodexAuthResolver.resolve();
  final client = ChatGptWhamClient();
  try {
    final usage = await client.fetchUsage(creds);
    final resets = await client.fetchResetCredits(creds);
    print('email=${usage.email}');
    print('plan=${usage.planType}');
    print('source=${usage.authSource}');
    print('primary=${usage.primary?.usedPercent}% resets ${usage.primary?.resetDescription}');
    print('secondary=${usage.secondary?.usedPercent}');
    print('resetCredits=${resets.availableCount}');
    for (final c in resets.credits) {
      print('  - ${c.title} expires ${c.expiresAt}');
    }
  } finally {
    client.close();
  }
}
