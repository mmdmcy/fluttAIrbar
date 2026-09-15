enum CodexShortcutFileState { missing, installed, conflict }

class CodexShortcutDefinition {
  const CodexShortcutDefinition({
    required this.name,
    required this.arguments,
    required this.description,
  });

  final String name;
  final List<String> arguments;
  final String description;

  String get commandPreview => 'codex ${arguments.join(' ')}';

  String scriptContents() {
    final marker = '# fluttairbar-codex-shortcut: $name:v1';
    final quotedArguments = arguments.map(_quoteForShell).join(' ');
    return '#!/bin/sh\n'
        '$marker\n'
        '# Managed by fluttAIrbar. Use Settings to update this file.\n'
        'exec codex $quotedArguments "\$@"\n';
  }

  String _quoteForShell(String value) {
    if (value.isEmpty) return "''";
    return "'${value.replaceAll("'", "'\"'\"'")}'";
  }
}

const codexShortcutDefinitions = <CodexShortcutDefinition>[
  CodexShortcutDefinition(
    name: 'codexunsafe',
    arguments: ['--dangerously-bypass-approvals-and-sandbox'],
    description: 'Start Codex with approvals and sandboxing bypassed.',
  ),
  CodexShortcutDefinition(
    name: 'codexunsaferesume',
    arguments: [
      '--dangerously-bypass-approvals-and-sandbox',
      'resume',
      '--all',
      '--no-alt-screen',
    ],
    description:
        'Resume Codex across all saved sessions without the alt screen.',
  ),
];

class CodexShortcutFileStatus {
  const CodexShortcutFileStatus({
    required this.definition,
    required this.path,
    required this.state,
  });

  final CodexShortcutDefinition definition;
  final String path;
  final CodexShortcutFileState state;

  bool get installed => state == CodexShortcutFileState.installed;
  bool get conflict => state == CodexShortcutFileState.conflict;
}

class CodexShortcutStatus {
  const CodexShortcutStatus({
    required this.supported,
    required this.installDirectory,
    required this.pathConfigPath,
    required this.pathAvailable,
    required this.pathConfigured,
    required this.files,
    this.error,
  });

  final bool supported;
  final String installDirectory;
  final String pathConfigPath;
  final bool pathAvailable;
  final bool pathConfigured;
  final List<CodexShortcutFileStatus> files;
  final String? error;

  bool get allInstalled =>
      supported && files.isNotEmpty && files.every((file) => file.installed);

  bool get hasConflicts => files.any((file) => file.conflict);

  bool get ready => allInstalled && pathConfigured;
}

class CodexShortcutOperationResult {
  const CodexShortcutOperationResult({
    required this.ok,
    required this.message,
    required this.status,
  });

  final bool ok;
  final String message;
  final CodexShortcutStatus status;
}
