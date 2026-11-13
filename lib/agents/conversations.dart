/// `fluttairbar-cli conversations`: Claude Code and Codex conversation
/// history, kept on two devices. History is kept, always: nothing here
/// deletes or prunes a session, only the projects the settings exclude are
/// left out, and a copy never touches its source.
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
///
/// # Projects never packed or copied, in either direction: a project whose
/// # path contains one of these (see [LeftOut]).
/// exclude = ["/Documents/acme", "acme-intern"]
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
    this.exclude = const [],
  });

  final List<(String, String)> pairs;
  final List<(String device, String path)> extras;
  final int? bwlimitKbps;

  /// Parts of a project's path: a project that contains one is never packed
  /// or copied.
  final List<String> exclude;

  /// These settings with [more] exclude entries (from the command line, or
  /// from the device that runs the copy).
  ConversationSettings excluding(Iterable<String> more) => ConversationSettings(
    pairs: pairs,
    extras: extras,
    bwlimitKbps: bwlimitKbps,
    exclude: {...exclude, ...more}.toList(),
  );

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
    final exclude = tomlStrings(toml['exclude'], 'exclude');
    for (final text in exclude) {
      if (!excludeText(text)) throw TomlError(excludeRefused(text));
    }
    return ConversationSettings(
      pairs: pairs,
      extras: extras,
      bwlimitKbps: limit as int?,
      exclude: exclude.toSet().toList(),
    );
  }
}

/// Whether [text] can be an exclude entry: a part of a path with a letter or
/// a digit in it (`/` alone would leave out every project).
bool excludeText(String text) => RegExp('[A-Za-z0-9]').hasMatch(text);

String excludeRefused(String text) =>
    'exclude "$text" names no project: give a part of its path with a letter or digit, such as "/Documents/acme"';

/// A path spelled the way Claude Code names a project's folder: every
/// character other than a letter or digit becomes `-`.
String claudeName(String path) => path.replaceAll(RegExp('[^A-Za-z0-9]'), '-');

/// The history files with a line per prompt or session of every project.
const _historyFiles = {
  'claude/history.jsonl',
  'codex/history.jsonl',
  'codex/session_index.jsonl',
};

/// What the exclude list leaves out: the Claude project folders and Codex
/// sessions of every project whose path contains one of its entries, found
/// in this device's history and in its slim copy (a copy made before the
/// entry was added stays where it is, and is not sent on), and their lines in
/// the history files.
///
/// A project's path is compared the way Claude Code spells it in a folder
/// name, which cannot tell `/`, `.`, `_` and `-` apart, and without regard to
/// case: an entry leaves out at least the projects it names. Claude's project
/// folder name is its path; a Codex session names its own (`cwd`), and a
/// Codex session that names none is copied.
class LeftOut {
  LeftOut(this.exclude);

  final List<String> exclude;

  /// Left out of the copy, relative to the slim folder: a Claude project as
  /// `claude/projects/NAME/`, a Codex session as the name of its copy.
  final paths = <String>{};

  /// The Codex sessions left out, by id: their history lines go too.
  final codexIds = <String>{};

  final _projects = <String, Set<String>>{};
  final _sessions = <String, Set<String>>{};

  late final _spelled = [
    for (final text in exclude) (text, claudeName(text).toLowerCase()),
  ];

  /// The exclude entry that leaves out the project at [path] (a path, or a
  /// Claude project folder's name), or null.
  String? matchOf(String path) {
    final spelled = claudeName(path).toLowerCase();
    for (final (text, part) in _spelled) {
      if (spelled.contains(part)) return text;
    }
    return null;
  }

  /// Whether the copy named [relative] (inside the slim folder) is left out.
  bool leavesOut(String relative) {
    if (paths.contains(relative)) return true;
    final parts = relative.split('/');
    return parts.length > 3 &&
        parts[0] == 'claude' &&
        parts[1] == 'projects' &&
        paths.contains('claude/projects/${parts[2]}/');
  }

