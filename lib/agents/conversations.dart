/// `fluttairbar-cli conversations`: Claude Code and Codex conversation
/// history, kept on two devices. History is kept, always: nothing here
/// deletes, prunes or leaves out a session, and a copy never touches its
/// source.
///
/// `pack` makes a slim copy of this device's history in
/// `~/Backups/conversations/DEVICE/`: every session's text is kept, the
/// screenshots inside it are left out (a note says how big each was), and
/// each file is gzip-compressed, about a fifth of the original. It only
/// handles files that changed since the last pack and never deletes a copy,
/// so a session removed on the device stays here.
///
/// `copy` packs both devices of each pair in the settings and copies each
/// side's slim folder to the other with rsync over SSH, without `--delete`:
///
/// ```toml
/// [[pair]]
/// devices = ["laptop", "desktop"]
///
/// # A folder copied (compressed, as it is) with that device's history.
/// [[extra]]
/// device = "desktop"
/// path = "/srv/backups/old-sessions"
///
/// # Upload cap per copy in KB/s (0 = none).
/// bwlimit_kbps = 1000
/// ```
///
/// What is read: Claude's `~/.claude/projects` and `history.jsonl`; Codex's
/// `~/.codex/sessions`, `archived_sessions`, `history.jsonl` and
/// `session_index.jsonl`. Never sign-ins, caches or packages.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'local.dart';
import 'skill_settings.dart' show SettingsStore;
import 'toml_lite.dart';

const conversationsSchema = 'fluttairbar.conversations.v1';
const backupRoot = 'Backups/conversations';
const _manifestName = '.manifest.json';
const _longTimeout = Duration(hours: 4);

/// History folders and files, relative to the home folder, and where their
/// copies go inside the device's slim folder.
const historySources = [
  ('.claude/projects', 'claude/projects'),
  ('.claude/history.jsonl', 'claude/history.jsonl'),
  ('.codex/sessions', 'codex/sessions'),
  ('.codex/archived_sessions', 'codex/archived_sessions'),
  ('.codex/history.jsonl', 'codex/history.jsonl'),
  ('.codex/session_index.jsonl', 'codex/session_index.jsonl'),
];

class ConversationsError implements Exception {
  ConversationsError(this.message);
  final String message;
  @override
  String toString() => message;
}

class ConversationSettings {
  ConversationSettings({
    this.pairs = const [],
    this.extras = const [],
    this.bwlimitKbps,
  });

  final List<(String, String)> pairs;
  final List<(String device, String path)> extras;
  final int? bwlimitKbps;

  factory ConversationSettings.parse(String text) {
    final toml = parseToml(text);
    final pairs = <(String, String)>[];
    for (final pair in _tables(toml['pair'], 'pair')) {
      final devices = tomlStrings(pair['devices'], 'pair devices');
      if (devices.length != 2 || devices[0] == devices[1]) {
        throw TomlError('a [[pair]] names two different devices');
      }
      pairs.add((devices[0], devices[1]));
    }
    final extras = [
      for (final extra in _tables(toml['extra'], 'extra'))
        (
          tomlText(extra['device'], 'extra device'),
          tomlText(extra['path'], 'extra path'),
        ),
    ];
    final limit = toml['bwlimit_kbps'];
    if (limit != null && (limit is! int || limit < 0)) {
      throw TomlError('bwlimit_kbps should be a number of KB/s (0 = none)');
    }
    return ConversationSettings(
      pairs: pairs,
      extras: extras,
      bwlimitKbps: limit as int?,
    );
  }
}

List<Map<String, Object?>> _tables(Object? value, String name) {
  if (value == null) return const [];
  if (value is List<Map<String, Object?>>) return value;
  throw TomlError('$name should be [[$name]] tables');
}

/// The state kept between copies: the last run of each direction.
class CopyState {
  CopyState(this.local);
  final Local local;

  String get ownPath => '${local.stateHome}/fluttairbar/conversations.json';

