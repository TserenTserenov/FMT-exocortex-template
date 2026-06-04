#!/usr/bin/env python3
# OUTDATED: canonical copy at workspace scripts/iwe-agent-dispatcher.py
# See #143 for RC1-RC5 fixes. Do not use this file in production.
"""
iwe-agent-dispatcher.py — диспетчер Agent Inbox IWE (WP-324 Ф8).

Канал: headless `claude -p` (Claude Code CLI в неинтерактивном режиме).
Не зависит от RemoteTrigger v1→v2 translation bug (см. bugs/bug-2026-05-17).

Цикл:
  1. git pull --rebase в рабочем клоне governance-репо
  2. Скан inbox/agent/tasks/TASK-*.md → найти status: pending AND due ≤ now
  3. Для каждой: загрузить template, подставить params, вызвать `claude -p`
  4. Записать inbox/agent/results/RESULT-<task-id>.md
  5. Обновить task frontmatter (status: pending → completed/failed, assigned_at, completed_at)
  6. Один commit на task → git push

Запуск: systemd timer часовой. Lock-файл против параллельных запусков.

Зависимости: stdlib + claude CLI в PATH + gh auth для git push.

Использование:
  iwe-agent-dispatcher.py --workdir /var/iwe/dispatcher
  iwe-agent-dispatcher.py --workdir /var/iwe/dispatcher --dry-run
  iwe-agent-dispatcher.py --workdir /var/iwe/dispatcher --task TASK-2026-05-17-analyze-section-11
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

# === Конфигурация (можно переопределить через env vars или CLI args) ===
GOV_REPO_URL = os.environ.get("IWE_DISPATCHER_REPO_URL", "")  # обязательно задать через env
GOV_BRANCH = os.environ.get("IWE_DISPATCHER_REPO_BRANCH", "main")
LOCK_FILE = os.environ.get("IWE_DISPATCHER_LOCK_FILE", "/tmp/iwe-agent-dispatcher.lock")
LOCK_TTL_MIN = int(os.environ.get("IWE_DISPATCHER_LOCK_TTL_MIN", "50"))
MODEL_DEFAULT = os.environ.get("IWE_DISPATCHER_MODEL_DEFAULT", "sonnet")
CLAUDE_TIMEOUT_SEC = int(os.environ.get("IWE_DISPATCHER_CLAUDE_TIMEOUT_SEC", "1800"))
COMMIT_AUTHOR_NAME = os.environ.get("IWE_DISPATCHER_AUTHOR_NAME", "IWE Agent Dispatcher")
COMMIT_AUTHOR_EMAIL = os.environ.get("IWE_DISPATCHER_AUTHOR_EMAIL", "noreply@example.com")

# === Утилиты ===

def now_utc() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def log(msg: str, level: str = "INFO") -> None:
    ts = now_utc().strftime("%Y-%m-%dT%H:%M:%SZ")
    print(f"[{ts}] {level}: {msg}", flush=True)


def run(cmd: list[str], cwd: Path | None = None, check: bool = True,
        capture: bool = True, timeout: int | None = 60) -> subprocess.CompletedProcess:
    """Запуск shell-команды с логированием."""
    log(f"run: {' '.join(cmd[:5])}{'...' if len(cmd) > 5 else ''}", "DEBUG")
    return subprocess.run(
        cmd, cwd=cwd, check=check,
        capture_output=capture, text=True, timeout=timeout,
    )


# === Frontmatter parser (минимальный) ===
# Поддержка:
#   key: scalar
#   key:
#     nested_key: value
#   key:
#     - item
#     - item


def parse_frontmatter(text: str) -> tuple[dict, str]:
    """Возвращает (frontmatter_dict, body_str)."""
    m = re.match(r"^---\n(.*?\n)---\n(.*)$", text, re.DOTALL)
    if not m:
        return {}, text
    fm_text = m.group(1)
    body = m.group(2)

    data: dict = {}
    stack: list[tuple[int, dict | list, str]] = [(0, data, "")]
    list_pending: dict | None = None

    for raw_line in fm_text.splitlines():
        if not raw_line.strip() or raw_line.lstrip().startswith("#"):
            continue
        indent = len(raw_line) - len(raw_line.lstrip())
        line = raw_line.lstrip()

        # Pop stack до текущего отступа
        while stack and indent < stack[-1][0]:
            stack.pop()

        parent_indent, parent, parent_key = stack[-1]

        # Item списка
        if line.startswith("- "):
            value = parse_scalar(line[2:].strip())
            if isinstance(parent, list):
                parent.append(value)
            else:
                # parent ещё dict, переключаем родителя на list
                if parent_key and isinstance(parent.get(parent_key), list):
                    parent[parent_key].append(value)
                else:
                    raise ValueError(f"Unexpected list item at indent {indent}: {line}")
            continue

        # Key: value
        if ":" in line:
            key, sep, val = line.partition(":")
            key = key.strip()
            val = val.strip()
            if val == "":
                # Nested block следует
                # Заглядываем, что начнётся — список (- item) или dict
                # Создаём оба варианта lazy через placeholder, но проще:
                # сначала dict, при первом `- ` переключаем на list
                placeholder: dict = {}
                if isinstance(parent, dict):
                    parent[key] = placeholder
                else:
                    raise ValueError(f"Cannot nest under list at: {line}")
                stack.append((indent + 2, placeholder, key))
                # для возможности list-переключения помечаем
                _maybe_promote_list_next(stack, parent, key)
            else:
                value = parse_scalar(val)
                if isinstance(parent, dict):
                    parent[key] = value
                else:
                    raise ValueError(f"Cannot set key under list at: {line}")
            continue

        raise ValueError(f"Unparsed line: {raw_line!r}")

    # Post-process: dict с только списочными элементами стоит сразу — мы их и так
    # обрабатывали. Но проще: пройдёмся и сконвертируем dict, у которых
    # все элементы добавлены через "- " (мы не различали) — пропускаем,
    # парсер выше уже обрабатывает item списка как append к parent dict с
    # placeholder, что не так. Упростим: переписать как двухпроходный парсер.

    return data, body


def _maybe_promote_list_next(*_args):
    """Placeholder для будущего двухпроходного fix-up."""
    pass


def parse_scalar(s: str):
    if s.startswith('"') and s.endswith('"'):
        return s[1:-1]
    if s.startswith("'") and s.endswith("'"):
        return s[1:-1]
    if s.lower() == "true":
        return True
    if s.lower() == "false":
        return False
    if s.lower() == "null" or s == "~":
        return None
    # int
    if re.fullmatch(r"-?\d+", s):
        return int(s)
    # float
    if re.fullmatch(r"-?\d+\.\d+", s):
        return float(s)
    # ISO datetime
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}([+-]\d{2}:\d{2})?", s):
        try:
            return dt.datetime.fromisoformat(s)
        except Exception:
            return s
    # ISO date
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}", s):
        try:
            return dt.date.fromisoformat(s)
        except Exception:
            return s
    return s


# Двухпроходный фронтматер-парсер (на случай если выше глючит на списках):

def parse_frontmatter_v2(text: str) -> tuple[dict, str]:
    """Простой парсер frontmatter — двухпроходный, толерантный к ошибкам."""
    m = re.match(r"^---\n(.*?\n)---\n(.*)$", text, re.DOTALL)
    if not m:
        return {}, text
    fm_text = m.group(1)
    body = m.group(2)

    lines = [l for l in fm_text.splitlines() if l.strip() and not l.lstrip().startswith("#")]

    data: dict = {}
    i = 0
    while i < len(lines):
        line = lines[i]
        indent = len(line) - len(line.lstrip())
        if indent != 0:
            i += 1
            continue
        if ":" not in line:
            i += 1
            continue
        key, _, val = line.partition(":")
        key = key.strip()
        val = val.strip()
        if val:
            data[key] = parse_scalar(val)
            i += 1
        else:
            # Nested block
            block_lines = []
            j = i + 1
            while j < len(lines):
                sub_indent = len(lines[j]) - len(lines[j].lstrip())
                if sub_indent == 0:
                    break
                block_lines.append(lines[j])
                j += 1
            data[key] = _parse_nested_block(block_lines)
            i = j

    return data, body


def _parse_nested_block(block_lines: list[str]):
    """Парсит nested-блок: либо list (только `- item`), либо dict."""
    if not block_lines:
        return {}
    first = block_lines[0].lstrip()
    if first.startswith("- "):
        # list
        result = []
        for line in block_lines:
            content = line.lstrip()
            if content.startswith("- "):
                result.append(parse_scalar(content[2:].strip()))
        return result
    else:
        # dict
        result_d: dict = {}
        for line in block_lines:
            if ":" not in line:
                continue
            k, _, v = line.lstrip().partition(":")
            result_d[k.strip()] = parse_scalar(v.strip())
        return result_d


# === Acquire / release lock ===

def acquire_lock() -> bool:
    """True если лок взят, False если кто-то держит свежий."""
    if Path(LOCK_FILE).exists():
        try:
            mtime = Path(LOCK_FILE).stat().st_mtime
            age_min = (time.time() - mtime) / 60
            if age_min < LOCK_TTL_MIN:
                log(f"Lock held by another dispatcher (age={age_min:.0f}m, ttl={LOCK_TTL_MIN}m). Skipping.")
                return False
            log(f"Stale lock found (age={age_min:.0f}m > ttl). Reclaiming.")
        except FileNotFoundError:
            pass
    Path(LOCK_FILE).write_text(f"{os.getpid()}\n{now_utc().isoformat()}\n")
    return True


def release_lock() -> None:
    try:
        Path(LOCK_FILE).unlink()
    except FileNotFoundError:
        pass


# === Git operations ===

def _repo_basename() -> str:
    """Извлекает имя репо из URL: https://.../my-repo.git → my-repo."""
    if not GOV_REPO_URL:
        raise RuntimeError("IWE_DISPATCHER_REPO_URL не задан (env var)")
    name = GOV_REPO_URL.rsplit("/", 1)[-1]
    if name.endswith(".git"):
        name = name[:-4]
    return name


