# Grok Build

## Role

`grok` is the Grok Build agent runtime. It can expose native xAI/Grok models and
can also route selected aliases through OpenRouter.

## Files

- `$HOME/.grok/config.toml` — active Grok configuration.
- `$HOME/.grok/models_cache.json` — vendor/cache data; it can contain a broad
  historical or remote catalog and is not the effective allowlist.
- `$HOME/.grok/auth.json` — sensitive credentials; never print it.

## Direct configuration

The active default is the alias `ox-alpha`, mapped to:

```text
stealth/ox-alpha
```

The other local aliases are:

```text
inkling-small-free -> thinkingmachines/inkling-small:free
inkling-free       -> thinkingmachines/inkling:free
```

Each alias uses the OpenRouter base URL and the `openrouter` auth provider.

The critical setting is:

```toml
[features]
remote_fetch = false
```

This prevents Grok from replacing the focused local configuration with a
remote OpenRouter catalog. Do not remove it unless a broad dynamic catalog is
wanted again.

Native Grok entries are intentionally retained. Direct `grok models` currently
shows `grok-4.6`, `grok-4.5`, and the three OpenRouter aliases. The native
secondary fork model is also configured as `grok-4.6`.

## Ori-mediated configuration

`ori grok` supplies the OpenRouter credential and launch environment to Grok.
The effective OpenRouter-routed view is:

```bash
ori grok models
```

At the snapshot date it showed the three OpenRouter aliases, with `ox-alpha`
as the default. Native Grok models are not part of that Ori-routed view.

## Inkling request compatibility

The model picker is not an authorization test. The current Grok route lists
all three aliases, but the 2026-08-22 request smoke test produced this result:

| Alias | OpenRouter ID | `ori grok` request |
| --- | --- | --- |
| `ox-alpha` | `stealth/ox-alpha` | `HTTP 200` |
| `inkling-small-free` | `thinkingmachines/inkling-small:free` | `HTTP 403` |
| `inkling-free` | `thinkingmachines/inkling:free` | `HTTP 403` |

The `403` is an upstream free-route/client-identity restriction, not a
missing alias, malformed model ID, or local credential redaction issue. Do not
make Grok impersonate Pi, Codex, or OpenCode. Use one of those verified
runtimes for Inkling, or retry after OpenRouter enables the Grok client
identity.

## Verification

```bash
grok --version
grok models
ori grok models
grok doctor
```

Expected direct output contains the three aliases plus native Grok models.
Expected Ori output contains the OpenRouter aliases, but only Ox Alpha is
currently expected to answer through the Grok request path. `grok doctor` may
report terminal color/newline recommendations; those are unrelated to model
routing.

## Maintenance

Keep alias names stable because users may select them in Grok. Verify both the
alias-to-ID mapping and `remote_fetch = false` after Grok or Ori updates. Never
delete the vendor model cache as a substitute for disabling remote fetching.
