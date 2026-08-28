# Local AI Harness Documentation

This directory is the durable handoff for the local AI-agent setup. It is
written for future agents and maintainers who need to understand which program
does what, where its configuration lives, and why the model lists differ.

Start with [`context.md`](context.md) for the architecture and the verified
cross-harness state. Then read the page for the harness being changed:

- [`codex.md`](codex.md) — native OpenAI/Codex runtime and its opt-in OpenRouter profile.
- [`codex-capability-packs.md`](codex-capability-packs.md) — research, implementation notes, and safety boundaries for toggling Codex plugins and MCP servers.
- [`pi.md`](pi.md) — direct Pi configuration and the Ori late-extension shim.
- [`grok.md`](grok.md) — Grok Build native models plus its fixed OpenRouter aliases.
- [`opencode.md`](opencode.md) — OpenCode provider whitelist and native OpenAI defaults.
- [`ori.md`](ori.md) — Ori as the launcher, credential, and harness-adapter layer.
- [`cursor-agent.md`](cursor-agent.md) — Cursor's separate first-party model catalog.
- [`fx.md`](fx.md) — Vercel Labs fx and its independent AI Gateway catalog.
- [`zcode.md`](zcode.md) — ZCode's direct Z.AI configuration.

## Scope

The current OpenRouter allowlist is deliberately limited to these exact model
IDs:

```text
stealth/ox-alpha
thinkingmachines/inkling-small:free
thinkingmachines/inkling:free
```

This restriction applies to OpenRouter-backed model entries. It does not
remove native OpenAI, xAI, Cursor, Vercel AI Gateway, or Z.AI models from the
harnesses that own those catalogs. Native Codex/OpenAI selection remains the
default for direct Codex use.

## What “approved agentic harness” means

OpenRouter's official Ori guide currently supports Claude Code, Codex, Grok
Build, Hermes, OpenCode, Pi, Prime Agent, and DeepSeek Harness (`dsh`). These
are agent runtimes: they own an agent loop, tools, sessions, and a model
protocol. Ori is the adapter that starts or configures them; it is not an
additional agent runtime.

That Ori support list is not a promise that every free endpoint accepts every
client identity. The Inkling free routes performed a provider-side client
check during the snapshot below. Pi, Codex, and OpenCode request identities
returned `HTTP 200`; a generic Ori identity and the Grok path returned
`HTTP 403` for Inkling. Ox Alpha worked through the tested Grok path. A model
appearing in a picker is therefore not proof that a request is authorized.

Do not spoof another harness's headers to bypass this check. Use a supported
path that the provider accepts, or wait for the provider to enable the desired
client identity.

## Security rule

Never paste or print the contents of any `auth.json`, `credentials.json`, API
key environment variable, or credential store. The pages in this directory
record paths, provider names, model IDs, and commands only. If a diagnostic
ever exposes a key, rotate the affected key before using it again.

## Snapshot

The checks documented here were run on 2026-08-22. Model catalogs and vendor
CLIs can change, so rerun the verification commands after updating a harness,
Ori, or the OpenRouter provider.

Official references:

- [Ori Harness guide](https://openrouter.ai/docs/guides/ori/harness)
- [Ox Alpha](https://openrouter.ai/stealth/ox-alpha)
- [Inkling Small (free)](https://openrouter.ai/thinkingmachines/inkling-small:free)
- [Inkling (free)](https://openrouter.ai/thinkingmachines/inkling:free)