  List<Map<String, Object?>> read() {
    for (final path in [ownPath]) {
      final file = File(path);
      if (!file.existsSync()) continue;
      try {
        return (jsonDecode(file.readAsStringSync()) as List)
            .cast<Map<String, Object?>>();
      } on Object {
        return [];
      }
    }
    return [];
  }

  void write(List<Map<String, Object?>> runs) => writeAtomically(
    ownPath,
    const JsonEncoder.withIndent('  ').convert(runs),
  );
}

// ------------------------------------------------------------------ pack

/// Every regular file below [path] (or [path] itself), sorted; links are
/// not followed and unreadable folders are skipped.
List<String> filesBelow(String path) {
  final out = <String>[];
  final stack = [path];
  while (stack.isNotEmpty) {
    final next = stack.removeLast();
    final type = FileSystemEntity.typeSync(next, followLinks: false);
    if (type == FileSystemEntityType.file) {
      out.add(next);
    } else if (type == FileSystemEntityType.directory) {
      try {
        stack.addAll(
          Directory(next).listSync(followLinks: false).map((e) => e.path),
        );
      } on FileSystemException {
        // An unreadable folder: what can be read is still copied.
      }
    }
  }
  return out..sort();
}

/// (size, mtime in seconds) of a file.
(int, int)? fileState(String path) {
  try {
    final stat = File(path).statSync();
    if (stat.type == FileSystemEntityType.notFound) return null;
    return (stat.size, stat.modified.millisecondsSinceEpoch ~/ 1000);
  } on FileSystemException {
    return null;
  }
}

const _note = 'screenshot left out of this copy';

/// Replaces screenshots inside one transcript record with a short note.
/// Claude stores them as `{"type":"base64","media_type":"image/…",
/// "data":…}`, Codex as `data:image/…;base64,…` strings.
Object? stripImages(Object? value, List<int> count) {
  if (value is Map<String, Object?>) {
    final type = value['type'];
    final media = value['media_type'];
    final data = value['data'];
    if (type == 'base64' &&
        media is String &&
        media.startsWith('image/') &&
        data is String) {
      count[0]++;
      value['data'] = '[$_note: ${data.length * 3 ~/ 4 ~/ 1024} KB]';
      return value;
    }
    for (final key in value.keys.toList()) {
      value[key] = stripImages(value[key], count);
    }
    return value;
  }
  if (value is List<Object?>) {
    for (var i = 0; i < value.length; i++) {
      value[i] = stripImages(value[i], count);
    }
    return value;
  }
  if (value is String &&
      value.startsWith('data:image/') &&
      value.length > 200) {
    count[0]++;
    return '[$_note: ${value.length * 3 ~/ 4 ~/ 1024} KB]';
  }
  return value;
}

final _base64Word = ascii.encode('base64');

bool _contains(List<int> haystack, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}

/// One transcript line without its screenshots; a line that is not JSON is
/// kept as it is.
List<int> slimLine(List<int> line, List<int> count) {
  if (!_contains(line, _base64Word)) return line;
  try {
    final value = jsonDecode(utf8.decode(line));
    final before = count[0];
    final slim = stripImages(value, count);
    return count[0] == before ? line : utf8.encode(jsonEncode(slim));
  } on Object {
    return line;
  }
}

bool alreadyCompressed(String path) =>
    RegExp(r'\.(gz|zst|xz|bz2|zip)$').hasMatch(path);

/// The copy's path for a source file: `.gz` added unless it is compressed.
String copyName(String relative, String source) =>
    alreadyCompressed(source) ? relative : '$relative.gz';

/// Folder-safe name for an extra folder: `/srv/x/y` → `srv-x-y`.
String extraName(String path) => path
    .replaceAll(RegExp(r'^/+|/+$'), '')
    .replaceAll(RegExp(r'[^A-Za-z0-9._]'), '-');

