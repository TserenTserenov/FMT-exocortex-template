#!/usr/bin/env python3
"""session-dispatcher-tsekh.py — stateless session dispatcher for цех-1 (WP-358 Ф8).

Polls GitHub API for pending /claude sessions. No git clone, no local repo.
Runs claude CLI headless via ANTHROPIC_API_KEY.

Usage (called by systemd timer every 30s):
    python3 session-dispatcher-tsekh.py [--dry-run]
"""
import base64
import datetime as dt
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

from iwe_agent_backend import invoke as invoke_agent

# ---------------------------------------------------------------------------
# Config from environment
# ---------------------------------------------------------------------------
GITHUB_PAT     = os.environ.get("GITHUB_SESSION_PAT", "")
GITHUB_REPO    = os.environ.get("GITHUB_SESSION_REPO", "${GITHUB_OWNER:-owner}/${IWE_GOVERNANCE_REPO:-DS-strategy}")
# WP-358 Ф10.7: per-bot routing. Dispatcher выбирает токен на основе target_bot из meta.
# TG_BOT_TOKEN_PROD — токен @aist_me_bot (по умолчанию)
# TG_BOT_TOKEN_PILOT — токен @aist_pilot_bot
# TG_BOT_TOKEN — fallback для обратной совместимости (читается если PROD не задан)
TG_BOT_TOKEN_PROD  = os.environ.get("TG_BOT_TOKEN_PROD", "") or os.environ.get("TG_BOT_TOKEN", "")
TG_BOT_TOKEN_PILOT = os.environ.get("TG_BOT_TOKEN_PILOT", "")
TG_BOT_TOKEN       = TG_BOT_TOKEN_PROD  # legacy alias для send_tg() без target_bot
# C-β (peer-session 2026-05-28-08): separate API key for session dispatcher,
# fallback to ANTHROPIC_API_KEY если не задан. Цель — изолировать spend cap
# session dispatcher от marathon-генератора. Workspace настраивается в Anthropic
# Console; ключ в ~/.iwe/session-dispatcher.env. См. docs/operations.md.
ANTHROPIC_KEY  = os.environ.get("ANTHROPIC_API_KEY_SESSION") or os.environ.get("ANTHROPIC_API_KEY", "")
SESSIONS_PATH  = "inbox/agent/sessions"
GOV_BRANCH     = os.environ.get("GITHUB_SESSION_BRANCH", "main")
CLAUDE_BIN     = os.path.expanduser("~/.local/bin/claude-iwe")
SESSION_ID_RE  = re.compile(r"^SESSION-\d{8}-\d{6}-[a-f0-9]{6}$")

DRY_RUN = "--dry-run" in sys.argv


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
def log(msg: str, level: str = "INFO") -> None:
    ts = dt.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
    print(f"[{ts}] [{level}] {msg}", flush=True)


# ---------------------------------------------------------------------------
# GitHub API helpers
# ---------------------------------------------------------------------------
def _gh_headers() -> dict:
    return {
        "Authorization": f"Bearer {GITHUB_PAT}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    }


def _gh_get(path: str) -> dict | list | None:
    url = f"https://api.github.com/repos/{GITHUB_REPO}/contents/{path}?ref={GOV_BRANCH}"
    req = urllib.request.Request(url, headers=_gh_headers())
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise


def _gh_get_content(path: str) -> tuple[str, str] | tuple[None, None]:
    """Returns (decoded_text, sha) or (None, None) if not found."""
    data = _gh_get(path)
    if data is None or isinstance(data, list):
        return None, None
    content = base64.b64decode(data["content"]).decode("utf-8")
    return content, data["sha"]


def _gh_put(path: str, content: str, message: str, sha: str | None = None) -> bool:
    url = f"https://api.github.com/repos/{GITHUB_REPO}/contents/{path}"
    payload = {
        "message": message,
        "content": base64.b64encode(content.encode("utf-8")).decode("ascii"),
        "branch": GOV_BRANCH,
    }
    if sha:
        payload["sha"] = sha
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=_gh_headers(), method="PUT")
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status in (200, 201)
    except urllib.error.HTTPError as e:
        if e.code == 422:
            # SHA conflict — retry with fresh SHA
            _, fresh_sha = _gh_get_content(path)
            if fresh_sha is None:
                log(f"PUT {path} → 422 but file not found, cannot retry", "ERROR")
                return False
            payload["sha"] = fresh_sha
            data = json.dumps(payload).encode("utf-8")
            req2 = urllib.request.Request(url, data=data, headers=_gh_headers(), method="PUT")
            try:
                with urllib.request.urlopen(req2, timeout=15) as r2:
                    return r2.status in (200, 201)
            except urllib.error.HTTPError:
                return False
        raise


