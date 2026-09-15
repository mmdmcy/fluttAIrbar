import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/codex_shortcut.dart';
import 'harness_config.dart';

class CodexShortcutInstaller {
  CodexShortcutInstaller({
    HarnessEnvironment? environment,
    String? shell,
    String? currentPath,
    bool? supported,
  }) : _environment = environment ?? HarnessEnvironment.system(),
       _shell = shell ?? Platform.environment['SHELL'],
       _currentPath = currentPath ?? Platform.environment['PATH'],
       _supported = supported ?? (Platform.isLinux || Platform.isMacOS);

  static const _pathStart = '# >>> fluttAIrbar Codex shortcuts PATH >>>';
  static const _pathEnd = '# <<< fluttAIrbar Codex shortcuts PATH <<<';

  final HarnessEnvironment _environment;
  final String? _shell;
  final String? _currentPath;
  final bool _supported;

  String get installDirectory => p.join(_environment.home, '.local', 'bin');

  CodexShortcutStatus inspect() {
    final directory = installDirectory;
    final pathConfigPath = _pathConfigPath;
    if (!_supported || _environment.home.isEmpty) {
      return CodexShortcutStatus(
        supported: false,
        installDirectory: directory,
        pathConfigPath: pathConfigPath,
        pathAvailable: false,
        pathConfigured: false,
        files: const [],
        error: 'Codex shortcuts are supported on macOS and Linux only.',
      );
    }

    final pathAvailable = _pathContains(directory, _currentPath);
    final pathConfigured = pathAvailable || _configContainsPath(pathConfigPath);
    return CodexShortcutStatus(
      supported: true,
      installDirectory: directory,
      pathConfigPath: pathConfigPath,
      pathAvailable: pathAvailable,
      pathConfigured: pathConfigured,
      files: _fileStatuses(directory),
    );
  }

  Future<CodexShortcutOperationResult> install() async {
    final before = inspect();
    if (!before.supported) {
      return CodexShortcutOperationResult(
        ok: false,
        message: before.error ?? 'This platform is not supported.',
        status: before,
      );
    }
    if (before.hasConflicts) {
      final names = before.files
          .where((file) => file.conflict)
          .map((file) => file.definition.name)
          .join(', ');
      return CodexShortcutOperationResult(
        ok: false,
        message:
            'Refusing to replace existing files: $names. Move them first, '
            'then try again.',
        status: before,
      );
    }

    try {
      Directory(installDirectory).createSync(recursive: true);
      for (final definition in codexShortcutDefinitions) {
        _writeShortcut(definition);
      }
      _ensurePathConfigured();
      final after = inspect();
      if (!after.allInstalled || !after.pathConfigured) {
        return CodexShortcutOperationResult(
          ok: false,
          message:
              'The shortcuts were written, but PATH could not be verified.',
          status: after,
        );
      }
      return CodexShortcutOperationResult(
        ok: true,
        message: after.pathAvailable
            ? 'Codex shortcuts installed and ready.'
            : 'Codex shortcuts installed. Open a new terminal to load PATH.',
        status: after,
      );
    } on Object catch (error) {
      final after = inspect();
      return CodexShortcutOperationResult(
        ok: false,
        message: 'Could not install Codex shortcuts: $error',
        status: after,
      );
    }
  }

  Future<CodexShortcutOperationResult> uninstall() async {
    final before = inspect();
    if (!before.supported) {
      return CodexShortcutOperationResult(
        ok: false,
        message: before.error ?? 'This platform is not supported.',
        status: before,
      );
    }
    if (before.hasConflicts) {
      final names = before.files
          .where((file) => file.conflict)
          .map((file) => file.definition.name)
          .join(', ');
      return CodexShortcutOperationResult(
        ok: false,
        message:
            'Refusing to remove files not installed by fluttAIrbar: $names.',
        status: before,
      );
    }

    try {
      for (final file in before.files.where((file) => file.installed)) {
        _deleteShortcut(file);
      }
      _removePathBlock();
      return CodexShortcutOperationResult(
        ok: true,
        message: 'Codex shortcuts removed.',
        status: inspect(),
      );
    } on Object catch (error) {
      return CodexShortcutOperationResult(
        ok: false,
        message: 'Could not remove Codex shortcuts: $error',
        status: inspect(),
      );
    }
  }

  List<CodexShortcutFileStatus> _fileStatuses(String directory) {
    return [
      for (final definition in codexShortcutDefinitions)
        _fileStatus(definition, p.join(directory, definition.name)),
    ];
  }

