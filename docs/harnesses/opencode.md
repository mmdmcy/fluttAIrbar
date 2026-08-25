# OpenCode

## Role

`opencode` is a multi-provider agent runtime. It owns its provider registry,
model picker, agents, tools, and sessions.

## Files

- `$HOME/.config/opencode/opencode.json` — active provider, agent, permission,
  and model configuration.
- `$HOME/.local/share/opencode/auth.json` — sensitive provider credentials; never
  print it.
- `$HOME/.config/opencode/package.json` — installed OpenCode plugins.

## Native defaults

The default OpenCode model is native OpenAI:

```text
openai/gpt-5.6-sol
```

The configured OpenAI model variants and agent defaults are intentionally not
part of the OpenRouter allowlist. They remain available for native OpenAI use.

## OpenRouter allowlist

The `openrouter` provider contains this whitelist:

```json
[
  "stealth/ox-alpha",
  "thinkingmachines/inkling-small:free",
  "thinkingmachines/inkling:free"
]
```

The relevant scoped check is:

```bash
opencode models openrouter
```

It should print exactly the three IDs with the `openrouter/` provider prefix.
`ori opencode models openrouter` should produce the same scoped set while Ori
supplies the credential and launch environment.

Direct OpenCode and `ori opencode` both returned successful headless requests
for all three IDs in the 2026-08-22 smoke check. OpenCode is therefore a
verified path for the Inkling free routes as well as Ox Alpha.

## Important distinction

`opencode models` is a global cross-provider list. It also includes OpenCode's
built-in `opencode/*` models and native `openai/*` models. That is expected and
does not mean the OpenRouter provider whitelist failed.

The requirement is to restrict OpenRouter entries while preserving native
OpenAI selection. Do not remove the native provider or interpret the global
list as the scoped OpenRouter list.

## Verification

```bash
opencode --version
opencode models openrouter
ori opencode models openrouter
opencode debug config
```

Inspect resolved configuration without printing the auth file. Recheck the
whitelist after OpenCode upgrades because provider schema behavior can change.

## Maintenance

Keep provider/model IDs in the OpenCode namespace only where the command
requires them. The whitelist uses raw OpenRouter IDs; the model-list command
renders them as `openrouter/<id>`. Preserve the distinction when comparing
configuration files and command output.

fluttAIrbar checks the `opencode-ai` npm release before offering an update. If
the executable is installed in an isolated `node_modules` tree, it installs
the verified target version into that same tree with npm. This avoids invoking
OpenCode's interactive installation-method prompt, which is not safe for a
tray update action.
