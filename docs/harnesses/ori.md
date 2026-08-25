# Ori Launcher and Adapter

## Role

Ori is the local OpenRouter launcher, credential resolver, and harness adapter.
It is not a separate agent runtime or an independent model picker in this
setup. The underlying harness still owns the UI, sessions, tools, provider
protocol, and model behavior.

Think of Ori as:

```text
OpenRouter credential + launch overrides + harness-specific adapter
  -> codex, grok, opencode, pi, or another supported harness
```

## Files

- `$HOME/.ori/config.json` — Ori channel and feature settings.
- `$HOME/.ori/credentials.json` — sensitive global credential vault; never
  print it.
- `$HOME/.ori/pi/openrouter-auth.ts` — generated Pi adapter extension.
- `$HOME/.ori/pi-agent/settings.json` — Ori-managed Pi settings, including the
  enabled model IDs.
- `$HOME/.ori/pi-agent/models.json` — Ori-managed Pi provider metadata.

## Supported local launch paths

The installed Ori CLI exposes launchers for `codex`, `grok`, `opencode`, and
`pi`, among others. The local harness inventory did not find standalone
`claude`, `hermes`, `prime-agent`, or `dsh` binaries at the snapshot date.

The official Ori-supported runtime list is Claude Code, Codex, Grok Build,
Hermes, OpenCode, Pi, Prime Agent, and DeepSeek Harness. The local machine
currently has Codex, Grok Build, OpenCode, and Pi available. A supported Ori
launcher is not automatically an accepted client for every provider's free
route; Inkling currently accepts the tested Pi, Codex, and OpenCode identities
but returns `HTTP 403` on the Grok request path.

Everything after Ori's own flags is passed to the underlying harness. The
common options include `--model`, `--reasoning-effort`, and
`--global-auth`/`--no-global-auth`, depending on the target.

## Per-harness behavior

| Command | What Ori injects | Model restriction |
| --- | --- | --- |
| `ori codex` | Temporary Codex `-c` provider settings and OpenRouter auth environment | Pass one of the three IDs explicitly; Ori does not inject the direct Codex catalog profile |
| `ori grok` | OpenRouter credential and Grok launch environment | Catalog lists the three aliases; Ox works, Inkling currently returns `HTTP 403` |
| `ori opencode` | OpenRouter credential and launch environment | OpenCode's local provider whitelist remains the authority |
| `ori pi` | Generated Pi extension plus the late static overlay | Exactly the three IDs after the overlay |

Use the target's page for exact paths and maintenance rules. Never assume that
a change to direct harness configuration automatically changes its Ori path.

## Credential flow

Ori resolves an OpenRouter credential from its supported environment/vault
sources and supplies it to the child harness. Diagnostic output may identify a
credential source, but no command should print the key itself. The child
harness still decides how to read the environment or command-backed provider.

## Why Pi is special

Ori's generated Pi extension can fetch a broad user model catalog. The local
Pi wrapper appends `$HOME/.pi/agent/ori-openrouter-free-models.ts` after that
generated extension so the static three-model provider wins. This ordering
constraint does not apply to the other local launchers in the same way.

## Verification

```bash
ori --version
ori pi --list-models
ori grok models
ori opencode models openrouter
ori harness-doctor codex
ori harness-doctor pi
```

The `ori pi` and `ori opencode` scoped lists should contain only the three
requested IDs. `ori harness-doctor codex` has zero conflicts and one expected
warning about intentional provider headers. The Pi doctor may warn that it
cannot infer a version through the local `pi` wrapper even though the
underlying Pi version and runtime behavior are healthy.

## Maintenance

When adding or changing a harness, document both direct and Ori-mediated
launches. Record whether Ori passes flags, environment variables, generated
extensions, or provider config. Do not describe Ori as an eighth/ninth model
provider; it is the layer that adapts OpenRouter to the underlying runtime.
