# Codex CLI

## Role

`codex` is the native OpenAI/Codex agent runtime. It owns the Codex TUI,
OpenAI authentication, model picker, tool execution, and session state.

The important preference is that direct Codex stays OpenAI-native first. The
OpenRouter setup is an opt-in profile and must not be merged into the default
configuration.

## Files

The current user-level files are:

- `$CODEX_HOME/config.toml` — default Codex settings; currently
  `$HOME/.codex/config.toml`.
- `$CODEX_HOME/models_cache.json` — Codex's native model cache; do not hand-edit
  it to hide OpenRouter models.
- `$CODEX_HOME/openrouter-free.config.toml` — opt-in OpenRouter profile.
- `$CODEX_HOME/models_openrouter_free.json` — the profile's model catalog.
- `$CODEX_HOME/auth.json` — sensitive native Codex/ChatGPT credentials; never
  print or copy it.

## Default path

`$HOME/.codex/config.toml` intentionally contains:

```toml
model = "gpt-5.6-luna"
model_provider = "openai"
model_reasoning_effort = "max"
```

It also defines an `openrouter` provider using the OpenRouter base URL and a
command-backed credential lookup from Ori's vault. Defining that provider does
not make it the default and does not add a model catalog to native Codex.

## OpenRouter path

The opt-in profile is `$HOME/.codex/openrouter-free.config.toml`:

```toml
model = "stealth/ox-alpha"
model_provider = "openrouter"
model_context_window = 1048576
model_reasoning_effort = "xhigh"
model_catalog_json = "$CODEX_HOME/models_openrouter_free.json"
```

The catalog contains exactly these `models[].slug` values:

```text
stealth/ox-alpha
thinkingmachines/inkling-small:free
thinkingmachines/inkling:free
```

Use the profile explicitly when direct Codex should run through OpenRouter:

```bash
codex --profile openrouter-free
codex --profile openrouter-free --model thinkingmachines/inkling:free
```

The profile is deliberately separate because Codex's `model_catalog_json`
setting controls the model catalog loaded for that profile. The official OpenAI
Codex configuration reference documents profile files as
`$CODEX_HOME/profile-name.config.toml` and allows `model_catalog_json` to be
overridden per profile.

## Ori path

`ori codex` is not the same as `codex --profile openrouter-free`. Ori launches
Codex with temporary `-c` provider overrides and supplies the OpenRouter
credential through the environment/command-backed provider. When a model is
provided, Ori translates it to Codex's `-m` flag:

```bash
ori codex --model stealth/ox-alpha
ori codex --model thinkingmachines/inkling-small:free
ori codex --model thinkingmachines/inkling:free
```

`ori codex` does not inject the local three-entry `model_catalog_json` profile.
Use an explicit allowlisted `--model` with that launcher. If the native Codex
picker and native OpenAI-first ordering are the goal, use direct Codex instead.

The three models were also exercised through the direct OpenRouter profile and
through `ori codex`; all returned successfully in the 2026-08-22 smoke check.
That is separate from the default native OpenAI path.

## Verification

These checks avoid printing credential contents:

```bash
codex --version
codex doctor
jq -r '.models[].slug' "$HOME/.codex/models_openrouter_free.json"
codex --profile openrouter-free exec --help
ori harness-doctor codex
```

Expected facts:

- Direct Codex reports `model_provider = openai` in the default config.
- The profile catalog prints only the three OpenRouter IDs.
- `ori harness-doctor codex` reports zero conflicts and one expected warning
  about intentional provider headers; it reports zero conflicts.

Historical Codex rollouts can mention `openrouter` in the state database. That
is session history, not evidence that the default model catalog is polluted.

## Maintenance

When updating Codex, preserve the separation between `config.toml` and the
`openrouter-free` profile. Recheck the official Codex configuration reference
if a new version changes model-catalog or profile semantics. Never replace the
native model cache with the small OpenRouter catalog.
