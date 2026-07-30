#!/usr/bin/env python3
"""
iwe-agent-dispatcher.py — диспетчер Agent Inbox IWE (WP-324 Ф8).

SoT (Source-of-Truth): ~/IWE/<governance-repo>/scripts/iwe-agent-dispatcher.py
Все другие копии должны синхронизироваться отсюда:
  - FMT-exocortex-template/scripts/
  - FMT-exocortex-template/extensions/agent-inbox/scripts/
  - DS-autonomous-agents/scripts/
Синхронизация: `cp <canonical> <target>` + `git add -u && git commit -m "sync iwe-agent-dispatcher"`

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
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import time
from pathlib import Path

# WP-436 Ф1 gate integration: single-writer classify_and_log routes + logs in one call.
sys.path.insert(0, str(Path(__file__).parent))
try:
    from iwe_gate import classify_and_log as _gate_classify_and_log, GateInput
    _GATE_AVAILABLE = True
except ImportError:
    _GATE_AVAILABLE = False

# === Конфигурация (можно переопределить через env vars или CLI args) ===
GOV_REPO_URL = os.environ.get("IWE_DISPATCHER_REPO_URL", "")  # обязательно задать через env
GOV_BRANCH = os.environ.get("IWE_DISPATCHER_REPO_BRANCH", "main")
LOCK_FILE = os.environ.get("IWE_DISPATCHER_LOCK_FILE", "/tmp/iwe-agent-dispatcher.lock")
LOCK_TTL_MIN = int(os.environ.get("IWE_DISPATCHER_LOCK_TTL_MIN", "50"))
MODEL_DEFAULT = os.environ.get("IWE_DISPATCHER_MODEL_DEFAULT", "sonnet")
CLAUDE_TIMEOUT_SEC = int(os.environ.get("IWE_DISPATCHER_CLAUDE_TIMEOUT_SEC", "1800"))

# WP-7 TGSH (2026-05-30): heartbeat в event-gateway для session-mode.
# Каждые HEARTBEAT_INTERVAL_SEC dispatcher publish session.heartbeat → бот edits "⏳ Работаю..." с счётчиком.
HEARTBEAT_INTERVAL_SEC = int(os.environ.get("IWE_DISPATCHER_HEARTBEAT_INTERVAL_SEC", "15"))
# WP-358 follow-up Ф3a (2026-05-30): inline Python POST в event-gateway (без shell-обёртки).
# Зависимости только из stdlib — нужно для Y.2 deploy без локального клона репо.
IWE_EVENT_GATEWAY_URL = os.environ.get(
    "IWE_EVENT_GATEWAY_URL", "https://event-gateway.aisystant.workers.dev"
)
IWE_OWNER_ORY_UUID = os.environ.get("IWE_OWNER_ORY_UUID", "")

# WP-428 Ф6 mid-session control: sentinel returned by invoke_claude_with_heartbeat
# when the pilot issued /stop or /cancel via the event-gateway command channel.
_STOPPED_BY_USER = "STOPPED_BY_USER"
_STOP_ACTIONS = frozenset(("stop", "cancel"))

COMMIT_AUTHOR_NAME = os.environ.get("IWE_DISPATCHER_AUTHOR_NAME", "IWE Agent Dispatcher")
COMMIT_AUTHOR_EMAIL = os.environ.get("IWE_DISPATCHER_AUTHOR_EMAIL", "noreply@example.com")

# WP-358 follow-up Ф3 (2026-05-30): Y.2 deploy — stateless dispatcher на tsekh-1.
# При наличии GITHUB_TOKEN session-mode использует GitHub Contents API (read) +
# Git Data API (atomic write blob+tree+commit+ref). Без TOKEN — fallback на старый
# stateful session-mode через локальный клон (--workdir обязателен).
IWE_DISPATCHER_GITHUB_TOKEN = os.environ.get("IWE_DISPATCHER_GITHUB_TOKEN", os.environ.get("GITHUB_TOKEN", ""))
IWE_DISPATCHER_GITHUB_REPO = os.environ.get("IWE_DISPATCHER_GITHUB_REPO", "your-username/your-governance-repo")
IWE_DISPATCHER_GITHUB_BRANCH = os.environ.get("IWE_DISPATCHER_GITHUB_BRANCH", "main")
IWE_DISPATCHER_ETAG_DB = os.path.expanduser(
    os.environ.get("IWE_DISPATCHER_ETAG_DB", "~/.iwe/dispatcher-etags.db")
)

# Version self-check — see _check_dispatcher_version().
__version__ = "2026-05-30-y2-1"
# WP-503 Ф5.2 Security pre-flight (2026-07-26): PII-filter + shell-injection guard
_SECURITY_VERSION = "2026-07-26-security-1"

# === Security: PII-filter + shell-injection guard (WP-503 Ф5.2) ===
# See also: WP-500 (agent-trace-recorder.sh) for similar PII-masking pattern.

# PII blocking patterns (Security Gate B7.3)
_PII_PATTERNS = [
    (r'[\w.+-]+@[\w-]+\.\w+', '[email]'),          # email@domain.com
    (r'(?<![\w/])@\w{3,}(?!\w)', '[mention]'),    # @username (but not @types/*)
    (r'cp\.\w+\s*=\s*\S+', '[config]'),            # cp.field = value
    (r'User[ID]*\s*[:=]\s*\S+', '[userid]'),       # User: or UserID = ...
]

_PII_RE = re.compile('|'.join(f'({pat})' for pat, _ in _PII_PATTERNS), re.IGNORECASE)


def mask_pii(value: str, max_length: int = 500) -> str:
    """Mask PII in string values; truncate long strings to prevent log spam.

    Used in TG alert digests and logs to comply with Security Gate B7.3.
    """
    if not isinstance(value, str) or not value:
        return value
    if len(value) > max_length:
        value = value[:max_length] + '...'
    def replace_pii(match):
        for i, (_, mask) in enumerate(_PII_PATTERNS):
            if match.group(i + 1):
                return mask
        return match.group(0)
    return _PII_RE.sub(replace_pii, value)


def sanitize_shell_param(value) -> str:
    """Escape parameter for safe shell execution using shlex.quote.

    WP-503 Ф5.2 shell-injection guard: all frontmatter parameters
    passed to shell commands must be quoted via this function.
    """
    if value is None:
        return "''"
    return shlex.quote(str(value))


def build_safe_digest(task_id: str, output: str, fm: dict, max_len: int = 200) -> str:
    """Build TG-safe digest: hash + size + safe params, NO content or PII.

    WP-503 Ф5.2 PII-filter compliance: TG alert digests only contain
    public identifiers and hashed output, never content or PII.
    """
    output_hash = hashlib.sha256(output.encode()).hexdigest()[:8]
    size_kb = len(output) / 1024

    safe_fields = {
        'task_id': task_id,
        'output_hash': output_hash,
        'size_kb': f'{size_kb:.1f}',
    }

    if 'model' in fm:
        safe_fields['model'] = fm.get('model', 'unknown')
    if 'agent' in fm:
        safe_fields['agent'] = fm.get('agent', 'unknown')

    digest = ' | '.join(f'{k}={v}' for k, v in safe_fields.items())

    if len(digest) > max_len:
        digest = digest[:max_len] + '...'

    return digest

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


def _guard_repo_dir_is_isolated(repo_dir: Path) -> None:
    """Отказ вместо тихого reset --hard / identity-перезаписи в живой рабочей копии пилота.

    bug-2026-07-25: --workdir ~/IWE (вместо изолированного /tmp/...) заставил ensure_workdir()
    переписать git user.name/email в ~/IWE/<governance-repo> и оставить это на будущее — коммиты
    из живой рабочей копии стали подписываться как диспетчер. reset --hard в том же вызове
    мог бы стереть незакоммиченную работу пилота.
    """
    iwe_root = Path(os.environ.get("IWE_HOME", str(Path.home() / "IWE"))).resolve()
    if not iwe_root.is_dir():
        return
    resolved = repo_dir.resolve()
    for candidate in iwe_root.iterdir():
        if (candidate / ".git").is_dir() and candidate.resolve() == resolved:
            raise SystemExit(
                f"REFUSING: --workdir resolves to a live pilot working copy ({candidate}), "
                f"not an isolated dispatcher clone. Pass an isolated --workdir (e.g. /tmp/iwe-dispatcher)."
            )


def ensure_workdir(workdir: Path) -> None:
    """Гарантирует наличие свежего клона."""
    repo_dir = workdir / _repo_basename()
    _guard_repo_dir_is_isolated(repo_dir)
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
        # A git op killed mid-write leaves .git/index.lock, which makes every
        # later `reset --hard` fail (exit 128) → the dispatcher crash-loops
        # forever. Safe to clear here: launchd runs a single dispatcher instance,
        # so no concurrent git process holds it. (bug-2026-06-20-session-dispatcher-py39)
        (repo_dir / ".git" / "index.lock").unlink(missing_ok=True)
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
        # process-run cards (WP-482 Ф3) already miss this TASK-*.md glob by naming
        # convention; this check makes that an invariant, not just a filename habit,
        # in case the glob is ever widened for an unrelated reason.
        if fm.get("kind") == "process-run":
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


def invoke_claude(prompt: str, model: str, repo_dir: Path | None = None) -> tuple[bool, str]:
    """Возвращает (ok, output).

    Backward-compatible obвёртка вокруг `invoke_claude_with_heartbeat` без heartbeat-канала.
    Используется в task-mode (Agent Inbox). Session-mode использует `invoke_claude_with_heartbeat`.
    """
    return invoke_claude_with_heartbeat(prompt, model, session_id=None, turn_n=None, repo_dir=repo_dir)


# WP-358 follow-up Ф3a (2026-05-30): inline POST в event-gateway, без shell.
# Source-of-truth контракта: DP.SC.044 (event-gateway envelope).
_ACTIVITY_DOMAIN_MAP = {
    "session.heartbeat": "practice",
    "session.turn_completed": "practice",
    "session.turn_failed": "practice",
    "iwe_session": "practice",
}


def _emit_event(event_type: str, ext_suffix: str, payload: dict) -> None:
    """WP-7 TGSH + WP-358 follow-up Ф3a: эмитит событие в event-gateway через urllib. Non-blocking.

    Заменяет shell-обёртку iwe_event_emit.sh — убирает зависимость от локального клона репо
    на tsekh-1 (Y.2 deploy). Stdlib only.
    """
    import urllib.request as _urlreq
    import urllib.error as _urlerr
    try:
        payload = dict(payload)  # copy, чтобы не мутировать caller
        if IWE_OWNER_ORY_UUID and "ory_uuid" not in payload:
            payload["ory_uuid"] = IWE_OWNER_ORY_UUID
        if "activity_domain" not in payload:
            domain = _ACTIVITY_DOMAIN_MAP.get(event_type)
            if domain:
                payload["activity_domain"] = domain

        envelope = {
            "source": "iwe",
            "external_id": f"iwe-{event_type}-{ext_suffix}",
            "event_type": event_type,
            "schema_version": "v1",
            "occurred_at": now_utc().strftime("%Y-%m-%dT%H:%M:%SZ"),
            "account_id": IWE_OWNER_ORY_UUID if IWE_OWNER_ORY_UUID else None,
            "payload": payload,
        }
        body = json.dumps(envelope).encode("utf-8")
        req = _urlreq.Request(
            f"{IWE_EVENT_GATEWAY_URL}/events",
            data=body,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with _urlreq.urlopen(req, timeout=5) as resp:
                status = resp.status
                if status not in (200, 201):
                    log(f"event_emit {event_type}: HTTP {status}", level="WARN")
        except _urlerr.HTTPError as he:
            log(f"event_emit {event_type}: HTTP {he.code}", level="WARN")
        except Exception as exc:  # noqa: BLE001
            log(f"event_emit {event_type}: {type(exc).__name__}: {exc}", level="WARN")
    except Exception as exc:  # noqa: BLE001
        # Никогда не блокируем dispatcher из-за event-gateway отказа.
        log(f"event_emit failed for {event_type}: {type(exc).__name__}", level="WARN")


def _poll_stop_command(session_id: str) -> bool:
    """Poll event-gateway for a pending stop/cancel command for this session.

    Returns True when action is 'stop' or 'cancel'; False on any error or 404.
    The /sessions/<id>/commands endpoint does not exist until the event-gateway
    side of WP-428 Ф6 is deployed — fail-open on 404 is intentional so the
    runner side can ship independently (WP-428 Ф6 scope: runner only).
    """
    import urllib.request as _urlreq
    url = f"{IWE_EVENT_GATEWAY_URL}/sessions/{session_id}/commands"
    try:
        req = _urlreq.Request(url, method="GET",
                              headers={"Accept": "application/json"})
        with _urlreq.urlopen(req, timeout=5) as resp:
            if resp.status != 200:
                return False
            data = json.loads(resp.read().decode("utf-8"))
            return data.get("action", "") in _STOP_ACTIONS
    except Exception:  # noqa: BLE001 — 404 / network / no endpoint yet: silently skip
        return False


# Регэкспы для классификации Claude API failure modes (WP-7 TGSH8).
_USAGE_LIMIT_PATTERNS = re.compile(
    r"usage.{0,5}limit|regain.{0,5}access|exceeded.{0,15}quota|"
    r"rate.{0,5}limit|429|insufficient.{0,5}credit",
    re.IGNORECASE,
)


def _classify_claude_failure(stderr: str, stdout: str) -> str:
    """Возвращает причину неудачи Claude headless для session.turn_failed.

    Returns: 'usage_limit' | 'timeout' | 'not_found' | 'unknown'
    """
    combined = (stderr or "") + "\n" + (stdout or "")
    if _USAGE_LIMIT_PATTERNS.search(combined):
        return "usage_limit"
    if "TIMEOUT after" in combined:
        return "timeout"
    if "CLI not found" in combined:
        return "not_found"
    return "unknown"


# =============================================================================
# Executor selection (WP-428 Ф5) — runtime factory for agentic session execution.
# The bot writes `executor` into the SESSION meta; the dispatcher builds the
# headless CLI command per runtime here. Adding a 4th runtime = new subclass +
# one EXECUTORS entry, with no change to the invocation loop (anti-coupling
# invariant). See: inbox/WP-428/adr-unified-bot-router.md (v2).
# =============================================================================

_SECURITY_WHITELIST_PATH = Path(__file__).parent / "config" / "pipeline-security-whitelist.yaml"


def _load_disallowed_tools() -> list[str]:
    """WP-503 Ф9 (АрхГейт Ф5 NBR №3): headless Executor не должен повторить
    инцидент WP-7 23.07 (`railway list_variables` без фильтра напечатал ~90
    боевых секретов). Читает файл заново на каждый вызов (не кэширует) —
    расширение whitelist не требует перезапуска диспетчера.

    Пустой список при отсутствующем/битом файле — это НЕ fail-open дыра:
    отсутствие --disallowedTools просто не сужает права сверх дефолтных
    permission-настроек CLI, whitelist добавляет ограничения, не снимает их."""
    import yaml
    try:
        with open(_SECURITY_WHITELIST_PATH, encoding="utf-8") as f:
            data = yaml.safe_load(f) or {}
    except (OSError, yaml.YAMLError) as e:
        log(f"security whitelist не загружен ({_SECURITY_WHITELIST_PATH}): {e}, продолжаю без --disallowedTools", "WARN")
        return []
    tools = data.get("disallowed_tools") or []
    return [str(t) for t in tools if isinstance(t, str)]


class Executor:
    """Base agentic executor: builds the headless CLI command for one runtime."""

    name: str = "base"
    # Whether this runtime streams long enough to warrant session.heartbeat events.
    supports_heartbeat: bool = False

    def build_cmd(self, prompt: str, model: str) -> list[str]:
        raise NotImplementedError


class ClaudeCodeExecutor(Executor):
    """Claude Code CLI (`claude -p`). Streaming run → emits heartbeats."""

    name = "claude"
    supports_heartbeat = True

    def build_cmd(self, prompt: str, model: str) -> list[str]:
        cmd = ["claude", "-p", prompt, "--model", model, "--output-format", "text"]
        disallowed = _load_disallowed_tools()
        if disallowed:
            cmd += ["--disallowedTools", ",".join(disallowed)]
        return cmd


class KimiCliExecutor(Executor):
    """Kimi CLI (`kimi -p`) one-shot. Synchronous → no heartbeat channel.

    The Claude model string is not portable to Kimi, so it is ignored here and
    the Kimi CLI default model is used.
    """

    name = "kimi"
    supports_heartbeat = False

    def build_cmd(self, prompt: str, model: str) -> list[str]:
        # `--print` runs Kimi non-interactively AND auto-approves tool actions
        # (per `kimi --help`). Without it, `kimi -p` opens an interactive agent
        # that never returns to stdout — the dispatcher poll loop would block
        # until CLAUDE_TIMEOUT_SEC. `--final-message-only` prints just the final
        # assistant message (without it, `--output-format text` dumps the whole
        # event stream). `--output-format` is only honoured with `--print`. The
        # Claude model string is not portable to Kimi, so the Kimi config
        # default model is used instead of passing `--model`.
        # The Kimi binary may be VS Code-managed and reachable only via a shell
        # alias (invisible to subprocess). Resolve an explicit path: IWE_KIMI_BIN
        # override → PATH lookup → bare "kimi" (the bare value soft-fails with
        # "kimi CLI not found in PATH" in invoke_claude_with_heartbeat).
        kimi_bin = os.environ.get("IWE_KIMI_BIN") or shutil.which("kimi") or "kimi"
        return [
            kimi_bin, "--print", "--final-message-only",
            "--output-format", "text", "-p", prompt,
        ]


# Registry of agentic runtimes reachable through the bot SESSION path.
# Note: `hermes` is intentionally absent — in Ф5 it is a conversational
# bot-side route to hermes_chat and never reaches the dispatcher. Full agentic
# Hermes is a separate spin-off РП.
EXECUTORS: dict[str, "Executor"] = {
    "claude": ClaudeCodeExecutor(),
    "kimi": KimiCliExecutor(),
}
DEFAULT_EXECUTOR = "claude"


def resolve_executor(executor_key: str | None) -> "Executor":
    """Map a SESSION `executor` value to an Executor, defaulting to Claude.

    Unknown values fall back to the default with a warning rather than failing —
    the dispatcher must keep serving the pilot even if the bot writes a value it
    does not recognise.
    """
    key = (executor_key or DEFAULT_EXECUTOR).strip().lower()
    executor = EXECUTORS.get(key)
    if executor is None:
        log(f"Unknown executor {key!r} — falling back to {DEFAULT_EXECUTOR}", "WARN")
        return EXECUTORS[DEFAULT_EXECUTOR]
    return executor


def invoke_claude_with_heartbeat(
    prompt: str,
    model: str,
    session_id: str | None,
    turn_n: int | None,
    repo_dir: Path | None = None,
    executor_key: str = DEFAULT_EXECUTOR,
) -> tuple[bool, str]:
    """Run an agentic executor headless via Popen, emitting session.heartbeat
    events every HEARTBEAT_INTERVAL_SEC for streaming runtimes.

    WP-7 TGSH (2026-05-30): with session_id=None behaves like the old
    invoke_claude (no heartbeat).
    WP-428 Ф5: `executor_key` selects the runtime (claude | kimi). The function
    name is kept for backward compatibility with existing call sites.
    """
    executor = resolve_executor(executor_key)
    cmd = executor.build_cmd(prompt, model)
    started = time.monotonic()

    try:
        proc = subprocess.Popen(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            cwd=str(repo_dir) if repo_dir else None,
        )
        log(f"[RC5] dispatch executor={executor.name} pid={proc.pid} cwd={repo_dir}")
    except FileNotFoundError:
        return False, f"{executor.name} CLI not found in PATH"

    last_heartbeat = 0.0
    timed_out = False
    stopped_by_user = False  # WP-428 Ф6 mid-session control

    while True:
        elapsed = time.monotonic() - started
        if elapsed > CLAUDE_TIMEOUT_SEC:
            proc.kill()
            timed_out = True
            break

        if (executor.supports_heartbeat and session_id
                and (elapsed - last_heartbeat) >= HEARTBEAT_INTERVAL_SEC):
            _emit_event(
                "session.heartbeat",
                f"{session_id}-turn{turn_n}-{int(elapsed)}",
                {
                    "session_id": session_id,
                    "turn_n": turn_n,
                    "elapsed_sec": int(elapsed),
                    "progress_hint": "Claude генерирует ответ",
                },
            )
            last_heartbeat = elapsed
            # WP-428 Ф6: check for pilot stop/cancel on each heartbeat tick.
            if _poll_stop_command(session_id):
                proc.kill()
                stopped_by_user = True
                break

        if proc.poll() is not None:
            break

        time.sleep(1)  # tight poll, lightweight

    try:
        stdout, stderr = proc.communicate(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        stdout, stderr = proc.communicate()

    if timed_out:
        output = f"TIMEOUT after {CLAUDE_TIMEOUT_SEC}s"
        if session_id:
            _emit_event(
                "session.turn_failed",
                f"{session_id}-turn{turn_n}",
                {"session_id": session_id, "turn_n": turn_n, "reason": "timeout"},
            )
        return False, output

    if stopped_by_user:
        log(f"[RC5] session {session_id} stopped by user command")
        return False, _STOPPED_BY_USER

    ok = (proc.returncode == 0)
    output = (stdout or "") + (("\n" + stderr) if stderr else "")

    if session_id:
        if ok:
            _emit_event(
                "session.turn_completed",
                f"{session_id}-turn{turn_n}",
                {"session_id": session_id, "turn_n": turn_n, "elapsed_sec": int(elapsed)},
            )
        else:
            reason = _classify_claude_failure(stderr or "", stdout or "")
            _emit_event(
                "session.turn_failed",
                f"{session_id}-turn{turn_n}",
                {"session_id": session_id, "turn_n": turn_n, "reason": reason},
            )

    return ok, output


# RC2: domain verdict parsing + TG alert
_VERDICT_RE = re.compile(r"VERDICT:\s*(PASS|FAIL|SYSTEM FAIL)", re.IGNORECASE)


def _parse_verdict(output: str) -> str | None:
    """Extract domain verdict from agent stdout."""
    m = _VERDICT_RE.search(output)
    return m.group(1).upper() if m else None


def _send_tg_alert(task_id: str, verdict: str, output: str) -> None:
    """Send TG alert on FAIL/SYSTEM FAIL (RC2).

    WP-503 Ф5.2 Security Gate §Б: digest does NOT include output content,
    only hash + size (PII-safe, no sensitive details leaked to Telegram).
    """
    chat_id = os.environ.get("TG_ALERT_CHAT_ID")
    if not chat_id:
        log("TG_ALERT_CHAT_ID not set — skipping alert", "WARN")
        return
    # WP-503 Ф5.2: use safe_digest instead of raw output excerpt
    summary = build_safe_digest(task_id, output, {"verdict": verdict}, max_len=120)
    text = (
        f"🚨 Agent Inbox FAIL\n"
        f"Verdict: {verdict}\n"
        f"Digest: {summary}"
    )
    ok = _send_tg_with_routing(int(chat_id), text, target_bot=None)
    log(f"TG alert {'sent' if ok else 'failed'} for {task_id} verdict={verdict}")


def write_result(repo_dir: Path, task_id: str, fm: dict,
                  ok: bool, output: str, started_at: dt.datetime,
                  finished_at: dt.datetime, verdict: str | None = None) -> Path:
    results_dir = repo_dir / "inbox" / "agent" / "results"
    results_dir.mkdir(parents=True, exist_ok=True)
    result_path = results_dir / f"RESULT-{task_id.replace('TASK-', '')}.md"

    content = (
        f"---\n"
        f"task_id: {task_id}\n"
        f"status: {'completed' if ok else 'failed'}\n"
        f"verdict: {verdict or 'UNKNOWN'}\n"
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

    # WP-436 Ф1 gate: classify+log via the single writer; reflex execution driven by catalog exec_kind
    _gate_out = None
    if _GATE_AVAILABLE:
        _gate_inp: GateInput = {
            "task_type": fm.get("task_type", ""),
            "no_py_files": bool(fm.get("no_py_files", False)),
        }
        _gate_out = _gate_classify_and_log(_gate_inp, source="dispatcher", task_id=task_id)
        log(f"gate routing={_gate_out['routing']} handler={_gate_out['handler']} "
            f"exec_kind={_gate_out['exec_kind']} confidence={_gate_out['confidence']:.2f}")

        if _gate_out["routing"] == "reflex":
            _kind = _gate_out["exec_kind"]
            if _kind == "none":
                # Sentinel reflex: nothing to run, the decision itself is the action.
                log(f"reflex sentinel skip: {_gate_out['handler']}")
                update_task_frontmatter(task_path, {
                    "status": "completed",
                    "finished_at": now_utc().isoformat(),
                    "result": f"skipped via gate reflex sentinel ({_gate_out['handler']})",
                })
                commit_and_push(repo_dir,
                    f"dispatch(WP-324): {task_id} reflex-skip {_gate_out['handler']}",
                    [task_path])
                return True
            if _kind != "script":
                # Unknown/missing exec_kind = catalog config error. Mirror the door (_exec_reflex):
                # do not guess "script", never silently fall to LLM -- hard fail (WP-436 review).
                log(f"reflex '{_gate_out['handler']}' has no/unknown exec_kind ({_kind}) -- fix catalog; hard fail", "ERROR")
                update_task_frontmatter(task_path, {
                    "status": "failed",
                    "finished_at": now_utc().isoformat(),
                    "result": f"reflex bad exec_kind ({_kind}): {_gate_out['handler']}",
                })
                commit_and_push(repo_dir,
                    f"dispatch(WP-324): {task_id} reflex-bad-exec-kind {_gate_out['handler']}",
                    [task_path])
                return False
            # exec_kind == "script": catalog is authoritative. A missing handler is a config
            # bug, NOT a reason to call the LLM -- hard fail keeps the gate enforced (WP-436 cond.3).
            _handler = _gate_out["handler"] or ""
            _handler_path = Path(__file__).parent / _handler
            if not _handler_path.exists():
                log(f"reflex handler '{_handler}' is exec:script but not found -- hard fail, no LLM fallback", "ERROR")
                update_task_frontmatter(task_path, {
                    "status": "failed",
                    "finished_at": now_utc().isoformat(),
                    "result": f"reflex handler not found: {_handler}",
                })
                commit_and_push(repo_dir,
                    f"dispatch(WP-324): {task_id} reflex-handler-missing {_handler}",
                    [task_path])
                return False
            log(f"executing reflex handler: {_handler_path}")
            _hresult = subprocess.run(
                [sys.executable, str(_handler_path), str(task_path)],
                capture_output=True, text=True, timeout=120, cwd=repo_dir,
            )
            _hok = _hresult.returncode == 0
            log(f"reflex handler done ok={_hok}")
            update_task_frontmatter(task_path, {
                "status": "completed" if _hok else "failed",
                "finished_at": now_utc().isoformat(),
            })
            commit_and_push(repo_dir,
                f"dispatch(WP-324): {task_id} reflex done via {_handler}",
                [task_path])
            return _hok

    # Invoke claude (LLM path). The llm decision was already logged at classify time by
    # classify_and_log -- the dispatcher is no longer a second writer of the journal.
    ok, output = invoke_claude(prompt, model, repo_dir)
    finished_at = now_utc()
    log(f"claude done ok={ok} duration={(finished_at - started_at).total_seconds():.0f}s")

    # Sync with origin: agent may have committed its own result during execution.
    # reset --hard picks up those commits before we write dispatcher's status update.
    log("Syncing with origin after claude returned...")
    run(["git", "fetch", "origin", GOV_BRANCH], cwd=repo_dir, timeout=30)
    run(["git", "reset", "--hard", f"origin/{GOV_BRANCH}"], cwd=repo_dir, timeout=30)

    # Parse domain verdict from output (RC2 fix)
    domain_verdict = _parse_verdict(output)

    # Dispatcher is the single writer of result files (RC3 fix).
    results_dir = repo_dir / "inbox" / "agent" / "results"
    result_path = write_result(repo_dir, task_id, fm, ok, output, started_at, finished_at, verdict=domain_verdict)

    if domain_verdict in ("FAIL", "SYSTEM FAIL"):
        _send_tg_alert(task_id, domain_verdict, output)

    # Update task status with domain verdict
    update_task_frontmatter(task_path, {
        "status": "completed" if ok else "failed",
        "completed_at": finished_at.isoformat(),
        "verdict": domain_verdict or ("PASS" if ok else "UNKNOWN"),
    })
    commit_and_push(repo_dir,
        f"dispatch(WP-324): {task_id} → {'completed' if ok else 'failed'}",
        [task_path, result_path])

    return True


def _agent_to_model(agent: str) -> str:
    # WP-366 Ф4.C+D ч.2: dispatcher = Claude-only runtime by design.
    # Agent Inbox задачи агентские (tool-use: читают репо, пишут RESULT, коммитят),
    # поэтому плоский OpenRouter /chat/completions их НЕ исполняет. Дешёвая OR-миграция
    # агентских задач = отдельный OR-tool-use-loop (backlog, триггер >=1000 calls/day).
    # Не-Claude значения agent (kimi/gpt/gemini/...) не имеют серверного backend здесь —
    # раньше они МОЛЧА коэрсились в MODEL_DEFAULT. Теперь fallback громкий (structured WARN),
    # чтобы логи/пилот не врали о том, кто и на чём исполняется.
    if "opus" in agent:
        return "opus"
    if "sonnet" in agent:
        return "sonnet"
    if "haiku" in agent:
        return "haiku"
    log(
        f"agent_routing_fallback agent={agent!r} backend=none-on-server "
        f"chosen_model={MODEL_DEFAULT} reason=no-server-backend-for-non-claude-agent "
        f"note=cheap-OR-migration-of-agentic-tasks-needs-separate-WP",
        "WARN",
    )
    return MODEL_DEFAULT


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--workdir", required=False, type=Path, default=None,
                        help="Рабочая директория для клона governance-репо. "
                             "Обязателен для batch-mode; session-mode при наличии IWE_DISPATCHER_GITHUB_TOKEN "
                             "работает stateless через GitHub API (Y.2 deploy, WP-358 follow-up).")
    parser.add_argument("--dry-run", action="store_true",
                        help="Не вызывать claude, не пушить — только показать что будет")
    parser.add_argument("--task", default=None,
                        help="Обработать только task с этим ID (substring match)")
    parser.add_argument("--no-lock", action="store_true",
                        help="Игнорировать lock-файл")
    parser.add_argument("--mode", default="batch", choices=["batch", "session"],
                        help="batch (default): Agent Inbox tasks. session: External Session (WP-358)")
    parser.add_argument("--use-api", action="store_true",
                        help="Session-mode: принудительно использовать GitHub API (Y.2). "
                             "По умолчанию автоопределение по наличию IWE_DISPATCHER_GITHUB_TOKEN.")
    args = parser.parse_args()

    if not args.no_lock and not acquire_lock():
        sys.exit(0)

    try:
        if args.mode == "session":
            # WP-358 follow-up Ф3 (2026-05-30): Y.2 stateless через GitHub API
            # активируется наличием GITHUB_TOKEN или явным --use-api. Fallback —
            # старая stateful реализация через локальный клон (требует --workdir).
            use_api = args.use_api or bool(IWE_DISPATCHER_GITHUB_TOKEN)
            if use_api:
                _check_dispatcher_version()  # WARN при drift'е версии
                session_mode_main_api(args.dry_run)
            else:
                if args.workdir is None:
                    log("session-mode без GITHUB_TOKEN требует --workdir для локального клона", "ERROR")
                    sys.exit(2)
                session_mode_main(args.workdir, args.dry_run)
            return

        if args.workdir is None:
            log("batch-mode требует --workdir", "ERROR")
            sys.exit(2)
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
TG_BOT_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "") or os.environ.get("TG_BOT_TOKEN", "")
SESSION_IDLE_TIMEOUT_MIN = int(os.environ.get("IWE_SESSION_IDLE_TIMEOUT_MIN", "60"))

# Allowlist for session_id values — prevents path traversal via crafted GitHub files
_SESSION_ID_RE = re.compile(r'^SESSION-[A-Za-z0-9-]+$')

_TURN_HEADER_RE = re.compile(
    r"^\[turn:(\d+),\s*role:([\w-]+)"  # WP-428 Ф5: role = pilot | claude | kimi | hermes | …
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
    # WP-5 Ф-21 hotfix (peer-session 2026-05-30-41 consensus):
    # Explicit column list — БД на диске может иметь legacy колонки
    # (commit_sha, committed_at) от предыдущей миграции. Implicit VALUES
    # упадёт с OperationalError «table has 5 columns but 3 values were supplied».
    conn.execute(
        "INSERT OR IGNORE INTO processed_turns (session_id, turn_n, processed_at) VALUES (?,?,?)",
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
                           turns: list[dict], new_turn_n: int,
                           executor: str = DEFAULT_EXECUTOR) -> str:
    """Build the headless agent prompt for a session turn (executor-aware)."""
    thread_text = ""
    for t in turns:
        header = f"[turn:{t['n']}, role:{t['role']}"
        if t.get("ts"):
            header += f", ts:{t['ts']}"
        header += "]"
        thread_text += f"{header}\n{t['text']}\n\n"

    latest = next(t for t in turns if t["n"] == new_turn_n)

    # WP-428 Ф5: identity follows the actual runtime, not a hardcoded "Claude Code"
    # (a kimi run that is told "you are Claude Code" is a false-green smoke).
    agent_label = {"claude": "Claude Code", "kimi": "Kimi",
                   "hermes": "Hermes"}.get(executor, executor)
    return f"""Ты — {agent_label} (IWE-агент) в External Working Session (DP.SC.162).
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


