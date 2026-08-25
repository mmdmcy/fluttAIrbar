# Cursor Agent

## Role

`cursor-agent` is Cursor's first-party agent runtime. Its model catalog and
account capabilities come from Cursor's service, not from the local OpenRouter
configuration documented for Pi, Codex, Grok, OpenCode, or Ori.

## Files

- `$HOME/.cursor/cli-config.json` — local CLI preferences and selected Cursor
  model information.
- `$HOME/.cursor/agent-cli-state.json` — CLI state.
- `$HOME/.config/cursor/auth.json` — sensitive Cursor credentials; never print
  it.
- Cursor desktop state may live under
  `$HOME/.config/Cursor/User/globalStorage/state.vscdb`.

## OpenRouter scope

There is no active OpenRouter provider or requested Ox/Inkling entry in the
Cursor CLI configuration. Cursor's model picker is intentionally separate:

```bash
cursor-agent --list-models
cursor-agent models
```

Those commands list Cursor-native account models. Do not edit Cursor's model
catalog to add OpenRouter IDs unless a separate, explicit Cursor integration is
requested.

## Verification

```bash
cursor-agent --version
cursor-agent --list-models
```

The expected result is a working Cursor-native catalog with no dependency on
the OpenRouter allowlist. A broad Cursor list is not evidence that the
OpenRouter filtering failed elsewhere.

## Maintenance

Treat Cursor upgrades and account model availability as service-managed. Keep
Cursor documentation separate from the OpenRouter runbooks and avoid copying
credentials or account state into this repository.

fluttAIrbar currently labels Cursor Agent as manual-only. Cursor's local CLI
does not expose a reliable release check in this catalog, so the app refuses
to guess that an update is available or run `cursor-agent update` blindly.
