/// The part of TOML the agent settings files use, read and written without a
/// package: comments, `key = value` with strings (basic and literal),
/// integers, booleans and arrays of those, `[table]` and `[[array of
/// tables]]`. Anything else is refused with its line number, so a file is
/// never half-read.
library;

class TomlError implements Exception {
  TomlError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Parses [text] into maps: a table is a `Map<String, Object?>`, an array of
/// tables a `List<Map<String, Object?>>`.
Map<String, Object?> parseToml(String text) {
  final root = <String, Object?>{};
  var current = root;
  final lines = text.split('\n');
  for (var index = 0; index < lines.length; index++) {
    final number = index + 1;
    var line = lines[index].trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    if (line.startsWith('[[')) {
      final end = line.indexOf(']]');
      if (end < 0) throw TomlError('line $number: [[ without ]]');
      final name = line.substring(2, end).trim();
      _checkRest(line.substring(end + 2), number);
      final list = root.putIfAbsent(name, () => <Map<String, Object?>>[]);
      if (list is! List<Map<String, Object?>>) {
        throw TomlError('line $number: $name is not an array of tables');
      }
      current = <String, Object?>{};
      list.add(current);
      continue;
    }
    if (line.startsWith('[')) {
      final end = line.indexOf(']');
      if (end < 0) throw TomlError('line $number: [ without ]');
      final name = line.substring(1, end).trim();
      _checkRest(line.substring(end + 1), number);
      if (root.containsKey(name)) {
        throw TomlError('line $number: [$name] is defined twice');
      }
      current = <String, Object?>{};
      root[name] = current;
      continue;
    }
    final equals = line.indexOf('=');
    if (equals < 0) throw TomlError('line $number: expected key = value');
    final key = _key(line.substring(0, equals).trim(), number);
    var rest = line.substring(equals + 1).trim();
    // An array may run over several lines: read until its brackets close.
    while (rest.startsWith('[') && !_closed(rest)) {
      index++;
      if (index >= lines.length) {
        throw TomlError('line $number: an array that never closes');
      }
      rest = '$rest\n${lines[index]}';
    }
    final reader = _Reader(rest, number);
    final value = reader.value();
    reader.end();
    if (current.containsKey(key)) {
      throw TomlError('line $number: $key is set twice');
    }
    current[key] = value;
  }
  return root;
}

void _checkRest(String rest, int number) {
  final trimmed = rest.trim();
  if (trimmed.isNotEmpty && !trimmed.startsWith('#')) {
    throw TomlError('line $number: unexpected $trimmed');
  }
}

String _key(String raw, int number) {
  if (raw.startsWith('"') || raw.startsWith("'")) {
    final reader = _Reader(raw, number);
    final key = reader.value();
    reader.end();
    if (key is String) return key;
  }
  if (RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(raw)) return raw;
  throw TomlError('line $number: $raw is not a key');
}

/// Whether the brackets of an array opened at the start are closed, outside
/// strings and comments.
bool _closed(String text) {
  var depth = 0;
  String? quote;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (quote != null) {
      if (c == '\\' && quote == '"') {
        i++;
      } else if (c == quote) {
        quote = null;
      }
      continue;
    }
    if (c == '"' || c == "'") {
      quote = c;
    } else if (c == '#') {
      final newline = text.indexOf('\n', i);
      if (newline < 0) return false;
      i = newline;
    } else if (c == '[') {
      depth++;
    } else if (c == ']') {
      depth--;
      if (depth == 0) return true;
    }
  }
  return false;
}

class _Reader {
  _Reader(this.text, this.line);
  final String text;
  final int line;
  var at = 0;

  Never fail(String what) => throw TomlError('line $line: $what');