MAX_LOCK_TTL_SEC = 600  # stale lock threshold: 10 minutes


def _gh_create_file(path: str, content: str, message: str) -> bool:
    """Create file; returns False if file exists and lock is fresh (TTL not expired).
    If existing lock is stale (> MAX_LOCK_TTL_SEC), deletes it and retries once.
    """
    url = f"https://api.github.com/repos/{GITHUB_REPO}/contents/{path}"
    payload = {
        "message": message,
        "content": base64.b64encode(content.encode("utf-8")).decode("ascii"),
        "branch": GOV_BRANCH,
    }
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=_gh_headers(), method="PUT")
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status == 201
    except urllib.error.HTTPError as e:
        if e.code == 422:
            # Check if existing lock is stale
            lock_text, _ = _gh_get_content(path)
            if lock_text:
                try:
                    lock_ts = dt.datetime.fromisoformat(lock_text.strip().rstrip("Z"))
                    age = (dt.datetime.utcnow() - lock_ts).total_seconds()
                    if age > MAX_LOCK_TTL_SEC:
                        log(f"Stale lock at {path} (age={age:.0f}s) — removing", "WARN")
                        _gh_delete(path, f"remove stale lock: {path}")
                        # Retry create once
                        data2 = json.dumps(payload).encode("utf-8")
                        req2 = urllib.request.Request(url, data=data2,
                                                      headers=_gh_headers(), method="PUT")
                        try:
                            with urllib.request.urlopen(req2, timeout=15) as r2:
                                return r2.status == 201
                        except urllib.error.HTTPError:
                            return False
                except (ValueError, TypeError):
                    pass
            return False  # fresh lock held by another dispatcher
        raise


def _gh_delete(path: str, message: str) -> None:
    _, sha = _gh_get_content(path)
    if sha is None:
        return
    url = f"https://api.github.com/repos/{GITHUB_REPO}/contents/{path}"
    payload = {"message": message, "sha": sha, "branch": GOV_BRANCH}
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=_gh_headers(), method="DELETE")
    try:
        with urllib.request.urlopen(req, timeout=15):
            pass
    except urllib.error.HTTPError as e:
        log(f"DELETE {path} failed: {e.code}", "WARN")


# ---------------------------------------------------------------------------
# Frontmatter parsing
# ---------------------------------------------------------------------------
def parse_frontmatter(text: str) -> dict:
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return {}
    fm: dict = {}
    for line in lines[1:]:
        if line.strip() == "---":
            break
        if ":" in line:
            k, _, v = line.partition(":")
            fm[k.strip()] = v.strip().strip('"')
    return fm


def _yaml_value(v: str) -> str:
    """WP-358 P3: unified meta format с bot — без кавычек для простых значений.

    Кавычки только если строка содержит специальные YAML-символы (`:#`),
    чтобы не сломать парсинг. Это синхронизирует format с bot._meta_content,
    закрывает архитектурный долг расхождения форматов между диспетчерами.
    """
    s = str(v)
    return f'"{s}"' if re.search(r"[:#]", s) else s


