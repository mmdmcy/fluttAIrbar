/// `fluttairbar-cli quiz`: asks every coding agent on this device a few fixed
/// questions in a fresh session, from an empty folder and with no tools, and
/// checks the answers. It tests what an agent knows before it opens any
/// project: the shared instructions file and what it points to. The
/// questions are the owner's, in quiz.txt next to that file; how to ask each
/// agent is the `ask` line of the agent table.
///
/// quiz.txt: a line starting with "?" is a question, the "=" lines under it
/// are accepted answers (any one, case-insensitive); "#" lines are
/// comments. Every run uses the agents' own subscriptions, so it runs only
/// when asked.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'local.dart';
import 'skill_settings.dart';

const quizSchema = 'fluttairbar.quiz.v1';

/// The answer must come from what the agent already knows.
const quizPrefix =
    'Answer from your instructions only, without running any command or reading any file, in one short line: ';

class QuizQuestion {
  QuizQuestion(this.question);
  final String question;
  final accept = <String>[];
}

class QuizError implements Exception {
  QuizError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Reads quiz.txt. A question whose accepted answer appears in the question
/// itself would pass on an echo, so it is refused.
List<QuizQuestion> parseQuiz(String text) {
  final quiz = <QuizQuestion>[];
  final lines = text.split('\n');
  for (var n = 0; n < lines.length; n++) {
    final line = lines[n].trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    if (line.startsWith('?')) {
      quiz.add(QuizQuestion(line.substring(1).trim()));
    } else if (line.startsWith('=')) {
      if (quiz.isEmpty) {
        throw QuizError('line ${n + 1}: an answer before any question');
      }
      final answer = line.substring(1).trim();
      final question = quiz.last;
      if (question.question.toLowerCase().contains(answer.toLowerCase())) {
        throw QuizError(
          'line ${n + 1}: "$answer" is in its own question, so an echo would pass',
        );
      }
      question.accept.add(answer);
    } else {
      throw QuizError(
        'line ${n + 1}: start with ? (question), = (answer) or # (comment)',
      );
    }
  }
  for (final question in quiz) {
    if (question.question.isEmpty || question.accept.isEmpty) {
      throw QuizError('question "${question.question}" has no accepted answer');
    }
  }
  if (quiz.isEmpty) throw QuizError('no questions');
  return quiz;
}

bool passes(String answer, List<String> accept) {
  final lower = answer.toLowerCase();
  return accept.any((a) => lower.contains(a.toLowerCase()));
}

/// Fills an agent's ask template.
List<String> askArgs(List<String> template, String question, String out) => [
  for (final arg in template)
    arg
        .replaceAll('{question}', '$quizPrefix$question')
        .replaceAll('{out}', out),
];

/// The quiz file beside the shared instructions.
String quizFile(Local local, String instructions) {
  final path = local.expand(instructions);
  return '${File(path).parent.path}/quiz.txt';
}

/// Asks the agents here that have an ask line and a command on PATH; [only]
/// limits it to one agent.
Future<Map<String, Object?>> runQuiz({
  required Local local,
  required SkillSettings settings,
  String? only,
  Future<Map<String, Object?>> Function(AgentDef agent, QuizQuestion question)?
  ask,
}) async {
  if (settings.instructions.isEmpty) {
    throw QuizError(
      'no shared instructions file: add instructions = "~/PATH/AGENTS.md" to the skills settings (fluttairbar-cli skills settings says where they are)',
    );
  }
  final file = quizFile(local, settings.instructions);
  final text = File(file).existsSync() ? File(file).readAsStringSync() : null;
  if (text == null) {
    throw QuizError(
      'no questions: write $file (? question, = accepted answer)',
    );
  }
  final List<QuizQuestion> quiz;
  try {
    quiz = parseQuiz(text);
  } on QuizError catch (error) {
    throw QuizError('$file: ${error.message}');
  }
  final results = <Map<String, Object?>>[];
  for (final agent in settings.agentTable()) {
    if (agent.ask.isEmpty || (only != null && agent.id != only)) continue;
    if (!Directory(local.expand(agent.dir)).parent.existsSync()) continue;
    if (ask == null && !await _onPath(agent.ask.first)) continue;
    for (final question in quiz) {
      results.add(await (ask ?? askOne)(agent, question));
    }
  }
  if (results.isEmpty) {
    throw QuizError('no agent here can be asked (the agent table\'s ask line)');
  }
  return {
    'schema_version': quizSchema,
    'questions': file,
    'results': results,
    'failed': results.where((result) => result['passed'] != true).length,
  };
}

Future<bool> _onPath(String command) async {
  try {
    final result = await Process.run('sh', [
      '-c',
      'command -v ${shellQuote(command)}',
    ]);
    return result.exitCode == 0;
  } on ProcessException {
    return false;
  }
}

/// Asks one agent one question from an empty folder, so no project's
/// instructions are read; nothing is read from its standard input.
Future<Map<String, Object?>> askOne(AgentDef agent, QuizQuestion q) async {
  final result = <String, Object?>{
    'agent': agent.id,
    'question': q.question,
    'passed': false,
    'answer': '',
  };
  final dir = Directory.systemTemp.createTempSync('fluttairbar-quiz-');
  try {
    final out = '${dir.path}/answer.txt';
    final args = askArgs(agent.ask, q.question, out);
    String answer;
    String? error;
    try {
      final process = await Process.start(
        args.first,
        args.sublist(1),
        workingDirectory: dir.path,
      );
      await process.stdin.close();
      final stdoutText = process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();
      final stderrDone = process.stderr.drain<void>();
      final code = await process.exitCode.timeout(
        const Duration(minutes: 4),
        onTimeout: () {
          process.kill();
          return 124;
        },
      );
      answer = await stdoutText;
      await stderrDone;
      if (code != 0) error = 'exit status $code';
    } on ProcessException catch (e) {
      answer = '';
      error = e.message;
    }
    if (agent.ask.contains('{out}') && File(out).existsSync()) {
      answer = File(out).readAsStringSync();
    }
    result['answer'] = answer.trim();
    if (error != null && answer.trim().isEmpty) result['error'] = error;
    result['passed'] = passes(answer.trim(), q.accept);
  } finally {
    dir.deleteSync(recursive: true);
  }
  return result;
}

String _firstLine(String text) {
  var line = text.trim();
  final newline = line.indexOf('\n');
  if (newline >= 0) line = line.substring(0, newline);
  return line.length > 160 ? '${line.substring(0, 160)}…' : line;
}

String textQuiz(Map<String, Object?> report) {
  final results = (report['results'] as List).cast<Map<String, Object?>>();
  final lines = [
    for (final r in results)
      '${(r['passed'] == true ? 'pass' : 'FAIL').padRight(4)} ${'${r['agent']}'.padRight(8)} ${r['question']}\n      ${_firstLine('${r['answer']}${r['error'] ?? ''}')}',
    '${results.length - (report['failed'] as int)} of ${results.length} answered as expected (${report['questions']})',
  ];
  return lines.join('\n');
}