def ensure_workdir(workdir: Path) -> None:
    """Гарантирует наличие свежего клона."""
    repo_dir = workdir / _repo_basename()
    if not repo_dir.exists():
        workdir.mkdir(parents=True, exist_ok=True)
        log(f"Cloning {GOV_REPO_URL} → {repo_dir}")
        run(["git", "clone", "-b", GOV_BRANCH, GOV_REPO_URL, str(repo_dir)],
            timeout=180)
    else:
        log(f"Pull --rebase {repo_dir}")
        # Abort any stuck rebase before resetting — git reset --hard does not
        # clear rebase-merge state left by a previously interrupted rebase.
        subprocess.run(["git", "rebase", "--abort"], cwd=repo_dir,
                       capture_output=True)
        run(["git", "fetch", "origin", GOV_BRANCH], cwd=repo_dir, timeout=60)
        run(["git", "reset", "--hard", f"origin/{GOV_BRANCH}"], cwd=repo_dir,
            timeout=30)
    # Configure git identity
    run(["git", "config", "user.name", COMMIT_AUTHOR_NAME], cwd=repo_dir)
    run(["git", "config", "user.email", COMMIT_AUTHOR_EMAIL], cwd=repo_dir)


def commit_and_push(repo_dir: Path, message: str, files: list[Path]) -> None:
    rel_files = [str(f.relative_to(repo_dir)) for f in files]
    run(["git", "add", *rel_files], cwd=repo_dir)
    run(["git", "commit", "-m", message], cwd=repo_dir)
    run(["git", "fetch", "origin", GOV_BRANCH], cwd=repo_dir, timeout=30)
    run(["git", "rebase", f"origin/{GOV_BRANCH}"], cwd=repo_dir, timeout=30)
    run(["git", "push", "origin", GOV_BRANCH], cwd=repo_dir, timeout=60)