def update_frontmatter(text: str, updates: dict) -> str:
    lines = text.splitlines(keepends=True)
    if not lines or lines[0].strip() != "---":
        return text
    new_lines = [lines[0]]
    end_idx = 1
    for i, line in enumerate(lines[1:], 1):
        if line.strip() == "---":
            end_idx = i
            break
        key = line.partition(":")[0].strip()
        if key in updates:
            new_lines.append(f'{key}: {_yaml_value(updates[key])}\n')
        else:
            new_lines.append(line)
    # Append keys not already in frontmatter
    existing_keys = {l.partition(":")[0].strip() for l in new_lines[1:]}
    for k, v in updates.items():
        if k not in existing_keys:
            new_lines.append(f'{k}: {_yaml_value(v)}\n')
    new_lines.append(lines[end_idx])
    new_lines.extend(lines[end_idx + 1:])
    return "".join(new_lines)


# ---------------------------------------------------------------------------
# Thread parsing
# ---------------------------------------------------------------------------
def parse_thread(text: str) -> list[dict]:
    turns = []
    for m in re.finditer(
        r"\[turn:(\d+), role:(\w+)(?:, [^\]]+)?\]\n(.*?)(?=\[turn:|\Z)",
        text, re.DOTALL
    ):
        turns.append({
            "n": int(m.group(1)),
            "role": m.group(2),
            "text": m.group(3).strip(),
        })
    return turns


# ---------------------------------------------------------------------------
# Telegram
# ---------------------------------------------------------------------------
def _pick_tg_token(target_bot: str) -> str:
    """WP-358 Ф10.7: выбор токена на основе target_bot из meta SESSION-файла.

    target_bot = "pilot" → TG_BOT_TOKEN_PILOT (fallback на PROD если не задан)
    target_bot = "prod"  → TG_BOT_TOKEN_PROD
    target_bot отсутствует / неизвестный → TG_BOT_TOKEN_PROD (backwards compat).
    """
    flavor = (target_bot or "prod").strip().lower()
    if flavor == "pilot" and TG_BOT_TOKEN_PILOT:
        return TG_BOT_TOKEN_PILOT
    return TG_BOT_TOKEN_PROD


