# Codex capability packs

## Status

Research and implementation notes. Updated 2026-08-26. The app changes only
the user-level Codex configuration after an explicit user confirmation; it
does not install, restart, or interrupt Codex automatically.

## Decision summary

The idea is feasible for Codex CLI, with one terminology adjustment: the
product should manage **capability packs** and their components, rather than
promise that it can hot-load and hot-unload arbitrary instructions from an
existing session.

A capability pack can group:

- one or more Codex plugins and their bundled skills;
- direct local skills, when a stable `SKILL.md` path is available; and
- one or more MCP servers.

The implemented v1 manages already-installed Codex plugins and MCP servers at
the user level. It shows each component's state, applies a small targeted
configuration change, keeps a backup, and tells the user when a new Codex task
or restart is required. Direct standalone skill entries and plugin installation
are intentionally deferred.

This gives the user the intended outcome—many capabilities can remain
available on disk while only the relevant set is exposed to the model—without
implying a runtime unload guarantee for an already-running task.

### Direct answer for this conversation

Yes, the Stripe MCP is exposed in this conversation. The current tool
registry contains 10 `mcp__stripe__...` tools covering account management,
documentation search, API search/read/write, analytics, and integration
planning. I have not called any of them. The distinction is therefore:

```text
Stripe MCP: exposed to the model, not invoked
Stripe skills: catalog metadata exposed, full skill bodies not selected
```

The available-skill inventory in this conversation also contains eight
Stripe-related skill entries. Their names, descriptions, and source locations
are present in the model-visible instructions. I have not selected or read a
Stripe `SKILL.md` body in this conversation, so “loaded” is accurate for the
lightweight inventory metadata but not for the full skill instructions.

This is exactly the bloat/control problem in the proposal. The current
conversation's host has already decided which tools and skill inventory to
expose; fluttAIrbar cannot retroactively remove them from this active session.
For Codex CLI, fluttAIrbar can change the host configuration for future Codex
processes or tasks, then verify that the new session has a smaller exposed
surface.

## What Codex actually loads

Codex has four related but different concepts:

| Concept | What it means | Product implication |
| --- | --- | --- |
| Discoverable | Codex found a skill and can advertise its name and description. | A large inventory has bounded metadata overhead and can affect discoverability. |
| Exposed | The current host has placed a tool schema or skill inventory entry in the model input. | This is the bloat and authority surface the user actually wants to control. |
| Enabled | Configuration permits the skill, plugin, or MCP server to be used. | This is the main state fluttAIrbar can manage. |
| Selected/active in a session | The running task has loaded a skill's full instructions, or the host has connected an MCP server and exposed its tools. | Configuration changes should be shown as pending until a new task/restart. |

### Skills

Codex starts with a skill's name and description and loads the full
`SKILL.md` only when the skill is selected. The current skills documentation
also describes a bounded initial skill list—at most 2% of context or 8,000
characters when the limit is otherwise unknown—and warns that large skill
sets can be truncated. That means an always-installed skill set is not the
same as loading every full instruction file, but a very large inventory can
still consume metadata budget and make the right skill harder to find.

Skills can be explicitly invoked with `$skill-name`. A skill can also opt out
of implicit invocation through `agents/openai.yaml` with
`allow_implicit_invocation: false`; this reduces accidental activation but
does not by itself remove the skill from the discoverable inventory.

Codex supports disabling a local skill without deleting it through a
`[[skills.config]]` entry with the skill's `SKILL.md` path and
`enabled = false`. This is a useful control for direct local skills, although
plugin-cache paths are a poor long-term identifier for a product registry.

For a pack containing many direct skills, fluttAIrbar can manage the set of
individual `skills.config` entries. For a bundled plugin, the preferred pack
operation is the plugin's own on/off state if the current Codex host exposes
it. The exact whole-plugin behavior must be verified in a fresh task; do not
infer it from a plugin's installed/listed state alone.

