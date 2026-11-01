// fluttAIrbar's command-line tool. Build a standalone binary with:
//   dart compile exe tool/fluttairbar_cli.dart -o fluttairbar-cli
// It imports no Flutter code, so it runs headless.

import 'dart:io';

import 'package:fluttairbar/cli/cli.dart';

Future<void> main(List<String> args) async {
  exitCode = await runCli(args);
}