  void blank() {
    while (at < text.length) {
      final c = text[at];
      if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
        at++;
      } else if (c == '#') {
        final newline = text.indexOf('\n', at);
        at = newline < 0 ? text.length : newline;
      } else {
        break;
      }
    }
  }

  void end() {
    blank();
    if (at < text.length) fail('unexpected ${text.substring(at).trim()}');
  }

  Object value() {
    blank();
    if (at >= text.length) fail('a value is missing');
    final c = text[at];
    if (c == '"') return basic();
    if (c == "'") return literal();
    if (c == '[') return array();
    final match = RegExp(r'[A-Za-z0-9_+.-]+').matchAsPrefix(text, at);
    if (match == null) fail('cannot read ${text.substring(at)}');
    at = match.end;
    final word = match.group(0)!;
    if (word == 'true') return true;
    if (word == 'false') return false;
    final number = int.tryParse(word.replaceAll('_', ''));
    if (number == null) fail('$word is not a string, number or boolean');
    return number;
  }

  String literal() {
    final end = text.indexOf("'", at + 1);
    if (end < 0) fail("a ' string that never ends");
    final value = text.substring(at + 1, end);
    if (value.contains('\n')) fail('a string runs over the end of the line');
    at = end + 1;
    return value;
  }

  String basic() {
    final out = StringBuffer();
    at++;
    while (true) {
      if (at >= text.length || text[at] == '\n') {
        fail('a " string that never ends');
      }
      final c = text[at];
      if (c == '"') {
        at++;
        return out.toString();
      }
      if (c != '\\') {
        out.write(c);
        at++;
        continue;
      }
      if (at + 1 >= text.length) fail('a \\ at the end of a string');
      final escape = text[at + 1];
      at += 2;
      switch (escape) {
        case '"':
        case '\\':
          out.write(escape);
        case 'n':
          out.write('\n');
        case 't':
          out.write('\t');
        case 'r':
          out.write('\r');
        case 'u':
        case 'U':
          final length = escape == 'u' ? 4 : 8;
          if (at + length > text.length) fail('a short \\$escape escape');
          final code = int.tryParse(text.substring(at, at + length), radix: 16);
          if (code == null) fail('a \\$escape escape that is not hex');
          out.writeCharCode(code);
          at += length;
        default:
          fail('unknown escape \\$escape');
      }
    }
  }

  List<Object> array() {
    at++;
    final items = <Object>[];
    while (true) {
      blank();
      if (at >= text.length) fail('an array that never closes');
      if (text[at] == ']') {
        at++;
        return items;
      }
      items.add(value());
      blank();
      if (at < text.length && text[at] == ',') {
        at++;
      } else if (at >= text.length || text[at] != ']') {
        fail('expected , or ] in an array');
      }
    }
  }
}

/// A TOML basic string for [value].
String tomlString(String value) {
  final out = StringBuffer('"');
  for (final rune in value.runes) {
    switch (rune) {
      case 0x22:
        out.write(r'\"');
      case 0x5c:
        out.write(r'\\');
      case 0x0a:
        out.write(r'\n');
      case 0x09:
        out.write(r'\t');
      case 0x0d:
        out.write(r'\r');
      default:
        if (rune < 0x20 || rune == 0x7f) {
          out.write('\\u${rune.toRadixString(16).padLeft(4, '0')}');
        } else {
          out.writeCharCode(rune);
        }
    }
  }
  out.write('"');
  return out.toString();
}

/// `key = value` for a string, a number, a boolean or a list of those.
String tomlLine(String key, Object value) {
  final name = RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(key)
      ? key
      : tomlString(key);
  return '$name = ${_tomlValue(value)}';
}

String _tomlValue(Object value) => switch (value) {
  String text => tomlString(text),
  bool flag => '$flag',
  int number => '$number',
  List<Object?> items => '[${items.map((i) => _tomlValue(i!)).join(', ')}]',
  _ => throw ArgumentError('cannot write $value as TOML'),
};

/// Reads a list of strings from a parsed value, or refuses it.
List<String> tomlStrings(Object? value, String what) {
  if (value == null) return [];
  if (value is List && value.every((item) => item is String)) {
    return value.cast<String>();
  }
  throw TomlError('$what should be a list of strings');
}

/// Reads a string from a parsed value, or refuses it.
String tomlText(Object? value, String what) {
  if (value == null) return '';
  if (value is String) return value;
  throw TomlError('$what should be a string');
}