# === Task lifecycle ===

def find_pending_tasks(repo_dir: Path, filter_id: str | None = None) -> list[Path]:
    """Возвращает список TASK-*.md с status: pending AND due ≤ now."""
    tasks_dir = repo_dir / "inbox" / "agent" / "tasks"
    if not tasks_dir.exists():
        return []
    now = now_utc()
    result = []
    for f in sorted(tasks_dir.glob("TASK-*.md")):
        if filter_id and filter_id not in f.name:
            continue
        try:
            fm, _ = parse_frontmatter_v2(f.read_text())
        except Exception as e:
            log(f"Не парсится frontmatter {f.name}: {e}", "WARN")
            continue
        if fm.get("status") != "pending":
            continue
        due = fm.get("due")
        if isinstance(due, dt.datetime):
            due_utc = due.astimezone(dt.timezone.utc) if due.tzinfo else due.replace(tzinfo=dt.timezone.utc)
            if due_utc > now:
                continue
        result.append(f)
    return result


def update_task_frontmatter(task_path: Path, updates: dict) -> None:
    """Обновляет YAML frontmatter в task-файле."""
    text = task_path.read_text()
    m = re.match(r"^---\n(.*?\n)---\n(.*)$", text, re.DOTALL)
    if not m:
        raise ValueError(f"{task_path}: нет frontmatter")
    fm_text = m.group(1)
    body = m.group(2)

    lines = fm_text.splitlines()
    new_lines = []
    handled_keys = set()
    for line in lines:
        if not line.strip() or line.lstrip().startswith("#"):
            new_lines.append(line)
            continue
        if ":" in line and (len(line) - len(line.lstrip())) == 0:
            key, _, _ = line.partition(":")
            key = key.strip()
            if key in updates:
                val = updates[key]
                new_lines.append(f"{key}: {_yaml_repr(val)}")
                handled_keys.add(key)
                continue
        new_lines.append(line)

    # Добавить новые ключи в конец
    for k, v in updates.items():
        if k not in handled_keys:
            new_lines.append(f"{k}: {_yaml_repr(v)}")

    new_fm = "\n".join(new_lines) + "\n"
    task_path.write_text(f"---\n{new_fm}---\n{body}")


