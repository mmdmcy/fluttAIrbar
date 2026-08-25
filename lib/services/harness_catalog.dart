import '../models/harness.dart';

class HarnessCatalog {
  const HarnessCatalog._();

  static List<HarnessDefinition> get definitions => const [
    HarnessDefinition(
      id: 'pi',
      displayName: 'Pi coding agent',
      executable: 'pi',
      versionArgs: ['--version'],
      updateArgs: ['update', '--self'],
      updateSource: HarnessUpdateSource.npm,
      npmPackages: [
        '@earendil-works/pi-coding-agent',
        '@mariozechner/pi-coding-agent',
      ],
      configs: [
        HarnessConfigSpec(
          label: 'Settings',
          pathTemplate: '{piDir}/settings.json',
        ),
        HarnessConfigSpec(
          label: 'Model catalog',
          pathTemplate: '{piDir}/models.json',
        ),
        HarnessConfigSpec(
          label: 'Credentials',
          pathTemplate: '{piDir}/auth.json',
          sensitive: true,
        ),
      ],
      description:
          'OpenRouter/provider and model settings live in Pi settings.',
    ),
    HarnessDefinition(
      id: 'codex',
      displayName: 'Codex CLI',
      executable: 'codex',
      versionArgs: ['--version'],
      updateArgs: ['update'],
      updateSource: HarnessUpdateSource.npm,
      npmPackage: '@openai/codex',
      configs: [
        HarnessConfigSpec(
          label: 'Settings',
          pathTemplate: '{codexHome}/config.toml',
        ),
        HarnessConfigSpec(
          label: 'Credentials',
          pathTemplate: '{codexHome}/auth.json',
          sensitive: true,
        ),
      ],
      description:
          'Codex uses config.toml for model, sandbox, and MCP settings.',
      updateWithNpmGlobal: true,
    ),
    HarnessDefinition(
      id: 'grok',
      displayName: 'Grok Build',
      executable: 'grok',
      versionArgs: ['--version'],
      updateArgs: ['update', '--stable'],
      checkArgs: ['update', '--check', '--json'],
      updateSource: HarnessUpdateSource.officialChannel,
      configs: [
        HarnessConfigSpec(label: 'Settings', pathTemplate: '{grokConfigPath}'),
        HarnessConfigSpec(
          label: 'Default settings',
          pathTemplate: '{home}/.grok/config.toml',
        ),
        HarnessConfigSpec(
          label: 'Credentials',
          pathTemplate: '{home}/.grok/auth.json',
          sensitive: true,
        ),
      ],
      description:
          'Grok Build reads config.toml and can route models through OpenRouter.',
    ),
    HarnessDefinition(
      id: 'cursor-agent',
      displayName: 'Cursor Agent',
      executable: 'cursor-agent',
      versionArgs: ['--version'],
      updateArgs: ['update'],
      updateSource: HarnessUpdateSource.officialChannel,
      configs: [
        HarnessConfigSpec(
          label: 'CLI settings',
          pathTemplate: '{home}/.cursor/cli-config.json',
        ),
        HarnessConfigSpec(
          label: 'Credentials',
          pathTemplate: '{configHome}/cursor/auth.json',
          sensitive: true,
        ),
        HarnessConfigSpec(
          label: 'App state',
          pathTemplate: '{configHome}/Cursor/User/globalStorage/state.vscdb',
          sensitive: true,
        ),
      ],
      description:
          'Cursor Agent keeps CLI preferences separate from app credentials.',
      supportsUpdate: false,
    ),
    HarnessDefinition(
      id: 'opencode',
      displayName: 'OpenCode',
      executable: 'opencode',
      versionArgs: ['--version'],
      updateArgs: ['upgrade'],
      updateSource: HarnessUpdateSource.npm,
      npmPackage: 'opencode-ai',
      configs: [
        HarnessConfigSpec(
          label: 'Settings',
          pathTemplate: '{configHome}/opencode/opencode.json',
        ),
        HarnessConfigSpec(
          label: 'Package plugins',
          pathTemplate: '{configHome}/opencode/package.json',
        ),
        HarnessConfigSpec(
          label: 'Credentials',
          pathTemplate: '{dataHome}/opencode/auth.json',
          sensitive: true,
        ),
      ],
      description:
          'OpenCode provider/model configuration lives in opencode.json.',
      updatePackageInPlace: true,
    ),
    HarnessDefinition(
      id: 'fx',
      displayName: 'fx (Vercel Labs)',
      executable: 'fx',
      versionArgs: ['--version'],
      updateArgs: ['upgrade', '--channel', 'stable'],
      updateSource: HarnessUpdateSource.githubRelease,
      releaseRepository: 'vercel-labs/fx',
      configs: [
        HarnessConfigSpec(
          label: 'Settings',
          pathTemplate: '{home}/.fx/settings.json',
        ),
        HarnessConfigSpec(
          label: 'Credentials',
          pathTemplate: '{home}/.fx/auth.json',
          sensitive: true,
        ),
      ],
      description:
          'Vercel Labs fx is a native agent with its own release channel.',
    ),
    HarnessDefinition(
      id: 'ori',
      displayName: 'Ori harness launcher',
      executable: 'ori',
      versionArgs: ['version', '--json'],
      updateArgs: ['update', '--stable'],
      updateSource: HarnessUpdateSource.officialChannel,
      checkArgs: ['update', '--check', '--json'],
      configs: [
        HarnessConfigSpec(
          label: 'Settings',
          pathTemplate: '{home}/.ori/config.json',
        ),
        HarnessConfigSpec(
          label: 'Pi model catalog',
          pathTemplate: '{home}/.ori/pi-agent/models.json',
        ),
        HarnessConfigSpec(
          label: 'Credentials',
          pathTemplate: '{home}/.ori/credentials.json',
          sensitive: true,
        ),
      ],
      description:
          'Ori launches other harnesses with OpenRouter settings and credentials; it is not a standalone agent.',
    ),
    HarnessDefinition(
      id: 'zcode',
      displayName: 'ZCode',
      executable: 'zcode',
      versionArgs: ['--version'],
      updateArgs: [],
      updateSource: HarnessUpdateSource.officialChannel,
      supportsUpdate: false,
      configs: [
        HarnessConfigSpec(
          label: 'CLI settings',
          pathTemplate: '{home}/.zcode/cli/config.json',
        ),
        HarnessConfigSpec(
          label: 'Runtime settings',
          pathTemplate: '{home}/.zcode/v2/config.json',
        ),
      ],
      description:
          'ZCode is configured for Z.AI directly and has no safe built-in updater command.',
    ),
  ];
}
