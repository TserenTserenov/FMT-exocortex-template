#!/usr/bin/env python3
"""Tests of .codex/hooks/guard_adapter.py, the Codex adapter for the template's guards (WP-592 F6).

Fake guards check how every answer form is translated (exit 2, pretty-printed and one-line JSON
deny, ask, decision block, crash, silence) and that the patch is split into one call per file. Real
guards of the template check the apply_patch paths Codex 0.169 actually sends (captured 27.11).
Run: python3 .claude/hooks/tests/test-codex-guard-adapter.py
"""
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

TEMPLATE = Path(__file__).resolve().parents[3]
ADAPTER = TEMPLATE / ".codex" / "hooks" / "guard_adapter.py"
SECRET_MATCHER = ("--matcher", "Read|Edit|MultiEdit|Grep")  # as in .claude/settings.json
FAILED = []
PASSED = [0]

FAKE_GUARDS = {
    "exit2.sh": 'cat >/dev/null; echo "нельзя" >&2; exit 2',
    "pretty-deny.sh": 'cat >/dev/null; printf \'{\\n  "hookSpecificOutput": {\\n    "hookEventName": "PreToolUse",\\n'
                      '    "permissionDecision": "deny",\\n    "permissionDecisionReason": "секрет"\\n  }\\n}\\n\'',
    "line-ask.sh": 'cat >/dev/null; echo \'{"hookSpecificOutput":{"permissionDecision":"ask","permissionDecisionReason":"спроси"}}\'',
    "block.sh": 'cat >/dev/null; echo "подсказка"; echo \'{"decision":"block","reason":"стоп"}\'',
    "crash.sh": 'cat >/dev/null; exit 7',
    "garbage.sh": 'cat >/dev/null; echo "{не json"',
    "allow.sh": 'cat >/dev/null; echo "просто подсказка"',
    # Records what it saw, then allows: the split of a patch into calls.
    "record.sh": 'cat >> "$IWE_ROOT/seen.jsonl"; echo >> "$IWE_ROOT/seen.jsonl"',
    # Blocks only a write to a path containing "protected".
    "path.sh": 'jq -e \'.tool_input.file_path | test("protected")\' >/dev/null && { echo "защищено" >&2; exit 2; }; exit 0',
}


def check(name, got, want):
    if got == want:
        PASSED[0] += 1
    else:
        FAILED.append(f"{name}: ожидалось {want!r}, получено {got!r}")


def make_site(with_template_hooks):
    site = Path(tempfile.mkdtemp()).resolve()
    (site / ".codex" / "hooks").mkdir(parents=True)
    shutil.copy(ADAPTER, site / ".codex" / "hooks" / "guard_adapter.py")
    if with_template_hooks:
        shutil.copytree(TEMPLATE / ".claude", site / ".claude", symlinks=True)
    else:
        (site / ".claude" / "hooks").mkdir(parents=True)
    for name, body in FAKE_GUARDS.items():
        (site / ".claude" / "hooks" / name).write_text("#!/usr/bin/env bash\n" + body + "\n")
    subprocess.run(["git", "init", "-q", str(site)], check=True)
    return site


def run(site, guard, envelope, raw=None, args=(), extra_env=None):
    """(decision, reason) as Codex reads the adapter's stdout: ("allow", "") when it is empty."""
    env = {"PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin", "HOME": str(site), **(extra_env or {})}
    done = subprocess.run([sys.executable, str(site / ".codex" / "hooks" / "guard_adapter.py"), guard, *args],
                          input=raw if raw is not None else json.dumps(envelope),
                          capture_output=True, text=True, env=env, timeout=120)
    if done.returncode != 0:
        return ("adapter-exit", str(done.returncode))
    out = done.stdout.strip()
    if not out:
        return ("allow", "")
    data = json.loads(out)
    if "hookSpecificOutput" in data:
        return (data["hookSpecificOutput"]["permissionDecision"], data["hookSpecificOutput"]["permissionDecisionReason"])
    return (data.get("decision"), data.get("reason"))


def bash(site, command):
    return {"hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {"command": command},
            "cwd": str(site), "session_id": "019d-test"}


def patch(site, body, event="PreToolUse"):
    return {"hook_event_name": event, "tool_name": "apply_patch",
            "tool_input": {"command": "*** Begin Patch\n" + body + "\n*** End Patch"},
            "cwd": str(site), "session_id": "019d-test"}


