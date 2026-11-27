#!/usr/bin/env python3
"""Codex adapter for the template's Claude Code guards (WP-592 F6).

Usage, from .codex/hooks.json:
    python3 "$(git rev-parse --show-toplevel)/.codex/hooks/guard_adapter.py" <guard> [--agent codex] [--matcher REGEX]

<guard> is a file name in .claude/hooks (for example extensions-gate.sh); REGEX is the guard's matcher
in .claude/settings.json, so the guard sees exactly the Claude tools it sees under Claude Code.

Codex 0.169 sends the Claude Code envelope (hook_event_name, session_id, cwd, tool_name, tool_input)
for Bash and MCP tools, so such a call goes to the guard unchanged. For apply_patch the files are only
inside the patch text in tool_input.command. The adapter applies the sections of the patch one after
another to an in-memory copy of each file and shows the guard one Claude-shaped call per touched file
with the whole file before and after: Edit(old_string=current text, new_string=result) for a file that
exists and is not empty, Write(content=result) otherwise.

The copy must end where Codex's write ends, so the adapter accepts only what it can place exactly as
Codex does: a hunk or an "@@" anchor is placed only by an exact line match, which Codex also tries
first from the same position. Codex's looser matches (trailing or all spacing, look-alike characters)
could land elsewhere, so a hunk that needs one is a deny, as is anything else the adapter cannot read
unambiguously. Through the shell only `apply_patch <<'EOF'` alone, with a quoted delimiter, is read;
any other command that names apply_patch is a deny (cd, expansion, a pipe or a file could make Codex
write a path or text the adapter does not see).

The guard may answer in any of the Claude Code forms: exit 2 with a reason on stderr, or exit 0 with
JSON permissionDecision "deny"/"ask", decision "block" or continue false. Codex has no prompt for
"ask", so it is a deny too. Every failure to read the input, run the guard in time or understand its
answer is a deny: an error never becomes an allow (Codex itself treats a failed hook as an allow).

The guards find the workspace through CLAUDE_PROJECT_DIR and IWE_ROOT; both are set to the folder
that holds this .codex/, so a guard never reads another workspace's state.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEADLINE = 50  # seconds for the whole call, below the 60 s hook timeout in .codex/hooks.json
SHELL_PATCH = re.compile(r"(?s)\A\s*apply_?patch\s*<<\s*(['\"])(\w+)\1[ \t]*\n(\*\*\* Begin Patch\n.*\n\*\*\* End Patch)\n\2\s*\Z")
LENIENT = re.compile(r"(?s)\A\s*<<\s*(['\"]?)(\w+)\1[ \t]*\n(.*)\n\2\s*\Z")
PATCH_WORD = re.compile(r"\bapply_?patch\b")


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


# --- the patch, read the way Codex 0.169 reads it (codex-rs/apply-patch) --------------------------

def parse_patch(text):
    """[{op, path, move, add_lines, chunks}]; a chunk is {anchor, lines: [(kind, text)], eof}."""
    wrapped = LENIENT.match(text)
    if wrapped:  # Codex accepts a patch wrapped in <<'EOF' ... EOF inside apply_patch itself
        text = wrapped.group(3)
    lines = [line[:-1] if line.endswith("\r") else line for line in text.strip().split("\n")]
    if len(lines) < 2 or lines[0].strip() != "*** Begin Patch" or lines[-1].strip() != "*** End Patch":
        raise AdapterError("заплатка не обрамлена строками «*** Begin Patch» и «*** End Patch»")
    body, i, sections = lines[1:-1], 0, []
    while i < len(body):
        head = body[i].strip()
        i += 1
        if not head:
            continue
        op = next((name for name, m in (("add", "*** Add File: "), ("delete", "*** Delete File: "),
                                        ("update", "*** Update File: ")) if head.startswith(m)), None)
        if op is None:
            raise AdapterError(f"строка «{head[:60]}» не заголовок файла")
        section = {"op": op, "path": header_path(head.split(": ", 1)[1]), "move": None, "add_lines": [], "chunks": []}
        if op == "add":
            while i < len(body) and body[i].startswith("+"):
                section["add_lines"].append(body[i][1:])
                i += 1
        elif op == "update":
            if i < len(body) and body[i].startswith("*** Move to: "):
                section["move"] = header_path(body[i][len("*** Move to: "):])
                i += 1
            i = parse_chunks(body, i, section["chunks"])
            if not section["chunks"]:
                raise AdapterError(f"в правке {section['path']} нет ни одного куска")
        sections.append(section)
    if not sections:
        raise AdapterError("в заплатке нет файлов")
    return sections


def header_path(value):
    """The path of a header as Codex takes it: everything after the marker, right-trimmed.

    Codex keeps leading spaces: " /../x" is a relative path for it (the segment " " and then ".."),
    while a stripped "/../x" points outside the workspace. Such a path is refused, not guessed.
    """
    path = value.rstrip()
    if not path:
        raise AdapterError("в заголовке файла нет пути")
    if path[0].isspace():
        raise AdapterError("путь в заголовке начинается с пробела")
    return path


def parse_chunks(body, i, chunks):
    """Read the hunks of one Update File; return the index of the first line after them."""
    current = None
    while i < len(body):
        line = body[i]
        if line == "@@" or line.startswith("@@ "):
            anchor = line[3:].rstrip() if line.startswith("@@ ") else ""  # leading spaces kept, as Codex
            current = {"anchor": anchor or None, "lines": [], "eof": False}
            chunks.append(current)
        elif line.rstrip() == "*** End of File" and current is not None:
            current["eof"] = True
        elif line[:1] in (" ", "+", "-") or line == "":
            if current is None:  # Codex allows the first hunk without "@@"
                current = {"anchor": None, "lines": [], "eof": False}
                chunks.append(current)
            current["lines"].append((line[:1] or " ", line[1:]))
        else:
            return i
        i += 1
    return i


class FileText:
    """A file as lines without their endings, each ending kept (CRLF or LF), the way Codex keeps them."""

    def __init__(self, text):
        if re.search(r"\r(?!\n)", text):
            raise AdapterError("в файле одиночный символ CR — строки делятся иначе, чем видит проверка")
        raw = text.split("\n")
        self.final_newline = raw[-1] == ""
        if self.final_newline:
            raw.pop()
        self.keys = [line[:-1] if line.endswith("\r") else line for line in raw]
        self.cr = [line.endswith("\r") for line in raw]
        self._normalized = {}

    def normalized(self, n, norm):
        if n not in self._normalized:
            self._normalized[n] = [norm(k) for k in self.keys]
        return self._normalized[n]

    def eol_for_new(self):
        return "\r" if self.cr and sum(self.cr) * 2 > len(self.cr) else ""

    def text(self):
        lines = [k + ("\r" if cr else "") for k, cr in zip(self.keys, self.cr)]
        return "\n".join(lines) + ("\n" if lines else "")


LOOK_ALIKE = str.maketrans({**{c: "-" for c in "\u2010\u2011\u2012\u2013\u2014\u2015\u2212"},
                            **{c: "'" for c in "\u2018\u2019\u201a\u201b"},
                            **{c: '"' for c in "\u201c\u201d\u201e\u201f"},
                            **{c: " " for c in "\u00a0\u2000\u2001\u2002\u2003\u2004\u2005\u2006"
                                               "\u2007\u2008\u2009\u200a\u202f\u205f\u3000"}})
# Codex's looser passes, after the exact one: trailing spacing, all spacing, look-alike characters.
LOOSER = (str.rstrip, str.strip, lambda s: s.translate(LOOK_ALIKE).strip())


def scan(keys, pattern, start, stop, deadline):
    """First index in [start, stop) where pattern matches keys exactly, or None."""
    first, size = pattern[0], len(pattern)
    end = len(keys) - size + 1 if stop is None else min(stop, len(keys) - size + 1)
    for k in range(start, end):
        if k % 4096 == 0 and time.monotonic() > deadline:
            raise AdapterError(f"разбор заплатки не уложился в {DEADLINE} с")
        if keys[k] == first and keys[k:k + size] == pattern:
            return k
    return None


def seek(f, pattern, start, eof, deadline):
    """Where Codex places pattern, when every pass of Codex's search agrees on it; None when none matches.

    Codex tries an exact pass, then looser ones, each from the same start, and takes the first hit.
    The exact hit is accepted only when no looser pass hits earlier: then Codex lands on it whichever
    pass it reaches (also when it compares lines with their CR and its exact pass misses).
    """
    if not pattern:
        return None
    if eof and len(f.keys) >= len(pattern):
        start = max(start, len(f.keys) - len(pattern))
    k = scan(f.keys, pattern, start, None, deadline)
    for n, norm in enumerate(LOOSER):
        j = scan(f.normalized(n, norm), [norm(p) for p in pattern], start, None if k is None else k + 1, deadline)
        if j is not None and j != k:
            raise AdapterError("место правки находится только нестрогим совпадением — где его применит Codex, неоднозначно")
    return k


def without_trailing_empty(lines):
    """Drop the last empty old line and, if the new text then ends with an empty line, that one too."""
    lines = list(lines)
    for side in ((" ", "-"), (" ", "+")):
        idx = next((n for n in range(len(lines) - 1, -1, -1) if lines[n][0] in side), None)
        if idx is not None and lines[idx][1] == "":
            del lines[idx]
    return lines


def apply_chunks(text, chunks, path, deadline):
    f = FileText(text)
    eol = f.eol_for_new()
    replacements, cursor = [], 0
    for seq, c in enumerate(chunks):
        if c["anchor"] is not None:
            k = seek(f, [c["anchor"]], cursor, False, deadline)
            if k is None:
                raise AdapterError(f"якорь «@@ {c['anchor'][:40]}» не найден в {path} точным совпадением")
            cursor = k + 1
        lines = c["lines"]
        old = [t for kind, t in lines if kind in (" ", "-")]
        if not old:
            replacements.append((len(f.keys), seq, 0, lines))
            continue
        k = seek(f, old, cursor, c["eof"], deadline)
        if k is None and old[-1] == "":  # Codex retries without the trailing empty old and new line
            lines = without_trailing_empty(lines)
            old = [t for kind, t in lines if kind in (" ", "-")]
            k = seek(f, old, cursor, c["eof"], deadline)
        if k is None:
            raise AdapterError(f"кусок правки не ложится на {path} точным совпадением")
        replacements.append((k, seq, len(old), lines))
        cursor = k + len(old)
    for at, _, length, lines in sorted(replacements, reverse=True):
        keys, cr, j = [], [], at
        for kind, t in lines:
            if kind == " ":  # a context line keeps the file's own text and ending
                keys.append(f.keys[j]); cr.append(f.cr[j]); j += 1
            elif kind == "-":
                j += 1
            else:
                keys.append(t); cr.append(eol == "\r")
        f.keys[at:at + length] = keys
        f.cr[at:at + length] = cr
    return f.text()


def read_current(path):
    """Current text of a file with its line endings, or None when it does not exist."""
    try:
        return path.read_bytes().decode("utf-8")
    except FileNotFoundError:
        return None
    except UnicodeDecodeError:
        raise AdapterError(f"файл {path} не текст в UTF-8")


def file_call(path, before, after):
    """The Claude tool call that turns `before` into `after` for this path."""
    if before:
        return ("Edit", {"file_path": str(path), "old_string": before, "new_string": after})
    return ("Write", {"file_path": str(path), "content": after})


def patch_calls(patch, cwd, event, deadline):
    """(tool_name, tool_input) per file the patch touches, with the file before and after all sections."""
    resolve = lambda p: Path(os.path.normpath(cwd / p))  # "../" is resolved by text, as Codex does
    sections = parse_patch(patch)
    if event == "PostToolUse":  # already applied: the files on disk are the result; deleted ones are gone
        written = {resolve(s["move"] or s["path"]) for s in sections if s["op"] != "delete"}
        return [("Write", {"file_path": str(p), "content": read_current(p) or ""}) for p in sorted(written)]
    original, current = {}, {}

    def state(p):
        if p not in current:
            original[p] = current[p] = read_current(p)
        return current[p]

    for s in sections:
        path = resolve(s["path"])
        before = state(path)
        if s["op"] == "add":
            current[path] = "".join(line + "\n" for line in s["add_lines"])
            continue
        if before is None:
            raise AdapterError(f"файла {path} нет — заплатка к нему не применится")
        if s["op"] == "delete":
            current[path] = None
            continue
        after = apply_chunks(before, s["chunks"], path, deadline)
        if s["move"]:
            target = resolve(s["move"])
            state(target)
            current[path], current[target] = None, after
        else:
            current[path] = after
    return [file_call(p, original[p], current[p] or "") for p in current if current[p] != original[p]]


def claude_calls(envelope, event, deadline):
    """The Claude-shaped envelopes the guard has to see for this Codex call."""
    tool = envelope.get("tool_name")
    tool_input = envelope.get("tool_input")
    if not isinstance(tool, str) or not isinstance(tool_input, dict):
        raise AdapterError("во входе нет имени инструмента или его аргументов")
    cwd = Path(envelope.get("cwd") or ROOT)
    command = tool_input.get("command")
    own, patches = [envelope], []
    if tool == "apply_patch":
        if not isinstance(command, str):
            raise AdapterError("у apply_patch нет текста заплатки")
        own, patches = [], [command]
    elif tool == "Bash" and isinstance(command, str) and PATCH_WORD.search(command):
        # Any other shell form (unquoted heredoc, $(...), a pipe, a file) can write a path or text
        # the adapter does not see: only the one literal form is read, the rest is a deny.
        shell = SHELL_PATCH.match(command)
        if not shell:
            raise AdapterError("заплатку через оболочку передавай только отдельной командой apply_patch <<'EOF' … EOF")
        patches = [shell.group(3)]
    return own + [dict(envelope, tool_name=name, tool_input=ti)
                  for patch in patches for name, ti in patch_calls(patch, cwd, event, deadline)]


# --- the guard and its answer ---------------------------------------------------------------------

def guard_verdict(guard, call, agent, deadline):
    """None when the guard allows, else the reason of its block."""
    left = deadline - time.monotonic()
    if left <= 1:
        raise AdapterError(f"проверки не уложились в {DEADLINE} с на всё действие")
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
                              text=True, timeout=left, env=env, cwd=call.get("cwd") or ROOT)
    except subprocess.TimeoutExpired:
        raise AdapterError(f"{guard.name} не уложился во время")
    reason = done.stderr.strip()
    if done.returncode == 2:
        return reason or f"заблокировано проверкой {guard.name}"
    if done.returncode != 0:
        raise AdapterError(f"{guard.name} упал с кодом {done.returncode}: {reason}")
    return json_block_reason(guard, done.stdout)


def json_documents(text):
    """Every JSON object in the answer that starts a line, also a pretty-printed one after hint text."""
    decoder, found, pos = json.JSONDecoder(), [], 0
    for line in text.splitlines(keepends=True):
        if line.lstrip().startswith("{"):
            try:
                obj, _ = decoder.raw_decode(text, pos + len(line) - len(line.lstrip()))
                found.append(obj)
            except json.JSONDecodeError:
                found.append(None)
        pos += len(line)
    return found


def json_block_reason(guard, stdout):
    """Read the answer of an exit-0 guard: the reason of a deny/ask/block/stop, else None."""
    documents = json_documents(stdout)
    if documents and all(d is None for d in documents):
        raise AdapterError(f"{guard.name} ответил неразборчиво")
    for data in (d for d in documents if isinstance(d, dict)):
        spec = data.get("hookSpecificOutput") if isinstance(data.get("hookSpecificOutput"), dict) else {}
        decision = spec.get("permissionDecision")
        if decision in ("deny", "ask"):
            prefix = "нужно подтверждение человека: " if decision == "ask" else ""
            return prefix + (spec.get("permissionDecisionReason") or f"запрещено проверкой {guard.name}")
        if data.get("decision") == "block":
            return data.get("reason") or f"заблокировано проверкой {guard.name}"
        if data.get("continue") is False:
            return data.get("stopReason") or f"остановлено проверкой {guard.name}"
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
    deadline = time.monotonic() + DEADLINE
    event = "PreToolUse"
    try:
        envelope = json.loads(sys.stdin.read())
        if not isinstance(envelope, dict):
            raise AdapterError("вход хука — не объект JSON")
        event = envelope.get("hook_event_name") if envelope.get("hook_event_name") == "PostToolUse" else event
        guard, agent, matcher = parse_args(argv)
        if shutil.which("jq") is None:
            raise AdapterError("jq не установлен, проверки не могут разобрать вход")
        # Like Claude Code, the guard sees only the tools its matcher names; the rest is not its job.
        calls = [c for c in claude_calls(envelope, event, deadline) if matcher is None or matcher.fullmatch(c["tool_name"])]
        for call in calls:
            reason = guard_verdict(guard, call, agent, deadline)
            if reason:
                answer(event, reason)
    except Exception as exc:  # any failure is a deny; Codex would read a traceback as an allow
        answer(event, f"проверка не может оценить действие ({type(exc).__name__}: {exc}) — действие не пропущено")
    sys.exit(0)


if __name__ == "__main__":
    main(sys.argv)
