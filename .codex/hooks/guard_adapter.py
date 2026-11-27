#!/usr/bin/env python3
"""Codex adapter for the template's Claude Code guards (WP-592 F6).

Usage, from .codex/hooks.json:
    python3 "$(git rev-parse --show-toplevel)/.codex/hooks/guard_adapter.py" <guard> [--agent codex] [--matcher REGEX]

<guard> is a file name in .claude/hooks (for example extensions-gate.sh); REGEX is the guard's matcher
in .claude/settings.json, so the guard sees exactly the Claude tools it sees under Claude Code.

Codex 0.169 sends the Claude Code envelope (hook_event_name, session_id, cwd, tool_name, tool_input)
for Bash as is, so a Bash call goes to the guard unchanged. For apply_patch the files are only inside
the patch text in tool_input.command; the adapter splits the patch into one Claude-shaped call per
file (Add -> Write, Update -> Edit, Delete -> Write with empty content, Move -> Write of the target
too), runs the guard on each, and the first block wins.

The guard may answer in any of the Claude Code forms: exit 2 with a reason on stderr, or exit 0 with
JSON permissionDecision "deny"/"ask" or decision "block". Codex has no prompt for "ask", so it is a
deny too. Every failure to read the input, run the guard or understand its answer is a deny: an
error never becomes an allow (Codex itself treats a failed hook as an allow).

The guards find the workspace through CLAUDE_PROJECT_DIR and IWE_ROOT; both are set to the folder
that holds this .codex/, so a guard never reads another workspace's state.
"""
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GUARD_TIMEOUT = 55  # below the 60 s hook timeout in .codex/hooks.json
FILE_HEADERS = (
    ("*** Add File: ", "add"),
    ("*** Update File: ", "update"),
    ("*** Delete File: ", "delete"),
)


class AdapterError(Exception):
    """The adapter cannot evaluate the call: the answer is a deny."""


def answer(event, reason):
    """Print the deny in the form Codex reads for this event and stop."""
    if event == "PostToolUse":
        out = {"decision": "block", "reason": reason}
    else:
        out = {"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                      "permissionDecision": "deny",
                                      "permissionDecisionReason": reason}}
    print(json.dumps(out, ensure_ascii=False))
    sys.exit(0)


def split_patch(text):
    """Return [{op, path, plus, minus, move}] for each file of a Codex patch."""
    lines = text.split("\n")
    if not lines or lines[0].strip() != "*** Begin Patch":
        raise AdapterError("заплатка не начинается с «*** Begin Patch»")
    files, current = [], None
    for line in lines[1:]:
        if line.strip() == "*** End Patch":
            break
        header = next(((line[len(p):].strip(), op) for p, op in FILE_HEADERS if line.startswith(p)), None)
        if header:
            current = {"op": header[1], "path": header[0], "plus": [], "minus": [], "move": None}
            files.append(current)
        elif current is None:
            if line.strip():
                raise AdapterError("в заплатке текст до заголовка файла")
        elif line.startswith("*** Move to: "):
            current["move"] = line[len("*** Move to: "):].strip()
        elif line.startswith("+"):
            current["plus"].append(line[1:])
        elif line.startswith("-"):
            current["minus"].append(line[1:])
    else:
        raise AdapterError("заплатка не заканчивается «*** End Patch»")
    if not files or any(not f["path"] for f in files):
        raise AdapterError("в заплатке нет файла или пути")
    return files


def claude_calls(envelope):
    """The Claude-shaped envelopes the guard has to see for this Codex call."""
    tool = envelope.get("tool_name")
    if tool != "apply_patch":
        return [envelope]
    patch = (envelope.get("tool_input") or {}).get("command")
    if not isinstance(patch, str):
        raise AdapterError("у apply_patch нет текста заплатки")
    cwd = Path(envelope.get("cwd") or ROOT)
    calls = []
    for f in split_patch(patch):
        path = str(cwd / f["path"])  # an absolute path stays as is
        plus = "\n".join(f["plus"])
        if f["op"] == "add":
            calls.append(("Write", {"file_path": path, "content": plus + "\n"}))
        elif f["op"] == "delete":
            calls.append(("Write", {"file_path": path, "content": ""}))
        else:
            calls.append(("Edit", {"file_path": path, "old_string": "\n".join(f["minus"]), "new_string": plus}))
        if f["move"]:
            calls.append(("Write", {"file_path": str(cwd / f["move"]), "content": plus}))
    return [dict(envelope, tool_name=name, tool_input=tool_input) for name, tool_input in calls]