def _yaml_repr(v) -> str:
    if isinstance(v, str):
        if re.search(r"[:#\n]", v):
            return f'"{v}"'
        return v
    if isinstance(v, (dt.datetime, dt.date)):
        return v.isoformat()
    if v is None:
        return "null"
    return str(v)


def build_prompt(task_path: Path, repo_dir: Path) -> str:
    """Строит итоговый промпт из template + params."""
    fm, body = parse_frontmatter_v2(task_path.read_text())
    template_name = fm.get("template", "_template")
    template_path = repo_dir / "inbox" / "agent" / "templates" / f"{template_name}.md"
    if not template_path.exists():
        raise FileNotFoundError(f"Template not found: {template_path}")
    template_text = template_path.read_text()

    # Extract prompt section from template (между ```...``` под "## Промпт").
    # Используем "первый открывающий ``` после ## Промпт" + "последний ``` в файле".
    # Это позволяет промпту содержать nested code blocks.
    header_idx = template_text.find("## Промпт")
    if header_idx < 0:
        raise ValueError(f"Template {template_name}: нет секции '## Промпт'")
    after_header = template_text[header_idx + len("## Промпт"):]
    fence_open = after_header.find("\n```\n")
    if fence_open < 0:
        raise ValueError(f"Template {template_name}: нет открывающего ``` после ## Промпт")
    content_start = fence_open + len("\n```\n")
    fence_close = after_header.rfind("\n```")
    if fence_close <= content_start:
        raise ValueError(f"Template {template_name}: нет закрывающего ``` после промпта")
    prompt_raw = after_header[content_start:fence_close]

    # Substitute params
    params = fm.get("params", {})
    if isinstance(params, dict):
        for k, v in params.items():
            # Поддержка {{section_number:02d}}
            for match in re.finditer(rf"\{{\{{{re.escape(k)}(?::([^}}]+))?\}}\}}", prompt_raw):
                fmt = match.group(1)
                if fmt:
                    formatted = f"{{:{fmt}}}".format(v)
                else:
                    formatted = str(v)
                prompt_raw = prompt_raw.replace(match.group(0), formatted)

    # Add task body как контекст
    full_prompt = (
        f"# Контекст задачи\n\n"
        f"Это автоматическая задача из Agent Inbox (task_id: {fm.get('id')}).\n"
        f"Result location: {fm.get('result_location')}\n"
        f"Acceptance criteria:\n"
        + "\n".join(f"  - {c}" for c in (fm.get('acceptance') or []))
        + "\n\n"
        f"# Инструкции\n\n{prompt_raw.strip()}\n\n"
        f"# Дополнительный контекст task-файла\n\n{body.strip()}\n"
    )
    return full_prompt


def invoke_claude(prompt: str, model: str) -> tuple[bool, str]:
    """Возвращает (ok, output)."""
    cmd = ["claude", "-p", prompt, "--model", model, "--output-format", "text"]
    try:
        r = subprocess.run(
            cmd, capture_output=True, text=True,
            timeout=CLAUDE_TIMEOUT_SEC,
        )
        return (r.returncode == 0), r.stdout + ("\n" + r.stderr if r.stderr else "")
    except subprocess.TimeoutExpired:
        return False, f"TIMEOUT after {CLAUDE_TIMEOUT_SEC}s"
    except FileNotFoundError:
        return False, "claude CLI not found in PATH"


def write_result(repo_dir: Path, task_id: str, fm: dict,
                  ok: bool, output: str, started_at: dt.datetime,
                  finished_at: dt.datetime) -> Path:
    results_dir = repo_dir / "inbox" / "agent" / "results"
    results_dir.mkdir(parents=True, exist_ok=True)
    result_path = results_dir / f"RESULT-{task_id.replace('TASK-', '')}.md"

    content = (
        f"---\n"
        f"task_id: {task_id}\n"
        f"status: {'completed' if ok else 'failed'}\n"
        f"started_at: {started_at.isoformat()}\n"
        f"finished_at: {finished_at.isoformat()}\n"
        f"model: {fm.get('model', MODEL_DEFAULT)}\n"
        f"dispatcher: iwe-agent-dispatcher.py\n"
        f"channel: claude-cli-headless\n"
        f"---\n\n"
        f"# Результат: {task_id}\n\n"
        f"## Статус\n\n"
        f"**{'✅ COMPLETED' if ok else '❌ FAILED'}** — {(finished_at - started_at).total_seconds():.0f}s\n\n"
        f"## Вывод агента\n\n"
        f"```\n{output}\n```\n\n"
        f"## Acceptance check\n\n"
        f"_Не проверено автоматически — см. acceptance criteria в task-файле._\n"
    )
    result_path.write_text(content)
    return result_path