def test_answer_forms():
    site = make_site(False)
    try:
        ls = bash(site, "ls")
        check("код 2 → запрет", run(site, "exit2.sh", ls), ("deny", "нельзя"))
        check("многострочный JSON deny → запрет", run(site, "pretty-deny.sh", ls), ("deny", "секрет"))
        check("ask → запрет", run(site, "line-ask.sh", ls), ("deny", "нужно подтверждение человека: спроси"))
        check("decision block среди подсказок → запрет", run(site, "block.sh", ls), ("deny", "стоп"))
        check("падение → запрет", run(site, "crash.sh", ls)[0], "deny")
        check("неразборчивый JSON → запрет", run(site, "garbage.sh", ls)[0], "deny")
        check("подсказка без решения → разрешение", run(site, "allow.sh", ls), ("allow", ""))
        check("нет такой проверки → запрет", run(site, "missing.sh", ls)[0], "deny")
        check("имя проверки с путём → запрет", run(site, "../hooks/allow.sh", ls)[0], "deny")
        check("вход не JSON → запрет", run(site, "allow.sh", None, raw="{oops")[0], "deny")
        check("неизвестный ключ → запрет", run(site, "allow.sh", ls, args=("--mode", "x"))[0], "deny")
        check("неверное выражение → запрет", run(site, "allow.sh", ls, args=("--matcher", "("))[0], "deny")
        check("ключ без значения → запрет", run(site, "allow.sh", ls, args=("--agent",))[0], "deny")
        post = dict(bash(site, "ls"), hook_event_name="PostToolUse")
        check("после действия — форма decision block", run(site, "exit2.sh", post), ("block", "нельзя"))
    finally:
        shutil.rmtree(site)


def test_patch_split():
    site = make_site(False)
    try:
        body = (f"*** Add File: {site}/new.txt\n+hello\n"
                f"*** Update File: old.txt\n@@\n-keep\n+kept\n"
                f"*** Update File: a.txt\n*** Move to: b.txt\n@@\n-x\n+y\n"
                f"*** Delete File: {site}/gone.txt")
        check("заплатка из четырёх файлов → разрешение", run(site, "record.sh", patch(site, body)), ("allow", ""))
        seen = [json.loads(l) for l in (site / "seen.jsonl").read_text().splitlines() if l.strip()]
        got = [(c["tool_name"], c["tool_input"]["file_path"].replace(str(site) + "/", ""),
                c["tool_input"].get("content", c["tool_input"].get("new_string"))) for c in seen]
        check("разбор заплатки", got, [("Write", "new.txt", "hello\n"), ("Edit", "old.txt", "kept"),
                                       ("Edit", "a.txt", "y"), ("Write", "b.txt", "y"), ("Write", "gone.txt", "")])
        check("правка: старый текст", seen[1]["tool_input"]["old_string"], "keep")
        check("конверт сохраняет номер беседы", seen[0]["session_id"], "019d-test")
        two = f"*** Add File: {site}/fine.txt\n+a\n*** Add File: {site}/protected.txt\n+b"
        check("второй файл заплатки защищён → запрет", run(site, "path.sh", patch(site, two)), ("deny", "защищено"))
        check("заплатка без начала → запрет", run(site, "allow.sh", dict(patch(site, ""), tool_input={"command": "x"}))[0], "deny")
        no_end = dict(patch(site, ""), tool_input={"command": f"*** Begin Patch\n*** Add File: {site}/z\n+z"})
        check("заплатка без конца → запрет", run(site, "allow.sh", no_end)[0], "deny")
        check("заплатка без файлов → запрет", run(site, "allow.sh", patch(site, ""))[0], "deny")
        protected_new = patch(site, f"*** Add File: {site}/protected.txt\n+b")
        check("matcher без Write: запись нового файла не его дело", run(site, "path.sh", protected_new, args=("--matcher", "Edit")), ("allow", ""))
        protected_edit = patch(site, f"*** Update File: {site}/protected.txt\n@@\n-a\n+b")
        check("matcher с Edit: правка защищённого → запрет", run(site, "path.sh", protected_edit, args=("--matcher", "Edit"))[0], "deny")
        check("matcher не совпал с Bash → разрешение", run(site, "exit2.sh", bash(site, "ls"), args=("--matcher", "Edit|Write")), ("allow", ""))
    finally:
        shutil.rmtree(site)


