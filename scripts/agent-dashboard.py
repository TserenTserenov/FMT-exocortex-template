#!/usr/bin/env python3
"""
Agent Dashboard — статус всех агентов IWE через Aisystant MCP.

Источник данных: `agent_status_list` MCP-инструмент (платформенный реестр РП-395).
Аутентификация: OAuth-токен из ~/.hermes/mcp-tokens/aisystant.json или AISYSTANT_MCP_TOKEN.
Никаких хардкод-credentials — работает для любого пользователя IWE-шаблона.

Использование:
  agent-dashboard.py              # показать дашборд
  agent-dashboard.py --json       # сырой JSON (для скриптов)
  agent-dashboard.py --help       # справка

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
from typing import Optional, List, Dict

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
            with open(TOKEN_PATH) as f:
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
        with open(TOKEN_PATH) as f:
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
        with open(TOKEN_PATH, "w") as f:
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


def get_agents(token: str, _retry: bool = False) -> list[dict]:
    """Получить список агентов через agent_status_list."""
    try:
        result = call_mcp(
            "tools/call",
            {"name": "agent_status_list", "arguments": {}},
            token
        )
        # MCP-ответ: result.content[0].text = JSON-строка
        content = result.get("result", {}).get("content", [])
        if not content:
            die("MCP `agent_status_list`: пустой ответ (нет content)")
        text = content[0].get("text", "{}")
        data = json.loads(text)
        return data.get("agents", [])
    except urllib.error.HTTPError as e:
        if e.code == 401 and not _retry:
            # Токен протух — пробуем обновить и повторить (максимум 1 раз)
            new_token = refresh_token()
            if new_token:
                return get_agents(new_token, _retry=True)
            die("Токен истёк, обновить не удалось. Перезапусти `hermes setup`.")
        die(f"MCP-сервер вернул HTTP {e.code}: {e.reason}")
    except urllib.error.URLError as e:
        die(f"MCP-сервер недоступен: {e.reason}")
    except json.JSONDecodeError:
        die("MCP-сервер вернул некорректный JSON.")
    return []


# ── Отображение ────────────────────────────────────────────────────

def die(msg: str, code: int = 1):
    """Ошибка и выход."""
    print(f"{c('Ошибка', COLOR_RED)}: {msg}", file=sys.stderr)
    sys.exit(code)


def render_dashboard(agents: list[dict]):
    """Показать дашборд агентов в терминале."""
    if not agents:
        print(c("Нет данных об агентах. Возможно, ни один агент ещё не отчитывался.", COLOR_DIM))
        return

    # Заголовок
    now = datetime.now().strftime("%H:%M")
    print()
    print(c("═══ Агенты IWE ", COLOR_BOLD) + c(f"[{now}]", COLOR_DIM))
    print()

    for a in agents:
        name = a.get("agent", "?")
        status = a.get("status", "idle")
        task: str = a.get("task") or ""
        files = a.get("files") or []
        updated = a.get("updated_at", "")
        stale = is_stale(updated)

        icon = STATUS_ICONS.get(status, "❓")
        status_ru = STATUS_NAMES.get(status, status)

        # Цвет статуса: рабочий зелёный, заблокирован красный, stale жёлтый
        if stale and status != "idle":
            status_color = COLOR_YELLOW
            staleness = f" [{c('устарел', COLOR_YELLOW)}: {ago(updated)}]"
        elif status == "blocked":
            status_color = COLOR_RED
            staleness = ""
        elif status in ("working", "peer-session"):
            status_color = COLOR_GREEN
            staleness = ""
        else:
            status_color = COLOR_DIM
            staleness = ""

        # Строка агента
        agent_line = f"  {icon}  {c(name, COLOR_BOLD, COLOR_CYAN)}"
        status_line = f" — {c(status_ru, status_color)}{staleness}"
        print(agent_line + status_line)

        # Задача
        if task:
            print(f"      {c(task, COLOR_DIM)}")

        # Файлы
        if files:
            files_str = ", ".join(files[:3])
            if len(files) > 3:
                files_str += f" +{len(files)-3}"
            print(f"      {c(f'📄 {files_str}', COLOR_DIM)}")

        # Время
        if updated:
            print(f"      {c(f'{ts_iso(updated)}  ({ago(updated)})', COLOR_DIM)}")

        print()

    # Легенда
    print(c("─" * 50, COLOR_DIM))
    print(c("  💤 свободен   🔧 работает   🤝 peer-сессия   🚫 заблокирован", COLOR_DIM))
    print(c(f"  Статусы старше 15 мин. — жёлтая пометка «устарел»", COLOR_DIM))
    print()


def render_json(agents: list[dict]):
    """Вывести сырой JSON."""
    print(json.dumps({"agents": agents}, indent=2, ensure_ascii=False))


# ── main ────────────────────────────────────────────────────────────

def main():
    if "--help" in sys.argv or "-h" in sys.argv:
        print(__doc__)
        sys.exit(0)

    json_mode = "--json" in sys.argv

    token = get_token()
    agents = get_agents(token)

    if json_mode:
        render_json(agents)
    else:
        render_dashboard(agents)


if __name__ == "__main__":
    main()