  /// Whether a history record belongs to a project left out: Claude's history
  /// names its project, Codex's its session.
  bool dropsLine(Object? record) {
    if (record is! Map) return false;
    bool session(Object? id) =>
        id is String && codexIds.contains(id.toLowerCase());
    final project = record['project'];
    return (project is String && matchOf(project) != null) ||
        session(record['session_id']) ||
        session(record['id']);
  }

  void _project(String match, String project) =>
      _projects.putIfAbsent(match, () => {}).add(project);

  void _session(String match, String relative) =>
      _sessions.putIfAbsent(match, () => {}).add(relative);

  /// Per entry, how many projects and sessions it leaves out (0 for an entry
  /// that names nothing here, which is worth a look).
  List<Map<String, Object?>> toJson() => [
    for (final text in exclude)
      {
        'match': text,
        'projects': _projects[text]?.length ?? 0,
        'sessions': _sessions[text]?.length ?? 0,
      },
  ];
}

final _sessionId = RegExp(
  r'([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\.jsonl(\.gz)?$',
);

List<String> _folders(String path) {
  try {
    return [
      for (final entry in Directory(path).listSync(followLinks: false))
        if (entry is Directory) entry.path.split('/').last,
    ];
  } on FileSystemException {
    return const [];
  }
}

/// What [exclude] leaves out of this device's history and of its slim copy
/// in [folder].
LeftOut findLeftOut(Local local, List<String> exclude, String folder) {
  final left = LeftOut(exclude);
  if (exclude.isEmpty) return left;
  // Claude: the project folder's name is its path.
  final names = {
    ..._folders('${local.home}/.claude/projects'),
    ..._folders('$folder/claude/projects'),
  };
  for (final name in names) {
    final match = left.matchOf(name);
    if (match == null) continue;
    left.paths.add('claude/projects/$name/');
    left._project(match, name);
    for (final base in [
      '${local.home}/.claude/projects/$name',
      '$folder/claude/projects/$name',
    ]) {
      for (final file in filesBelow(base)) {
        if (!file.endsWith('.jsonl') && !file.endsWith('.jsonl.gz')) continue;
        final rest = file.substring(base.length + 1);
        left._session(
          match,
          '$name/${rest.replaceFirst(RegExp(r'\.gz$'), '')}',
        );
      }
    }
  }
  // Codex: each session names the folder it ran in; a copy whose session is
  // gone here is read for it.
  void codex(String relative, String path) {
    final cwd = sessionCwd(path);
    final match = cwd == null ? null : left.matchOf(cwd);
    if (match == null) return;
    left.paths.add('$relative.gz');
    left._project(match, claudeName(cwd!));
    left._session(match, relative);
    final id = _sessionId.firstMatch(path)?.group(1);
    if (id != null) left.codexIds.add(id.toLowerCase());
  }

  for (final from in ['sessions', 'archived_sessions']) {
    final seen = <String>{};
    final base = '${local.home}/.codex/$from';
    for (final source in filesBelow(base)) {
      if (!source.endsWith('.jsonl')) continue;
      final relative = 'codex/$from/${source.substring(base.length + 1)}';
      seen.add(relative);
      codex(relative, source);
    }
    final copies = '$folder/codex/$from';
    for (final copy in filesBelow(copies)) {
      if (!copy.endsWith('.jsonl.gz')) continue;
      final relative =
          'codex/$from/${copy.substring(copies.length + 1, copy.length - 3)}';
      if (!seen.contains(relative)) codex(relative, copy);
    }
  }
  return left;
}

/// How a Codex session names its folder, and the byte that ends the name: a
/// record's `"cwd":"…"`, and in sessions older than that, `<cwd>…</cwd>` in
/// the environment it was told about. Either sits inside a JSON string.
final _cwdKeys = [
  (ascii.encode('"cwd":"'), 0x22),
  (ascii.encode('<cwd>'), 0x3c),
];

/// Finds the first folder name in a stream of bytes.
class _CwdFinder implements Sink<List<int>> {
  String? cwd;
  Uint8List _rest = Uint8List(0);