def test_real_guards():
    site = make_site(True)
    try:
        (site / ".env").write_text("TOKEN=abc\n")
        env_edit = patch(site, f"*** Update File: {site}/.env\n@@\n-TOKEN=abc\n+TOKEN=x")
        check("secret-file-read-block: правка .env → запрет", run(site, "secret-file-read-block.sh", env_edit, args=SECRET_MATCHER)[0], "deny")
        plain = patch(site, f"*** Add File: {site}/notes.md\n+hello")
        check("secret-file-read-block: обычный файл → разрешение", run(site, "secret-file-read-block.sh", plain, args=SECRET_MATCHER), ("allow", ""))
        check("secret-leak-block: cat .env → запрет", run(site, "secret-leak-block.sh", bash(site, "cat .env"))[0], "deny")
        check("secret-leak-block: ls → разрешение", run(site, "secret-leak-block.sh", bash(site, "ls")), ("allow", ""))
        protocol = patch(site, f"*** Update File: {site}/memory/protocol-open.md\n@@\n-a\n+b")
        check("extensions-gate: правка протокола → запрет", run(site, "extensions-gate.sh", protocol)[0], "deny")
        ext = patch(site, f"*** Add File: {site}/extensions/my-rule.md\n+правило")
        check("extensions-gate: свой файл расширений → разрешение", run(site, "extensions-gate.sh", ext), ("allow", ""))
        commit = bash(site, "git commit -m x")
        check("session-open-gate: коммит без сессии → запрет", run(site, "session-open-gate.sh", commit, args=("--agent", "codex"))[0], "deny")
        # The caller's shell exports another workspace with an open Codex session (live probe 27.11).
        other = Path(tempfile.mkdtemp()).resolve()
        (other / ".iwe-runtime" / "sessions").mkdir(parents=True)
        (other / ".iwe-runtime" / "sessions" / "codex-1.open").write_text("agent: codex\nwp: WP-1\n")
        foreign = run(site, "session-open-gate.sh", commit, args=("--agent", "codex"), extra_env={"IWE_ROOT": str(other)})
        check("session-open-gate: чужой IWE_ROOT с открытой сессией не разрешает", foreign[0], "deny")
        shutil.rmtree(other)
        check("destructive-guard: rm -rf → запрет", run(site, "destructive-guard.sh", bash(site, "rm -rf victim"))[0], "deny")
    finally:
        shutil.rmtree(site)


MINIMAL_SET = {  # the pilot's minimal set, WP-592 F6 (27.11)
    "destructive-guard.sh", "destructive-mcp-guard.sh", "secret-file-read-block.sh", "secret-leak-block.sh",
    "secret-mcp-dump-guard.sh", "sql-pii-guard.sh", "dry-run-gate.sh", "extensions-gate.sh",
    "pack-creator-spf-guard.sh", "session-open-gate.sh",
}


def test_config_parity():
    """.codex/hooks.json wires the whole set, each guard on the event Claude uses and with its matcher."""
    claude = {}
    settings = json.loads((TEMPLATE / ".claude" / "settings.json").read_text())
    for event, groups in settings["hooks"].items():
        for g in groups:
            for h in g["hooks"]:
                claude[(event, Path(h["command"].split()[0]).name)] = g.get("matcher", "")
    wired = set()
    codex = json.loads((TEMPLATE / ".codex" / "hooks.json").read_text())
    for event, groups in codex["hooks"].items():
        for g in groups:
            for h in g["hooks"]:
                words = h["command"].split('guard_adapter.py" ', 1)[1].split(" ", 1)
                guard, options = words[0], (words[1] if len(words) > 1 else "")
                wired.add(guard)
                check(f"{guard}: файл есть", (TEMPLATE / ".claude" / "hooks" / guard).is_file(), True)
                check(f"{guard}: событие как у Claude", (event, guard) in claude, True)
                if "--matcher" in options:
                    matcher = options.split("--matcher ", 1)[1].split('"')[1]
                    check(f"{guard}: matcher как у Claude", matcher, claude.get((event, guard)))
                check(f"{guard}: лимит выше предела сторожа", h["timeout"] >= 60, True)
    check("подключён весь минимальный набор", wired, MINIMAL_SET)


if __name__ == "__main__":
    test_config_parity()
    test_answer_forms()
    test_patch_split()
    test_real_guards()
    for line in FAILED:
        print("FAIL:", line)
    print(f"codex-guard-adapter: {PASSED[0]} passed, {len(FAILED)} failed")
    sys.exit(1 if FAILED else 0)
