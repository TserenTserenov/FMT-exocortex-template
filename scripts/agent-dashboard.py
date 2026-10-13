#!/usr/bin/env python3
"""
Agent Dashboard — статус всех агентов IWE через Aisystant MCP.

Источник данных: `agent_status_list` MCP-инструмент (WP-398, API v2.0).
Аутентификация: OAuth-токен из ~/.hermes/mcp-tokens/aisystant.json или AISYSTANT_MCP_TOKEN.
Никаких хардкод-credentials — работает для любого пользователя IWE-шаблона.

Использование:
  agent-dashboard.py                        # личный дашборд
  agent-dashboard.py --repo org/repo-name  # командный дашборд по репо
  agent-dashboard.py --json                # сырой JSON (для скриптов)
  agent-dashboard.py --help                # справка

Формат API v2.0 (agent_status_list):
  {
    "version": "2.0",
    "mode": "personal" | "team",
    "repo": "org/repo-name" | null,
    "agents": [
      {
        "agent": "claude-code",
        "pilot": "<user_id>",        # только в командном режиме (UUID)
        "pilot_name": "<display>",   # только если getUserNames предоставлен
        "sessions": [
          { "session_id": "...", "status": "working|idle|...",
            "task": "...", "files": [...], "updated_at": "<ISO-8601>",
            "stale": false }
        ],
        "summary": { "working": N, "total": M }
      }
    ]
  }

Нормализация путей (normalize_file_path):
  Пути из поля `files` конвертируются в relpath от IWE_ROOT (~/IWE).
  POSIX-разделители (/) на всех платформах.
  Пути вне IWE_ROOT возвращаются нормализованными (не basename).
  IWE_ROOT берётся из IWE_DIR env или ~/IWE.

Stale-порог (STALE_THRESHOLD):
  900 секунд (15 мин) — агент считается устаревшим при status != idle.
  >15 мин — жёлтый [устарел], >2ч — красный [вероятно зависла].

Требования:
  - Python 3.9+
  - curl (для обновления токена)
  - OAuth-токен к Aisystant MCP (настраивается через `hermes setup` или вручную)
"""

import json
import os
import subprocess
import sys
import time
import urllib.request
import urllib.error
import ssl
from datetime import datetime, timezone
from typing import Dict, List, Optional, Tuple

# ── Константы ──────────────────────────────────────────────────────

MCP_URL = "https://mcp.aisystant.com/mcp"
TOKEN_URL = "https://mcp.aisystant.com/token"
CLIENT_ID = "gateway-mcp"
TOKEN_PATH = os.path.expanduser("~/.hermes/mcp-tokens/aisystant.json")
STALE_THRESHOLD = 15 * 60  # 15 минут — агент считается stale

STATUS_ICONS = {
    "idle": "💤",
    "working": "🔧",
    "peer-session": "🤝",
    "blocked": "🚫",
}

STATUS_NAMES = {
    "idle": "свободен",
    "working": "работает",
    "peer-session": "peer-сессия",
    "blocked": "заблокирован",
}

# ANSI-цвета (отключаются если stdout не tty)
COLOR_RESET = "\033[0m"
COLOR_BOLD = "\033[1m"
COLOR_DIM = "\033[2m"
COLOR_YELLOW = "\033[33m"
COLOR_RED = "\033[31m"
COLOR_GREEN = "\033[32m"
COLOR_CYAN = "\033[36m"


# ── Утилиты ─────────────────────────────────────────────────────────

def use_colors() -> bool:
    return sys.stdout.isatty()


def c(text: str, *codes: str) -> str:
    """Обернуть текст ANSI-кодами (если tty)."""
    if not use_colors():
        return text
    prefix = "".join(codes)
    return f"{prefix}{text}{COLOR_RESET}"


def ts_iso(ts: str) -> str:
    """ISO-8601 → человекочитаемое локальное время."""
    try:
        dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
        local = dt.astimezone()
        return local.strftime("%H:%M")
    except Exception:
        return ts


