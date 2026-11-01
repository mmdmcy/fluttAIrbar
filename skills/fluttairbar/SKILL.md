---
name: fluttairbar
description: Check the AI command-line tools on this device (Claude Code, Codex, OpenCode, Pi, Cursor Agent, Grok Build, fx, Ori, ZCode) for their installed and newest versions and safe updates, and how much of the Claude, Codex and Cursor subscriptions signed in here is used, with fluttAIrbar's command line `fluttairbar-cli`. Use when asked whether AI tools are up to date, how much usage or limit is left, when a limit resets, or before updating an AI command-line tool.
---

# fluttAIrbar

`fluttairbar-cli` reads what is installed and signed in on this device. It
never prints tokens, emails or account ids and never rewrites a credentials
file.

## AI command-line tools

```bash
fluttairbar-cli harnesses --json            # every tool it knows
fluttairbar-cli harnesses --json --only codex,claude
```

One object per tool: `id`, `name`, `installed`, `currentVersion`,
`latestVersion`, `updateAvailable`, `ageGateSatisfied`, `updateSource`
(`npm`, `githubRelease` or `officialChannel`), `checkError`, and `configs`
(each tool's config files, sensitive ones shown as present only).

- `updateAvailable` with `ageGateSatisfied: false` means the release is
  newer than 14 days: fluttAIrbar holds npm and GitHub releases back until
  then. Say so; do not install it another way.
- `officialChannel` tools (Claude Code's native install, Grok Build) update
  through their own updater.

## Usage limits

```bash
fluttairbar-cli usage --json
```

`{"schema":"fluttairbar.usage.v1","providers":[...]}`, one provider each for
`codex`, `claude` and `cursor`: `state` (`ok`, `signed-out`, `expired`,
`stale`, `paused`, `error`), `detail` (what to do, in a sentence), `plan`, and
`windows`, each with `label` ("5 hours", "7 days"), `used_percent` and
`resets_at` (ISO 8601, UTC). Report the percentages and when they reset in
the user's local time. `stale` or `expired` means the user should run that
tool once to renew its session; never renew it yourself.

## Updating (ask first)

```bash
fluttairbar-cli harnesses --update --only codex   # one tool
fluttairbar-cli harnesses --update                # every verified update
fluttairbar-cli harnesses --sync-codex-daemon     # Codex CLI to its daemon's version
```

These install software: ask the user before running them, and run them
only for tools the scan showed as ready. Exit 1 means an update failed; the
output says which.

## Not installed?

From a checkout of https://github.com/mmdmcy/fluttAIrbar on Linux:
`tool/install_linux.sh` (the tray app and `fluttairbar-cli`), or only the
command line with `dart compile exe tool/fluttairbar_cli.dart -o
~/.local/bin/fluttairbar-cli`.
