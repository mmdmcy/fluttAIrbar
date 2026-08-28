#!/usr/bin/env python3
"""Copy the upstream pstack skills into a Codex plugin.

The port is deliberately local and pinned by the caller. It never fetches from
the network, and it only accepts a directory whose upstream manifest identifies
the source as Cursor's pstack plugin.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
from pathlib import Path


MODEL_NAMES = (
    "claude-fable-5-thinking-max",
    "gpt-5.6-sol-max",
    "grok-4.6-fast-xhigh",
    "claude-opus-5-thinking-xhigh",
)

REMOVED_FRONTMATTER_KEYS = {
    "disable-model-invocation",
    "disable_model_invocation",
    "mode",
    "icon",
    "color",
    "reminder",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Port a pinned upstream Cursor pstack checkout into a Codex plugin."
    )
    parser.add_argument("source", type=Path, help="upstream pstack directory")
    parser.add_argument("destination", type=Path, help="Codex plugin directory")
    parser.add_argument(
        "--source-commit",
        required=True,
        help="commit hash recorded in the generated port metadata",
    )
    parser.add_argument(
        "--upstream-version",
        required=True,
        help="version recorded in the generated port metadata",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    source = args.source.resolve()
    destination = args.destination.resolve()
    validate_source(source)
    destination.mkdir(parents=True, exist_ok=True)

    source_skills = source / "skills"
    destination_skills = destination / "skills"
    if destination_skills.exists():
        shutil.rmtree(destination_skills)
    shutil.copytree(source_skills, destination_skills)

    skill_names = sorted(
        path.name for path in destination_skills.iterdir() if path.is_dir()
    )
    for skill_root in sorted(destination_skills.iterdir()):
        if not skill_root.is_dir():
            continue
        skill_file = skill_root / "SKILL.md"
        if not skill_file.is_file():
            raise SystemExit(f"missing SKILL.md: {skill_file}")
        port_skill(skill_file, skill_root.name, skill_names)
        write_agent_metadata(skill_root, skill_root.name)
        for path in skill_root.rglob("*"):
            if path.is_file() and path.suffix.lower() in {".md", ".mdc"}:
                if path.name != "SKILL.md":
                    path.write_text(adapt_text(path.read_text(encoding="utf-8"), skill_names), encoding="utf-8")
    package_json = destination_skills / "poteto-mode" / "scripts" / "package.json"
    if package_json.is_file():
        package_json.write_text(
            package_json.read_text(encoding="utf-8").replace(
                "@cursor-skill/poteto-mode-tools", "@fluttairbar/poteto-mode-tools"
            ),
            encoding="utf-8",
        )
    bun_lock = destination_skills / "poteto-mode" / "scripts" / "bun.lock"
    if bun_lock.is_file():
        bun_lock.write_text(
            bun_lock.read_text(encoding="utf-8").replace(
                "@cursor-skill/poteto-mode-tools", "@fluttairbar/poteto-mode-tools"
            ),
            encoding="utf-8",
        )
    worktree_audit = destination_skills / "poteto-mode" / "scripts" / "worktree-audit.sh"
    if worktree_audit.is_file():
        worktree_audit.write_text(
            adapt_text(worktree_audit.read_text(encoding="utf-8"), skill_names),
            encoding="utf-8",
        )

    license_file = source / "LICENSE"
    if license_file.is_file():
        shutil.copy2(license_file, destination / "LICENSE")

    port_metadata = {
        "schemaVersion": 1,
        "upstream": {
            "name": "pstack",
            "version": args.upstream_version,
            "repository": "https://github.com/cursor/plugins",
            "path": "pstack",
            "commit": args.source_commit,
            "license": "MIT",
            "author": "Lauren Tan",
        },
        "target": {
            "harness": "codex",
            "implicitInvocation": False,
            "skillCount": len(skill_names),
            "omittedComponents": [
                "agents/",
                "automations/benny/",
            ],
        },
    }
    (destination / "pstack-port.json").write_text(
        json.dumps(port_metadata, indent=2) + "\n", encoding="utf-8"
    )


def validate_source(source: Path) -> None:
    manifest_path = source / ".cursor-plugin" / "plugin.json"
    skills_path = source / "skills"
    if not manifest_path.is_file() or not skills_path.is_dir():
        raise SystemExit(f"not an upstream pstack checkout: {source}")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise SystemExit(f"invalid upstream manifest: {manifest_path}: {error}") from error
    if manifest.get("name") != "pstack":
        raise SystemExit(f"expected pstack manifest, got {manifest.get('name')!r}")


def port_skill(path: Path, skill_name: str, skill_names: list[str]) -> None:
    contents = path.read_text(encoding="utf-8")
    if not contents.startswith("---\n"):
        raise SystemExit(f"skill has no YAML frontmatter: {path}")
    end = contents.find("\n---\n", 4)
    if end == -1:
        raise SystemExit(f"skill frontmatter is not closed: {path}")

    frontmatter = adapt_text(contents[4:end], skill_names)
    body = adapt_text(contents[end + len("\n---\n") :], skill_names)
    frontmatter_lines = []
    for line in frontmatter.splitlines():
        match = re.match(r"^(?P<key>[A-Za-z0-9_-]+):", line)
        if match and match.group("key") in REMOVED_FRONTMATTER_KEYS:
            continue
        if match and match.group("key") == "name":
            frontmatter_lines.append(f"name: {skill_name}")
        else:
            frontmatter_lines.append(line)

    path.write_text(
        "---\n" + "\n".join(frontmatter_lines) + "\n---\n" + body,
        encoding="utf-8",
    )


def read_description(path: Path) -> str:
    contents = path.read_text(encoding="utf-8")
    end = contents.find("\n---\n", 4)
    if end == -1:
        return ""
    frontmatter = contents[4:end]
    match = re.search(r"^description:\s*(.+)$", frontmatter, flags=re.MULTILINE)
    if match is None:
        return ""
    return match.group(1).strip().strip('"').strip("'")


def write_agent_metadata(skill_root: Path, skill_name: str) -> None:
    display_name = " ".join(part.capitalize() for part in skill_name.split("-"))
    short_description = f"pstack {display_name} workflow"
    prompt = f"Use ${skill_name} to apply the pstack {display_name} workflow."
    yaml = (
        "interface:\n"
        f"  display_name: {quote_yaml(display_name)}\n"
        f"  short_description: {quote_yaml(short_description)}\n"
        f"  default_prompt: {quote_yaml(prompt)}\n"
        "policy:\n"
        "  allow_implicit_invocation: false\n"
    )
    agent_root = skill_root / "agents"
    agent_root.mkdir(exist_ok=True)
    (agent_root / "openai.yaml").write_text(yaml, encoding="utf-8")


def quote_yaml(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def adapt_text(contents: str, skill_names: list[str]) -> str:
    replacements = (
        ("~/.cursor/rules/pstack-models.mdc", "~/.codex/pstack-models.md"),
        ("writes an always-applied rule that overrides the skill defaults", "writes a pstack role map that records overrides for future pstack runs"),
        ("an always-applied rule that sets pstack's model per role", "a pstack role map that sets pstack's model per role"),
        ("with `alwaysApply: true` and one line per role", "with one line per role"),
        ("alwaysApply: true\n", ""),
        ("`inherit-parent` or `auto` as a value: the role runs on the parent chat model (omit Task `model`).", "`inherit-parent` or `auto` as a value: the role runs on the parent chat model (omit an explicit model)."),
        ("Task `model`", "an explicit model"),
        ("@cursor-skill/poteto-mode-tools", "@fluttairbar/poteto-mode-tools"),
        ("~/.cursor/projects/<slug>/agent-transcripts/<uuid>/<uuid>.jsonl", "the active Codex session transcript path provided by the host"),
        ("Transcripts dir: ~/.cursor/projects/<slugified-repo-path>/agent-transcripts.", "Optional transcript correlation: set CODEX_TRANSCRIPTS_DIR when the host exposes a stable transcript directory."),
        ('transcripts="$HOME/.cursor/projects/$slug/agent-transcripts"', 'transcripts="${CODEX_TRANSCRIPTS_DIR:-}"'),
        ("~/Library/Application Support/Cursor", "the editor cache directory"),
        (".cursor/", ".codex/"),
        ("Cursor's built-in `create-skill`", "Codex's `$skill-creator` skill"),
        ("Cursor's built-in create-skill", "Codex's `$skill-creator` skill"),
        ("Cursor's built-in `/create-skill`", "Codex's `$skill-creator` skill"),
        ("Cursor's built-in babysit skill", "the host's task-monitoring workflow"),
        ("cursor-team-kit", "host tooling plugin"),
        ("control-cli", "host CLI verification tooling"),
        ("control-ui", "host UI verification tooling"),
        ("host tooling plugin", "available host tooling"),
        ("cursor location", "current editor location"),
        ("cursor environment", "Codex environment"),
        ("cursor restart", "Codex restart"),
        ("Codex cloud agent", "Codex background subagent"),
        ("cloud agent", "background subagent"),
        ("Cursor's", "Codex's"),
        ("Cursor’s", "Codex’s"),
        ("agents/poteto-agent.md", "skills/poteto-mode/SKILL.md"),
        ('subagent_type: "generalPurpose"', "a general-purpose subagent"),
        ('subagent_type: generalPurpose', "a general-purpose subagent"),
        ('subagent_type: "poteto-agent"', "a pstack-style subagent"),
        ('subagent_type: "Comment Sicko"', "the pstack comment reviewer"),
        ("`subagent_type`: `generalPurpose`", "subagent type: general-purpose"),
        ("`subagent_type`: generalPurpose", "subagent type: general-purpose"),
        ("`subagent_type`: `poteto-agent`", "subagent type: pstack-style"),
        ("`subagent_type`: `Comment Sicko`", "the pstack comment reviewer"),
        ("AskQuestion", "structured user-choice prompt"),
        ("Task tool", "subagent interface"),
        ("`Task` tool", "subagent interface"),
        ("`Task` subagent", "subagent"),
        ("Task response", "subagent response"),
        ("`Task` calls", "`subagent` calls"),
        ("`Task` call", "`subagent` call"),
        ("`Task` prompts", "`subagent` prompts"),
        ("`Task` call", "subagent call"),
        ("full Task schema", "full subagent schema"),
        ("Cloud agents", "Background subagents"),
        ("Always `environment: \"cloud\"`", "Prefer background execution"),
        ("unless the task needs this machine", "unless the task needs this machine"),
        ('`environment: "cloud"`, `run_in_background: true`, and the configured model', "background execution, `run_in_background: true`, and the configured model"),
        ('Use `environment: "local"` only when the worker needs access to something on the user\'s computer', "Use the host's local execution mode only when the worker needs access to something on the user's computer"),
        ("Task subagent", "subagent"),
        ("Frontmatter `disable-model-invocation: true`", "Codex metadata `allow_implicit_invocation: false`"),
    )
    for old, new in replacements:
        contents = contents.replace(old, new)
    for model_name in MODEL_NAMES:
        contents = contents.replace(model_name, "auto")

    contents = re.sub(r"(?<![A-Za-z0-9_$:./-])/create-skill(?![A-Za-z0-9_-])", "$skill-creator", contents)
    contents = re.sub(r"(?<![A-Za-z0-9_$:./-])/deslop(?![A-Za-z0-9_-])", "$unslop", contents)
    contents = re.sub(r"(?<![A-Za-z0-9_$:./-])/no-comments(?![A-Za-z0-9_-])", "$no-comments", contents)
    contents = re.sub(
        r"(?<![A-Za-z0-9_$:./-])/babysit(?![A-Za-z0-9_-])",
        "the host task-monitoring workflow",
        contents,
    )
    contents = re.sub(
        r"(?<![A-Za-z0-9_$:./-])/loop(?![A-Za-z0-9_-])",
        "the host recurring-monitoring workflow",
        contents,
    )

    contents = re.sub(
        r"(?<![A-Za-z0-9_$:./-])create-skill(?![A-Za-z0-9_-])",
        "$skill-creator",
        contents,
    )
    contents = re.sub(
        r"(?<![A-Za-z0-9_$:./-])deslop(?![A-Za-z0-9_-])",
        "$unslop",
        contents,
    )
    contents = re.sub(
        r"(?<![A-Za-z0-9_$:./-])poteto-agent(?![A-Za-z0-9_-])",
        "pstack-style subagent",
        contents,
    )

    contents = re.sub(r"(?<![/A-Za-z0-9_.-])Cursor(?![/A-Za-z0-9_.-])", "Codex", contents)
    contents = re.sub(r"(?<![/A-Za-z0-9_.-])cursor(?![/A-Za-z0-9_.-])", "Codex", contents)

    # Convert direct pstack slash invocations to Codex's explicit skill form,
    # while protecting URLs, relative paths, and ordinary filesystem paths.
    known = set(skill_names)

    def replace_skill_invocation(match: re.Match[str]) -> str:
        name = match.group("name")
        return f"${name}" if name in known else match.group(0)

    return re.sub(
        r"(?<![A-Za-z0-9_$:./-])/(?P<name>[a-z][a-z0-9-]*)(?![A-Za-z0-9_-])",
        replace_skill_invocation,
        contents,
    )


if __name__ == "__main__":
    main()