/// Writes the slim copy of [source] to [target] (through a temporary file).
Future<void> packFile(String source, String target, List<int> images) async {
  final parent = File(target).parent..createSync(recursive: true);
  final temporary = '${parent.path}/.${target.split('/').last}.part';
  if (alreadyCompressed(source)) {
    File(source).copySync(temporary);
  } else {
    final sink = File(temporary).openWrite();
    final gzipped = GZipCodec(level: 6).encoder.startChunkedConversion(sink);
    final transcript = source.endsWith('.jsonl');
    final pending = BytesBuilder(copy: false);
    void emit(List<int> line, bool newline) {
      gzipped.add(transcript ? slimLine(line, images) : line);
      if (newline) gzipped.add(const [10]);
    }

    try {
      await for (final read in File(source).openRead()) {
        final chunk = read is Uint8List ? read : Uint8List.fromList(read);
        var start = 0;
        for (var i = 0; i < chunk.length; i++) {
          if (chunk[i] != 10) continue;
          if (pending.isEmpty) {
            emit(Uint8List.sublistView(chunk, start, i), true);
          } else {
            pending.add(Uint8List.sublistView(chunk, start, i));
            emit(pending.takeBytes(), true);
          }
          start = i + 1;
        }
        if (start < chunk.length) {
          pending.add(Uint8List.sublistView(chunk, start));
        }
      }
      if (pending.isNotEmpty) emit(pending.takeBytes(), false);
      gzipped.close();
      await sink.done;
    } on Object {
      gzipped.close();
      await sink.done.catchError((_) {});
      if (File(temporary).existsSync()) File(temporary).deleteSync();
      rethrow;
    }
  }
  File(temporary).renameSync(target);
}

/// This device's slim copy, brought up to date.
Future<Map<String, Object?>> pack(
  Local local,
  ConversationSettings settings,
) async {
  final folder = '${local.home}/$backupRoot/${local.device}';
  Directory(folder).createSync(recursive: true);
  final manifestPath = '$folder/$_manifestName';
  final manifest = <String, Object?>{};
  try {
    manifest.addAll(
      (jsonDecode(File(manifestPath).readAsStringSync()) as Map)
          .cast<String, Object?>(),
    );
  } on Object {
    // No manifest yet, or a broken one: every file is packed again.
  }
  final report = <String, Object?>{
    'schema_version': conversationsSchema,
    'device': local.device,
    'folder': folder,
    'packed': 0,
    'unchanged': 0,
    'failed': <String>[],
    'original_bytes': 0,
    'copy_bytes': 0,
    'images_left_out': 0,
    'sessions': 0,
  };
  void add(String key, int amount) =>
      report[key] = (report[key] as int) + amount;
  final roots = [
    for (final (from, to) in historySources) ('${local.home}/$from', to),
    for (final (device, path) in settings.extras)
      if (device == local.device) (path, 'extra/${extraName(path)}'),
  ];
  final images = [0];
  for (final (root, into) in roots) {
    if (FileSystemEntity.typeSync(root) == FileSystemEntityType.notFound) {
      continue;
    }
    for (final source in filesBelow(root)) {
      final rest = source == root ? '' : source.substring(root.length + 1);
      final relative = rest.isEmpty ? into : '$into/$rest';
      final state = fileState(source);
      if (state == null) continue;
      if (source.endsWith('.jsonl')) add('sessions', 1);
      add('original_bytes', state.$1);
      final target = '$folder/${copyName(relative, source)}';
      final known = manifest[relative];
      final unchanged =
          known is List &&
          known.length == 2 &&
          known[0] == state.$1 &&
          known[1] == state.$2 &&
          File(target).existsSync();
      if (unchanged) {
        add('unchanged', 1);
      } else {
        try {
          await packFile(source, target, images);
          manifest[relative] = [state.$1, state.$2];
          add('packed', 1);
        } on Object catch (error) {
          (report['failed'] as List<String>).add('$relative: $error');
        }
      }
      try {
        add('copy_bytes', File(target).lengthSync());
      } on FileSystemException {
        // Not packed: nothing to count.
      }
    }
  }
  report['images_left_out'] = images[0];
  final temporary = '$manifestPath.part';
  File(temporary).writeAsStringSync(jsonEncode(manifest));
  File(temporary).renameSync(manifestPath);
  return report;
}