# -------- Ф6 audit-trail (WP-428) --------
# Append-only, machine-readable journal of agent actions, co-located with the
# SESSION files in the pilot's repo (their trust boundary, NOT Telegram —
# Security Gate B7.3 invariant 2). Distinct from `_emit_event` (the remote
# notification channel): this is the local audit log that satisfies B7.3
# invariant 1 (every agent action recorded) and invariant 4 (PII masked).

# Blocking PII patterns (B7.3 invariant 4 / DP.SC.183): user cp-profile
# assignments, emails and @-handles must never land in the audit verbatim.
# `WP-\d+` is log-only (legitimate inside repo paths) and is deliberately NOT
# masked here.
# The @-handle alternative requires the `@` to NOT follow a word char or `/`, so
# package scopes like `src/@types/index.ts` are not over-masked (cold-review
# 2026-06-21). Emails are caught by the preceding alternative.
_AUDIT_PII_RE = re.compile(r"cp\.\w+\s*=\s*\S+|[\w.+-]+@[\w-]+\.\w+|(?<![\w/])@\w{3,}")


def _audit_mask(value):
    """Mask blocking PII in a free-text audit field; pass non-strings through."""
    if not isinstance(value, str):
        return value
    return _AUDIT_PII_RE.sub("[masked]", value)


