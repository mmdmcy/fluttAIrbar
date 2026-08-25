# Harness Context Dump

## Executive summary

The local setup has several AI harnesses and one important adapter layer:

- A **harness** is the agent runtime that owns the terminal UI, tools, model
  protocol, and session behavior.
- **Ori is not a separate agent runtime in this setup.** It is a launcher and
  adapter that resolves OpenRouter credentials, injects provider settings, and
  starts another harness. `ori pi` means “run Pi through Ori”; it does not mean
  “select an Ori model.”
- The three OpenRouter models currently allowed are `stealth/ox-alpha`,
  `thinkingmachines/inkling-small:free`, and `thinkingmachines/inkling:free`.
- Direct Codex remains native OpenAI-first. Its OpenRouter catalog is opt-in
  through a profile rather than being part of the default Codex configuration.

## Installed harness map

| Program | Runtime role | OpenRouter relationship | Effective model-list check |
| --- | --- | --- | --- |
| `codex` | Native OpenAI/Codex agent | Three-model catalog only in the `openrouter-free` profile | `codex` default is native; inspect the profile catalog |
| `pi` | Coding-agent runtime | Direct configuration exposes the three-model allowlist | `pi --list-models` |
| `grok` | Grok Build agent | Direct config exposes three OpenRouter aliases alongside native Grok entries; Inkling requests are currently blocked on the Grok client path | `grok models` |
| `opencode` | Multi-provider agent runtime | The OpenRouter provider is whitelisted to the three IDs | `opencode models openrouter` |
| `cursor-agent` | Cursor first-party agent | Does not use the local OpenRouter configuration | `cursor-agent --list-models` |
| `fx` | Vercel Labs agent using AI Gateway | Uses its own broad gateway catalog | `fx models` |
| `zcode` | Z.AI desktop/CLI agent | Uses Z.AI directly; no OpenRouter entry | inspect ZCode config |
| `ori` | Launcher/adapter/auth layer | Starts supported runtimes with OpenRouter settings | `ori <harness> ...` |

Ori currently exposes launcher commands for `codex`, `grok`, `opencode`, and
`pi` among others. `claude`, `hermes`, `prime-agent`, and `dsh` are Ori
capabilities but were not installed on this machine during the snapshot.

## Version snapshot

These versions were observed on 2026-08-22:

| Program | Version |
| --- | --- |
| `codex` | `0.149.0` |
| `pi` | `0.84.2` |
| `grok` | `1.0.5` |
| `opencode` | `1.18.21` |
| `cursor-agent` | `2026.08.11-e8db854` |
| `fx` | `0.0.5` |
| `ori` | `0.8.0+3511459` |
| `zcode` | GUI-oriented; CLI version output is not reliable in this setup |

## Configuration flow

There are two different paths and they must not be conflated:

```text
direct harness
  └─ reads its own config and credential store

ori <harness>
  └─ Ori resolves OpenRouter auth and injects flags/env/extensions
       └─ the underlying harness still owns the UI and model handling
```

The same model ID can therefore be visible through different mechanisms:

- Pi receives a generated Ori extension and needs a later static overlay to
  replace the generated dynamic OpenRouter provider.
- Codex receives temporary `-c` provider overrides from `ori codex`; this is
  different from the direct `codex --profile openrouter-free` path.
- Grok and OpenCode retain their own configuration semantics while Ori supplies
  the OpenRouter credential and launch environment.

## Model policy

The intended policy is **OpenRouter-only restriction, native-provider
preservation**:

1. Keep direct Codex's native OpenAI provider and model order intact.
2. Keep only the three requested IDs in OpenRouter-specific catalogs.
3. Do not edit vendor caches just to hide models; control the effective provider
   configuration instead.
4. Do not force Cursor, fx, or ZCode to pretend they are OpenRouter clients.

The public OpenRouter model catalog was checked on the snapshot date and
reported zero prompt and completion pricing for all three requested IDs. This
confirms current catalog metadata, not a permanent availability guarantee.

## Approved harness versus accepted client identity

