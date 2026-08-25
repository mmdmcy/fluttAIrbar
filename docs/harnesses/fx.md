# fx

## Role

`fx` is the Vercel Labs terminal agent. It uses Vercel AI Gateway and maintains
its own provider/model catalog. It is not an OpenRouter client merely because
some catalog entries have similar model families.

## Files

- `$HOME/.fx/settings.json` — fx settings; the current file records the fx
  credential source and acknowledgement state.
- `$HOME/.fx/auth.json` — sensitive Vercel credential state; never print it.
- `$HOME/.fx/sessions` — fx session state; do not copy it into documentation.

## OpenRouter scope

The OpenRouter allowlist does not control `fx`. The current fx catalog is broad
and is obtained through the Vercel gateway:

```bash
fx models
```

That output can include many providers and model families. It is expected to
differ from `opencode models openrouter` or `pi --list-models`. There is no
local three-ID OpenRouter whitelist in the current fx settings.

If a future requirement is “show only three models in fx's own picker,” treat
that as a separate fx-specific investigation. Do not fake it by editing the
OpenRouter files or vendor caches.

## Current health note

At the snapshot date, `fx doctor` reported a refreshable but expired `fx login`
session. That is an fx authentication issue, not a model-allowlist issue:

```bash
fx login
fx doctor
```

Only perform login when the user intends to refresh the Vercel session.

## Verification

```bash
fx --version
fx status --json
fx models
fx doctor
```

Avoid including account or credential values in captured output.