# === Главный цикл ===

def process_task(task_path: Path, repo_dir: Path, dry_run: bool) -> bool:
    """Возвращает True если task была обработана (status изменился)."""
    fm, _ = parse_frontmatter_v2(task_path.read_text())
    task_id = fm.get("id", task_path.stem)
    log(f"=== Processing {task_id} ===")

    try:
        prompt = build_prompt(task_path, repo_dir)
    except Exception as e:
        log(f"Build prompt failed: {e}", "ERROR")
        return False

    if dry_run:
        log(f"DRY-RUN: would invoke claude with prompt ({len(prompt)} chars)")
        log(f"---PROMPT START---\n{prompt[:500]}...\n---PROMPT END---")
        return False

    model = fm.get("model") or _agent_to_model(fm.get("agent", "ccr-opus"))
    started_at = now_utc()

    # Mark task as assigned
    update_task_frontmatter(task_path, {
        "status": "assigned",
        "assigned_at": started_at.isoformat(),
        "dispatcher": "iwe-agent-dispatcher",
    })
    commit_and_push(repo_dir,
        f"dispatch(WP-324): {task_id} pending→assigned via claude-cli-headless",
        [task_path])

    # Invoke claude
    ok, output = invoke_claude(prompt, model)
    finished_at = now_utc()
    log(f"claude done ok={ok} duration={(finished_at - started_at).total_seconds():.0f}s")

    # Sync with origin: agent may have committed its own result during execution.
    # reset --hard picks up those commits before we write dispatcher's status update.
    log("Syncing with origin after claude returned...")
    run(["git", "fetch", "origin", GOV_BRANCH], cwd=repo_dir, timeout=30)
    run(["git", "reset", "--hard", f"origin/{GOV_BRANCH}"], cwd=repo_dir, timeout=30)

    # Write result only if agent didn't already write it
    results_dir = repo_dir / "inbox" / "agent" / "results"
    result_path = results_dir / f"RESULT-{task_id.replace('TASK-', '')}.md"
    if result_path.exists():
        log(f"Agent already wrote result file — skipping dispatcher write")
    else:
        result_path = write_result(repo_dir, task_id, fm, ok, output, started_at, finished_at)

    # Update task status
    update_task_frontmatter(task_path, {
        "status": "completed" if ok else "failed",
        "completed_at": finished_at.isoformat(),
    })
    commit_and_push(repo_dir,
        f"dispatch(WP-324): {task_id} → {'completed' if ok else 'failed'}",
        [task_path])

    return True


def _agent_to_model(agent: str) -> str:
    if "opus" in agent:
        return "opus"
    if "sonnet" in agent:
        return "sonnet"
    if "haiku" in agent:
        return "haiku"
    return MODEL_DEFAULT


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--workdir", required=True, type=Path,
                        help="Рабочая директория для клона governance-репо")
    parser.add_argument("--dry-run", action="store_true",
                        help="Не вызывать claude, не пушить — только показать что будет")
    parser.add_argument("--task", default=None,
                        help="Обработать только task с этим ID (substring match)")
    parser.add_argument("--no-lock", action="store_true",
                        help="Игнорировать lock-файл")
    parser.add_argument("--mode", default="batch", choices=["batch", "session"],
                        help="batch (default): Agent Inbox tasks. session: External Session (WP-358)")
    args = parser.parse_args()

    if not args.no_lock and not acquire_lock():
        sys.exit(0)

    try:
        if args.mode == "session":
            session_mode_main(args.workdir, args.dry_run)
            return

        ensure_workdir(args.workdir)
        repo_dir = args.workdir / _repo_basename()

        pending = find_pending_tasks(repo_dir, filter_id=args.task)
        log(f"Найдено pending+due tasks: {len(pending)}")
        if not pending:
            return

        processed = 0
        for task_path in pending:
            try:
                if process_task(task_path, repo_dir, args.dry_run):
                    processed += 1
            except Exception as e:
                log(f"Ошибка обработки {task_path.name}: {e}", "ERROR")
                import traceback
                log(traceback.format_exc(), "ERROR")

        log(f"Цикл завершён. Обработано: {processed}/{len(pending)}")
    finally:
        if not args.no_lock:
            release_lock()


# =============================================================================
# SESSION MODE (--mode session, WP-358 Ф2, DP.SC.162)
# =============================================================================
# See: PACK-digital-platform/.../08-service-clauses/DP.SC.162-external-session-request.md
#      inbox/agent/sessions/SPEC.md

import sqlite3
import urllib.error
import urllib.parse
import urllib.request