def send_tg(chat_id: int, text: str, target_bot: str = "") -> bool:
    """Отправка TG-сообщения через токен, выбранный по target_bot (WP-358 Ф10.7).

    target_bot="" → legacy путь через TG_BOT_TOKEN (= TG_BOT_TOKEN_PROD).
    """
    token = _pick_tg_token(target_bot)
    if not token:
        log(f"TG token not set (target_bot={target_bot!r}) — skip", "WARN")
        return False
    url = f"https://api.telegram.org/bot{token}/sendMessage"
    payload = json.dumps({"chat_id": chat_id, "text": text}).encode("utf-8")
    req = urllib.request.Request(url, data=payload,
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.loads(r.read()).get("ok", False)
    except Exception as exc:
        log(f"TG send error (target_bot={target_bot!r}): {exc}", "ERROR")
        return False


# ---------------------------------------------------------------------------
# Claude invocation
# ---------------------------------------------------------------------------
def build_prompt(session_id: str, tg_chat_id: str, turns: list[dict],
                 turn_n: int) -> str:
    thread_text = "\n".join(
        f"[turn:{t['n']}, role:{t['role']}]\n{t['text']}" for t in turns
    )
    latest = next((t for t in turns if t["n"] == turn_n), turns[-1])
    return f"""Ты — Claude Code в External Working Session (DP.SC.162).
Пилот работает удалённо через Telegram. session_id={session_id}, tg_chat_id={tg_chat_id}.

## История диалога

{thread_text}

## Текущий ход

Ход {turn_n} (пилот): «{latest['text']}»

## Инструкции

1. Выполни работу согласно запросу пилота.
2. Capability scope: анализ, код, git, knowledge_search.
3. Отвечай кратко (Telegram ≤800 символов если возможно).
4. После завершения выведи финальный ответ СТРОГО между делимитерами:

===TELEGRAM_RESPONSE_START===
<текст ответа для Telegram>
===TELEGRAM_RESPONSE_END===
"""


def invoke_claude(prompt: str) -> tuple[bool, str]:
    provider = os.environ.get("IWE_AGENT_PROVIDER", "claude").lower()
    if provider == "claude" and not os.path.exists(CLAUDE_BIN):
        log(f"claude not found at {CLAUDE_BIN}", "ERROR")
        return False, ""
    env = os.environ.copy()
    # C-β (peer-session 2026-05-28-08): override ANTHROPIC_API_KEY с session-specific
    # ключом если задан. Изолирует spend cap session dispatcher от marathon-генератора.
    # Если ANTHROPIC_API_KEY_SESSION не задан — fallback к ANTHROPIC_API_KEY (статус-кво).
    if os.environ.get("ANTHROPIC_API_KEY_SESSION"):
        env["ANTHROPIC_API_KEY"] = os.environ["ANTHROPIC_API_KEY_SESSION"]
    # Ensure HOME is set (systemd user units may strip it)
    if "HOME" not in env:
        import pwd
        env["HOME"] = pwd.getpwuid(os.getuid()).pw_dir
    # Ensure ~/.local/bin is in PATH (needed on NixOS where systemd has minimal PATH)
    local_bin = os.path.expanduser("~/.local/bin")
    env["PATH"] = local_bin + ":" + env.get("PATH", "/usr/local/bin:/usr/bin:/bin")
    old_bin = os.environ.get("IWE_CLAUDE_BIN")
    old_key = os.environ.get("ANTHROPIC_API_KEY")
    os.environ["IWE_CLAUDE_BIN"] = CLAUDE_BIN
    if env.get("ANTHROPIC_API_KEY"):
        os.environ["ANTHROPIC_API_KEY"] = env["ANTHROPIC_API_KEY"]
    try:
        return invoke_agent(prompt, os.environ.get("IWE_SESSION_MODEL", "medium"),
                            cwd=Path(os.environ.get("IWE_WORKSPACE", os.getcwd())),
                            timeout=270, provider=provider)
    finally:
        if old_bin is None:
            os.environ.pop("IWE_CLAUDE_BIN", None)
        else:
            os.environ["IWE_CLAUDE_BIN"] = old_bin
        if old_key is None:
            os.environ.pop("ANTHROPIC_API_KEY", None)
        else:
            os.environ["ANTHROPIC_API_KEY"] = old_key


def extract_tg_response(output: str) -> str:
    start = "===TELEGRAM_RESPONSE_START==="
    end = "===TELEGRAM_RESPONSE_END==="
    si = output.find(start)
    ei = output.find(end)
    if si >= 0 and ei > si:
        return output[si + len(start):ei].strip()
    return output.strip()[:800]


# ---------------------------------------------------------------------------
# API unavailability detection and system reply (Fix 3, peer-session 2026-05-28-05)
# ---------------------------------------------------------------------------
# Regex для парсинга даты+времени восстановления из «regain access on 2026-06-01 at 00:00 UTC»
# Принимает «at HH:MM», «THH:MM», « HH:MM» — все вариации форматов Anthropic
_API_ERROR_DATE_RE = re.compile(
    r"API Error:\s*(\d{3}).{0,500}?(?:regain access on|reset at|available again at|until)"
    r"\s+(\d{4}-\d{2}-\d{2})"
    r"(?:(?:\s+at\s+|[T ])(\d{2}:\d{2}(?::\d{2})?))?"
    r"(?:\s*Z|\s*UTC|\s*GMT)?",
    re.IGNORECASE | re.DOTALL,
)
_API_ERROR_429_RE = re.compile(r"API Error:\s*(429)\b", re.IGNORECASE)
_API_ERROR_4XX_RE = re.compile(r"API Error:\s*(4\d{2})\b", re.IGNORECASE)


def _detect_api_unavailable(output: str) -> str:
    """Return ISO timestamp for api_unavailable_until if Anthropic returned 4xx; else ''."""
    if not output or "API Error" not in output:
        return ""
    # Match explicit «regain access on DATE [at TIME] [UTC]»
    m = _API_ERROR_DATE_RE.search(output)
    if m:
        date_str = m.group(2)
        time_str = m.group(3) or "00:00:00"
        # Pad seconds if только HH:MM
        if time_str.count(":") == 1:
            time_str += ":00"
        return f"{date_str}T{time_str}Z"
    # Rate limit (429) → block for 10 minutes
    if _API_ERROR_429_RE.search(output):
        until = dt.datetime.now(dt.timezone.utc) + dt.timedelta(minutes=10)
        return until.replace(microsecond=0).isoformat().replace("+00:00", "Z")
    # Other 4xx без explicit time → block for 60 minutes
    if _API_ERROR_4XX_RE.search(output):
        until = dt.datetime.now(dt.timezone.utc) + dt.timedelta(hours=1)
        return until.replace(microsecond=0).isoformat().replace("+00:00", "Z")
    return ""


def _write_system_reply(
    session_id: str, thread_path: str, meta_path: str, meta_text: str,
    turn_n: int, text: str, tg_chat_id_str: str,
    extra_meta: dict | None = None,
) -> bool:
    """Write a system-source claude reply (Fix 3). Returns True on full success.

    extra_meta: дополнительные frontmatter поля (например, api_unavailable_until)
    которые надо записать одним PUT вместе с финальным meta-update.
    Гарантирует atomicity между thread-write и meta-write: если thread не записан,
    meta тоже не трогаем; если meta не записан после успешного thread, логируем,
    но возвращаем False — следующий poll корректно увидит несовместимое
    состояние (turn в thread, статус не api_unavailable) и потенциально может
    исправить. Без TG send при любой неудаче (избегаем «обещание без записи»).
    """
    # Без timestamp с микросекундами для консистентности с bot _now_iso()
    ts = dt.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
    response_n = turn_n + 1
    # Append claude turn with source:system marker
    thread_now, thread_sha = _gh_get_content(thread_path)
    new_entry = (
        f"\n[turn:{response_n}, role:claude, source:system, ts:{ts}]\n{text}\n"
    )
    new_thread = (thread_now or "") + new_entry
    thread_ok = _gh_put(thread_path, new_thread,
                        f"session({session_id}): system reply turn {response_n}",
                        thread_sha)
    if not thread_ok:
        log(f"{session_id}: failed to write system reply thread — skip meta+TG", "ERROR")
        return False

    # Update meta — один PUT для всех полей (api_unavailable_until + status + ...)
    meta_now, meta_sha_now = _gh_get_content(meta_path)
    meta_updates = {
        "status": "api_unavailable",
        "last_turn_at": ts,
        "turn_count": str(response_n),
    }
    if extra_meta:
        meta_updates.update(extra_meta)
    patched_meta = update_frontmatter(meta_now or meta_text, meta_updates)
    meta_ok = _gh_put(meta_path, patched_meta,
                      f"session({session_id}): api_unavailable",
                      meta_sha_now)
    if not meta_ok:
        log(f"{session_id}: thread written but meta update failed — incomplete state", "ERROR")
        return False

    # Notify TG только после успешной записи обоих файлов
    try:
        chat_id_int = int(tg_chat_id_str) if tg_chat_id_str else None
    except (ValueError, TypeError):
        chat_id_int = None
    if chat_id_int:
        # WP-358 Ф10.7: target_bot из meta — выбор токена per-bot
        target_bot = parse_frontmatter(meta_now or meta_text).get("target_bot", "")
        sent = send_tg(chat_id_int, text, target_bot=target_bot)
        log(f"{session_id}: system TG send {'ok' if sent else 'FAILED'} → {chat_id_int} (target_bot={target_bot!r})")
    return True


# ---------------------------------------------------------------------------
# Session processor
# ---------------------------------------------------------------------------
def process_session(session_id: str) -> bool:
    meta_path = f"{SESSIONS_PATH}/{session_id}.md"
    thread_path = f"{SESSIONS_PATH}/{session_id}-thread.md"
    lock_path = f"{SESSIONS_PATH}/LOCK-{session_id}"

    meta_text, meta_sha = _gh_get_content(meta_path)
    if meta_text is None:
        log(f"{session_id}: meta not found", "WARN")
        return False
    fm = parse_frontmatter(meta_text)

    status = fm.get("status", "")
    if status not in ("pending", "active"):
        return False

    # Acquire lock — protects against concurrent dispatchers (Mac launchd + цех systemd)
    # Store ISO timestamp so stale-lock detection can check age
    lock_ts = dt.datetime.utcnow().isoformat()
    locked = _gh_create_file(lock_path, lock_ts, f"lock: {session_id}")
    if not locked:
        log(f"{session_id}: lock held by another dispatcher — skip")
        return False

    try:
        original_status = status

        def _revert_status() -> None:
            """Revert session status back to original on early bail-out."""
            try:
                txt, sha = _gh_get_content(meta_path)
                if txt:
                    reverted = update_frontmatter(txt, {"status": original_status})
                    _gh_put(meta_path, reverted, f"session({session_id}): revert to {original_status}", sha)
            except Exception as exc:
                log(f"{session_id}: failed to revert status: {exc}", "WARN")

        # Mark as processing immediately
        updated_meta = update_frontmatter(meta_text, {"status": "processing"})
        _, current_sha = _gh_get_content(meta_path)
        _gh_put(meta_path, updated_meta, f"session({session_id}): processing", current_sha)

        # Load thread
        thread_text, _ = _gh_get_content(thread_path)
        if thread_text is None:
            log(f"{session_id}: thread not found", "WARN")
            _revert_status()
            return False
        turns = parse_thread(thread_text)
        if not turns:
            log(f"{session_id}: empty thread", "WARN")
            _revert_status()
            return False

        # Order-based guard (peer-session 2026-05-28-05): skip if last turn
        # in file is NOT pilot. Bot и dispatcher по-разному считали turn-номера
        # (bot += 1 на пилот-ход, dispatcher claude = pilot_turn+1) → коллизия
        # `pilot turn 2` vs `claude turn 2` → silent skip 27 мая.
        # Edge case: несколько pilot-ходов подряд (пилот шлёт 2 сообщения до
        # обработки) → обрабатывается только последний. Это сознательный
        # компромисс — иначе queue explosion + stale ответы.
        # Fake claude reply от Fix 3 имеет role:claude → корректно skipped.
        if turns[-1]["role"] != "pilot":
            log(f"{session_id}: last turn is {turns[-1]['role']}, not pilot — skip")
            _revert_status()
            return False

        latest_pilot = turns[-1]
        turn_n = latest_pilot["n"]

        # Fix 3: if API is unavailable, write a system reply without invoking Claude
        api_unavail_until = fm.get("api_unavailable_until", "")
        if api_unavail_until:
            try:
                until_dt = dt.datetime.fromisoformat(api_unavail_until.replace("Z", "+00:00"))
                now_dt = dt.datetime.now(dt.timezone.utc)
                if until_dt > now_dt:
                    _write_system_reply(
                        session_id, thread_path, meta_path, meta_text, turn_n,
                        f"ИИ-ассистент временно недоступен (лимит API). "
                        f"Восстановление: {api_unavail_until}. Сообщение сохранено, "
                        f"вернусь к нему после восстановления.",
                        fm.get("tg_chat_id", ""),
                    )
                    return True
            except (ValueError, TypeError) as exc:
                log(f"{session_id}: failed to parse api_unavailable_until={api_unavail_until!r}: {exc}", "WARN")

        tg_chat_id = fm.get("tg_chat_id", "")
        prompt = build_prompt(session_id, tg_chat_id, turns, turn_n)

        if DRY_RUN:
            log(f"DRY-RUN: would process {session_id} turn {turn_n} ({len(prompt)} chars)")
            return False

        log(f"{session_id}: invoking claude for turn {turn_n}...")
        started = dt.datetime.utcnow()
        ok, output = invoke_claude(prompt)
        elapsed = (dt.datetime.utcnow() - started).total_seconds()
        log(f"{session_id}: claude done ok={ok} elapsed={elapsed:.0f}s")

        tg_msg = extract_tg_response(output)

        # Fix 3: detect Anthropic API 4xx → record api_unavailable_until in system reply (single PUT)
        api_until = _detect_api_unavailable(output)
        if api_until:
            log(f"{session_id}: API unavailable detected — until={api_until}")
            _write_system_reply(
                session_id, thread_path, meta_path, meta_text, turn_n,
                f"ИИ-ассистент временно недоступен (лимит API). "
                f"Восстановление: {api_until}. Сообщение сохранено, "
                f"вернусь к нему после восстановления.",
                fm.get("tg_chat_id", ""),
                extra_meta={"api_unavailable_until": api_until},
            )
            return True

        response_n = turn_n + 1
        # Без микросекунд для консистентности с bot _now_iso() (peer-session 2026-05-28-05 review)
        ts = dt.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")

        # Append claude turn to thread
        thread_text_now, thread_sha = _gh_get_content(thread_path)
        new_entry = f"\n[turn:{response_n}, role:claude, ts:{ts}]\n{tg_msg}\n"
        new_thread = (thread_text_now or "") + new_entry
        _gh_put(thread_path, new_thread, f"session({session_id}): turn {response_n}",
                thread_sha)

        # Update meta: completed
        meta_now, meta_sha_now = _gh_get_content(meta_path)
        final_meta = update_frontmatter(meta_now or meta_text, {
            "status": "completed",
            "last_turn_at": ts,
            "turn_count": str(response_n),
        })
        _gh_put(meta_path, final_meta, f"session({session_id}): completed",
                meta_sha_now)

        # Notify via Telegram (WP-358 Ф10.7: per-bot routing через target_bot из meta)
        try:
            tg_chat_id_int = int(tg_chat_id) if tg_chat_id else None
        except (ValueError, TypeError):
            tg_chat_id_int = None
        if tg_chat_id_int:
            target_bot = fm.get("target_bot", "")
            sent = send_tg(tg_chat_id_int, tg_msg, target_bot=target_bot)
            log(f"{session_id}: TG send {'ok' if sent else 'FAILED'} → {tg_chat_id_int} (target_bot={target_bot!r})")

        return True

    finally:
        _gh_delete(lock_path, f"unlock: {session_id}")


# ---------------------------------------------------------------------------
# Main scan loop
# ---------------------------------------------------------------------------
def main() -> None:
    if not GITHUB_PAT:
        log("GITHUB_SESSION_PAT not set", "ERROR")
        sys.exit(1)
    if not ANTHROPIC_KEY and not DRY_RUN:
        log("ANTHROPIC_API_KEY not set", "ERROR")
        sys.exit(1)

    log(f"Starting dispatcher (repo={GITHUB_REPO} branch={GOV_BRANCH} dry_run={DRY_RUN})")

    sessions_listing = _gh_get(SESSIONS_PATH)
    if not isinstance(sessions_listing, list):
        log("Cannot list sessions directory", "WARN")
        return

    session_ids = []
    for f in sessions_listing:
        name = f.get("name", "")
        if name.endswith(".md") and not name.endswith("-thread.md"):
            sid = name[:-3]
            if SESSION_ID_RE.match(sid):
                session_ids.append(sid)

    if not session_ids:
        log("No sessions found")
        return

    log(f"Found {len(session_ids)} session(s)")
    processed = 0
    for sid in sorted(session_ids):
        try:
            if process_session(sid):
                processed += 1
        except Exception as exc:
            log(f"{sid}: error — {exc}", "ERROR")

    log(f"Done. Processed {processed}/{len(session_ids)} session(s)")


if __name__ == "__main__":
    main()
