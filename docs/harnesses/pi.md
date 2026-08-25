# Pi

## Role

`pi` is the direct coding-agent runtime. It owns the Pi TUI, provider registry,
extensions, model picker, and Pi sessions.

Pi is also the runtime launched by `ori pi`, so direct Pi and Ori-mediated Pi
must be verified separately.

## Files

- `$HOME/.pi/agent/settings.json` — direct defaults; currently OpenRouter with
  `stealth/ox-alpha` as the default model.
- `$HOME/.pi/agent/models.json` — static direct provider/model catalog.
- `$HOME/.pi/agent/auth.json` — sensitive Pi credentials; never print it.
- `$HOME/.pi/agent/extensions/openrouter-free-models.ts` — direct and reusable
  static provider overlay.
- `$HOME/.pi/agent/ori-openrouter-free-models.ts` — late-overlay re-export used
  after Ori's generated extension.
- `$HOME/.pi/agent/models-store.json` — Pi's other provider cache; it is not the
  source of the effective direct OpenRouter list.

## Direct configuration

`settings.json` selects:

```json
{
  "defaultProvider": "openrouter",
  "defaultModel": "stealth/ox-alpha"
}
```

`models.json` defines one effective OpenRouter provider with exactly:

```text
stealth/ox-alpha
thinkingmachines/inkling-small:free
thinkingmachines/inkling:free
```

The `openrouter-free-models.ts` extension also unregisters the provider and
re-registers only the requested models. It suppresses other built-in providers
for this focused direct-Pi setup and does not add a dynamic catalog refresh.

## Ori-mediated configuration

Ori writes/uses `$HOME/.ori/pi/openrouter-auth.ts`. That generated extension
supports dynamic OpenRouter catalog loading, which can expose hundreds of
models. The local overlay must therefore be loaded after it:

```text
Ori generated extension
  -> $HOME/.pi/agent/ori-openrouter-free-models.ts
```

`$HOME/.local/bin/pi` is a guarded wrapper. Its behavior is intentionally
conditional:

- Direct `pi` calls execute the preserved `$HOME/.local/bin/pi-real` target
  without adding an Ori extension.
- When Ori passes `$HOME/.ori/pi/openrouter-auth.ts`, the wrapper appends the
  late static overlay.
- The wrapper invokes Node directly or finds the installed Node fallback, so
  version probes do not depend on the caller's full interactive `PATH`.

Do not remove the wrapper or rename the late overlay without rechecking
`ori pi --list-models`. The original Pi target is preserved at
`$HOME/.local/bin/pi-real`.

## Verification

```bash
pi --version
pi --list-models
ori pi --list-models
bash -n "$HOME/.local/bin/pi"
ori harness-doctor pi
```

Both model-list commands should show only the three requested OpenRouter IDs.
Pi is currently `0.84.2`.

Headless requests for all three IDs succeeded through both direct Pi and
`ori pi` in the 2026-08-22 smoke check. This is why Pi is one of the verified
paths for the two Inkling free routes, not merely a path where the aliases are
visible.

`ori harness-doctor pi` can show one detector warning because it cannot infer a
package version through the wrapper path. This is not a runtime failure:
`pi --version` works, both model lists are correct, and the doctor reports no
warning when the underlying Pi symlink is first on `PATH`.

## Maintenance

If Pi or Ori changes extension loading order, generated extension paths, or the
provider registration API, update both overlay files and retest direct plus
Ori-mediated Pi. Do not solve this by editing a generated Ori file alone; Ori
may regenerate it.