def ago(ts: str) -> str:
    """Сколько минут назад от now."""
    try:
        dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
        delta = (datetime.now(timezone.utc) - dt).total_seconds()
        if delta < 60:
            return "сейчас"
        mins = int(delta / 60)
        if mins < 60:
            return f"{mins}м назад"
        hrs = mins // 60
        return f"{hrs}ч {mins % 60}м назад"
    except Exception:
        return "?"


def is_stale(ts: str) -> bool:
    """Агент не обновлялся > STALE_THRESHOLD секунд."""
    try:
        dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
        return (datetime.now(timezone.utc) - dt).total_seconds() > STALE_THRESHOLD
    except Exception:
        return True


# ── Аутентификация ─────────────────────────────────────────────────

def load_token() -> Optional[str]:
    """Загрузить access_token. Приоритет: env → файл."""
    # 1. Явная переменная окружения (CI/скрипты)
    env_token = os.environ.get("AISYSTANT_MCP_TOKEN")
    if env_token:
        return env_token

    # 2. Файл токенов Hermes
    if os.path.isfile(TOKEN_PATH):
        try:
            with open(TOKEN_PATH, encoding="utf-8") as f:
                data = json.load(f)
            return data.get("access_token")
        except Exception:
            return None

    return None


def refresh_token() -> Optional[str]:
    """Попытаться обновить access_token через refresh_token (curl)."""
    if not os.path.isfile(TOKEN_PATH):
        return None

    try:
        with open(TOKEN_PATH, encoding="utf-8") as f:
            tokens = json.load(f)
    except Exception:
        return None

    refresh = tokens.get("refresh_token")
    if not refresh:
        return None

    # Cloudflare блокирует urllib на /token — используем curl
    result = subprocess.run(
        [
            "curl", "-fsS",
            "-X", "POST", TOKEN_URL,
            "-H", "Content-Type: application/x-www-form-urlencoded",
            "-H", "Accept: application/json",
            "-H", "User-Agent: Hermes-Agent/1.0",
            "-d", f"grant_type=refresh_token&refresh_token={refresh}&client_id={CLIENT_ID}",
        ],
        capture_output=True, text=True, timeout=15
    )

    if result.returncode != 0:
        return None

    try:
        new_tokens = json.loads(result.stdout)
        new_access = new_tokens.get("access_token")
        new_refresh = new_tokens.get("refresh_token")

        # Обновить файл токенов
        tokens["access_token"] = new_access
        if new_refresh:
            tokens["refresh_token"] = new_refresh
        with open(TOKEN_PATH, "w", encoding="utf-8") as f:
            json.dump(tokens, f)

        return new_access
    except Exception:
        return None


def get_token() -> str:
    """Получить валидный access_token. Райзит SystemExit если не удалось."""
    token: Optional[str] = load_token()
    if token:
        return token

    # Попробовать обновить
    token = refresh_token()
    if token:
        return token

    die(
        "Нет OAuth-токена для Aisystant MCP.\n\n"
        "Как получить:\n"
        "  1. Запусти `hermes setup` если используешь Hermes Agent\n"
        "  2. Или установи переменную окружения AISYSTANT_MCP_TOKEN\n"
        "     (токен можно получить через OAuth-поток mcp.aisystant.com)\n\n"
        f"Ожидаемый путь к файлу токенов: {TOKEN_PATH}"
    )


# ── MCP-вызов ───────────────────────────────────────────────────────

def call_mcp(method: str, params: dict, token: str) -> dict:
    """Вызвать MCP-инструмент через JSON-RPC."""
    body = json.dumps({
        "jsonrpc": "2.0",
        "id": 1,
        "method": method,
        "params": params,
    }).encode()

    req = urllib.request.Request(MCP_URL, data=body, headers={
        "Content-Type": "application/json",
        "Authorization": f"Bearer {token}",
        "Accept": "application/json, text/event-stream",
        "User-Agent": "Hermes-Agent/1.0",
    })

    ctx = ssl.create_default_context()
    with urllib.request.urlopen(req, context=ctx, timeout=15) as resp:
        return json.loads(resp.read())


