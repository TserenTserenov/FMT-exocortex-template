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
import time
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
    "hint-pretty-block.sh": 'cat >/dev/null; echo "подсказка"; printf \'{\\n  "decision": "block",\\n  "reason": "стоп"\\n}\\n\'',
    "stop.sh": 'cat >/dev/null; echo \'{"continue": false, "stopReason": "хватит"}\'',
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


def cleanup(site):
    """Remove a test site; guards a killed adapter started may still be writing into it."""
    for _ in range(5):
        try:
            shutil.rmtree(site)
            return
        except OSError:
            time.sleep(1)
    print(f"не удалось удалить тестовую папку {site}")


def make_site(with_template_hooks):
    site = Path(tempfile.mkdtemp()).resolve()
    (site / ".codex" / "hooks").mkdir(parents=True)
    shutil.copy(ADAPTER, site / ".codex" / "hooks" / "guard_adapter.py")
    if with_template_hooks:
        shutil.copytree(TEMPLATE / ".claude", site / ".claude", symlinks=True)
        shutil.copy(TEMPLATE / "update-manifest.json", site / "update-manifest.json")
    else:
        (site / ".claude" / "hooks").mkdir(parents=True)
    for name, body in FAKE_GUARDS.items():
        (site / ".claude" / "hooks" / name).write_text("#!/usr/bin/env bash\n" + body + "\n")
    subprocess.run(["git", "init", "-q", str(site)], check=True)
    return site


def run(site, guard, envelope, raw=None, args=(), extra_env=None):
    """(decision, reason) as Codex reads the adapter's stdout: ("allow", "") when it is empty."""
    env = {"PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin", "HOME": str(site), "IWE_TEMPLATE": str(site), **(extra_env or {})}
    try:
        done = subprocess.run([sys.executable, str(site / ".codex" / "hooks" / "guard_adapter.py"), guard, *args],
                              input=raw if raw is not None else json.dumps(envelope),
                              capture_output=True, text=True, env=env, timeout=70)
    except subprocess.TimeoutExpired:
        return ("timeout", "")  # Codex would have killed the hook at 60 s and allowed the action
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
        cleanup(site)


