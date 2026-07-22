#!/usr/bin/env python3
"""Translate Codex hook events to the existing IWE/Claude hook contract.

The scripts in .claude/hooks remain the behavior source of truth.  This adapter
normalizes Codex tool names and payloads, runs dependent policies sequentially,
and converts their output back to the current Codex hook schema.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


ROOT = Path(os.environ.get("CODEX_PROJECT_DIR", Path(__file__).resolve().parents[2]))
CLAUDE_HOOKS = Path(os.environ.get("IWE_CLAUDE_HOOKS", ROOT / ".claude" / "hooks"))

HOOKS: dict[str, list[str]] = {
    "SessionStart": ["check-trash.sh"],
    "UserPromptSubmit": [
        "wp-gate-reminder.sh",
        "close-gate-reminder.sh",
        "inject-role-prefixes.sh",
        "lazy-context-loader.sh",
    ],
    "PreToolUse:Bash": [
        "pull-on-touch.sh",
        "destructive-guard.sh",
        "protocol-artifact-validate.sh",
        "dry-run-gate.sh",
    ],
    "PreToolUse:apply_patch": [
        "pull-on-touch.sh",
        "extensions-gate.sh",
        "capture-bus.sh",
        "dry-run-gate.sh",
    ],
    "PreToolUse:other": ["pull-on-touch.sh", "dry-run-gate.sh"],
    "PostToolUse:apply_patch": ["memory-exocortex-sync.sh"],
    "PostToolUse:other": ["protocol-completion-reminder.sh"],
    "PreCompact": ["precompact-checkpoint.sh"],
    # Codex has no SessionEnd.  Stop is the closest safe fail-safe: status is
    # refreshed after each completed turn, and capture cleanup remains timely.
    "Stop": ["protocol-stop-gate.sh", "capture-bus.sh", "session-end-status.sh"],
}


def load_input() -> dict[str, Any]:
    try:
        value = json.load(sys.stdin)
        return value if isinstance(value, dict) else {}
    except (json.JSONDecodeError, OSError):
        return {}


def patch_paths(command: str) -> list[str]:
    return re.findall(r"^\*\*\* (?:Add|Update|Delete) File: (.+)$", command, re.M)


def claude_payload(source: dict[str, Any]) -> dict[str, Any]:
    payload = dict(source)
    tool = str(source.get("tool_name", ""))
    tool_input = source.get("tool_input")
    tool_input = dict(tool_input) if isinstance(tool_input, dict) else {}
    if tool == "apply_patch":
        paths = patch_paths(str(tool_input.get("command", "")))
        payload["tool_name"] = "Write"
        if paths:
            path = Path(paths[0])
            tool_input["file_path"] = str(path if path.is_absolute() else ROOT / path)
    payload["tool_input"] = tool_input
    if "prompt" in source:
        payload["message"] = source["prompt"]
    return payload


def select_hooks(event: str, source: dict[str, Any]) -> list[str]:
    if event not in ("PreToolUse", "PostToolUse"):
        return HOOKS.get(event, [])
    tool = str(source.get("tool_name", ""))
    if tool == "Bash":
        return HOOKS.get(f"{event}:Bash", HOOKS.get(f"{event}:other", []))
    if tool == "apply_patch":
        return HOOKS.get(f"{event}:apply_patch", HOOKS.get(f"{event}:other", []))
    return HOOKS.get(f"{event}:other", [])


def contexts_from(value: dict[str, Any]) -> list[str]:
    result: list[str] = []
    direct = value.get("additionalContext")
    if isinstance(direct, str) and direct:
        result.append(direct)
    specific = value.get("hookSpecificOutput")
    if isinstance(specific, dict):
        context = specific.get("additionalContext")
        if isinstance(context, str) and context:
            result.append(context)
    message = value.get("systemMessage")
    if isinstance(message, str) and message:
        result.append(message)
    return result


def iwe_memory_context() -> str:
    """Load shared IWE operational memory through the workspace alias."""
    candidates = [ROOT / ".codex" / "iwe-memory" / "MEMORY.md", ROOT / "memory" / "MEMORY.md"]
    for path in candidates:
        try:
            if path.is_file():
                content = path.read_text(encoding="utf-8").strip()
                if content:
                    return "IWE shared operational memory (Claude/Codex):\n\n" + content[:12000]
        except OSError:
            continue
    return ""


def main() -> int:
    event = sys.argv[1] if len(sys.argv) > 1 else ""
    source = load_input()
    payload = claude_payload(source)
    env = os.environ.copy()
    env.update({
        "CLAUDE_PROJECT_DIR": str(ROOT),
        "CODEX_PROJECT_DIR": str(ROOT),
        "CLAUDE_SESSION_ID": str(source.get("session_id", "codex")),
        "CLAUDE_AGENT_ID": str(source.get("model", "codex")),
    })
    contexts: list[str] = []
    block_reason = ""

    if event == "SessionStart":
        memory = iwe_memory_context()
        if memory:
            contexts.append(memory)

    for name in select_hooks(event, source):
        script = CLAUDE_HOOKS / name
        if not script.is_file():
            continue
        try:
            proc = subprocess.run(
                ["bash", str(script)], input=json.dumps(payload), text=True,
                capture_output=True, timeout=120, cwd=source.get("cwd") or ROOT, env=env,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired):
            # Existing hooks classify operational failures as non-blocking.
            continue
        stdout = proc.stdout.strip()
        value: dict[str, Any] = {}
        if stdout:
            try:
                parsed = json.loads(stdout)
                value = parsed if isinstance(parsed, dict) else {}
            except json.JSONDecodeError:
                if event in ("SessionStart", "UserPromptSubmit"):
                    contexts.append(stdout)
        contexts.extend(contexts_from(value))
        if proc.returncode == 2:
            block_reason = proc.stderr.strip() or stdout or f"Blocked by {name}"
            break
        if value.get("decision") == "block":
            block_reason = str(value.get("reason") or f"Blocked by {name}")
            break

    if block_reason:
        print(json.dumps({"decision": "block", "reason": block_reason}, ensure_ascii=False))
        return 0
    if contexts:
        print(json.dumps({
            "hookSpecificOutput": {
                "hookEventName": event,
                "additionalContext": "\n\n".join(contexts),
            }
        }, ensure_ascii=False))
    else:
        print("{}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