def guard_verdict(guard, call, agent):
    """None when the guard allows, else the reason of its block."""
    env = dict(os.environ)
    # Always this workspace, even when the caller's shell exports another IWE_ROOT: a guard reading
    # another workspace's open sessions let a commit through in the live probe of 27.11.
    env["CLAUDE_PROJECT_DIR"] = str(ROOT)
    env["IWE_ROOT"] = str(ROOT)
    if agent:
        env["IWE_AGENT"] = agent
    runner = ["python3"] if guard.suffix == ".py" else ["bash"]
    try:
        done = subprocess.run(runner + [str(guard)], input=json.dumps(call), capture_output=True,
                              text=True, timeout=GUARD_TIMEOUT, env=env, cwd=call.get("cwd") or ROOT)
    except subprocess.TimeoutExpired:
        raise AdapterError(f"{guard.name} не уложился в {GUARD_TIMEOUT} с")
    except OSError as exc:
        raise AdapterError(f"{guard.name} не запустился: {exc}")
    reason = done.stderr.strip()
    if done.returncode == 2:
        return reason or f"заблокировано проверкой {guard.name}"
    if done.returncode != 0:
        raise AdapterError(f"{guard.name} упал с кодом {done.returncode}: {reason}")
    return json_block_reason(guard, done.stdout)


def json_block_reason(guard, stdout):
    """Read the answer of an exit-0 guard: the reason of a deny/ask/block, else None.

    The answer is one JSON document (some guards pretty-print it over many lines) or JSON lines
    mixed with plain hint text; an answer that starts like JSON but does not parse is a deny.
    """
    text = stdout.strip()
    if not text:
        return None
    try:
        documents = [json.loads(text)]
    except json.JSONDecodeError:
        documents = []
        for line in text.splitlines():
            try:
                documents.append(json.loads(line))
            except json.JSONDecodeError:
                continue  # plain hint text next to the JSON is not a decision
        if not documents and text.startswith("{"):
            raise AdapterError(f"{guard.name} ответил неразборчиво")
    for data in documents:
        reason = decision_reason(guard, data) if isinstance(data, dict) else None
        if reason:
            return reason
    return None


def decision_reason(guard, data):
    spec = data.get("hookSpecificOutput") or {}
    decision = spec.get("permissionDecision")
    if decision in ("deny", "ask"):
        prefix = "нужно подтверждение человека: " if decision == "ask" else ""
        return prefix + (spec.get("permissionDecisionReason") or f"запрещено проверкой {guard.name}")
    if data.get("decision") == "block":
        return data.get("reason") or f"заблокировано проверкой {guard.name}"
    return None


def parse_args(argv):
    """<guard> [--agent NAME] [--matcher REGEX]; REGEX is the guard's matcher in .claude/settings.json."""
    if len(argv) < 2 or len(argv) % 2:
        raise AdapterError("вызов: guard_adapter.py <проверка> [--agent <имя>] [--matcher <выражение>]")
    options = dict(zip(argv[2::2], argv[3::2]))
    if set(options) - {"--agent", "--matcher"}:
        raise AdapterError(f"неизвестный ключ: {sorted(set(options) - {'--agent', '--matcher'})}")
    name = argv[1]
    if "/" in name or not (ROOT / ".claude" / "hooks" / name).is_file():
        raise AdapterError(f"проверка {name} не найдена в .claude/hooks")
    try:
        matcher = re.compile(options["--matcher"]) if "--matcher" in options else None
    except re.error as exc:
        raise AdapterError(f"неверное выражение --matcher: {exc}")
    return ROOT / ".claude" / "hooks" / name, options.get("--agent"), matcher


def main(argv):
    event = "PreToolUse"
    try:
        envelope = json.loads(sys.stdin.read())
        if not isinstance(envelope, dict):
            raise AdapterError("вход хука — не объект JSON")
        event = envelope.get("hook_event_name") or event
        guard, agent, matcher = parse_args(argv)
        if shutil.which("jq") is None:
            raise AdapterError("jq не установлен, проверки не могут разобрать вход")
        # Like Claude Code, the guard sees only the tools its matcher names; the rest is not its job.
        calls = [c for c in claude_calls(envelope) if matcher is None or matcher.fullmatch(c["tool_name"])]
        for call in calls:
            reason = guard_verdict(guard, call, agent)
            if reason:
                answer(event, reason)
    except (AdapterError, ValueError, OSError) as exc:  # ValueError: stdin is not JSON
        answer(event, f"проверка не может оценить действие ({exc}) — действие не пропущено")
    sys.exit(0)


if __name__ == "__main__":
    main(sys.argv)