def test_patch_split():
    site = make_site(False)
    try:
        (site / "old.txt").write_text("keep\nstay\n")
        (site / "a.txt").write_text("x\n")
        (site / "gone.txt").write_text("bye\n")
        body = (f"*** Add File: {site}/new.txt\n+hello\n"
                f"*** Update File: old.txt\n@@\n-keep\n+kept\n"
                f"*** Update File: a.txt\n*** Move to: b.txt\n@@\n-x\n+y\n"
                f"*** Delete File: {site}/gone.txt")
        check("заплатка из четырёх файлов → разрешение", run(site, "record.sh", patch(site, body)), ("allow", ""))
        seen = recorded(site)
        got = [(c["tool_name"], c["tool_input"]["file_path"].replace(str(site) + "/", ""),
                c["tool_input"].get("content", c["tool_input"].get("new_string"))) for c in seen]
        check("файл целиком до и после", got, [("Write", "new.txt", "hello\n"), ("Edit", "old.txt", "kept\nstay\n"),
                                               ("Edit", "a.txt", ""), ("Write", "b.txt", "y\n"), ("Edit", "gone.txt", "")])
        check("правка: старый текст целиком", seen[1]["tool_input"]["old_string"], "keep\nstay\n")
        check("конверт сохраняет номер беседы", seen[0]["session_id"], "019d-test")
        (site / "n.txt").write_text("1\n2\n3\n4\n")
        run(site, "record.sh", patch(site, "*** Update File: n.txt\n@@\n-1\n+one\n@@\n-4\n+four"))
        check("два куска применяются по местам", recorded(site)[0]["tool_input"]["new_string"], "one\n2\n3\nfour\n")
        (site / "anchor.txt").write_text("a\nx\nb\nx\n")
        run(site, "record.sh", patch(site, "*** Update File: anchor.txt\n@@ b\n-x\n+y"))
        check("кусок с якорем «@@ строка»", recorded(site)[0]["tool_input"]["new_string"], "a\nx\nb\ny\n")
        run(site, "record.sh", patch(site, "*** Add File: docs/../SPF/x.md\n+a"))
        check("путь с «..» выравнивается", recorded(site)[0]["tool_input"]["file_path"], str(site / "SPF" / "x.md"))
        check("кусок не ложится на файл → запрет", run(site, "allow.sh", patch(site, "*** Update File: old.txt\n@@\n-nothere\n+x"))[0], "deny")
        check("правка несуществующего файла → запрет", run(site, "allow.sh", patch(site, "*** Update File: none.txt\n@@\n-a\n+b"))[0], "deny")
        two = f"*** Add File: {site}/fine.txt\n+a\n*** Add File: {site}/protected.txt\n+b"
        check("второй файл заплатки защищён → запрет", run(site, "path.sh", patch(site, two)), ("deny", "защищено"))
        check("заплатка без начала → запрет", run(site, "allow.sh", dict(patch(site, ""), tool_input={"command": "x"}))[0], "deny")
        no_end = dict(patch(site, ""), tool_input={"command": f"*** Begin Patch\n*** Add File: {site}/z\n+z"})
        check("заплатка без конца → запрет", run(site, "allow.sh", no_end)[0], "deny")
        check("заплатка без файлов → запрет", run(site, "allow.sh", patch(site, ""))[0], "deny")
        protected_new = patch(site, f"*** Add File: {site}/protected.txt\n+b")
        check("matcher без Write: запись нового файла не его дело", run(site, "path.sh", protected_new, args=("--matcher", "Edit")), ("allow", ""))
        (site / "protected.txt").write_text("a\n")
        protected_edit = patch(site, f"*** Update File: {site}/protected.txt\n@@\n-a\n+b")
        check("matcher с Edit: правка защищённого → запрет", run(site, "path.sh", protected_edit, args=("--matcher", "Edit")), ("deny", "защищено"))
        check("matcher не совпал с Bash → разрешение", run(site, "exit2.sh", bash(site, "ls"), args=("--matcher", "Edit|Write")), ("allow", ""))
        shell = bash(site, "apply_patch <<'EOF'\n*** Begin Patch\n*** Add File: protected2.txt\n+b\n*** End Patch\nEOF")
        check("заплатка через оболочку видна проверке записи", run(site, "path.sh", shell, args=("--matcher", "Write")), ("deny", "защищено"))
        check("обычная команда не видна проверке записи", run(site, "path.sh", bash(site, "echo protected"), args=("--matcher", "Write")), ("allow", ""))
        post_delete = patch(site, f"*** Delete File: {site}/gone-already.sql", event="PostToolUse")
        check("после удаления проверке нечего читать → разрешение", run(site, "record.sh", post_delete), ("allow", ""))
        check("после удаления вызовов нет", (site / "seen.jsonl").exists(), False)
    finally:
        cleanup(site)


def recorded(site):
    """Calls the record.sh guard saw since the last call of this function."""
    f = site / "seen.jsonl"
    calls = [json.loads(l) for l in f.read_text().splitlines() if l.strip()] if f.exists() else []
    f.unlink(missing_ok=True)
    return calls


