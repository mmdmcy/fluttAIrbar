# pstack for Codex

This plugin is a Codex adaptation of [Cursor's pstack](https://github.com/cursor/plugins/tree/main/pstack), originally authored by Lauren Tan. It keeps the upstream flat skill layout and category scheme while translating invocation metadata and host-specific references for Codex.

The plugin is explicit-only. Installing it does not make its skill bodies part of every task. Invoke the entry skill with `$poteto-mode`, or invoke a focused skill such as `$architect` or `$why` when needed.

## Install from this repository

From the repository root, add the local marketplace and install the plugin:

```bash
codex plugin marketplace add .
codex plugin add pstack@fluttairbar-local
```

Start a new Codex thread after installation. fluttAIrbar can show and edit the plugin's enabled state, but it does not restart or interrupt Codex.

## Categories

The original source uses one flat `skills/` directory. [`pstack-catalog.json`](./pstack-catalog.json) preserves the category groupings for tooling and lists the 22 Poteto Mode playbooks. The pack contains 44 skills.

- `poteto-mode` is the opt-in router.
- Workflow skills cover architecture, investigation, review, verification, writing, and execution.
- Principle skills are grouped into core, architecture, verification, delegation, and meta.

## Port boundary

The active plugin contains the 44 skill directories and their supporting references. Cursor-specific subagent manifests and the dormant `automations/benny/` pack are intentionally omitted. See [`UPSTREAM.md`](./UPSTREAM.md) for the pinned source, transformation rules, and attribution.

This is an independent Codex adaptation. It is not an official Cursor or OpenAI plugin.