def _audit_path(repo_dir: Path, session_id: str) -> Path:
    return (repo_dir / "inbox" / "agent" / "sessions"
            / f"audit-{session_id}.jsonl")


def _audit_build(session_id: str, executor: str, action: str,
                 actor: str = "agent", **fields) -> dict:
    """Build one PII-masked audit event dict (does not write to disk)."""
    event = {
        "ts": now_utc().strftime("%Y-%m-%dT%H:%M:%SZ"),
        "session_id": session_id,
        "executor": executor,
        "actor": actor,
        "action": action,
        "pii_masked": True,
    }
    for key, val in fields.items():
        event[key] = _audit_mask(val)
    return event


def _audit_append(repo_dir: Path, session_id: str, events: list[dict]) -> Path:
    """Append audit events to the session audit log (append-only JSONL).

    Never raises: an audit failure must not abort a session turn. Returns the
    audit file path so the caller can include it in the turn commit (so the log
    survives the reset-hard sync and reaches the pilot's repo).
    """
    path = _audit_path(repo_dir, session_id)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as fh:
            for event in events:
                fh.write(json.dumps(event, ensure_ascii=False) + "\n")
    except Exception as exc:  # noqa: BLE001 — audit must never break a turn
        log(f"audit_append failed for {session_id}: {type(exc).__name__}", "WARN")
    return path