def call_mcp_tool(token: str, tool_name: str, arguments: dict, _retry: bool = False) -> dict:
    """Вызвать MCP-инструмент и вернуть распарсенный JSON-ответ."""
    try:
        result = call_mcp("tools/call", {"name": tool_name, "arguments": arguments}, token)
        content = result.get("result", {}).get("content", [])
        if not content:
            die(f"MCP `{tool_name}`: пустой ответ (нет content)")
        text = content[0].get("text", "{}")
        return json.loads(text)
    except urllib.error.HTTPError as e:
        if e.code == 401 and not _retry:
            new_token = refresh_token()
            if new_token:
                return call_mcp_tool(new_token, tool_name, arguments, _retry=True)
            die("Токен истёк, обновить не удалось. Перезапусти `hermes setup`.")
        die(f"MCP-сервер вернул HTTP {e.code}: {e.reason}")
    except urllib.error.URLError as e:
        die(f"MCP-сервер недоступен: {e.reason}")
    except json.JSONDecodeError:
        die("MCP-сервер вернул некорректный JSON.")
    return {}


def get_dashboard_data(token: str, repo: Optional[str] = None) -> dict:
    """Получить v2-ответ agent_status_list. Возвращает весь объект {version, mode, agents}."""
    args_payload: Dict[str, str] = {}
    if repo:
        args_payload["repo"] = repo
    return call_mcp_tool(token, "agent_status_list", args_payload)


# ── Нормализация путей и конфликты ─────────────────────────────────

IWE_ROOT = os.path.normpath(os.path.expanduser(os.environ.get("IWE_DIR", "~/IWE")))


def normalize_file_path(p: str) -> str:
    """Нормализуй путь к relative от IWE_ROOT с POSIX-разделителями.

    Пути вне IWE_ROOT возвращаются как абсолютные нормализованные пути (не basename,
    не относительный ../../.. — он скрывает реальное расположение файла).
    """
    p = os.path.normpath(os.path.expanduser(p))
    try:
        rel = os.path.relpath(p, IWE_ROOT)
        # На Unix relpath всегда успешен, даже вне IWE_ROOT (даёт ../../../...)
        # Если путь выходит за пределы IWE_ROOT — возвращаем абсолютный путь
        if rel.startswith(".."):
            return p.replace(os.sep, "/")
        return rel.replace(os.sep, "/")
    except ValueError:
        # Разные диски (Windows) → вернуть нормализованный путь
        return p.replace(os.sep, "/")


# ── Отображение ────────────────────────────────────────────────────

def die(msg: str, code: int = 1):
    """Ошибка и выход."""
    print(f"{c('Ошибка', COLOR_RED)}: {msg}", file=sys.stderr)
    sys.exit(code)


def find_conflicts(agents: List[dict]) -> List[Tuple[str, List[dict]]]:
    """Найти файлы, которые одновременно держат 2+ активных сессии (нормализованный путь)."""
    file_sessions: Dict[str, List[dict]] = {}
    for group in agents:
        pilot = group.get("pilot_name") or group.get("pilot") or ""
        for sess in group.get("sessions", []):
            if sess.get("status") in ("working", "peer-session"):
                for f in sess.get("files") or []:
                    norm = normalize_file_path(f)
                    if norm not in file_sessions:
                        file_sessions[norm] = []
                    file_sessions[norm].append({
                        "agent": group.get("agent", "?"),
                        "session_id": sess.get("session_id", "?"),
                        "pilot": pilot,
                    })
    return [(f, ss) for f, ss in file_sessions.items() if len(ss) > 1]


