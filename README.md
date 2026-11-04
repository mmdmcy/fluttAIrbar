# fluttAIrbar

Cross-platform **system-tray** app for everything AI on a device: **ChatGPT / Codex** and **Claude** usage limits, read by reusing the sessions already on your machine (no in-app login), plus the versions and safe updates of the AI command-line tools installed there. Cursor usage is optional and paused by default. The same features are available headless through [`fluttairbar-cli`](#command-line).

Inspired by [steipete/CodexBar](https://github.com/steipete/CodexBar) (macOS). fluttAIrbar targets **Linux**, **Windows**, and **macOS** via Flutter.

## Features (v0.1)

- Codex / ChatGPT: session (5h) and/or weekly usage meters (weekly-only plans show just Weekly)
- Claude (Claude Code subscription): 5-hour, weekly and model-specific weekly meters, on by default when a Claude Code session exists
- Banked **limit reset credits** with double-confirm redeem
- Cursor plan usage % (opt-in from the Settings view; paused by default)
- System tray icon + tooltip; click to open the panel
- Supports quiet `--background` launch for desktop login integration
- Verified allowlisted updates for Pi, Codex, Claude Code, Grok Build, OpenCode, and Vercel Labs fx
- Detects when Codex's self-updating background daemon outruns the installed CLI and offers a one-click sync to the daemon's exact version
- Redacted configuration overview with one-click file opening
- Manual Codex capability controls for standalone user skills, installed plugins, and whole MCP servers
- Optional Codex terminal shortcut installer for `codexunsafe` and `codexunsaferesume`
- Dark mode by default (toggle in header)
- Refresh only on demand from the panel or tray menu
- `fluttairbar-cli`: harness check and usage meters as text or JSON for scripts and fleet tools
- Agent management in `fluttairbar-cli`: one collection of skills and one instructions file linked into every coding agent, agent hooks from a collection added to each agent's settings, a quiz of what each agent knows, and a kept, slim copy of Claude Code and Codex history on two devices ([Agent management](#agent-management))

## How auth works (no login here)

fluttAIrbar never asks for your password. It reads local sessions and calls the same unofficial usage APIs CodexBar uses.

`~/.codex/auth.json` is read-only by default. When the Codex session is older
than 8 days fluttAIrbar reports it as stale (run `codex` to renew it) instead of
refreshing the token itself, because rewriting the file while the Codex CLI
refreshes it too can log the CLI out. If you prefer fluttAIrbar to renew a stale
session and write it back, enable **Renew stale session in auth.json** in the
`Settings` view (stored locally, off by default).

The Claude Code session is always read-only. fluttAIrbar never refreshes the
Claude token or rewrites the credentials; when the stored access token has
expired it reports `expired: run claude to renew it`, and starting `claude`
renews it. Claude usage is polled by default only when a Claude Code session
exists, and can be paused or enabled in the `Settings` view.

| Provider | Where tokens come from | API |
|----------|------------------------|-----|
| Codex | `~/.codex/auth.json` (Codex CLI session) | `GET https://chatgpt.com/backend-api/wham/usage` |
| Reset credits | Same OAuth | `GET .../wham/rate-limit-reset-credits` · `POST .../consume` (double-confirm in UI) |
| Claude | Claude Code session: `~/.claude/.credentials.json` (`$CLAUDE_CONFIG_DIR/.credentials.json` when set) on Linux and Windows, Keychain item `Claude Code-credentials` on macOS (falls back to the file) | `GET https://api.anthropic.com/api/oauth/usage` with `anthropic-beta: oauth-2025-04-20`, the endpoint Claude Code's `/usage` view uses |
| Cursor | Cursor app `state.vscdb` (`cursorAuth/accessToken`) or `~/.config/cursor/auth.json` | `GET https://cursor.com/api/usage-summary` |

### Prerequisites

**Codex / ChatGPT**

```bash
# Codex CLI (fluttAIrbar reuses this session)
codex login
```

**Claude**

```bash
# Claude Code (fluttAIrbar reuses this session)
claude
```

Sign in once with a Claude subscription (Pro, Max, Team or Enterprise). An
API-key-only setup has no subscription usage windows and reads as signed out.
On macOS the first read can show a Keychain prompt for the
`Claude Code-credentials` item.

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
On Linux, `tool/install_linux.sh` does all of the following and also installs
`fluttairbar-cli` (the previous bundle is kept as `fluttairbar.bak-TIME`):

```bash
tool/install_linux.sh
```

By hand, the same steps:

```bash
flutter build linux --release
mkdir -p "$HOME/.local/opt/fluttairbar" "$HOME/.local/bin"
# Replace x64 with the generated architecture directory when needed.
rsync -a --delete build/linux/x64/release/bundle/ \
  "$HOME/.local/opt/fluttairbar/"
ln -sfn "$HOME/.local/opt/fluttairbar/fluttairbar" \
  "$HOME/.local/bin/fluttairbar"
```

Configure the desktop's startup manager to run `fluttairbar --background`. The app
then starts quietly in the tray; click the tray icon to open the small usage
panel. It does not need administrator permissions and never changes startup
configuration itself.

Headless smoke check (Codex only; run only in a private terminal because it
prints account and usage details):

```bash
dart run tool/smoke_codex.dart
```

### Harness updates

The harness view scans only this fixed allowlist: `pi`, `codex`, `claude`,
`grok`, `cursor-agent`, `opencode`, `fx`, `ori`, and `zcode`. It never accepts an
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
its own official non-npm channel and is labeled separately in the panel.
Claude Code's native install (`~/.local/bin/claude`) is labeled the same way:
its latest version comes from Anthropic's official release channel
(`https://downloads.claude.ai/claude-code-releases/latest`, or `stable` when
`autoUpdatesChannel` in `~/.claude/settings.json` says so) and its update action
is `claude update`. An npm install of `@anthropic-ai/claude-code` is detected
by its location under `node_modules` and follows the npm path instead,
including the 14-day release-age gate and the scoped exemption described
below. Cursor
Agent is shown as manual-only until it exposes a reliable update check; the app
will not guess or run its updater. Ori is a launcher/adapter for other
harnesses, not a standalone agent runtime. ZCode is shown for configuration
access but has no safe updater command.

When updating Codex, Claude Code (npm) or OpenCode, fluttAIrbar exempts the selected CLI and its
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

## Command line

`fluttairbar-cli` is the headless command-line tool. It imports no Flutter
code, so the compiled binary runs on servers and over SSH without Flutter or
Dart, and it is what fleet tools call. Building it needs the Flutter SDK
(which brings `dart`), because this package depends on Flutter and plain
`dart pub get` cannot resolve it. Build it once:

```bash
flutter pub get
dart compile exe tool/fluttairbar_cli.dart -o ~/.local/bin/fluttairbar-cli
# or, without compiling:
dart run tool/fluttairbar_cli.dart --help
```

`tool/install_linux.sh` compiles it too.

For AI agents, [`skills/fluttairbar/SKILL.md`](skills/fluttairbar/SKILL.md) is
an [Agent Skill](https://agentskills.io) that tells any coding agent (Claude
Code, Codex, OpenCode, Pi, Cursor, ...) how to use `fluttairbar-cli`: which
command answers which question, how to read the JSON, and to ask before
updating. Link the folder into your agent's skills folder, for example
`ln -s "$PWD/skills/fluttairbar" ~/.claude/skills/fluttairbar`.

```text
fluttairbar-cli harnesses [--json] [--only ID,ID] [--update] [--sync-codex-daemon]
fluttairbar-cli usage [--json]
fluttairbar-cli version
fluttairbar-cli --help
```

`harnesses` is the same command as `dart run tool/update_harnesses.dart` (that
script stays and runs the same code). Without a flag it only reads: installed
version, latest release, update source and redacted config files per harness.
`--update` and `--sync-codex-daemon` behave as described under
[Harness updates](#harness-updates). The JSON is a list with one object per
harness: `id`, `name`, `installed`, `path`, `currentVersion`, `latestVersion`,
`daemonVersion`, `daemonAhead`, `publishedAt`, `updateAvailable`,
`ageGateSatisfied`, `updateSource` (`npm`, `githubRelease` or
`officialChannel`), `checkError` and `configs`.

`usage` prints one line per provider, or with `--json` one document:

```json
{
  "schema": "fluttairbar.usage.v1",
  "providers": [
    {
      "id": "claude",
      "state": "ok",
      "detail": "Read from the Claude Code session.",
      "plan": "max",
      "windows": [
        {"id": "session", "label": "5 hours", "used_percent": 3.0, "resets_at": "2026-11-01T17:59:59.635Z"},
        {"id": "weekly", "label": "7 days", "used_percent": 47.0, "resets_at": "2026-11-03T07:59:59.635Z"},
        {"id": "weekly-opus", "label": "7 days · Opus", "used_percent": 86.0, "resets_at": "2026-11-03T07:59:59.635Z"}
      ]
    }
  ]
}
```

- `providers` always lists `codex`, `claude` and `cursor`, in that order.
- `state` is one of `ok`, `signed-out`, `expired`, `stale`, `paused` or
  `error`; `detail` is one plain sentence saying what happened and what to run.
  A `stale` Codex session still carries its windows when the fetch worked.
- `plan` is the provider's plan name (`pro`, `max`, `plus`, ...) or `""`.
- `windows[].id` is `session`, `weekly`, `weekly-<model>` for model-specific
  weekly limits, `plan` for Cursor's billing cycle, or a slug of a new window
  name; unknown windows from the provider are passed through, never fatal.
  `resets_at` is ISO-8601 UTC or `null`.
- Paused providers follow the app's `Settings` (Cursor off by default, Claude
  on when a session exists). The CLI never rewrites a credentials file, even
  when the app may renew Codex, and never prints tokens, emails or account ids.
- The compiled binary cannot load SQLite, so it reads Cursor only from
  `~/.config/cursor/auth.json`; when only the Cursor app's database holds the
  session it says so with state `error` instead of guessing.

Exit codes: `0` when the command ran (also when a provider is signed out or
expired), `1` when an update, a sync or a change failed (or a quiz answer was
not as expected), `3` when a change needs approval, `64` for wrong usage.

### Agent management

The same command line manages the coding agents on a device: one collection
of [Agent Skills](https://agentskills.io) linked into every agent, one
instructions file every agent starts with, hooks added to each agent's own
settings, a quiz of what an agent knows
before it opens a project, and a kept copy of the Claude Code and Codex
conversation history. It works on its own; a fleet tool can run it on each
device over SSH with `--format json` and present the answers.

```text
fluttairbar-cli skills [settings] [--json]
fluttairbar-cli skills install (SKILL... | --all) [--agent ID] [--replace] [-y|-n]
fluttairbar-cli skills add ~/PATH|URL [-y|-n]
fluttairbar-cli skills remove ~/PATH [-y|-n]
fluttairbar-cli skills on|off SKILL [--agent ID] [-y|-n]
fluttairbar-cli hooks [--json]
fluttairbar-cli hooks install (HOOK... | --all) [--replace] [-y|-n]
fluttairbar-cli hooks remove HOOK... [-y|-n]
fluttairbar-cli hooks add ~/PATH [-y|-n]
fluttairbar-cli quiz [--agent ID] [--json]
fluttairbar-cli conversations [pack | copy [-n]] [--json]
```

A change asks first: `-y` approves it, `-n` shows what it would do and
changes nothing, and without a terminal to ask on it stops with exit `3`.
`--json` is also spelled `--format json` or `-o json`; with `--json`, an error
is `{"error": {"code", "exit", "message", "hint"}}` on stdout. `--with-text`
adds the text view to the JSON as `text`.

**Skills.** `~/.config/fluttairbar/skills.toml`:

```toml
collections = ["~/Documents/github/myskills", "~/Documents/github/team/skills"]
instructions = "~/Documents/github/team/agents/AGENTS.md"

[off]
pi = ["safe-yeet"]       # skills switched off for one agent

[[agent]]                # an agent the built-in table lacks, or a change to one
id = "gemini"
name = "Gemini CLI"
dir = "~/.gemini/skills"
reads = ["~/.agents/skills"]
```

Built in: Claude Code, Codex, OpenCode (it also reads `~/.claude/skills`), Pi
(also `~/.agents/skills`) and Cursor Agent. `skills` reports
(`fluttairbar.skills.v1`) the collections and their commit, and per skill and
agent `linked`, `via DIR` (linked in another folder the agent reads), `copy`,
`link -> TARGET`, `off` or `missing`, with how many sessions of the last 30
days loaded it (from Claude Code, Codex and Pi history) and what keeps an
agent from seeing it (a SKILL.md without a header, name or description).
`install` links skills, and with `--all` the shared instructions file as each
agent's own (`~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`, ...), but refuses to
link a file that is not there. Nothing is overwritten: a folder or file in the
way is moved to `~/.local/share/fluttairbar/retired/` only with `--replace`.
`off` removes one agent's link (never a copy, never the skill) and keeps the
skill out of `install --all`; `on` links it again. `add` registers a folder,
or clones a git URL into `~/Documents/github/NAME` first; `remove` only
unregisters. `--settings FILE` reads other settings (`-` reads them from
standard input, read only, so a fleet tool can apply one device's list on
another); `skills settings` prints the settings in use.

**Hooks.** A hook collection is a folder with a `hooks.toml`:

```toml
[[hook]]
name = "promise-check"
agent = "claude"             # the agent id that runs it
event = "Stop"               # as that agent spells it
command = "python3 -I {dir}/promise-check.py"   # {dir}: this folder
timeout = 10                 # optional, seconds
matcher = "Bash"             # optional, for tool events
description = "What it does"
```

`~/.config/fluttairbar/hooks.toml` lists the collections
(`collections = ["~/Documents/github/team/agents/hooks"]`); `hooks add
~/PATH` registers one. An agent has hooks when its entry in the agent table
names a hook settings file, a JSON file with a `hooks` object in Claude
Code's shape: built in only for Claude Code (`~/.claude/settings.json`); an
`[[agent]]` in skills.toml can set `hooks = "~/PATH"` for another agent that
reads the same shape. `hooks` reports (`fluttairbar.hooks.v1`) each hook's
state for its agent: `installed`, `missing`, `different` (its command with
another event, matcher or timeout), `no hooks` (the agent has none),
`not here`, `unknown agent` or `unreadable`; hooks in an agent's settings that
no collection declares are listed as `others`. A hook is known by its
command. `install` adds a missing hook once, as a matcher group of its own;
`remove` takes every entry of its command out. Both keep the file as it was
next to it (`settings.json.bak-DATE`, then `-2`, `-3`, ...), keep its
permissions and a link to it, change nothing else, and refuse a file that is
not valid JSON or a result that does not read back as intended; a
`different` hook is put as `hooks.toml` says only with `--replace`.

**Quiz.** `quiz.txt` beside the shared instructions: a line starting with `?`
is a question, the `=` lines under it are accepted answers (any one,
case-insensitive), `#` lines are comments; an answer that appears in its own
question is refused. Each agent with a one-shot mode (Claude Code, Codex) is
asked every question from an empty folder with no tools, so only what it
knows before opening a project counts. It uses the agents' own
subscriptions: run it when you mean it. Exit `1` when an answer was not as
expected.

**Conversations.** History is kept, always: nothing deletes, prunes or leaves
out a session, and a copy never touches its source. `pack` writes a slim copy
of this device's history (Claude Code `~/.claude/projects` and
`history.jsonl`; Codex `sessions`, `archived_sessions`, `history.jsonl`,
`session_index.jsonl`) to `~/Backups/conversations/DEVICE/`: every word kept,
screenshots replaced by a note of their size, gzip, only files that changed.
`copy` packs both devices of each pair and rsyncs each side's folder to the
other, never with `--delete`; the other device needs `fluttairbar-cli` too.
`~/.config/fluttairbar/conversations.toml`:

```toml
bwlimit_kbps = 1000      # upload cap per copy in KB/s (0 = none)

[[pair]]
devices = ["laptop", "desktop"]

[[extra]]                # a folder copied (compressed, as it is) with a device's history
device = "desktop"
path = "/srv/backups/old-sessions"
```

`copy` reaches the other device with `ssh -o BatchMode=yes NAME`;
`--rsh NAME=COMMAND` and `--host NAME=USER@HOST` change that per device, and
`--bwlimit KBPS` caps the upload when the settings set no cap. The status
(`fluttairbar.conversations.v1`) lists the copies held here, the last copy in
each direction and, in `behind`, each direction that keeps failing with for
how many days. To copy every night, run `fluttairbar-cli conversations copy`
from a systemd user timer or cron.

## Privacy

- Tokens stay on your machine; fluttAIrbar does not upload them to any fluttAIrbar server.
- HTTP calls go to OpenAI / Anthropic / Cursor endpoints only, using your existing session.
- The Claude Code session and `~/.claude.json` are never shown or rewritten; only the plan name, usage percentages and reset times leave the credentials reader.
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

Unofficial project; not affiliated with OpenAI, Anthropic, Cursor, or CodexBar.