# -------- Per-turn processor --------

def _handle_session_stop(
    repo_dir: Path, session_id: str, executor_name: str,
    audit_events: list, db_conn: sqlite3.Connection,
    tg_chat_id: str | None, turn_n: int,
) -> bool:
    """Write stop tombstone, append audit entry, commit, push (best-effort).

    Called when invoke_claude_with_heartbeat returns _STOPPED_BY_USER.
    The tombstone (stop_requested: True, status: stopped) prevents the next
    dispatcher invocation from re-processing any pending turns of this session.
    """
    log(f"[RC5] session {session_id} writing stop tombstone (turn {turn_n})")
    audit_events.append(_audit_build(
        session_id, executor_name, "session_stopped",
        turn_n=turn_n, reason="stop_command"))
    tombstone_meta = _update_session_meta(repo_dir, session_id, {
        "stop_requested": True,
        "status": "stopped",
    })
    audit_file = _audit_append(repo_dir, session_id, audit_events)
    rel_files = [
        str(tombstone_meta.relative_to(repo_dir)),
        str(audit_file.relative_to(repo_dir)),
    ]
    try:
        run(["git", "add", *rel_files], cwd=repo_dir)
        run(["git", "commit", "-m",
             f"session({session_id}): stopped_by_user (turn {turn_n})"],
            cwd=repo_dir)
        subprocess.run(["git", "push", "origin", GOV_BRANCH],
                       cwd=repo_dir, capture_output=True, timeout=60)
    except Exception as exc:
        log(f"stop tombstone commit/push failed for {session_id}: {exc}", "WARN")
    _mark_turn_processed(db_conn, session_id, turn_n)
    if tg_chat_id:
        _send_tg_direct(int(tg_chat_id), "⏹ Сессия остановлена по вашему запросу.")
    return True


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

    # WP-428 Ф5: runtime chosen by the bot, carried in SESSION meta `executor`.
    executor_key = fm.get("executor") or DEFAULT_EXECUTOR
    executor_name = resolve_executor(executor_key).name  # actual runtime: prompt + audit role

    prompt = _build_session_prompt(session_id, tg_chat_id, turns, turn_n, executor_name)

    if dry_run:
        log(f"DRY-RUN: would process session turn {turn_n} "
            f"({len(prompt)} chars, executor={executor_name})")
        return False

    _heartbeat_ping(db_conn, session_id)

    # Ф6 audit-trail: record the dispatch and outcome of this agent turn.
    audit_events = [_audit_build(session_id, executor_name, "turn_dispatch",
                                 turn_n=turn_n)]

    started_at = now_utc()
    # WP-7 TGSH4/TGSH8: heartbeat в event-gateway каждые HEARTBEAT_INTERVAL_SEC + usage_limit classification.
    ok, output = invoke_claude_with_heartbeat(
        prompt, MODEL_DEFAULT, session_id=session_id, turn_n=turn_n, repo_dir=repo_dir,
        executor_key=executor_key,
    )
    finished_at = now_utc()
    log(f"agent done executor={executor_key} ok={ok} dur={(finished_at-started_at).total_seconds():.0f}s")

    # WP-428 Ф6: pilot issued /stop or /cancel — abort without writing a response.
    if not ok and output == _STOPPED_BY_USER:
        return _handle_session_stop(
            repo_dir, session_id, executor_name, audit_events,
            db_conn, tg_chat_id, turn_n)

    # Ф6 audit-trail: capture what the agent touched (before the reset-hard sync
    # in the push loop below discards uncommitted working-tree changes) and the
    # turn outcome.
    _porcelain = subprocess.run(
        ["git", "status", "--porcelain"], cwd=repo_dir,
        capture_output=True, text=True,
    ).stdout.strip()
    if _porcelain:
        _changed = [line[3:] for line in _porcelain.splitlines()]
        audit_events.append(_audit_build(
            session_id, executor_name, "agent_file_change", files=_changed))
    audit_events.append(_audit_build(
        session_id, executor_name, "turn_completed" if ok else "turn_failed",
        turn_n=turn_n, status="ok" if ok else "fail",
        duration_sec=int((finished_at - started_at).total_seconds())))

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

        updated_thread = _append_turn(repo_dir, session_id, response_n,
                                      executor_name, tg_msg)
        updated_meta = _update_session_meta(repo_dir, session_id, {
            "last_turn_at": finished_at.isoformat(),
            "turn_count": response_n,
            "status": "active" if ok else "failed",
        })

        # Ф6: append this turn's audit events (fresh on top of the just-reset
        # base) and include the audit log in the turn commit, so it survives the
        # reset-hard sync above and reaches the pilot's repo.
        audit_file = _audit_append(repo_dir, session_id, audit_events)

        rel_files = [
            str(updated_thread.relative_to(repo_dir)),
            str(updated_meta.relative_to(repo_dir)),
            str(audit_file.relative_to(repo_dir)),
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

        # WP-428 Ф6: tombstone written by _handle_session_stop → do not re-process.
        if fm.get("stop_requested"):
            log(f"Session {fm.get('session_id', meta_file.stem)} has stop_requested tombstone — skip")
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


# =============================================================================
# SESSION MODE — Y.2 API IMPLEMENTATION (WP-358 follow-up Ф3, 2026-05-30)
# =============================================================================
# Архитектура Y′ + Y.2 (peer-session 2026-05-30-36-dispatcher-unification-cleanup):
#   - Read: GitHub Contents API + ETag conditional polling (304 не считается в rate-limit).
#   - Write: GitHub Git Data API (blob → tree → commit → ref) — atomic commit thread+meta
#     без локального клона. Retry-on-422 (non-fast-forward) — first-class.
#   - Deploy: dispatcher.py выкатывается на tsekh-1 через scp/CI без локального клона репо.
#   - Heartbeat: inline _emit_event (stdlib).
#   - ETag cache: SQLite на tsekh-1 (~/.iwe/dispatcher-etags.db).
# See: sessions/2026-05/2026-05-30-36-dispatcher-unification-cleanup/report.md §4.
import hashlib


def _gh_etag_db() -> sqlite3.Connection:
    """SQLite cache для ETag conditional polling (idempotent: потеря БД = одна лишняя 200)."""
    db_dir = os.path.dirname(IWE_DISPATCHER_ETAG_DB)
    if db_dir:
        os.makedirs(db_dir, exist_ok=True)
    conn = sqlite3.connect(IWE_DISPATCHER_ETAG_DB)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS gh_etags (
            path TEXT PRIMARY KEY,
            etag TEXT NOT NULL,
            updated_at TEXT NOT NULL
        )
    """)
    conn.commit()
    return conn


def _gh_etag_get(conn: sqlite3.Connection, path: str) -> str | None:
    row = conn.execute("SELECT etag FROM gh_etags WHERE path=?", (path,)).fetchone()
    return row[0] if row else None


def _gh_etag_set(conn: sqlite3.Connection, path: str, etag: str) -> None:
    conn.execute(
        "INSERT INTO gh_etags VALUES (?,?,?) "
        "ON CONFLICT(path) DO UPDATE SET etag=excluded.etag, updated_at=excluded.updated_at",
        (path, etag, now_utc().isoformat()),
    )
    conn.commit()


def _gh_request(method: str, path: str, body: dict | None = None,
                extra_headers: dict | None = None,
                timeout: int = 15) -> tuple[int, dict | list | str, dict]:
    """Базовый HTTP вызов в GitHub API. Возвращает (status, parsed_body, response_headers).

    body=None для GET. body=dict для POST/PATCH/PUT (json.dumps).
    extra_headers для If-None-Match (conditional GET).
    Для 304 возвращает (304, {}, headers).
    Не raise на HTTPError — возвращает status и body для caller'а.
    """
    url = f"https://api.github.com{path}"
    headers = {
        "Authorization": f"Bearer {IWE_DISPATCHER_GITHUB_TOKEN}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": f"iwe-agent-dispatcher/{__version__}",
    }
    if extra_headers:
        headers.update(extra_headers)
    data = json.dumps(body).encode("utf-8") if body is not None else None
    if data is not None:
        headers["Content-Type"] = "application/json"

    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            status = resp.status
            raw = resp.read().decode("utf-8")
            resp_headers = dict(resp.headers)
            parsed: dict | list | str
            if raw:
                try:
                    parsed = json.loads(raw)
                except json.JSONDecodeError:
                    parsed = raw
            else:
                parsed = {}
            return status, parsed, resp_headers
    except urllib.error.HTTPError as he:
        status = he.code
        try:
            raw = he.read().decode("utf-8")
        except Exception:
            raw = ""
        resp_headers = dict(he.headers) if hasattr(he, "headers") and he.headers else {}
        if status == 304:
            return 304, {}, resp_headers
        try:
            parsed = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            parsed = raw
        return status, parsed, resp_headers


def _gh_list_sessions_dir(etag_conn: sqlite3.Connection) -> tuple[bool, list[dict]]:
    """List inbox/agent/sessions/ через Contents API c ETag conditional polling.

    Returns (changed, items). changed=False при 304 (нет новых файлов) — items пустой.
    changed=True при 200 — items = список dict {name, path, sha}.
    """
    sessions_path = "inbox/agent/sessions"
    cache_key = f"contents:{sessions_path}"
    etag = _gh_etag_get(etag_conn, cache_key)
    extra = {"If-None-Match": etag} if etag else {}

    status, parsed, resp_headers = _gh_request(
        "GET",
        f"/repos/{IWE_DISPATCHER_GITHUB_REPO}/contents/{sessions_path}"
        f"?ref={IWE_DISPATCHER_GITHUB_BRANCH}",
        extra_headers=extra,
    )
    if status == 304:
        return False, []
    if status == 404:
        log(f"sessions dir not found in {IWE_DISPATCHER_GITHUB_REPO} — empty", "INFO")
        return False, []
    if status != 200:
        log(f"_gh_list_sessions_dir failed: HTTP {status}", "WARN")
        return False, []

    new_etag = resp_headers.get("ETag") or resp_headers.get("etag")
    if new_etag:
        _gh_etag_set(etag_conn, cache_key, new_etag)
    return True, parsed if isinstance(parsed, list) else []


def _gh_get_file_content(path: str) -> tuple[str | None, str | None]:
    """GET content of a file via Contents API. Returns (text, blob_sha) or (None, None)."""
    import base64
    status, parsed, _ = _gh_request(
        "GET",
        f"/repos/{IWE_DISPATCHER_GITHUB_REPO}/contents/{path}?ref={IWE_DISPATCHER_GITHUB_BRANCH}",
    )
    if status != 200:
        log(f"GET {path}: HTTP {status}", "WARN")
        return None, None
    if not isinstance(parsed, dict):
        return None, None
    content_b64 = parsed.get("content", "").replace("\n", "")
    sha = parsed.get("sha")
    try:
        text = base64.b64decode(content_b64).decode("utf-8")
    except Exception as exc:
        log(f"Cannot decode {path}: {exc}", "WARN")
        return None, sha
    return text, sha


def _gh_get_ref_sha(branch: str) -> str | None:
    """Получить SHA HEAD ветки."""
    status, parsed, _ = _gh_request(
        "GET",
        f"/repos/{IWE_DISPATCHER_GITHUB_REPO}/git/ref/heads/{branch}",
    )
    if status != 200 or not isinstance(parsed, dict):
        return None
    obj = parsed.get("object") or {}
    return obj.get("sha")


def _gh_get_commit_tree(commit_sha: str) -> str | None:
    """Получить tree SHA коммита."""
    status, parsed, _ = _gh_request(
        "GET",
        f"/repos/{IWE_DISPATCHER_GITHUB_REPO}/git/commits/{commit_sha}",
    )
    if status != 200 or not isinstance(parsed, dict):
        return None
    tree = parsed.get("tree") or {}
    return tree.get("sha")


def _gh_atomic_commit(
    files: list[tuple[str, str]],
    commit_message: str,
    max_retries: int = 4,
) -> bool:
    """Atomic commit нескольких файлов через Git Data API (blob+tree+commit+ref).

    files: list of (repo_path, content_text).
    Retry-on-422: при non-fast-forward делает заново (re-fetch HEAD, новые blob/tree/commit/ref).

    Returns True on success, False on final failure.
    """
    for attempt in range(1, max_retries + 1):
        # 1. HEAD ref
        head_sha = _gh_get_ref_sha(IWE_DISPATCHER_GITHUB_BRANCH)
        if not head_sha:
            log(f"atomic_commit: cannot get HEAD ref (attempt {attempt})", "WARN")
            time.sleep(min(2 ** attempt, 8))
            continue

        # 2. Parent tree
        parent_tree_sha = _gh_get_commit_tree(head_sha)
        if not parent_tree_sha:
            log(f"atomic_commit: cannot get parent tree (attempt {attempt})", "WARN")
            time.sleep(min(2 ** attempt, 8))
            continue

        # 3. Blob per file
        tree_entries = []
        blob_ok = True
        for path, content in files:
            status, parsed, _ = _gh_request(
                "POST",
                f"/repos/{IWE_DISPATCHER_GITHUB_REPO}/git/blobs",
                body={"content": content, "encoding": "utf-8"},
            )
            if status != 201 or not isinstance(parsed, dict):
                log(f"atomic_commit: blob POST {path} failed: HTTP {status}", "WARN")
                blob_ok = False
                break
            tree_entries.append({
                "path": path,
                "mode": "100644",
                "type": "blob",
                "sha": parsed.get("sha"),
            })
        if not blob_ok:
            time.sleep(min(2 ** attempt, 8))
            continue

        # 4. Tree
        status, parsed, _ = _gh_request(
            "POST",
            f"/repos/{IWE_DISPATCHER_GITHUB_REPO}/git/trees",
            body={"base_tree": parent_tree_sha, "tree": tree_entries},
        )
        if status != 201 or not isinstance(parsed, dict):
            log(f"atomic_commit: tree POST failed: HTTP {status}", "WARN")
            time.sleep(min(2 ** attempt, 8))
            continue
        new_tree_sha = parsed.get("sha")

        # 5. Commit
        status, parsed, _ = _gh_request(
            "POST",
            f"/repos/{IWE_DISPATCHER_GITHUB_REPO}/git/commits",
            body={
                "message": commit_message,
                "tree": new_tree_sha,
                "parents": [head_sha],
                "author": {
                    "name": COMMIT_AUTHOR_NAME,
                    "email": COMMIT_AUTHOR_EMAIL,
                    "date": now_utc().strftime("%Y-%m-%dT%H:%M:%SZ"),
                },
            },
        )
        if status != 201 or not isinstance(parsed, dict):
            log(f"atomic_commit: commit POST failed: HTTP {status}", "WARN")
            time.sleep(min(2 ** attempt, 8))
            continue
        new_commit_sha = parsed.get("sha")

        # 6. Ref update — fast-forward only (force=false).
        # 422 non-fast-forward = другой writer commit'нулся между нашими шагами 1 и 6 — retry.
        status, parsed, _ = _gh_request(
            "PATCH",
            f"/repos/{IWE_DISPATCHER_GITHUB_REPO}/git/refs/heads/{IWE_DISPATCHER_GITHUB_BRANCH}",
            body={"sha": new_commit_sha, "force": False},
        )
        if status == 200:
            log(f"atomic_commit OK: {new_commit_sha[:8]} ({len(files)} files, attempt {attempt})")
            return True
        if status == 422:
            log(f"atomic_commit: non-fast-forward, retry (attempt {attempt}/{max_retries})", "INFO")
            time.sleep(min(2 ** attempt, 8))
            continue
        log(f"atomic_commit: ref PATCH failed: HTTP {status}", "WARN")
        time.sleep(min(2 ** attempt, 8))
    log(f"atomic_commit: all {max_retries} attempts failed", "ERROR")
    return False


def _pick_tg_token(target_bot: str | None) -> str:
    """Per-bot TG routing (backport tsekh, WP-358 Ф10.7).

    target_bot: 'pilot' | 'prod' | None.
    Возвращает первый non-empty: TG_BOT_TOKEN_<TARGET>, TELEGRAM_BOT_TOKEN.
    """
    if target_bot:
        env_key = f"TG_BOT_TOKEN_{target_bot.upper()}"
        tok = os.environ.get(env_key, "")
        if tok:
            return tok
    return TG_BOT_TOKEN


def _send_tg_with_routing(chat_id: int, text: str, target_bot: str | None) -> bool:
    """TG send с per-bot routing (backport tsekh)."""
    tok = _pick_tg_token(target_bot)
    if not tok:
        log(f"No TG token for target_bot={target_bot} — skip", "WARN")
        return False
    url = f"https://api.telegram.org/bot{tok}/sendMessage"
    payload = json.dumps({"chat_id": chat_id, "text": text}).encode()
    req = urllib.request.Request(url, data=payload,
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read()).get("ok", False)
    except Exception as exc:
        log(f"TG send error: {exc}", "ERROR")
        return False


def _detect_api_unavailable(stderr: str, stdout: str) -> tuple[bool, str | None]:
    """Backport tsekh: detect API unavailable (5xx, network), extract recovery hint.

    Returns (is_unavailable, recovery_message).
    """
    combined = (stderr or "") + "\n" + (stdout or "")
    unavail_patterns = re.compile(
        r"503|502|504|api\.anthropic\.com.*(unreachable|timeout|connection)|"
        r"network is unreachable|temporarily unavailable",
        re.IGNORECASE,
    )
    if unavail_patterns.search(combined):
        # Try extract recovery hint
        m = re.search(r"try again (in |after )?([^.]+)", combined, re.IGNORECASE)
        hint = m.group(0) if m else None
        return True, hint
    return False, None


def _write_system_reply(session_id: str, turn_n: int, reason: str,
                       message: str, recovery_hint: str | None = None) -> str:
    """Backport tsekh: формат системного ответа для 4xx/5xx (вместо Claude-ответа)."""
    parts = [f"⚠️ Сервис временно недоступен: {reason}"]
    if recovery_hint:
        parts.append(f"Попробуйте {recovery_hint}.")
    if message:
        parts.append(message)
    parts.append(f"(ход {turn_n}, session {session_id[:16]}...)")
    return "\n\n".join(parts)


def _check_dispatcher_version() -> None:
    """Self-check version: сравнить hash файла с HEAD-копией в репо.

    WARN при рассогласовании — снижает время обнаружения «забыли задеплоить».
    Non-blocking: ошибки сравнения не падают dispatcher.
    """
    try:
        local_path = os.path.abspath(__file__)
        with open(local_path, "rb") as fh:
            local_hash = hashlib.sha256(fh.read()).hexdigest()
        # Fetch from repo via Contents API
        text, _sha = _gh_get_file_content("scripts/iwe-agent-dispatcher.py")
        if text is None:
            return  # network or 404 — silent
        repo_hash = hashlib.sha256(text.encode("utf-8")).hexdigest()
        if local_hash != repo_hash:
            log(
                f"VERSION DRIFT: local sha256={local_hash[:12]} != repo sha256={repo_hash[:12]} "
                f"— deploy ahead of repo or repo ahead of deploy? "
                f"(version={__version__})",
                "WARN",
            )
        else:
            log(f"version OK: sha256={local_hash[:12]} (={__version__})", "DEBUG")
    except Exception as exc:
        log(f"version check skipped: {type(exc).__name__}", "DEBUG")


def _process_session_turn_api(
    session_id: str,
    fm: dict,
    turn_n: int,
    thread_text: str,
    db_conn: sqlite3.Connection,
    dry_run: bool,
) -> bool:
    """Process one session turn via GitHub API (Y.2, no local clone).

    Atomic write thread + meta через Git Data API.
    """
    tg_chat_id = fm.get("tg_chat_id")
    target_bot = fm.get("target_bot")  # pilot/prod from session meta
    log(f"=== Session {session_id} turn {turn_n} (API mode, target={target_bot}) ===")

    turns = _parse_thread(thread_text)

    if _is_turn_processed(db_conn, session_id, turn_n):
        log(f"Turn {turn_n} already processed — skip")
        return False

    # Order-based guard (backport): last turn must be `pilot`.
    if turns and turns[-1].get("role") != "pilot":
        log(f"Skip {session_id} turn {turn_n}: last turn role is not pilot", "INFO")
        return False

    # WP-428 Ф5: runtime chosen by the bot, carried in SESSION meta `executor`.
    executor_key = fm.get("executor") or DEFAULT_EXECUTOR
    executor_name = resolve_executor(executor_key).name  # actual runtime: prompt + audit role

    prompt = _build_session_prompt(session_id, tg_chat_id, turns, turn_n, executor_name)

    if dry_run:
        log(f"DRY-RUN: would process session turn {turn_n} "
            f"({len(prompt)} chars, executor={executor_name})")
        return False

    _heartbeat_ping(db_conn, session_id)

    started_at = now_utc()
    ok, output = invoke_claude_with_heartbeat(
        prompt, MODEL_DEFAULT, session_id=session_id, turn_n=turn_n, repo_dir=None,
        executor_key=executor_key,
    )
    finished_at = now_utc()
    log(f"agent done executor={executor_key} ok={ok} dur={(finished_at - started_at).total_seconds():.0f}s")

    # WP-428 Ф6: pilot issued /stop or /cancel — write tombstone in API mode too.
    if not ok and output == _STOPPED_BY_USER:
        return _handle_session_stop(
            repo_dir, session_id, executor_name, [],
            db_conn, tg_chat_id, turn_n)

    tg_msg, _transcript = _extract_tg_response(output)

    # API unavailable detection — wrap response with recovery hint.
    if not ok:
        unavail, hint = _detect_api_unavailable("", output)
        if unavail:
            tg_msg = _write_system_reply(session_id, turn_n, "Claude API",
                                          tg_msg, recovery_hint=hint)

    # Build new thread (append response) and new meta (update status, turn_count).
    response_n = max((t["n"] for t in turns), default=turn_n) + 1
    ts = now_utc().isoformat()
    new_thread = thread_text
    if not new_thread.endswith("\n"):
        new_thread += "\n"
    new_thread += f"\n[turn:{response_n}, role:{executor_name}, ts:{ts}]\n{tg_msg}\n"

    # Update meta frontmatter (simple replace via parsing)
    new_meta_fm = dict(fm)
    new_meta_fm["last_turn_at"] = finished_at.isoformat()
    new_meta_fm["turn_count"] = response_n
    new_meta_fm["status"] = "active" if ok else "failed"
    new_meta_text = _render_session_meta(new_meta_fm)

    thread_path_rel = f"inbox/agent/sessions/{session_id}-thread.md"
    meta_path_rel = f"inbox/agent/sessions/{session_id}.md"

    success = _gh_atomic_commit(
        files=[
            (thread_path_rel, new_thread),
            (meta_path_rel, new_meta_text),
        ],
        commit_message=f"session({session_id}): turn {turn_n}→{response_n}",
    )
    if not success:
        log(f"atomic_commit failed for {session_id} turn {turn_n}", "ERROR")
        return False

    _mark_turn_processed(db_conn, session_id, turn_n)
    _heartbeat_ping(db_conn, session_id)

    if tg_chat_id:
        sent = _send_tg_with_routing(int(tg_chat_id), tg_msg, target_bot)
        log(f"TG send {'ok' if sent else 'failed'} → chat {tg_chat_id} (bot={target_bot})")

    return True


def _render_session_meta(fm: dict) -> str:
    """Render session meta.md back from frontmatter dict.

    Простой serializer для plain key:value (без вложенных dict/list).
    """
    lines = ["---"]
    for k, v in fm.items():
        if v is None:
            lines.append(f"{k}: null")
        elif isinstance(v, bool):
            lines.append(f"{k}: {'true' if v else 'false'}")
        elif isinstance(v, (int, float)):
            lines.append(f"{k}: {v}")
        elif isinstance(v, str):
            if "\n" in v or ":" in v:
                lines.append(f'{k}: "{v}"')
            else:
                lines.append(f"{k}: {v}")
        else:
            lines.append(f"{k}: {json.dumps(v, ensure_ascii=False)}")
    lines.append("---")
    lines.append("")
    return "\n".join(lines)


def session_mode_main_api(dry_run: bool) -> None:
    """Y.2 session-mode: stateless через GitHub API. Без локального клона репо.

    WP-358 follow-up Ф3 (2026-05-30), peer-session 2026-05-30-36 consensus.
    """
    log(f"Session mode dispatcher starting (Y.2 API, version={__version__})")

    if not IWE_DISPATCHER_GITHUB_TOKEN:
        log("IWE_DISPATCHER_GITHUB_TOKEN not set — cannot run API mode", "ERROR")
        return

    etag_conn = _gh_etag_db()
    db_conn = _get_session_db()
    try:
        # 1. List sessions dir с ETag conditional polling.
        changed, items = _gh_list_sessions_dir(etag_conn)
        if not changed:
            log("Sessions dir not modified (304) — nothing to do")
            return

        # 2. Filter SESSION-*.md (skip -thread.md, validate id, status check).
        candidate_metas = []
        for item in items:
            if not isinstance(item, dict):
                continue
            name = item.get("name", "")
            if not name.startswith("SESSION-") or not name.endswith(".md"):
                continue
            if "-thread" in name:
                continue
            session_id = name[:-len(".md")]
            if not _SESSION_ID_RE.match(session_id):
                log(f"Skip session with invalid id: {session_id!r}", "WARN")
                continue
            candidate_metas.append((session_id, item.get("path", "")))

        log(f"Candidate sessions: {len(candidate_metas)}")

        # 3. For each — GET meta, check status, GET thread, find pending pilot turn.
        for session_id, meta_path in candidate_metas:
            try:
                meta_text, _meta_sha = _gh_get_file_content(meta_path)
                if meta_text is None:
                    continue
                fm, _ = parse_frontmatter_v2(meta_text)
                if fm.get("status") not in ("active", "pending"):
                    continue

                # Idle timeout check
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
                            # Atomic close: update status only.
                            new_fm = dict(fm)
                            new_fm["status"] = "completed"
                            new_meta_text = _render_session_meta(new_fm)
                            _gh_atomic_commit(
                                files=[(meta_path, new_meta_text)],
                                commit_message=f"session({session_id}): idle_timeout → completed",
                            )
                            continue
                    except Exception:
                        pass

                thread_path = f"inbox/agent/sessions/{session_id}-thread.md"
                thread_text, _thread_sha = _gh_get_file_content(thread_path)
                if thread_text is None:
                    log(f"Thread file missing for {session_id} — skip", "WARN")
                    continue
                turns = _parse_thread(thread_text)
                for turn in turns:
                    if (turn["role"] == "pilot"
                            and not _is_turn_processed(db_conn, session_id, turn["n"])):
                        _process_session_turn_api(
                            session_id=session_id,
                            fm=fm,
                            turn_n=turn["n"],
                            thread_text=thread_text,
                            db_conn=db_conn,
                            dry_run=dry_run,
                        )
                        break  # one turn at a time per session
            except Exception as exc:
                log(f"Error session {session_id}: {exc}", "ERROR")
                import traceback
                log(traceback.format_exc(), "ERROR")
    finally:
        db_conn.close()
        etag_conn.close()
    log("Session mode dispatcher (API) done")


if __name__ == "__main__":
    main()
