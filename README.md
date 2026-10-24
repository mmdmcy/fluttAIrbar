# fluttAIrbar

Cross-platform **system-tray** app that shows **ChatGPT / Codex** usage limits by reusing credentials already on your machine — no in-app login. Cursor usage is optional and paused by default.

Inspired by [steipete/CodexBar](https://github.com/steipete/CodexBar) (macOS). fluttAIrbar targets **Linux**, **Windows**, and **macOS** via Flutter.

## Features (v0.1)

- Codex / ChatGPT: session (5h) and/or weekly usage meters (weekly-only plans show just Weekly)
- Banked **limit reset credits** with double-confirm redeem
- Cursor plan usage % (opt-in from the Settings view; paused by default)
- System tray icon + tooltip; click to open the panel
- Supports quiet `--background` launch for desktop login integration
- Verified allowlisted updates for Pi, Codex, Grok Build, OpenCode, and Vercel Labs fx
- Detects when Codex's self-updating background daemon outruns the installed CLI and offers a one-click sync to the daemon's exact version
- Redacted configuration overview with one-click file opening
- Manual Codex capability controls for standalone user skills, installed plugins, and whole MCP servers
- Optional Codex terminal shortcut installer for `codexunsafe` and `codexunsaferesume`
- Dark mode by default (toggle in header)
- Refresh only on demand from the panel or tray menu

## How auth works (no login here)

fluttAIrbar never asks for your password. It reads local sessions and calls the same unofficial usage APIs CodexBar uses.

`~/.codex/auth.json` is read-only by default. When the Codex session is older
than 8 days fluttAIrbar reports it as stale (run `codex` to renew it) instead of
refreshing the token itself, because rewriting the file while the Codex CLI
refreshes it too can log the CLI out. If you prefer fluttAIrbar to renew a stale
session and write it back, enable **Renew stale session in auth.json** in the
`Settings` view (stored locally, off by default).

| Provider | Where tokens come from | API |
|----------|------------------------|-----|
| Codex | `~/.codex/auth.json` (Codex CLI session) | `GET https://chatgpt.com/backend-api/wham/usage` |
| Reset credits | Same OAuth | `GET .../wham/rate-limit-reset-credits` · `POST .../consume` (double-confirm in UI) |
| Cursor | Cursor app `state.vscdb` (`cursorAuth/accessToken`) or `~/.config/cursor/auth.json` | `GET https://cursor.com/api/usage-summary` |

### Prerequisites

**Codex / ChatGPT**

```bash
# Codex CLI (fluttAIrbar reuses this session)
codex login
```

**Cursor**

Cursor polling is paused by default. If you later resubscribe, open the
`Settings` view from the panel's view menu and enable it there, then sign in to
the Cursor desktop app (or Cursor CLI) so a local access token exists.

## Run

Needs [Flutter](https://docs.flutter.dev/get-started/install) with desktop enabled.

```bash
# Linux deps (Debian/Ubuntu/Mint)
sudo apt install libgtk-3-dev libayatana-appindicator3-dev libsqlite3-dev rsync

git clone https://github.com/mmdmcy/fluttAIrbar.git
cd fluttAIrbar
flutter pub get
flutter run -d linux
# or: flutter build linux --release
```

Install the complete release bundle in a stable location before configuring it
as a login application. Development builds must not be registered for startup.

```bash
flutter build linux --release
mkdir -p "$HOME/.local/opt/fluttairbar" "$HOME/.local/bin"
# Replace x64 with the generated architecture directory when needed.
rsync -a --delete build/linux/x64/release/bundle/ \
  "$HOME/.local/opt/fluttairbar/"
ln -sfn "$HOME/.local/opt/fluttairbar/fluttairbar" \
  "$HOME/.local/bin/fluttairbar"
```

Configure the desktop's startup manager to run `fluttairbar --background`, or
declare `autostart fluttairbar.desktop` in a LinuxMice endpoint profile. The app
then starts quietly in the tray; click the tray icon to open the small usage
panel. It does not need administrator permissions and never changes startup
configuration itself.

Headless smoke check (Codex only; run only in a private terminal because it
prints account and usage details):

```bash
dart run tool/smoke_codex.dart
```

### Harness updates

The harness view scans only this fixed allowlist: `pi`, `codex`, `grok`,
`cursor-agent`, `opencode`, `fx`, `ori`, and `zcode`. It never accepts an
arbitrary package or shell command. Open the labeled `Harnesses` button in the
panel header, expand any harness to see its config files, and use its
individual `Update` action or the safe `Update all` button. The default
terminal command is read-only:

```bash
dart run tool/update_harnesses.dart
dart run tool/update_harnesses.dart --only pi,codex
```

After reviewing the result, explicitly opt in to updates:

```bash
dart run tool/update_harnesses.dart --update
```

The terminal updater checks npm and fx releases against their public release
timestamp and skips them until they are at least 14 days old. If release
metadata cannot be verified, the update is skipped. In the GUI, an individual
`Update now` or confirmed `Update all` explicitly allows an early release, but
only for the fixed allowlist and only when metadata is verified. Grok Build uses
its own official non-npm channel and is labeled separately in the panel. Cursor
Agent is shown as manual-only until it exposes a reliable update check; the app
will not guess or run its updater. Ori is a launcher/adapter for other
harnesses, not a standalone agent runtime. ZCode is shown for configuration
access but has no safe updater command.

When updating Codex or OpenCode, fluttAIrbar exempts the selected CLI and its
platform binary packages from npm's configured minimum release age for that
install, including child npm processes started by the installer. Other
dependencies retain the age gate; the user's npm configuration is unchanged.
Codex discovery checks all npm installations visible on PATH and updates each
outdated copy in its owning prefix, so terminal and tray launches stay current.

#### Background daemon sync

Codex runs a background app-server daemon that updates itself on an hourly
schedule, outside npm, so it regularly runs a newer version than the
npm-installed CLI. That skew makes every Codex launch prompt about
"incompatible feature settings". fluttAIrbar's Codex scan queries
`codex app-server daemon version` and flags the mismatch. When the daemon is
ahead, the panel offers `Sync to daemon`, `Update all` includes the sync, and
the terminal tool accepts a dedicated flag:

```bash
dart run tool/update_harnesses.dart --sync-codex-daemon
```

Syncing installs the daemon's exact version into every npm copy of Codex on
PATH. Because that version already runs on the machine — it was installed by
Codex's own updater — the sync applies the same scoped release-age exemption
as a confirmed early update, and only for `@openai/codex`.

The durable local harness context is documented in
[`docs/harnesses/context.md`](docs/harnesses/context.md), with one runbook per
harness in [`docs/harnesses/`](docs/harnesses/).

### Codex capability packs

Open the panel view menu and choose `Capabilities`, then press `Scan`. The
panel can independently enable or disable standalone skills discovered in
`$HOME/.agents/skills` and `$CODEX_HOME/skills`, installed Codex plugins, and
whole MCP servers by editing `$CODEX_HOME/config.toml`. System-bundled and
repository-scoped skills are not included in this user-level view. Confirm
changes only while Codex is idle; fluttAIrbar never restarts or interrupts a
running CLI. Restart Codex manually, then scan again.

The repository also includes a first-party Codex port of the official Cursor
pstack source. Install it deliberately from the local marketplace before
scanning:

```bash
codex plugin marketplace add .
codex plugin add pstack@fluttairbar-local
```

See [`plugins/pstack/README.md`](plugins/pstack/README.md) and the
[`Codex capability research notes`](docs/harnesses/codex-capability-packs.md)
for the port boundary, categories, attribution, and safety model.

### Optional Codex terminal shortcuts

Open the panel view menu, choose `Settings`, and expand `Codex terminal
shortcuts` if you want the two local shortcuts used by this machine:

```text
codexunsafe
codexunsaferesume
```

The installer is opt-in. It writes executable, shell-independent wrappers to
`~/.local/bin`, preserves the exact Codex argument profiles, and refuses to
replace files it did not create. If `~/.local/bin` is not already on the
current PATH or in the detected Bash, Zsh, or Fish startup file, it adds a
managed PATH block and tells the user to open a new terminal. Repair and
Uninstall are available later; Uninstall removes only fluttAIrbar's files and
its own PATH block. Codex itself, credentials, and other shell configuration
are not changed apart from that managed PATH block.

### OpenRouter notes

Grok Build may list multiple Inkling entries: `thinkingmachines/inkling` is
the large paid model, while `thinkingmachines/inkling:free` is its restricted
free route. OpenRouter also lists `thinkingmachines/inkling-small:free` as a
separate smaller free model. The official Ori guide supports Claude Code,
Codex, Grok Build, Hermes, OpenCode, Pi, Prime Agent, and DeepSeek Harness;
these are agent runtimes, while Ori is their launcher/adapter. A free route
can still apply a narrower provider-side client check: the verified Pi,
Codex, and OpenCode paths accept both Inkling IDs, while the current Grok
request path returns `403` for them and succeeds for Ox Alpha. See the
[cross-harness request matrix](docs/harnesses/context.md) before treating a
visible model alias as usable. The harness overview shows provider/model hints
without printing API keys, so use it to confirm that the selected model and
provider match the command you are actually running.

## Privacy

- Tokens stay on your machine; fluttAIrbar does not upload them to any fluttAIrbar server.
- HTTP calls go to OpenAI / Cursor endpoints only, using your existing session.
- Reset credits are redeemed only after **two** confirmation dialogs; each redeem requires an explicit credit id.
- Harness scanning reads file presence and redacted provider/model hints; credential contents are never shown.
- Codex shortcut installation is opt-in and only removes files or PATH blocks it owns.
- Updates run fixed, reviewed argument lists; GUI early updates require explicit confirmation.

## Platforms

| OS | Status |
|----|--------|
| Linux | Primary (tested) |
| Windows | Same codebase (`flutter run -d windows`) |
| macOS | Same codebase (`flutter run -d macos`) |

## Future

- More providers if useful

## License

MIT — see [LICENSE](LICENSE).

Unofficial project; not affiliated with OpenAI, Cursor, or CodexBar.