// ------------------------------------------------------------------ copy

/// How to reach a device: the SSH command (shell words, as rsync's `-e`
/// takes them) and the host to give it.
class Reach {
  const Reach(this.rsh, this.host);
  final String rsh;
  final String host;

  /// Runs [command] there with this SSH.
  Future<ProcessResult> run(String command, {Duration? timeout}) => runShell(
    '$rsh ${shellQuote(host)} ${shellQuote(command)}',
    timeout: timeout ?? _longTimeout,
  );
}

/// The default SSH: the user's own configuration, never a password prompt.
const defaultRsh = 'ssh -o BatchMode=yes -o ConnectTimeout=10';

/// Finds fluttairbar-cli on the other device and runs it there.
String remoteCli(String args) =>
    'for f in "\$HOME/.local/bin/fluttairbar-cli" "\$(command -v fluttairbar-cli 2>/dev/null)" /opt/homebrew/bin/fluttairbar-cli /usr/local/bin/fluttairbar-cli; do [ -n "\$f" ] && [ -x "\$f" ] && exec "\$f" $args; done; echo "error=fluttairbar-cli is not installed there"; exit 127';

Future<String> _rsync(Reach reach, int limit, String from, String to) async {
  final words = [
    'rsync',
    '-a',
    '--partial',
    '--exclude=.*.part',
    '--stats',
    if (limit > 0) '--bwlimit=$limit',
    '-e',
    reach.rsh,
    from,
    to,
  ];
  final result = await runShell(
    words.map(shellQuote).join(' '),
    timeout: _longTimeout,
  );
  if (result.exitCode != 0) {
    final lines = '${result.stderr}'.trim().split('\n');
    throw ConversationsError(
      'rsync: ${lines.last.isEmpty ? 'failed' : lines.last}',
    );
  }
  return '${result.stdout}'
      .split('\n')
      .firstWhere(
        (line) =>
            line.startsWith('Total transferred file size') ||
            line.startsWith('Total bytes sent'),
        orElse: () => '',
      )
      .trim();
}

Map<String, Object?> _run(
  String from,
  String to,
  String result,
  String detail,
) => {
  'from': from,
  'to': to,
  'result': result,
  'detail': detail,
  'at_unix_seconds': unixNow(),
  'failing_since_unix_seconds': 0,
};

