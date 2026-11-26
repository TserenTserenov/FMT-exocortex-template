#!/usr/bin/env python3
"""Tests for scripts/postman-address-book.py (WP-418 F9). Run: python3 scripts/tests/test-postman-address-book.py"""
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / "scripts" / "postman-address-book.py"
BOOK = ROOT / "scripts" / "postman-address-book.yaml"
failures = []


def run(*args, env=None, params=None):
    with tempfile.TemporaryDirectory() as tmp:
        p = Path(tmp) / "params.yaml"
        p.write_text(params or "", encoding="utf-8")
        cmd = [sys.executable, str(TOOL), *args, "--params", str(p)]
        return subprocess.run(cmd, capture_output=True, text=True, env={**os.environ, **(env or {})})


def expect(name, cond, detail=""):
    if not cond:
        failures.append(f"{name}: {detail}")


def book_with(extra_row: str) -> Path:
    tmp = Path(tempfile.mkdtemp()) / "book.yaml"
    tmp.write_text(BOOK.read_text(encoding="utf-8") + extra_row, encoding="utf-8")
    return tmp


# 1. The shipped book is valid.
r = run("check")
expect("shipped book valid", r.returncode == 0, r.stderr)

# 2. Resolve an open WP to its mailbox; a closed one to the deferred list.
with tempfile.TemporaryDirectory() as ws:
    gov = Path(ws) / "GOV"
    (gov / "inbox" / "WP-7").mkdir(parents=True)
    (gov / "inbox" / "WP-7" / "WP-7.md").write_text("card", encoding="utf-8")
    env = {"IWE_WORKSPACE": ws, "IWE_GOVERNANCE_REPO": "GOV"}
    r = run("resolve", "WP-7", env=env)
    out = json.loads(r.stdout or "{}")
    expect("open WP address", out.get("address") == f"{gov}/inbox/WP-7/INBOX.md" and out.get("closed") is False, r.stdout + r.stderr)
    expect("open WP executor filled", out.get("executor") == "script:scripts/wp-inbox.sh add --to WP-7", r.stdout)
    r = run("resolve", "РП-8", env=env)
    out = json.loads(r.stdout or "{}")
    expect("closed WP goes to deferred list", out.get("address") == f"{gov}/inbox/backlog-with-triggers.md" and out.get("closed") is True, r.stdout + r.stderr)
    expect("closed WP not handed to wp-inbox.sh", out.get("executor", "").startswith("external:"), r.stdout)
    r = run("resolve", "owner", env=env)
    out = json.loads(r.stdout or "{}")
    expect("owner address is a store reference", out.get("address_kind") == "store" and out.get("delivery") == "external", r.stdout + r.stderr)

# 3. Unknown addressee: not supported, exit 1.
r = run("resolve", "someone-else")
expect("unknown addressee refused", r.returncode == 1 and "не поддерживается" in r.stderr, r.stderr)

# 4. A literal chat id or e-mail in the book is refused.
bad = book_with("""
  - kind: leak
    title: утечка
    delivery: external
    name_pattern: '^leak$'
    address: 'store:чат 123456789'
    executor: 'external:бот'
    semantics: none
    accepts: что угодно
    who_may_write: все
    status: target
""")
r = subprocess.run([sys.executable, str(TOOL), "check", "--book", str(bad), "--params", "/nonexistent"], capture_output=True, text=True)
expect("literal chat id refused", r.returncode == 1 and "номер чата" in r.stderr, r.stderr)

# 5. A user row may add a kind but not redefine a template one; a person address must be store:.
r = run("check", params="postman_addressees:\n  - kind: wp\n    title: x\n    delivery: internal\n    name_pattern: '^x$'\n    address: 'path:/x'\n    executor: 'external:x'\n    semantics: none\n    accepts: x\n    who_may_write: x\n    status: target\n")
expect("user cannot redefine template kind", r.returncode == 1 and "уже задан" in r.stderr, r.stderr)
r = run("check", params="postman_addressees:\n  - kind: colleague\n    title: коллега\n    delivery: external\n    name_pattern: '^colleague$'\n    address: 'path:/tmp/box'\n    executor: 'external:почта'\n    semantics: none\n    accepts: письмо\n    who_may_write: владелец\n    status: target\n")
expect("external address must be store:", r.returncode == 1 and "только ссылка store:" in r.stderr, r.stderr)
r = run("check", params="postman_addressees:\n  - kind: team\n    title: команда\n    delivery: internal\n    name_pattern: '^team$'\n    address: 'store:канал команды в настройках'\n    executor: 'external:сообщение в канал команды'\n    semantics: none\n    accepts: служебное сообщение\n    who_may_write: сессии этого IWE\n    status: target\n")
expect("user may add a new kind", r.returncode == 0, r.stderr)

# 6. A script executor that does not exist is refused.
bad = book_with("""
  - kind: ghost
    title: несуществующий исполнитель
    delivery: internal
    name_pattern: '^ghost$'
    address: 'path:/tmp/ghost'
    executor: 'script:scripts/no-such-tool.sh'
    semantics: none
    accepts: x
    who_may_write: x
    status: target
""")
r = subprocess.run([sys.executable, str(TOOL), "check", "--book", str(bad), "--params", "/nonexistent"], capture_output=True, text=True)
expect("missing script executor refused", r.returncode == 1 and "не найден" in r.stderr, r.stderr)

if failures:
    print("\n".join(failures), file=sys.stderr)
    sys.exit(1)
print("postman-address-book: все проверки прошли (6 групп)")