SESSION_DB_PATH = os.path.expanduser(
    os.environ.get("IWE_SESSION_DB", "~/.iwe/sessions.db")
)
TG_BOT_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "")
SESSION_IDLE_TIMEOUT_MIN = int(os.environ.get("IWE_SESSION_IDLE_TIMEOUT_MIN", "60"))

# Allowlist for session_id values — prevents path traversal via crafted GitHub files
_SESSION_ID_RE = re.compile(r'^SESSION-[A-Za-z0-9-]+$')

_TURN_HEADER_RE = re.compile(
    r"^\[turn:(\d+),\s*role:(pilot|claude)"
    r"(?:,\s*tg_msg_id:(\d+))?"
    r"(?:,\s*ts:([^\]]+))?\]$"
)


# -------- SQLite session DB --------

def _get_session_db() -> sqlite3.Connection:
    db_dir = os.path.dirname(SESSION_DB_PATH)
    if db_dir:
        os.makedirs(db_dir, exist_ok=True)
    conn = sqlite3.connect(SESSION_DB_PATH)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS processed_turns (
            session_id   TEXT NOT NULL,
            turn_n       INTEGER NOT NULL,
            processed_at TEXT NOT NULL,
            PRIMARY KEY (session_id, turn_n)
        )
    """)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS session_heartbeat (
            session_id TEXT PRIMARY KEY,
            last_ping  TEXT NOT NULL
        )
    """)
    conn.commit()
    return conn


def _is_turn_processed(conn: sqlite3.Connection, session_id: str, turn_n: int) -> bool:
    return conn.execute(
        "SELECT 1 FROM processed_turns WHERE session_id=? AND turn_n=?",
        (session_id, turn_n),
    ).fetchone() is not None


def _mark_turn_processed(conn: sqlite3.Connection, session_id: str, turn_n: int) -> None:
    conn.execute(
        "INSERT OR IGNORE INTO processed_turns VALUES (?,?,?)",
        (session_id, turn_n, now_utc().isoformat()),
    )
    conn.commit()


def _heartbeat_ping(conn: sqlite3.Connection, session_id: str) -> None:
    conn.execute(
        "INSERT INTO session_heartbeat VALUES (?,?) "
        "ON CONFLICT(session_id) DO UPDATE SET last_ping=excluded.last_ping",
        (session_id, now_utc().isoformat()),
    )
    conn.commit()


# -------- Thread file parsing --------

def _parse_thread(text: str) -> list[dict]:
    """Parse SESSION-<id>-thread.md → list of {n, role, tg_msg_id, ts, text}."""
    turns: list[dict] = []
    cur: dict | None = None
    cur_lines: list[str] = []

    for line in text.splitlines():
        m = _TURN_HEADER_RE.match(line.strip())
        if m:
            if cur is not None:
                cur["text"] = "\n".join(cur_lines).strip()
                turns.append(cur)
            cur = {
                "n": int(m.group(1)),
                "role": m.group(2),
                "tg_msg_id": int(m.group(3)) if m.group(3) else None,
                "ts": m.group(4),
            }
            cur_lines = []
        elif cur is not None:
            cur_lines.append(line)

    if cur is not None:
        cur["text"] = "\n".join(cur_lines).strip()
        turns.append(cur)

    return turns


def _build_session_prompt(session_id: str, tg_chat_id: int,
                           turns: list[dict], new_turn_n: int) -> str:
    """Build `claude -p` prompt for a session turn."""
    thread_text = ""
    for t in turns:
        header = f"[turn:{t['n']}, role:{t['role']}"
        if t.get("ts"):
            header += f", ts:{t['ts']}"
        header += "]"
        thread_text += f"{header}\n{t['text']}\n\n"

    latest = next(t for t in turns if t["n"] == new_turn_n)

    return f"""Ты — Claude Code в External Working Session (DP.SC.162).
Пилот работает удалённо через Telegram. session_id={session_id}, tg_chat_id={tg_chat_id}.

## История диалога

{thread_text.strip()}

## Текущий ход

Ход {new_turn_n} (пилот): «{latest['text']}»

## Инструкции

1. Выполни работу согласно запросу пилота. Доступны все файлы проекта и MCP-инструменты.
2. Capability scope: код + git, Google Calendar, create-wp.sh, knowledge_search.
3. Отвечай кратко (Telegram, ≤800 символов если возможно).
4. После завершения работы выведи финальный ответ СТРОГО между делимитерами:

===TELEGRAM_RESPONSE_START===
<текст ответа для Telegram>
===TELEGRAM_RESPONSE_END===

Только этот текст будет отправлен пилоту.
"""


# -------- Telegram direct send --------

