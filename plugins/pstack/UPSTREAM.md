# pstack port record

The Codex plugin was generated from the official `cursor/plugins` repository at commit `bdf7aa355337897f167153e05069aca505dae17c`, under `pstack/`, version `0.14.3`.

Source links:

- Repository: <https://github.com/cursor/plugins>
- Upstream plugin: <https://github.com/cursor/plugins/tree/main/pstack>

The repeatable port command is [`tool/port_pstack_to_codex.py`](../../tool/port_pstack_to_codex.py). It accepts a local, pinned checkout and does not fetch or execute upstream code. It copies the flat `skills/` tree, removes Cursor-only frontmatter fields, writes Codex `agents/openai.yaml` metadata with `allow_implicit_invocation: false`, and adapts common host references.

The port retains all 44 upstream skill directories and their Markdown references. It omits `agents/` and `automations/benny/` from the active plugin. The former relies on Cursor's subagent manifest format. The latter contains Slack, tracker, repository, and UI automation instructions that need a separate security review before any Codex integration.

The original MIT license and author attribution remain in [`LICENSE`](./LICENSE) and [`NOTICE`](./NOTICE). The plugin manifest identifies Lauren Tan as the original author and fluttAIrbar as the adapter. This project does not claim upstream endorsement.