Source: [Codex skills documentation](https://learn.chatgpt.com/docs/build-skills).

### Plugins

Codex plugins are distribution units. A plugin can bundle skills, MCP server
configuration, apps, hooks, and other assets. Codex's plugin documentation
supports installing plugins from marketplaces and configuring each plugin's
on/off state. A plugin-level switch is the most natural control for a
multi-skill bundle such as the original Cursor pstack, once it has been
adapted for Codex.

Plugin enablement is not a sufficient abstraction for every plugin. A plugin
may expose an app or an MCP server whose runtime identity is configured
separately. On this host, the installed Stripe plugin is
`stripe@openai-curated`, while its active MCP entry is the top-level server
`stripe`. The product must discover and verify those relationships rather
than assume that toggling one automatically toggles the other.

Source: [Codex plugin documentation](https://developers.openai.com/plugins/build/plugins)
and [Codex configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference).

### MCP servers

MCP servers supply tools and server instructions to the Codex client. They
are therefore a stronger candidate for “always-on” overhead and tool-surface
reduction than skills whose full instructions have not been selected. Exact
token savings depend on the server's tool schemas and the host; they should
be measured rather than assumed.

Codex supports `enabled = false` for an entire MCP server without deleting its
configuration. This is the primary switch in the user's proposal. It also
supports tool allowlists and denylists, which are a separate, narrower control
when a user wants a server connected but not every tool available.

The relevant configuration shape is approximately:

```toml
[mcp_servers.stripe]
enabled = false
```

The exact table name must come from Codex's resolved configuration. A pack
adapter must not write credentials, bearer tokens, HTTP headers, or
`auth.json`.

Source: [Codex MCP documentation](https://learn.chatgpt.com/docs/extend/mcp?surface=cli).

### Scope and lifecycle

Codex reads user configuration from `$CODEX_HOME/config.toml` (normally
`$HOME/.codex/config.toml`). Project-level `.codex/config.toml` files have
trust-sensitive behavior. The first fluttAIrbar implementation should use
the user-level scope and make project scope an explicit later choice.

The safe UI state model is:

```text
Installed → Enabled → Active in new task
                  ↘ Pending restart/new task
```

“Disabled” should mean “the next task will not receive this capability.” It
should not claim that instructions or tools already present in a running task
have been revoked. A running Codex session can retain state it already
received, and ending a session automatically could destroy unsaved work.

Sources: [Codex skills documentation](https://learn.chatgpt.com/docs/build-skills),
[Codex MCP documentation](https://learn.chatgpt.com/docs/extend/mcp?surface=cli),
and [Codex configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference).

## Local verification

The machine used for this research has Codex CLI `0.149.1` and currently
reports:

```text
codex mcp list → stripe, enabled, streamable HTTP, OAuth
codex plugin list --json → stripe@openai-curated, installed and enabled
```

That is the local Codex CLI layer. It is separate from the current API
conversation's host-level tool registry described above.

The CLI exposes these useful read-only surfaces:

```bash
codex plugin list --json
codex mcp list
codex mcp get stripe
codex debug prompt-input "local capability audit"
```

`codex debug prompt-input` renders the model-visible prompt input list as
JSON. It is useful for local before/after experiments, but its output can
include developer instructions and session context. fluttAIrbar must not
capture, upload, or log that output.

The configuration override below changes only that process invocation and
demonstrates the MCP control surface without editing the user's file:

```bash
codex -c 'mcp_servers.stripe.enabled=false' mcp list
```

The installed CLI reported the server as disabled under that override. A
similar plugin override should not be treated as verified until the resulting
skill/plugin behavior is checked in a fresh task; the plugin listing's
`enabled` field and the MCP runtime state are not interchangeable.

## Original Cursor pstack assessment

The trustworthy source to investigate is Cursor's official
[`cursor/plugins/pstack`](https://github.com/cursor/plugins/tree/main/pstack).
Its current manifest identifies pstack as version `0.14.3`, authored by Lauren
Tan, licensed under MIT, and declares `skills/` and `agents/` under a
`.cursor-plugin/plugin.json` manifest.

The current source tree contains 44 skills. The README describes 22 Poteto
Mode playbooks and 21 principle skills. It also contains a dormant Benny
automation pack under `automations/benny/`. The pstack manifest does not
declare an MCP server, so pstack's own burden is skill metadata/instructions
and optional automation, not a live MCP tool surface.

The source is Cursor-native rather than Codex-native:

- its metadata uses `.cursor-plugin/plugin.json`;
- its invocation examples use `/skill-name`;
- its instructions refer to Cursor primitives such as `Task` and
  `AskQuestion`; and
- its setup and automation material writes Cursor-specific files.

The original `poteto-mode` skill is marked `disable-model-invocation: true`
in its Cursor frontmatter. It is intended as an explicit entry point that
routes to other situational skills. That is a useful design signal for our
pack model, but it does not mean the other 43 skill descriptions disappear
from a Codex-compatible host.

Therefore the original pstack repository is a good source to audit and
adapt, but it cannot be treated as a ready-to-install Codex plugin. The
separately reviewed port now lives in [`plugins/pstack`](../../plugins/pstack/README.md).
It has a clear mapping for Cursor-only primitives, omits optional automation,
and makes every ported skill explicit-only. We do not use the previously
investigated third-party conversion as evidence or as a dependency.

## Implemented fluttAIrbar product shape

### Placement

The Codex-only “Capabilities” view is available from the existing panel view
menu beside Usage and Harnesses. Harness status/config inspection remains
separate. Capability changes have their own confirmation, backup, pending
restart, and error states.

### Pack and component model

The internal model should distinguish a pack from the resources it controls:

```text
CapabilityPack
  id, display name, publisher, source, version/commit
  harness = codex
  components[]

CapabilityComponent
  kind = plugin | skill | mcp
  stable identity
  observed identity/path
  enabled state
  restart/new-task requirement
  trust metadata and warnings
```

The current implementation supports `plugin` and `mcp` components. A bundled
plugin is the stable control for its skills; standalone `skill` components are
reserved for a later adapter around Codex's `skills.config` entries.

Current examples:

- **Stripe guidance** — the installed Stripe plugin's bundled guidance skills;
  the `stripe` MCP component is separate and independently toggleable.
- **pstack for Codex** — 44 explicitly-invoked skills ported from the pinned
  official Cursor source; Cursor subagent manifests and Benny automation are
  omitted from the active plugin.

The Stripe pack should allow its skills and MCP to be toggled independently.
Some tasks need Stripe API guidance without granting a live Stripe tool
surface.

### User interaction

The implemented panel provides:

- enabled/disabled and installed/not-installed state;
- a component-level toggle and a pack-level “enable all/disable all” action;
- a confirmation explaining that Codex must be idle and fluttAIrbar will not
  restart or interrupt it; and
- a persistent “restart Codex manually” reminder after a write.

Scanning is manual; opening the view does not invoke Codex. The panel discovers
installed plugins and configured MCP servers, including uncurated resources in
“Other” groups. It does not expose command stderr, `auth.json`, OAuth stores,
environment values, or HTTP headers.

Avoid calling the action “load” unless the UI also explains that full skill
instructions are selected by Codex inside a task. “Enable for new Codex
tasks” is more accurate.

## Implementation status and next phases

### Implemented — discovery and safe enable/disable

The first implementation now discovers, without writing:

- installed plugins from `codex plugin list --json`;
- configured MCP servers from `codex mcp list`/`get`;
- curated plugin/MCP relationships (Stripe and pstack) plus dynamic “Other”
  groups.

The existing `LocalCommandRunner` supplies fixed command execution and the
capability manager never passes arbitrary user-entered executable or argument
lists.

The Codex-specific config adapter makes only allowlisted, targeted changes to
plugin and MCP state. It:

1. reads the file before editing and refuses a concurrent change;
2. preserves unrelated keys and unknown settings;
3. creates `config.toml.fluttairbar.bak` and writes atomically; and
4. never opens `auth.json`, displays credential values, or changes credential
   settings.

It does not rewrite `config.toml` from a reduced in-memory map. The manager is
covered by focused TOML/config and identity-mapping tests.

### Implemented — curated pack registry

Known packs are local metadata with explicit component mappings. The pstack
plugin is a first-party repository artifact with a pinned upstream commit and
repeatable port script. Installing it is still a deliberate CLI step documented
in its README; the capability panel only manages already-installed resources.

### Deferred — session-aware UX and installation

The UI reports a manual restart/new-task requirement and never terminates an
active agent. A future adapter may add a confirmed install flow, direct skill
entries, or a supported app-server/session control if Codex exposes one.

### Deferred — measurement and other harnesses

Use Codex's local prompt-input diagnostic and task-level observations to
measure:

- skill metadata size and truncation/discoverability changes;
- MCP tool/schema count and startup behavior;
- time to first response; and
- whether a new task observes the requested state.

Only then decide whether the primary value proposition is context reduction,
tool-surface reduction, startup latency, or all three. Other harnesses should
get their own adapters after the Codex state model is stable.

## Security boundaries

Capability management is configuration management plus tool authorization.
The UI should therefore:

- require confirmation before enabling an MCP server or installing a plugin;
- display publisher, source, version/commit, OAuth/API-key requirement, and
  hooks/external-process warnings;
- keep `auth.json`, OAuth stores, environment values, and HTTP headers out of
  the UI and logs;
- default to user-level configuration and make project-level scope explicit;
- keep plugin, skill, and MCP toggles independently auditable;
- treat third-party manifests and repositories as untrusted input; and
- provide a clear rollback path for every write.

Disabling a capability is reversible, but it is not a substitute for
revoking credentials or assuming that an already-running task forgot tools
it previously received.

## Decisions and deferred work

1. Packs are named groups containing independently toggleable components; the
   pack-level action is a convenience, not an atomic preset.
2. v1 toggles a bundled plugin as a unit. Per-skill controls remain deferred
   until stable standalone skill identities and cache behavior are available.
3. “Off” means disabled for future tasks. fluttAIrbar never restarts Codex.
4. v1 manages installed resources. Pstack installation remains an explicit
   documented CLI action.
5. v1 edits user-level `$CODEX_HOME/config.toml`; project scope is deferred.

## Acceptance criteria for v1

- The user can inspect installed Codex plugins and MCP servers without
  exposing secrets.
- A Stripe skills-only change does not accidentally enable the Stripe MCP.
- A Stripe MCP change is represented as a separate component.
- The pstack artifact shows its source, compatibility boundary, skill count,
  category catalog, and non-skill omissions.
- Enabling/disabling changes only intended Codex settings and preserves all
  unrelated configuration.
- External edits are detected instead of overwritten.
- The UI clearly reports “restart required” and leaves the restart to the user.
- Tests cover TOML/config fixtures, backup creation, identity mapping, and
  independent plugin/MCP state.
- No context-savings claim is made until before/after measurements exist.