def _send_tg_direct(chat_id: int, text: str) -> bool:
    if not TG_BOT_TOKEN:
        log("TELEGRAM_BOT_TOKEN not set — TG send skipped", "WARN")
        return False
    import json as _json
    url = f"https://api.telegram.org/bot{TG_BOT_TOKEN}/sendMessage"
    payload = _json.dumps({"chat_id": chat_id, "text": text}).encode()
    req = urllib.request.Request(url, data=payload,
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return _json.loads(resp.read()).get("ok", False)
    except Exception as exc:
        log(f"TG send error: {exc}", "ERROR")
        return False


# -------- Response extraction --------

def _extract_tg_response(output: str) -> tuple[str, str]:
    """Returns (tg_message, full_transcript)."""
    start = "===TELEGRAM_RESPONSE_START==="
    end = "===TELEGRAM_RESPONSE_END==="
    si = output.find(start)
    ei = output.find(end)
    if si >= 0 and ei > si:
        tg_msg = output[si + len(start):ei].strip()
        transcript = (output[:si] + output[ei + len(end):]).strip()
        return tg_msg, transcript
    # Fallback: full output
    return output.strip(), output.strip()


# -------- Thread append + meta update --------

def _append_turn(repo_dir: Path, session_id: str,
                  turn_n: int, role: str, text: str) -> Path:
    thread_path = (repo_dir / "inbox" / "agent" / "sessions"
                   / f"{session_id}-thread.md")
    ts = now_utc().isoformat()
    entry = f"\n[turn:{turn_n}, role:{role}, ts:{ts}]\n{text}\n"
    with thread_path.open("a") as fh:
        fh.write(entry)
    return thread_path


def _update_session_meta(repo_dir: Path, session_id: str, updates: dict) -> Path:
    meta_path = (repo_dir / "inbox" / "agent" / "sessions"
                 / f"{session_id}.md")
    update_task_frontmatter(meta_path, updates)
    return meta_path


# -------- Per-turn processor --------

def _process_session_turn(
    session_id: str,
    thread_path: Path,
    meta_path: Path,
    repo_dir: Path,
    fm: dict,
    turn_n: int,
    db_conn: sqlite3.Connection,
    dry_run: bool,
) -> bool:
    tg_chat_id = fm.get("tg_chat_id")
    log(f"=== Session {session_id} turn {turn_n} ===")

    turns = _parse_thread(thread_path.read_text())

    if _is_turn_processed(db_conn, session_id, turn_n):
        log(f"Turn {turn_n} already processed — skip")
        return False

    prompt = _build_session_prompt(session_id, tg_chat_id, turns, turn_n)

    if dry_run:
        log(f"DRY-RUN: would process session turn {turn_n} ({len(prompt)} chars)")
        return False

    _heartbeat_ping(db_conn, session_id)

    started_at = now_utc()
    ok, output = invoke_claude(prompt, MODEL_DEFAULT)
    finished_at = now_utc()
    log(f"claude done ok={ok} dur={(finished_at-started_at).total_seconds():.0f}s")

    tg_msg, _transcript = _extract_tg_response(output)

    # Write response with retry loop: fetch+reset before each attempt so we
    # always push on top of the latest remote state. Retries handle concurrent
    # bot commits (GitHub API) that arrive between our fetch and push.
    _MAX_PUSH_RETRIES = 4
    push_ok = False
    for _attempt in range(_MAX_PUSH_RETRIES):
        log(f"Syncing with remote before writing response (attempt {_attempt+1})...")
        subprocess.run(["git", "rebase", "--abort"], cwd=repo_dir,
                       capture_output=True)  # clean up any stuck rebase
        run(["git", "fetch", "origin", GOV_BRANCH], cwd=repo_dir, timeout=30)
        run(["git", "reset", "--hard", f"origin/{GOV_BRANCH}"], cwd=repo_dir,
            timeout=30)

        # Re-read thread after reset for accurate response_n
        thread_file = (repo_dir / "inbox" / "agent" / "sessions"
                       / f"{session_id}-thread.md")
        if thread_file.exists():
            current_turns = _parse_thread(thread_file.read_text())
            response_n = max((t["n"] for t in current_turns), default=turn_n) + 1
        else:
            response_n = turn_n + 1

        updated_thread = _append_turn(repo_dir, session_id, response_n, "claude",
                                      tg_msg)
        updated_meta = _update_session_meta(repo_dir, session_id, {
            "last_turn_at": finished_at.isoformat(),
            "turn_count": response_n,
            "status": "active" if ok else "failed",
        })

        rel_files = [
            str(updated_thread.relative_to(repo_dir)),
            str(updated_meta.relative_to(repo_dir)),
        ]
        run(["git", "add", *rel_files], cwd=repo_dir)
        run(["git", "commit", "-m",
             f"session({session_id}): turn {turn_n}→{response_n}"], cwd=repo_dir)

        result = subprocess.run(
            ["git", "push", "origin", GOV_BRANCH],
            cwd=repo_dir, capture_output=True, timeout=60,
        )
        if result.returncode == 0:
            push_ok = True
            break
        log(f"Push rejected (attempt {_attempt+1}), will retry with fresh fetch...")
        # Undo the commit so next attempt starts clean
        subprocess.run(["git", "reset", "HEAD~1", "--hard"], cwd=repo_dir,
                       capture_output=True)

    if not push_ok:
        raise RuntimeError(
            f"Failed to push session response after {_MAX_PUSH_RETRIES} attempts"
        )

    _mark_turn_processed(db_conn, session_id, turn_n)
    _heartbeat_ping(db_conn, session_id)

    if tg_chat_id:
        sent = _send_tg_direct(int(tg_chat_id), tg_msg)
        log(f"TG send {'ok' if sent else 'failed'} → chat {tg_chat_id}")

    return True


# -------- Session scanner --------

def _find_pending_session_turns(
    repo_dir: Path, db_conn: sqlite3.Connection,
) -> list[tuple]:
    """Returns list of (session_id, thread_path, meta_path, fm, turn_n)."""
    sessions_dir = repo_dir / "inbox" / "agent" / "sessions"
    if not sessions_dir.exists():
        return []

    pending = []
    for meta_file in sorted(sessions_dir.glob("SESSION-*.md")):
        if "-thread" in meta_file.name:
            continue
        try:
            fm, _ = parse_frontmatter_v2(meta_file.read_text())
        except Exception as exc:
            log(f"Cannot parse {meta_file.name}: {exc}", "WARN")
            continue

        if fm.get("status") not in ("active", "pending"):
            continue

        session_id = fm.get("session_id", meta_file.stem)

        # Reject malformed session_id to prevent path traversal via crafted GitHub files
        if not _SESSION_ID_RE.match(str(session_id)):
            log(f"Skipping session with invalid id: {session_id!r}", "WARN")
            continue

        thread_file = meta_file.parent / f"{session_id}-thread.md"
        if not thread_file.exists():
            continue

        # Check for idle timeout
        last_turn_at = fm.get("last_turn_at") or fm.get("created_at", "")
        if last_turn_at:
            try:
                last_dt = dt.datetime.fromisoformat(
                    last_turn_at.replace("Z", "+00:00") if last_turn_at.endswith("Z")
                    else last_turn_at
                )
                idle_min = (now_utc() - last_dt.astimezone(dt.timezone.utc)).total_seconds() / 60
                if idle_min > SESSION_IDLE_TIMEOUT_MIN:
                    log(f"Session {session_id} idle {idle_min:.0f}m → closing")
                    _update_session_meta(repo_dir, session_id, {"status": "completed"})
                    # Commit and push the idle-close so it persists to remote
                    try:
                        rel_meta = str(meta_file.relative_to(repo_dir))
                        run(["git", "add", rel_meta], cwd=repo_dir)
                        run(["git", "commit", "-m",
                             f"session({session_id}): idle_timeout → completed"], cwd=repo_dir)
                        run(["git", "push", "origin", GOV_BRANCH], cwd=repo_dir, timeout=60)
                    except Exception as push_exc:
                        log(f"Idle-close push failed for {session_id}: {push_exc}", "WARN")
                    continue
            except Exception:
                pass

        turns = _parse_thread(thread_file.read_text())
        for turn in turns:
            if (turn["role"] == "pilot"
                    and not _is_turn_processed(db_conn, session_id, turn["n"])):
                pending.append((session_id, thread_file, meta_file, fm, turn["n"]))
                break  # one turn at a time per session

    return pending


# -------- Session mode main --------

def session_mode_main(workdir: Path, dry_run: bool) -> None:
    log("Session mode dispatcher starting (WP-358 Ф2)")
    ensure_workdir(workdir)
    repo_dir = workdir / _repo_basename()

    db_conn = _get_session_db()
    try:
        pending = _find_pending_session_turns(repo_dir, db_conn)
        log(f"Pending session turns: {len(pending)}")

        for session_id, thread_file, meta_file, fm, turn_n in pending:
            try:
                _process_session_turn(
                    session_id=session_id,
                    thread_path=thread_file,
                    meta_path=meta_file,
                    repo_dir=repo_dir,
                    fm=fm,
                    turn_n=turn_n,
                    db_conn=db_conn,
                    dry_run=dry_run,
                )
            except Exception as exc:
                log(f"Error session {session_id} turn {turn_n}: {exc}", "ERROR")
                import traceback
                log(traceback.format_exc(), "ERROR")
    finally:
        db_conn.close()
    log("Session mode dispatcher done")


if __name__ == "__main__":
    main()