OpenRouter's official [Ori Harness guide](https://openrouter.ai/docs/guides/ori/harness)
lists Claude Code, Codex, Grok Build, Hermes, OpenCode, Pi, Prime Agent, and
DeepSeek Harness as supported runtimes. “Approved agentic harness” in the
context of an Inkling `403` means a real tool-using agent runtime whose client
identity the provider currently accepts; it does not mean that Ori itself is
a model provider, nor that every Ori-supported runtime is accepted by every
free endpoint.

The following is the verified request matrix from 2026-08-22. A catalog check
only proves that a model was registered locally; the request column is the
important authorization check:

| Path | Ox Alpha | Inkling Small `:free` | Inkling `:free` |
| --- | --- | --- | --- |
| Direct Pi | `200` | `200` | `200` |
| `ori pi` | `200` | `200` | `200` |
| Codex OpenRouter profile | `200` | `200` | `200` |
| `ori codex` | `200` | `200` | `200` |
| Direct OpenCode | `200` | `200` | `200` |
| `ori opencode` | `200` | `200` | `200` |
| `ori grok` request | `200` | `403` | `403` |

`grok models` and `ori grok models` still list the three local aliases. Those
aliases are catalog-only for Inkling on the current Grok route; changing the
alias or local model list cannot fix an upstream client-identity restriction.
Use Pi, Codex, or OpenCode for the Inkling routes until OpenRouter accepts the
Grok identity. The generic Ori attribution was also rejected for Inkling, so
“through Ori” alone is not the approval condition.

This explains apparently different outputs. For example, `opencode models`
lists OpenCode's built-in provider and native OpenAI models as well as the
three OpenRouter entries; `opencode models openrouter` is the relevant scoped
check. Likewise, direct `grok models` keeps native Grok models, while
`ori grok models` is an OpenRouter-routed view.

## Why the Pi shim exists

Ori generates `$HOME/.ori/pi/openrouter-auth.ts`. That extension can refresh a
large OpenRouter user catalog. Direct Pi has a static allowlist, but the
generated Ori extension is loaded later and can replace it.

The local fix has three parts:

1. `$HOME/.pi/agent/extensions/openrouter-free-models.ts` unregisters the
   broad provider set and registers only the three requested models.
2. `$HOME/.pi/agent/ori-openrouter-free-models.ts` re-exports that extension so
   it can be loaded after Ori's generated extension.
3. `$HOME/.local/bin/pi` is a guarded wrapper. It invokes the preserved
   `$HOME/.local/bin/pi-real` target and appends the late overlay only when Ori
   passes `$HOME/.ori/pi/openrouter-auth.ts`.

The wrapper is intentionally conditional: direct Pi does not receive an Ori
extension, while `ori pi` gets the override after Ori's dynamic registration.

## Verification performed

The following checks passed at the snapshot date:

```bash
pi --list-models
ori pi --list-models
opencode models openrouter
ori opencode models openrouter
grok models
ori grok models
jq -r '.models[].slug' "$HOME/.codex/models_openrouter_free.json"
ori harness-doctor codex
```

The four Pi/OpenCode scoped checks and the Codex catalog return only the three
IDs. Direct Grok returns the three aliases plus its native Grok models, and
`ori grok` returns the three OpenRouter-routed aliases; the request matrix
above records which of those aliases actually responds.

## Known non-model findings

- `ori harness-doctor codex` reports zero conflicts and one expected warning
  about intentional OpenRouter provider headers.
- `ori harness-doctor pi` reports one warning only because it cannot infer a
  package version through the local wrapper. `pi --version` returns `0.84.2`,
  and the same doctor reports zero warnings when the underlying Pi symlink is
  first on `PATH`.
- `grok doctor` reports terminal capability recommendations, not an
  OpenRouter model error.
- `fx doctor` reports an expired refreshable `fx login` session. That is an fx
  authentication issue and is unrelated to the OpenRouter allowlist.

## Change protocol for future agents

Before changing model configuration:

1. Identify whether the command is direct or `ori <harness>`.
2. Read the harness-specific page and inspect only non-secret config fields.
3. Check the scoped model list before editing anything.
4. Change the provider's effective configuration, not a vendor cache, unless
   the harness explicitly requires a cache file.
5. Verify both direct and Ori paths when both are supported.
6. Record new paths, generated files, ordering constraints, and warnings here
   and in the relevant harness page.