def _render_session_line(sess: dict, indent: str = "      ", show_stale_2h: bool = True) -> None:
    """Вывести одну строку сессии."""
    sid = sess.get("session_id", "?")
    status = sess.get("status", "idle")
    task: str = sess.get("task") or ""
    files = sess.get("files") or []
    updated = sess.get("updated_at", "")

    icon = STATUS_ICONS.get(status, "❓")
    status_ru = STATUS_NAMES.get(status, status)

    mins_ago_val = 0
    try:
        dt = datetime.fromisoformat(updated.replace("Z", "+00:00"))
        mins_ago_val = int((datetime.now(timezone.utc) - dt).total_seconds() / 60)
    except Exception:
        pass

    stale_15 = mins_ago_val > 15 and status != "idle"
    stale_2h = mins_ago_val > 120 and status != "idle"

    if stale_2h and show_stale_2h:
        stale_label = c(f" [вероятно зависла: {ago(updated)}]", COLOR_RED)
    elif stale_15:
        stale_label = c(f" [устарел: {ago(updated)}]", COLOR_YELLOW)
    else:
        stale_label = ""

    task_short = (task[:60] + "…") if len(task) > 60 else task
    sid_short = sid[:20] if len(sid) > 20 else sid

    print(f"{indent}{icon} {c(sid_short, COLOR_DIM)}  {c(task_short, COLOR_BOLD)}{stale_label}")

    if files:
        files_str = ", ".join(normalize_file_path(f) for f in files[:3])
        if len(files) > 3:
            files_str += f" +{len(files)-3}"
        print(f"{indent}   {c(f'📄 {files_str}', COLOR_DIM)}")


def render_dashboard(agents: List[dict], repo: Optional[str] = None) -> None:
    """Показать дашборд агентов v2 (личный или командный)."""
    if not agents:
        print(c("Нет данных об агентах. Возможно, ни один агент ещё не отчитывался.", COLOR_DIM))
        return

    now = datetime.now().strftime("%H:%M")
    print()
    if repo:
        print(c("═══ Команда ", COLOR_BOLD) + c(f"{repo} [{now}]", COLOR_DIM))
    else:
        print(c("═══ Агенты IWE ", COLOR_BOLD) + c(f"[{now}]", COLOR_DIM))
    print()

    for group in agents:
        name = group.get("agent", "?")
        pilot_name = group.get("pilot_name") or group.get("pilot") or ""
        sessions = group.get("sessions") or []
        summary = group.get("summary") or {}
        working = summary.get("working", 0)
        total = summary.get("total", 0)

        # Заголовок группы
        pilot_str = f"  / {c(pilot_name, COLOR_CYAN)}" if pilot_name else ""
        summary_str = c(f"— {working} работает, {total - working} свободно ({total} сессий)", COLOR_DIM)
        print(f"  {c(name, COLOR_BOLD, COLOR_CYAN)}{pilot_str}  {summary_str}")

        for sess in sessions:
            _render_session_line(sess)

        print()

    # Блок конфликтов (только в командном режиме или если есть)
    conflicts = find_conflicts(agents)
    if conflicts:
        print(c("─" * 50, COLOR_DIM))
        print(c("  ⚠️  Конфликты файлов:", COLOR_YELLOW + COLOR_BOLD))
        for fpath, owners in conflicts:
            owners_str = ", ".join(
                f"{o['agent']}/{o['pilot']}" if o['pilot'] else o['agent']
                for o in owners
            )
            print(f"     {c(fpath, COLOR_BOLD)}  ←  {owners_str}")
        print()

    print(c("─" * 50, COLOR_DIM))
    print(c("  💤 свободен   🔧 работает   🤝 peer-сессия   🚫 заблокирован", COLOR_DIM))
    print(c("  Жёлтый [устарел] >15 мин.   Красный [вероятно зависла] >2ч", COLOR_DIM))
    print()


def render_json(data: dict) -> None:
    """Вывести сырой JSON."""
    print(json.dumps(data, indent=2, ensure_ascii=False))


# ── main ────────────────────────────────────────────────────────────

def main() -> None:
    if "--help" in sys.argv or "-h" in sys.argv:
        print(__doc__)
        sys.exit(0)

    json_mode = "--json" in sys.argv

    repo: Optional[str] = None
    if "--repo" in sys.argv:
        idx = sys.argv.index("--repo")
        if idx + 1 < len(sys.argv):
            repo = sys.argv[idx + 1]
        else:
            die("--repo требует аргумент: --repo org/repo-name")

    token = get_token()
    data = get_dashboard_data(token, repo=repo)
    agents = data.get("agents", [])

    if json_mode:
        render_json(data)
    else:
        render_dashboard(agents, repo=repo)


if __name__ == "__main__":
    main()