/// Both sides of every pair this device is in, packed and copied to each
/// other. Never deletes anything. [reach] says how to get to a device
/// (default: `ssh NAME`).
Future<Map<String, Object?>> copy({
  required Local local,
  required ConversationSettings settings,
  required bool execute,
  Map<String, Reach> reach = const {},
  int? bwlimit,
}) async {
  final me = local.device;
  final pairs = settings.pairs.where((p) => p.$1 == me || p.$2 == me).toList();
  if (pairs.isEmpty) {
    throw ConversationsError(
      '$me is in no pair; add [[pair]] devices = ["$me", "OTHER"] to the conversations settings',
    );
  }
  final limit = settings.bwlimitKbps ?? bwlimit ?? 0;
  final runs = <Map<String, Object?>>[];
  for (final pair in pairs) {
    final peer = pair.$1 == me ? pair.$2 : pair.$1;
    if (!execute) {
      runs
        ..add(
          _run(
            peer,
            me,
            'planned',
            'would pack $peer and copy its history here',
          ),
        )
        ..add(
          _run(
            me,
            peer,
            'planned',
            'would pack $me and copy its history to $peer',
          ),
        );
      continue;
    }
    final via = reach[peer] ?? Reach(defaultRsh, peer);
    // Here first: a failure on the other side does not stop this one.
    Object? localError;
    try {
      await pack(local, settings);
    } on Object catch (error) {
      localError = error;
    }
    try {
      final remote = await via.run(
        remoteCli('conversations pack --format json'),
      );
      final out = '${remote.stdout}';
      if (remote.exitCode == 255) {
        final detail = '${remote.stderr}'.trim();
        throw ConversationsError(
          detail.isEmpty ? '$peer did not answer over SSH' : detail,
        );
      }
      if (remote.exitCode == 64) {
        throw ConversationsError(
          'packing on $peer: the fluttairbar-cli there is older than conversations; update it',
        );
      }
      if (!_isReport(out)) {
        final last = '$out${remote.stderr}'.trim().split('\n').last;
        throw ConversationsError(
          'packing on $peer: ${last.isEmpty ? 'no answer' : last.replaceFirst('error=', '')}',
        );
      }
      final target = '${local.home}/$backupRoot/$peer';
      Directory(target).createSync(recursive: true);
      runs.add(
        _run(
          peer,
          me,
          'ok',
          await _rsync(
            via,
            limit,
            '${via.host}:$backupRoot/$peer/',
            '$target/',
          ),
        ),
      );
    } on Object catch (error) {
      runs.add(_run(peer, me, 'failed', '$error'));
    }
    if (localError != null) {
      runs.add(_run(me, peer, 'failed', 'packing here: $localError'));
      continue;
    }
    try {
      final made = await via.run(
        'mkdir -p "\$HOME"/${shellQuote('$backupRoot/$me')}',
        timeout: const Duration(minutes: 1),
      );
      if (made.exitCode != 0) {
        final detail = '${made.stderr}'.trim();
        throw ConversationsError(
          detail.isEmpty ? '$peer did not answer over SSH' : detail,
        );
      }
      runs.add(
        _run(
          me,
          peer,
          'ok',
          await _rsync(
            via,
            limit,
            '${local.home}/$backupRoot/$me/',
            '${via.host}:$backupRoot/$me/',
          ),
        ),
      );
    } on Object catch (error) {
      runs.add(_run(me, peer, 'failed', '$error'));
    }
  }
  if (execute) {
    final state = CopyState(local);
    final previous = state.read();
    for (final run in runs.where((run) => run['result'] == 'failed')) {
      final before = previous
          .where(
            (p) =>
                p['from'] == run['from'] &&
                p['to'] == run['to'] &&
                p['result'] == 'failed',
          )
          .firstOrNull;
      run['failing_since_unix_seconds'] = before == null
          ? run['at_unix_seconds']
          : ((before['failing_since_unix_seconds'] as int? ?? 0) > 0
                ? before['failing_since_unix_seconds']
                : before['at_unix_seconds']);
    }
    state.write(runs);
  }
  return {
    'schema_version': conversationsSchema,
    'executed': execute,
    'runs': runs,
  };
}

bool _isReport(String text) {
  try {
    final value = jsonDecode(text.trim());
    return value is Map && value['schema_version'] != null;
  } on Object {
    return false;
  }
}

// ---------------------------------------------------------------- status