def test_review_findings():
    """Cold review 27.11 (F1-F10): each input once let a block through or blocked wrongly."""
    site = make_site(True)
    try:
        skill = site / ".claude" / "skills" / "fpf" / "SKILL.md"
        rel = ".claude/skills/fpf/SKILL.md"
        (site / "docs").mkdir(exist_ok=True)
        (site / "docs" / "a.md").write_text("x\n*** End Patch\n")
        f1 = patch(site, f"*** Update File: docs/a.md\n@@\n-x\n+y\n *** End Patch\n*** Update File: {rel}\n@@\n-name: fpf\n+name: evil")
        check("F1: после «*** End Patch» с отступом второй файл проверяется", "USER-SPACE" in run(site, "extensions-gate.sh", f1)[1], True)
        f2 = patch(site, f"*** Add File: docs/ok.md\n+hi\n *** Add File: {rel}\n+evil")
        check("F2: заголовок с отступом проверяется", "USER-SPACE" in run(site, "extensions-gate.sh", f2)[1], True)
        lines = skill.read_text().split("\n")[:-1]
        (site / "docs" / "evil.md").write_text("MALICIOUS\na\n")
        f3 = patch(site, f"*** Update File: docs/evil.md\n*** Move to: {rel}\n@@\n-a\n" + "\n".join("+" + l for l in lines + [""]))
        check("F3: перенос несёт всё содержимое источника → запрет", "USER-SPACE" in run(site, "extensions-gate.sh", f3)[1], True)
        text = skill.read_text().replace("<!-- USER-SPACE -->\n", "<!-- USER-SPACE -->\nname: fpf\nnote\n", 1)
        skill.write_text(text)
        f4 = patch(site, f"*** Update File: {rel}\n@@\n ---\n-name: fpf\n+name: evil\n@@ <!-- USER-SPACE -->\n name: fpf\n-note\n+note")
        check("F4: куски не склеиваются → запрет", "USER-SPACE" in run(site, "extensions-gate.sh", f4)[1], True)
        f9 = patch(site, f"*** Update File: {rel}\n@@\n <!-- USER-SPACE -->\n+моя заметка\n name: fpf")
        check("F9: добавление строки внутри USER-SPACE → разрешение", run(site, "extensions-gate.sh", f9), ("allow", ""))
        spf = {"PACK_CREATOR_ACTIVE": "1"}
        f5 = patch(site, "*** Add File: docs/../SPF/x.md\n+a")
        check("F5: «..» к SPF → запрет", run(site, "pack-creator-spf-guard.sh", f5, extra_env=spf)[0], "deny")
        check("F5: без режима создания пака SPF не защищён", run(site, "pack-creator-spf-guard.sh", f5), ("allow", ""))
        many = "".join(f"*** Add File: docs/g{n}.md\n+b\n" for n in range(1300)) + f"*** Add File: {rel}\n+evil"
        t0 = time.monotonic()
        verdict = run(site, "extensions-gate.sh", patch(site, many))[0]
        check("F6: большая заплатка → запрет", verdict, "deny")
        check("F6: укладывается в лимит Codex 60 с", time.monotonic() - t0 < 58, True)
        ls = bash(site, "ls")
        check("F7: подсказка, затем многострочный decision block → запрет", run(site, "hint-pretty-block.sh", ls)[0], "deny")
        check("F7: continue false → запрет", run(site, "stop.sh", ls)[0], "deny")
        no_tool = {k: v for k, v in ls.items() if k != "tool_name"}
        check("F8: нет имени инструмента → запрет", run(site, "allow.sh", no_tool, args=("--matcher", "Bash"))[0], "deny")
        check("F8: аргументы строкой → запрет", run(site, "allow.sh", dict(ls, tool_name="apply_patch", tool_input="x"))[0], "deny")
        # Second cold review 27.11 (R1-R7) and the CRLF case found while fixing it.
        skill.write_text(skill.read_text().replace("<!-- USER-SPACE -->\n", "<!-- USER-SPACE -->\nslash: [/fpf]\n  phrases: []\n", 1))
        same = f"*** Update File: {skill}\n@@\n-slash: [/fpf]\n+mine\n"
        r1 = patch(site, same + same.rstrip("\n"))
        check("R1: две правки одного файла по очереди → запрет", run(site, "extensions-gate.sh", r1)[0], "deny")
        r2 = patch(site, f"*** Update File: {skill}\n@@   slash: [/fpf]\n-  phrases: []\n+  phrases: [evil]")
        check("R2: якорь с отступом как у Codex → правка платформы → запрет", "USER-SPACE" in run(site, "extensions-gate.sh", r2)[1], True)
        r3 = bash(site, f"cd .claude/skills && apply_patch <<'EOF'\n*** Begin Patch\n*** Add File: fpf/SKILL.md\n+evil\n*** End Patch\nEOF")
        check("R3: заплатка после cd → запрет", "отдельной командой" in run(site, "extensions-gate.sh", r3, args=("--matcher", "Edit|Write"))[1], True)
        r5 = patch(site, f"*** Add File: {site}/docs/howto.md\n+*** End Patch")
        check("R5: строка вида разметки в содержимом → разрешение", run(site, "extensions-gate.sh", r5), ("allow", ""))
        (site / "docs" / "dash.md").write_text("a \u2014 b\n")
        r6 = patch(site, f"*** Update File: {site}/docs/dash.md\n@@\n-a - b\n+c")
        check("R6: только нестрогое совпадение → запрет (осознанно строже Codex)", "нестрогим" in run(site, "allow.sh", r6)[1], True)
        (site / "docs" / "mixed.md").write_bytes(b"foo \nbar\nfoo\r\n")
        mixed = patch(site, f"*** Update File: {site}/docs/mixed.md\n@@\n-foo\n+baz")
        check("CRLF: нестрогий поиск Codex раньше точного → запрет", "нестрогим" in run(site, "allow.sh", mixed)[1], True)
        crlf = skill.read_text().replace("\n", "\r\n")
        skill.write_bytes(crlf.encode())
        r4 = patch(site, f"*** Update File: {skill}\n@@\n <!-- USER-SPACE -->\n+note\n slash: [/fpf]")
        check("R4: правка своего блока в файле с CRLF → разрешение", run(site, "extensions-gate.sh", r4), ("allow", ""))
        big = site / "docs" / "big.md"
        big.write_text("".join(f"line {n} \n" for n in range(140000)))
        r7 = patch(site, f"*** Update File: {big}\n@@\n" + "".join(f"-line {n}\n" for n in range(14000)) + "+x")
        t0 = time.monotonic()
        check("R7: огромный файл → запрет", run(site, "allow.sh", r7)[0], "deny")
        check("R7: укладывается в лимит Codex", time.monotonic() - t0 < 58, True)
        # Third cold review 27.11, checked against the Codex 0.169 source.
        two_spaces = patch(site, f"*** Add File:  /../{rel}\n+evil")
        check("3-F1: пробел перед путём → запрет", "пробела" in run(site, "extensions-gate.sh", two_spaces)[1], True)
        (site / "docs" / "m.md").write_text("a\n")
        move_spaces = patch(site, f"*** Update File: docs/m.md\n*** Move to:  /../{rel}\n@@\n-a\n+b")
        check("3-F1: пробел перед путём переноса → запрет", "пробела" in run(site, "extensions-gate.sh", move_spaces)[1], True)
        unquoted = bash(site, f"apply_patch <<EOF && true\n*** Begin Patch\n*** Add File: $(printf {rel})\n+evil\n*** End Patch\nEOF")
        check("3-F2: незакрытая от подстановок вставка → запрет", run(site, "extensions-gate.sh", unquoted, args=("--matcher", "Edit|Write"))[0], "deny")
        from_file = bash(site, 'apply_patch "$(cat /tmp/p.txt)"')
        check("3-F3: текст заплатки из файла → запрет", run(site, "destructive-guard.sh", from_file)[0], "deny")
        check("3-F3: заплатка через конвейер → запрет", run(site, "allow.sh", bash(site, "printf x | apply_patch"))[0], "deny")
        check("слово apply_patch в любой другой команде → запрет", run(site, "allow.sh", bash(site, "grep -n apply_patch notes.md"))[0], "deny")
        wrapped = dict(patch(site, ""), tool_input={"command": f"<<'EOF'\n*** Begin Patch\n*** Add File: {site}/docs/w.md\n+w\n*** End Patch\nEOF"})
        check("обёртка <<'EOF' внутри apply_patch читается", run(site, "record.sh", wrapped), ("allow", ""))
        check("обёртка: файл показан проверке", [c["tool_input"]["file_path"] for c in recorded(site)], [str(site / "docs" / "w.md")])
        (site / "docs" / "cr.md").write_bytes(b"a\rb\n")
        check("одиночный CR в файле → запрет", "CR" in run(site, "allow.sh", patch(site, f"*** Update File: {site}/docs/cr.md\n@@\n-b\n+c"))[1], True)
        (site / "docs" / "tail.md").write_text("a\nb\n")
        run(site, "record.sh", patch(site, f"*** Update File: {site}/docs/tail.md\n@@\n-a\n-\n+x\n+"))
        check("повтор без пустой последней строки, как у Codex", recorded(site)[0]["tool_input"]["new_string"], "x\nb\n")
        (site / "db").mkdir(exist_ok=True)
        f10 = patch(site, f"*** Delete File: {site}/db/old.sql", event="PostToolUse")
        check("F10: удалённый SQL после действия → разрешение", run(site, "sql-pii-guard.sh", f10, args=("--matcher", "Write|Edit|MultiEdit")), ("allow", ""))
    finally:
        cleanup(site)


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
        protocol = patch(site, f"*** Update File: {site}/memory/protocol-open.md\n@@\n+проба")
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
        cleanup(site)


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
    test_review_findings()
    test_real_guards()
    for line in FAILED:
        print("FAIL:", line)
    print(f"codex-guard-adapter: {PASSED[0]} passed, {len(FAILED)} failed")
    sys.exit(1 if FAILED else 0)
