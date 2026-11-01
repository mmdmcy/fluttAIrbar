// Same as `fluttairbar-cli harnesses`; kept for existing scripts and docs.
//   dart run tool/update_harnesses.dart [--json] [--only a,b] [--update]
//                                       [--sync-codex-daemon]

import 'dart:io';

import 'package:fluttairbar/cli/harnesses_command.dart';

Future<void> main(List<String> args) async {
  exitCode = await runHarnessesCommand(args, out: stdout, err: stderr);
}
