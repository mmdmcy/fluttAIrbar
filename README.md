# fluttAIrbar

Cross-platform **system-tray** app that shows **ChatGPT / Codex** and **Cursor** usage limits by reusing credentials already on your machine — no in-app login.

Inspired by [steipete/CodexBar](https://github.com/steipete/CodexBar) (macOS). fluttAIrbar targets **Linux**, **Windows**, and **macOS** via Flutter.

## Features (v0.1)

- Codex / ChatGPT: session (5h) and/or weekly usage meters (weekly-only plans show just Weekly)
- Banked **limit reset credits** with double-confirm redeem
- Cursor plan usage % (when local Cursor auth is available)
- System tray icon + tooltip; click to open the panel
- Dark mode by default (toggle in header)
- Refresh on demand and every ~3 minutes

## How auth works (no login here)

fluttAIrbar never asks for your password. It reads local sessions and calls the same unofficial usage APIs CodexBar uses.

| Provider | Where tokens come from | API |
|----------|------------------------|-----|
| Codex | `~/.local/share/opencode/auth.json` (OpenCode ChatGPT OAuth) **or** `~/.codex/auth.json` (Codex CLI) | `GET https://chatgpt.com/backend-api/wham/usage` |
| Reset credits | Same OAuth | `GET .../wham/rate-limit-reset-credits` · `POST .../consume` (double-confirm in UI) |
| Cursor | Cursor app `state.vscdb` (`cursorAuth/accessToken`) or `~/.config/cursor/auth.json` | `GET https://cursor.com/api/usage-summary` |

### Prerequisites

**Codex / ChatGPT**

```bash
# Option A — OpenCode (recommended if you already use it)
opencode providers login   # choose ChatGPT / Codex OAuth, not an API key

# Option B — Codex CLI
codex login
```

**Cursor**

Sign in to the Cursor desktop app (or Cursor CLI) so a local access token exists.

## Run

Needs [Flutter](https://docs.flutter.dev/get-started/install) with desktop enabled.

```bash
# Linux deps (Debian/Ubuntu/Mint)
sudo apt install libgtk-3-dev libayatana-appindicator3-dev libsqlite3-dev

git clone https://github.com/mmdmcy/fluttAIrbar.git
cd fluttAIrbar
flutter pub get
flutter run -d linux
# or: flutter build linux
```

Headless smoke check (Codex only):

```bash
dart run tool/smoke_codex.dart
```

## Privacy

- Tokens stay on your machine; fluttAIrbar does not upload them to any fluttAIrbar server.
- HTTP calls go to OpenAI / Cursor endpoints only, using your existing session.
- Reset credits are redeemed only after **two** confirmation dialogs; each redeem requires an explicit credit id.

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
