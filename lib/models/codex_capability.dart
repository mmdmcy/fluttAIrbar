enum CodexCapabilityComponentKind { plugin, mcp }

class CodexCapabilityComponentDefinition {
  const CodexCapabilityComponentDefinition({
    required this.id,
    required this.displayName,
    required this.description,
    required this.kind,
    required this.packId,
    this.pluginName,
    this.mcpServerName,
    this.skillCount = 0,
    this.categorySummary,
  });

  final String id;
  final String displayName;
  final String description;
  final CodexCapabilityComponentKind kind;
  final String packId;
  final String? pluginName;
  final String? mcpServerName;
  final int skillCount;
  final String? categorySummary;
}

class CodexCapabilityPackDefinition {
  const CodexCapabilityPackDefinition({
    required this.id,
    required this.displayName,
    required this.description,
    required this.components,
  });

  final String id;
  final String displayName;
  final String description;
  final List<CodexCapabilityComponentDefinition> components;
}

class CodexCapabilityCatalog {
  const CodexCapabilityCatalog._();

  static const packs = <CodexCapabilityPackDefinition>[
    CodexCapabilityPackDefinition(
      id: 'stripe',
      displayName: 'Stripe',
      description:
          'Stripe skills and the Stripe MCP server. Keep both separate so documentation guidance and live tools can be paused independently.',
      components: [
        CodexCapabilityComponentDefinition(
          id: 'stripe-plugin',
          packId: 'stripe',
          displayName: 'Stripe skills',
          description:
              'Stripe-specific guidance and workflows from the plugin.',
          kind: CodexCapabilityComponentKind.plugin,
          pluginName: 'stripe',
          skillCount: 8,
          categorySummary:
              'Apps, best practices, Connect, docs, projects, upgrades',
        ),
        CodexCapabilityComponentDefinition(
          id: 'stripe-mcp',
          packId: 'stripe',
          displayName: 'Stripe MCP',
          description: 'Stripe documentation, analytics, and API tools.',
          kind: CodexCapabilityComponentKind.mcp,
          mcpServerName: 'stripe',
        ),
      ],
    ),
    CodexCapabilityPackDefinition(
      id: 'pstack',
      displayName: 'pstack for Codex',
      description:
          'The first-party Codex adaptation of pstack. It keeps all 44 skills explicit-only and preserves the original category scheme.',
      components: [
        CodexCapabilityComponentDefinition(
          id: 'pstack-plugin',
          packId: 'pstack',
          displayName: 'pstack skills',
          description: 'Workflow, principle, review, and verification skills.',
          kind: CodexCapabilityComponentKind.plugin,
          pluginName: 'pstack',
          skillCount: 44,
          categorySummary: 'Entry mode, workflows, and five principle groups',
        ),
      ],
    ),
  ];

  static CodexCapabilityPackDefinition pack(String id) {
    return packs.firstWhere((pack) => pack.id == id);
  }
}

class CodexCapabilityComponentStatus {
  const CodexCapabilityComponentStatus({
    required this.definition,
    required this.installed,
    required this.enabled,
    required this.stateKnown,
    this.observedId,
    this.version,
    this.sourcePath,
    this.error,
    this.pendingEnabled,
  });

  final CodexCapabilityComponentDefinition definition;
  final bool installed;
  final bool enabled;
  final bool stateKnown;
  final String? observedId;
  final String? version;
  final String? sourcePath;
  final String? error;
  final bool? pendingEnabled;

  bool get toggleable => installed && stateKnown && observedId != null;

  bool get restartPending => pendingEnabled != null;

  CodexCapabilityComponentStatus withPending(bool? value) {
    return CodexCapabilityComponentStatus(
      definition: definition,
      installed: installed,
      enabled: value ?? enabled,
      stateKnown: stateKnown,
      observedId: observedId,
      version: version,
      sourcePath: sourcePath,
      error: error,
      pendingEnabled: value,
    );
  }
}

class CodexCapabilityPackStatus {
  const CodexCapabilityPackStatus({
    required this.definition,
    required this.components,
  });

  final CodexCapabilityPackDefinition definition;
  final List<CodexCapabilityComponentStatus> components;

  List<CodexCapabilityComponentStatus> get installedComponents =>
      components.where((component) => component.installed).toList();

  List<CodexCapabilityComponentStatus> get toggleableComponents =>
      installedComponents.where((component) => component.toggleable).toList();

  bool get installed => installedComponents.isNotEmpty;

  bool get stateKnown =>
      installedComponents.isNotEmpty &&
      installedComponents.every((component) => component.stateKnown);

  bool get fullyEnabled {
    final installed = installedComponents;
    return installed.isNotEmpty &&
        installed.every((component) => component.enabled);
  }

  bool get mixed {
    final installed = installedComponents;
    return installed.any((component) => component.enabled) &&
        installed.any((component) => !component.enabled);
  }

  int get enabledCount =>
      installedComponents.where((component) => component.enabled).length;

  int get installedCount => installedComponents.length;
}

class CodexCapabilitySnapshot {
  const CodexCapabilitySnapshot({
    required this.packs,
    required this.configPath,
    this.checkedAt,
    this.error,
  });

  factory CodexCapabilitySnapshot.empty({required String configPath}) {
    return CodexCapabilitySnapshot(
      packs: [
        for (final definition in CodexCapabilityCatalog.packs)
          CodexCapabilityPackStatus(
            definition: definition,
            components: [
              for (final component in definition.components)
                CodexCapabilityComponentStatus(
                  definition: component,
                  installed: false,
                  enabled: false,
                  stateKnown: false,
                ),
            ],
          ),
      ],
      configPath: configPath,
    );
  }

  final List<CodexCapabilityPackStatus> packs;
  final String configPath;
  final DateTime? checkedAt;
  final String? error;

  CodexCapabilityPackStatus pack(String id) =>
      packs.firstWhere((pack) => pack.definition.id == id);

  CodexCapabilityComponentStatus component(String id) {
    for (final pack in packs) {
      for (final component in pack.components) {
        if (component.definition.id == id) return component;
      }
    }
    throw StateError('Unknown Codex capability component: $id');
  }
}
