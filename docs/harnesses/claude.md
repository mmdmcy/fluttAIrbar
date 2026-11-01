# Claude Code

## Role

`claude` is Anthropic's Claude Code agent runtime. fluttAIrbar lists it in the
harness view and reads its subscription usage for the usage meters.

## Files

- `$HOME/.claude/settings.json` — user settings, including `model` and the
  update channel `autoUpdatesChannel` (`latest` by default, or `stable`).
- `$HOME/.claude/CLAUDE.md` — user instructions loaded into every session.
- `$HOME/.claude/skills/` — user skills, one folder each.
- `$HOME/.claude.json` — global state (projects, MCP servers, account data);
  sensitive, never print it.
- `$HOME/.claude/.credentials.json` — the OAuth session on Linux and
  Windows; sensitive, never print it. On macOS the session lives in the
  Keychain item `Claude Code-credentials`.

With `CLAUDE_CONFIG_DIR` set, all of these, `.claude.json` included, live in
that directory instead.

## Install and update

- Native install: `~/.local/bin/claude` links to
  `~/.local/share/claude/versions/<version>`. It follows Anthropic's own
  channel, which answers the newest version as plain text at
  `https://downloads.claude.ai/claude-code-releases/latest` (or `/stable`).
  fluttAIrbar compares against the channel the user's settings select and
  updates with `claude update`. No 14-day gate applies, as for Grok Build.
- npm install (`@anthropic-ai/claude-code`, binary under `node_modules`):
  checked with `npm view` and updated with an exact `npm install --global`,
  behind the 14-day release-age gate. The platform binary packages
  `@anthropic-ai/claude-code-*` share the scoped exemption used for a confirmed
  early update.

## Usage meters

`GET https://api.anthropic.com/api/oauth/usage` with the session's bearer
token and `anthropic-beta: oauth-2025-04-20`. Observed on 2026-11-01 the answer
holds top-level `five_hour` and `seven_day` objects (`utilization`,
`resets_at`), many other keys that are `null` (`seven_day_opus`,
`seven_day_sonnet` and internal names), an `extra_usage` object, and a
`limits` list (`kind`: `session`, `weekly_all`, `weekly_scoped`; `percent`,
`resets_at`, `scope.model.display_name`). Model-specific weekly limits
currently appear only in `limits`, so fluttAIrbar reads both shapes and keeps
any unknown window with a numeric `utilization`.

The session is never refreshed or rewritten. An expired access token is
reported as `expired: run claude to renew it`.

## Verification

```bash
claude --version
fluttairbar-cli harnesses --only claude
fluttairbar-cli usage
```