  CodexShortcutFileStatus _fileStatus(
    CodexShortcutDefinition definition,
    String path,
  ) {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      return CodexShortcutFileStatus(
        definition: definition,
        path: path,
        state: CodexShortcutFileState.missing,
      );
    }
    if (type != FileSystemEntityType.file) {
      return CodexShortcutFileStatus(
        definition: definition,
        path: path,
        state: CodexShortcutFileState.conflict,
      );
    }
    try {
      final file = File(path);
      final contents = file.readAsStringSync();
      final state = contents == definition.scriptContents()
          ? CodexShortcutFileState.installed
          : CodexShortcutFileState.conflict;
      return CodexShortcutFileStatus(
        definition: definition,
        path: path,
        state: state,
      );
    } on Object catch (_) {
      return CodexShortcutFileStatus(
        definition: definition,
        path: path,
        state: CodexShortcutFileState.conflict,
      );
    }
  }

  void _writeShortcut(CodexShortcutDefinition definition) {
    final file = File(p.join(installDirectory, definition.name));
    final contents = definition.scriptContents();
    _assertShortcutTarget(definition, file, contents);

    final temporaryDirectory = Directory(
      installDirectory,
    ).createTempSync('.fluttairbar-codex-shortcut-');
    final temporaryFile = File(
      p.join(temporaryDirectory.path, definition.name),
    );
    try {
      temporaryFile.writeAsStringSync(contents, flush: true);
      final result = Process.runSync('/bin/chmod', [
        '0755',
        temporaryFile.path,
      ], runInShell: false);
      if (result.exitCode != 0) {
        throw StateError('Could not make ${definition.name} executable.');
      }

      // Re-check immediately before the rename so a file appearing after the
      // initial inspect is treated as a conflict instead of being replaced.
      _assertShortcutTarget(definition, file, contents);
      temporaryFile.renameSync(file.path);
    } finally {
      _deleteTemporaryFile(temporaryFile, temporaryDirectory);
    }
  }

  void _deleteShortcut(CodexShortcutFileStatus status) {
    final file = File(status.path);
    final type = FileSystemEntity.typeSync(file.path, followLinks: false);
    if (type != FileSystemEntityType.file) {
      throw StateError(
        'Refusing to remove ${status.definition.name}: it is no longer a file.',
      );
    }
    if (file.readAsStringSync() != status.definition.scriptContents()) {
      throw StateError(
        'Refusing to remove ${status.definition.name}: its contents changed.',
      );
    }
    file.deleteSync();
  }

  void _assertShortcutTarget(
    CodexShortcutDefinition definition,
    File file,
    String expectedContents,
  ) {
    final type = FileSystemEntity.typeSync(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    if (type != FileSystemEntityType.file) {
      throw StateError('${definition.name} is not a regular file.');
    }
    if (file.readAsStringSync() != expectedContents) {
      throw StateError(
        'Refusing to replace ${definition.name}: its contents are not managed '
        'by fluttAIrbar.',
      );
    }
  }

  void _deleteTemporaryFile(File file, Directory directory) {
    try {
      if (FileSystemEntity.typeSync(file.path, followLinks: false) ==
          FileSystemEntityType.file) {
        file.deleteSync();
      }
    } on Object catch (_) {}
    try {
      if (FileSystemEntity.typeSync(directory.path, followLinks: false) ==
          FileSystemEntityType.directory) {
        directory.deleteSync();
      }
    } on Object catch (_) {}
  }

  void _ensurePathConfigured() {
    if (_pathContains(installDirectory, _currentPath) ||
        _configContainsPath(_pathConfigPath)) {
      return;
    }
    _assertRegularConfigFile(_pathConfigPath);
    final file = File(_pathConfigPath);
    final original = file.existsSync() ? file.readAsStringSync() : '';
    final updated = _insertPathBlock(original);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(updated, flush: true);
  }

  void _removePathBlock() {
    final file = File(_pathConfigPath);
    if (!file.existsSync()) return;
    final original = file.readAsStringSync();
    final updated = _removeManagedBlock(original);
    if (updated == original) return;
    _assertRegularConfigFile(_pathConfigPath);
    file.writeAsStringSync(updated, flush: true);
  }

  bool _pathContains(String directory, String? pathValue) {
    if (pathValue == null || pathValue.isEmpty) return false;
    return pathValue.split(':').any((entry) {
      if (entry.isEmpty) return false;
      return p.normalize(entry) == p.normalize(directory);
    });
  }

  bool _configContainsPath(String path) {
    final file = File(path);
    if (!file.existsSync()) return false;
    try {
      final contents = file.readAsStringSync();
      return contents.contains('\$HOME/.local/bin') ||
          contents.contains('~/.local/bin');
    } on Object catch (_) {
      return false;
    }
  }

  void _assertRegularConfigFile(String path) {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.file) {
      throw StateError('$path is not a regular shell configuration file.');
    }
  }

  String _insertPathBlock(String contents) {
    final block = _pathBlock;
    if (contents.isEmpty) return block;
    final separator = contents.endsWith('\n') ? '' : '\n';
    return '$contents$separator$block';
  }

  String _removeManagedBlock(String contents) {
    final pattern = RegExp(
      '${RegExp.escape(_pathStart)}\\n.*?'
      '${RegExp.escape(_pathEnd)}\\n?',
      multiLine: true,
      dotAll: true,
    );
    return contents.replaceFirst(pattern, '');
  }

  String get _pathBlock {
    if (_shellName == 'fish') {
      return '$_pathStart\n'
          'set -gx PATH \u0024HOME/.local/bin \u0024PATH\n'
          '$_pathEnd\n';
    }
    return '$_pathStart\n'
        'export PATH="\u0024HOME/.local/bin:\u0024PATH"\n'
        '$_pathEnd\n';
  }

  String _pathConfigPathForShell(String shellName) {
    if (shellName == 'zsh') {
      return p.join(_environment.home, '.zshrc');
    }
    if (shellName == 'fish') {
      return p.join(_environment.home, '.config', 'fish', 'config.fish');
    }
    if (shellName == 'bash') {
      if (_environment.isMacOS) {
        return p.join(_environment.home, '.bash_profile');
      }
      final bashrc = File(p.join(_environment.home, '.bashrc'));
      if (bashrc.existsSync()) return bashrc.path;
      return p.join(_environment.home, '.bash_profile');
    }
    return p.join(_environment.home, '.profile');
  }

  String get _shellName {
    final shell = _shell;
    final configured = shell == null || shell.isEmpty
        ? null
        : p.basename(shell);
    switch (configured) {
      case 'bash':
        return 'bash';
      case 'zsh':
        return 'zsh';
      case 'fish':
        return 'fish';
    }
    if (_environment.isMacOS) return 'zsh';
    return 'bash';
  }

  String get _pathConfigPath => _pathConfigPathForShell(_shellName);
}