/// What is kept here: the originals, the slim copies per device, the pairs,
/// the last copies, and each direction that keeps failing with for how many
/// days (from the failures recorded run after run and from the age of the
/// newest copy held here, which covers failures from before they were
/// recorded).
Map<String, Object?> status(Local local, ConversationSettings settings) {
  var sessions = 0;
  var originalBytes = 0;
  for (final (from, _) in historySources) {
    for (final file in filesBelow('${local.home}/$from')) {
      if (file.endsWith('.jsonl')) sessions++;
      originalBytes += fileState(file)?.$1 ?? 0;
    }
  }
  final copies = <Map<String, Object?>>[];
  final root = Directory('${local.home}/$backupRoot');
  if (root.existsSync()) {
    for (final entry in root.listSync()) {
      if (entry is! Directory) continue;
      var files = 0, bytes = 0, newest = 0;
      for (final file in filesBelow(entry.path)) {
        if (file.split('/').last.startsWith('.')) continue;
        final state = fileState(file);
        if (state == null) continue;
        files++;
        bytes += state.$1;
        if (state.$2 > newest) newest = state.$2;
      }
      copies.add({
        'device': entry.path.split('/').last,
        'files': files,
        'bytes': bytes,
        'newest_unix_seconds': newest,
      });
    }
  }
  copies.sort((a, b) => '${a['device']}'.compareTo('${b['device']}'));
  final runs = CopyState(local).read();
  final now = unixNow();
  final behind = <Map<String, Object?>>[];
  for (final run in runs.where((run) => run['result'] == 'failed')) {
    final failing = run['failing_since_unix_seconds'] as int? ?? 0;
    final since = failing > 0 ? failing : run['at_unix_seconds'] as int? ?? now;
    var days = (now - since) ~/ 86400;
    final held = copies.where((c) => c['device'] == run['from']).firstOrNull;
    final newest = held?['newest_unix_seconds'] as int? ?? 0;
    if (newest > 0 && (now - newest) ~/ 86400 > days) {
      days = (now - newest) ~/ 86400;
    }
    behind.add({
      'from': run['from'],
      'to': run['to'],
      'days': days,
      'detail': run['detail'],
    });
  }
  return {
    'schema_version': conversationsSchema,
    'device': local.device,
    'sessions': sessions,
    'original_bytes': originalBytes,
    'copies': copies,
    'pairs': [
      for (final pair in settings.pairs) [pair.$1, pair.$2],
    ],
    'last_runs': runs,
    'behind': behind,
  };
}

/// Reads the settings, or refuses them with where they are.
ConversationSettings loadConversationSettings(SettingsStore store) {
  try {
    return ConversationSettings.parse(store.read());
  } on TomlError catch (error) {
    throw ConversationsError('${store.path}: $error');
  }
}

// ------------------------------------------------------------------ text

String _mb(int bytes) => '${(bytes / 1e6).toStringAsFixed(0)} MB';

String textPack(Map<String, Object?> report) {
  final lines = [
    '${report['device']}: ${report['sessions']} sessions, ${_mb(report['original_bytes'] as int)} → ${_mb(report['copy_bytes'] as int)} in ${report['folder']} (${report['packed']} packed now, ${report['unchanged']} unchanged, ${report['images_left_out']} screenshots left out now)',
    for (final failure in report['failed'] as List) '  failed: $failure',
  ];
  return lines.join('\n');
}

String textCopy(Map<String, Object?> report) => [
  for (final r in (report['runs'] as List).cast<Map<String, Object?>>())
    '${r['from']} → ${r['to']}: ${r['result']} ${r['detail']}',
].join('\n');

String textStatus(Map<String, Object?> report) {
  final now = unixNow();
  final copies = (report['copies'] as List).cast<Map<String, Object?>>();
  final lines = [
    'Conversation history on ${report['device']}: ${report['sessions']} sessions, ${_mb(report['original_bytes'] as int)} (Claude and Codex)',
    if (copies.isEmpty)
      '  no slim copies here yet: fluttairbar-cli conversations copy',
    for (final copy in copies)
      '  copy of ${'${copy['device']}'.padRight(14)} ${copy['files']} files, ${_mb(copy['bytes'] as int)}, newest ${copy['newest_unix_seconds'] == 0 ? '-' : '${(now - (copy['newest_unix_seconds'] as int)) ~/ 3600} h ago'}',
    for (final run
        in (report['last_runs'] as List).cast<Map<String, Object?>>())
      '  last copy ${run['from']} → ${run['to']}: ${run['result']} ${run['detail']}',
  ];
  return lines.join('\n');
}