  @override
  void add(List<int> chunk) {
    if (cwd != null) return;
    final bytes =
        (BytesBuilder(copy: false)
              ..add(_rest)
              ..add(chunk))
            .takeBytes();
    var at = -1, start = 0, end = 0;
    for (final (key, last) in _cwdKeys) {
      final found = _indexOf(bytes, key);
      if (found >= 0 && (at < 0 || found < at)) {
        (at, start, end) = (found, found + key.length, last);
      }
    }
    if (at < 0) {
      // Keep what could be the start of a key cut by the chunk's end.
      final keep = bytes.length - 6;
      _rest = keep > 0 ? Uint8List.sublistView(bytes, keep) : bytes;
      return;
    }
    for (var i = start; i < bytes.length; i++) {
      if (bytes[i] == 0x5c) {
        i++; // an escaped character
        continue;
      }
      if (bytes[i] != end) continue;
      try {
        final escaped = utf8.decode(Uint8List.sublistView(bytes, start, i));
        cwd = jsonDecode('"$escaped"') as String;
      } on Object {
        cwd = '';
      }
      return;
    }
    // The name goes on in the next chunk.
    _rest = Uint8List.sublistView(bytes, at);
  }

  @override
  void close() {}
}

/// The folder a Codex session ran in: the first one its records name (its
/// `session_meta` or a `turn_context`, in older sessions the environment
/// context), read from the start of the file, and through gzip for a `.gz`
/// copy. Null when it names none.
String? sessionCwd(String path) {
  final found = _CwdFinder();
  RandomAccessFile? file;
  try {
    file = File(path).openSync();
    final Sink<List<int>> input = path.endsWith('.gz')
        ? gzip.decoder.startChunkedConversion(found)
        : found;
    while (found.cwd == null) {
      final chunk = file.readSync(1 << 16);
      if (chunk.isEmpty) break;
      input.add(chunk);
    }
  } on Object {
    // Unreadable or broken: what was found so far counts.
  } finally {
    file?.closeSync();
  }
  final cwd = found.cwd;
  return cwd == null || cwd.isEmpty ? null : cwd;
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

int _indexOf(List<int> haystack, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

bool _contains(List<int> haystack, List<int> needle) =>
    _indexOf(haystack, needle) >= 0;

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
/// A line whose record [drop] says no to is left out and counted in
/// [dropped].
Future<void> packFile(
  String source,
  String target,
  List<int> images, {
  bool Function(Object? record)? drop,
  List<int>? dropped,
}) async {
  final parent = File(target).parent..createSync(recursive: true);
  final temporary = '${parent.path}/.${target.split('/').last}.part';
  if (alreadyCompressed(source)) {
    File(source).copySync(temporary);
  } else {
    final sink = File(temporary).openWrite();
    final gzipped = GZipCodec(level: 6).encoder.startChunkedConversion(sink);
    final transcript = source.endsWith('.jsonl');
    final pending = BytesBuilder(copy: false);
    bool drops(List<int> line) {
      try {
        return drop!(jsonDecode(utf8.decode(line)));
      } on Object {
        return false; // not a record: kept as it is
      }
    }

    void emit(List<int> line, bool newline) {
      if (drop != null && drops(line)) {
        if (dropped != null) dropped[0]++;
        return;
      }
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

/// This device's slim copy, brought up to date. The projects the exclude
/// list names are not packed, and their lines are left out of the history
/// files (rewritten then at every pack); their copies made before stay, and
/// `excluded_paths` names them so a copy leaves them where they are.
Future<Map<String, Object?>> pack(
  Local local,
  ConversationSettings settings,
) async {
  final folder = '${local.home}/$backupRoot/${local.device}';
  Directory(folder).createSync(recursive: true);
  final left = findLeftOut(local, settings.exclude, folder);
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
    'exclude': settings.exclude,
    'excluded': left.toJson(),
    'excluded_paths': left.paths.toList()..sort(),
    'history_lines_left_out': 0,
  };
  void add(String key, int amount) =>
      report[key] = (report[key] as int) + amount;
  final roots = [
    for (final (from, to) in historySources) ('${local.home}/$from', to),
    for (final (device, path) in settings.extras)
      if (device == local.device) (path, 'extra/${extraName(path)}'),
  ];
  final images = [0];
  final dropped = [0];
  for (final (root, into) in roots) {
    if (FileSystemEntity.typeSync(root) == FileSystemEntityType.notFound) {
      continue;
    }
    for (final source in filesBelow(root)) {
      final rest = source == root ? '' : source.substring(root.length + 1);
      final relative = rest.isEmpty ? into : '$into/$rest';
      if (left.leavesOut(copyName(relative, source))) continue;
      final state = fileState(source);
      if (state == null) continue;
      if (source.endsWith('.jsonl')) add('sessions', 1);
      add('original_bytes', state.$1);
      final target = '$folder/${copyName(relative, source)}';
      final known = manifest[relative];
      // With an exclude list the history files are written again each
      // time: which lines go depends on the list, not only on the file.
      final filtered =
          settings.exclude.isNotEmpty && _historyFiles.contains(relative);
      final unchanged =
          !filtered &&
          known is List &&
          known.length == 2 &&
          known[0] == state.$1 &&
          known[1] == state.$2 &&
          File(target).existsSync();
      if (unchanged) {
        add('unchanged', 1);
      } else {
        try {
          await packFile(
            source,
            target,
            images,
            drop: filtered ? left.dropsLine : null,
            dropped: dropped,
          );
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
  report['history_lines_left_out'] = dropped[0];
  final temporary = '$manifestPath.part';
  File(temporary).writeAsStringSync(jsonEncode(manifest));
  File(temporary).renameSync(manifestPath);
  return report;
}

// ------------------------------------------------------------------ copy

/// How to reach a device: the SSH command (shell words, as rsync's `-e`
/// takes them), the host to give it, and what packs there where this CLI is
/// not installed (a shell command that writes the same slim copy and prints
/// the same JSON report; a device this CLI has no build for).
class Reach {
  const Reach(this.rsh, this.host, {this.pack});
  final String rsh;
  final String host;
  final String? pack;

  /// Runs [command] there with this SSH.
  Future<ProcessResult> run(String command, {Duration? timeout}) => runShell(
    '$rsh ${shellQuote(host)} ${shellQuote(command)}',
    timeout: timeout ?? _longTimeout,
  );
}

/// The default SSH: the user's own configuration, never a password prompt.
const defaultRsh = 'ssh -o BatchMode=yes -o ConnectTimeout=10';

/// Finds fluttairbar-cli on the other device and runs it there; where it
/// is not installed, [otherwise] runs instead, if given.
String remoteCli(String args, {String? otherwise}) =>
    'for f in "\$HOME/.local/bin/fluttairbar-cli" "\$(command -v fluttairbar-cli 2>/dev/null)" /opt/homebrew/bin/fluttairbar-cli /usr/local/bin/fluttairbar-cli; do [ -n "\$f" ] && [ -x "\$f" ] && exec "\$f" $args; done; ${otherwise ?? 'echo "error=fluttairbar-cli is not installed there"; exit 127'}';

/// Copies [from] to [to], leaving out [leaveOut] (paths inside [from], as a
/// pack's `excluded_paths` names them).
Future<String> _rsync(
  Reach reach,
  int limit,
  String from,
  String to, {
  Iterable<String> leaveOut = const [],
}) async {
  final patterns = [
    for (final path in leaveOut)
      if (path.isNotEmpty && !path.contains('\n') && !path.contains('\r'))
        '/$path',
  ];
  final scratch = patterns.isEmpty
      ? null
      : Directory.systemTemp.createTempSync('fluttairbar-exclude-');
  final ProcessResult result;
  try {
    if (scratch != null) {
      File(
        '${scratch.path}/list',
      ).writeAsStringSync('${patterns.join('\n')}\n');
    }
    final words = [
      'rsync',
      '-a',
      '--partial',
      '--exclude=.*.part',
      if (scratch != null) '--exclude-from=${scratch.path}/list',
      '--stats',
      if (limit > 0) '--bwlimit=$limit',
      '-e',
      reach.rsh,
      from,
      to,
    ];
    result = await runShell(
      words.map(shellQuote).join(' '),
      timeout: _longTimeout,
    );
  } finally {
    scratch?.deleteSync(recursive: true);
  }
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

/// The exclude entries a pack report does not say it applied.
List<String> _notApplied(List<String> exclude, Map<String, Object?> report) {
  final applied = report['exclude'];
  return [
    for (final text in exclude)
      if (applied is! List || !applied.contains(text)) text,
  ];
}

List<String> _excludedPaths(Map<String, Object?>? report) => [
  ...?(report?['excluded_paths'] as List?)?.whereType<String>(),
];

/// Both sides of every pair this device is in, packed and copied to each
/// other. Never deletes anything. [reach] says how to get to a device
/// (default: `ssh NAME`) and what packs there without this CLI.
///
/// The exclude list holds in both directions: the other side packs with it
/// too (`--exclude`, added to its own), a side whose report does not say it
/// applied it is not copied from, and each side's `excluded_paths` stay
/// where they are.
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
  final exclude = settings.exclude;
  final withExclude = [
    for (final text in exclude) ' --exclude ${shellQuote(text)}',
  ].join();
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
    Map<String, Object?>? mine;
    try {
      mine = await pack(local, settings);
    } on Object catch (error) {
      localError = error;
    }
    try {
      final remote = await via.run(
        remoteCli(
          'conversations pack --format json$withExclude',
          otherwise: via.pack == null ? null : '${via.pack}$withExclude',
        ),
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
          'packing on $peer: the fluttairbar-cli there is older than conversations${exclude.isEmpty ? '' : ' exclude'}; update it',
        );
      }
      final theirs = _report(out);
      if (theirs == null) {
        final last = '$out${remote.stderr}'.trim().split('\n').last;
        throw ConversationsError(
          'packing on $peer: ${last.isEmpty ? 'no answer' : last.replaceFirst('error=', '')}',
        );
      }
      final missing = _notApplied(exclude, theirs);
      if (missing.isNotEmpty) {
        throw ConversationsError(
          'packing on $peer did not apply exclude ${missing.map((t) => '"$t"').join(', ')} (its packer is older than exclude): nothing copied from $peer; update it',
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
            leaveOut: _excludedPaths(theirs),
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
            leaveOut: _excludedPaths(mine),
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

/// The pack report in [text], or null when it is none.
Map<String, Object?>? _report(String text) {
  try {
    final value = jsonDecode(text.trim());
    return value is Map && value['schema_version'] != null
        ? value.cast<String, Object?>()
        : null;
  } on Object {
    return null;
  }
}

// ---------------------------------------------------------------- status

/// What is kept here: the originals, the slim copies per device, the pairs,
/// the last copies, each direction that keeps failing with for how many
/// days (from the failures recorded run after run and from the age of the
/// newest copy held here, which covers failures from before they were
/// recorded), and per exclude entry how many projects and sessions it
/// leaves out.
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
    'exclude': settings.exclude,
    'excluded': findLeftOut(
      local,
      settings.exclude,
      '${local.home}/$backupRoot/${local.device}',
    ).toJson(),
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

/// One line per exclude entry: what it leaves out, and why.
List<String> _excludedLines(Map<String, Object?> report) => [
  for (final entry
      in (report['excluded'] as List? ?? const []).cast<Map<String, Object?>>())
    '  left out: ${_count(entry['projects'], 'project')} (${_count(entry['sessions'], 'session')}) whose path contains "${entry['match']}" (exclude)',
];

String _count(Object? n, String what) => '$n $what${n == 1 ? '' : 's'}';

String textPack(Map<String, Object?> report) {
  final lines = [
    '${report['device']}: ${report['sessions']} sessions, ${_mb(report['original_bytes'] as int)} → ${_mb(report['copy_bytes'] as int)} in ${report['folder']} (${report['packed']} packed now, ${report['unchanged']} unchanged, ${report['images_left_out']} screenshots left out now)',
    ..._excludedLines(report),
    if ((report['history_lines_left_out'] as int? ?? 0) > 0)
      '  left out: ${_count(report['history_lines_left_out'], 'history line')} of those projects',
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
    ..._excludedLines(report),
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
