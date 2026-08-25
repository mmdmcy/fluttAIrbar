# ZCode

## Role

ZCode is the Z.AI-focused desktop/CLI agent. Its configured provider family is
Z.AI, not OpenRouter, so the OpenRouter allowlist does not apply.

## Files

- `$HOME/.zcode/cli/config.json` — CLI provider and model configuration.
- `$HOME/.zcode/v2/config.json` — desktop/runtime provider definitions.
- `$HOME/.zcode/v2/setting.json` — selected provider family and UI settings.
- `$HOME/.local/share/zcode` — installed ZCode runtime data.

## Current provider

The CLI configuration uses the Z.AI Anthropic-compatible endpoint and currently
defines:

```text
zai/glm-5.1
zai/glm-4.7
```

The runtime settings select the Z.AI provider family. No Ox Alpha or Inkling
OpenRouter model is configured in the active ZCode files.

## Verification

ZCode is primarily desktop-oriented, so its CLI version/model output is less
useful than inspecting the active non-secret configuration:

```bash
zcode --version
jq -r '.provider.zai.models | keys[]' "$HOME/.zcode/cli/config.json"
jq -r '.modelProviderFamilyModes, .modelProviderFamilySelectedKeys' \
  "$HOME/.zcode/v2/setting.json"
```

Expected model IDs are the two Z.AI entries above. Do not use ZCode's provider
files as an OpenRouter configuration template.

## Maintenance

Keep ZCode updates and Z.AI authentication separate from Ori/OpenRouter work.
If ZCode gains a supported OpenRouter provider in a future release, create a
new harness-specific section and verify it independently before adding it to
the shared allowlist.
