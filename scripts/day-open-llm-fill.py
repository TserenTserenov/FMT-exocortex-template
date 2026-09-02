from __future__ import annotations
#!/usr/bin/env python3
"""
day-open-llm-fill.py — WP-356: per-section LLM-заполнение PENDING-маркеров DayPlan.

Интерфейс:
  python3 day-open-llm-fill.py \
    --scaffold PATH --weekplan PATH --wp-registry PATH \
    [--wp-dir PATH] [--cp-profile PATH] [--calendar PATH] [--out PATH] \
    [--proxy-url URL]

Инварианты:
- Только секции с <!-- PENDING... --> отправляются в LLM (per-section isolation).
- Секция 'План на сегодня' использует consolidated prompt с JSON-фактами из WP frontmatter.
- Секция без PENDING = неизменна (идемпотентность).
- Atomic write: tmp→rename если out == scaffold.
- Timeout: 60s на секцию, 300s общий.
- Proxy fail = hard fail (exit 1), fallback отключён.
- temperature=0 для today_plan (детерминированный рендерер).
"""

import argparse
import glob
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

import yaml
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
from wp_inbox import wp_card_paths  # noqa: E402 — lib path set above

DEFAULT_PROXY_URL = "http://localhost:18765"
SECTION_TIMEOUT_S = 60
TOTAL_TIMEOUT_S = 300


def _validated_pipeline_workspace() -> Path | None:
    """Return a physical IWE_ROOT supplied by the installed Day Open pipeline."""

    raw = os.environ.get("IWE_ROOT", "").strip()
    if not raw or "\x00" in raw:
        return None
    candidate = Path(raw).expanduser()
    if candidate.is_symlink():
        return None
    try:
        resolved = candidate.resolve(strict=True)
    except (OSError, RuntimeError):
        return None
    return resolved if resolved.is_dir() else None


PIPELINE_WORKSPACE = _validated_pipeline_workspace()


def _fault_profile_workspace() -> Path:
    configured = os.environ.get("IWE_WORKSPACE") or os.environ.get("WORKSPACE_DIR")
    if configured:
        return Path(configured).expanduser()
    return PIPELINE_WORKSPACE or Path.home() / "IWE"


def _fault_profile_script() -> str:
    """Resolve the one agent-neutral CLI in installed and template layouts."""

    script_dir = Path(__file__).resolve().parent
    workspace = _fault_profile_workspace()
    configured_scripts = Path(os.environ.get("IWE_SCRIPTS") or workspace / "scripts")
    candidates = (
        script_dir / "agent-fault" / "iwe_checklist_memory.py",
        configured_scripts / "agent-fault" / "iwe_checklist_memory.py",
        workspace / "FMT-exocortex-template" / "scripts" / "agent-fault" / "iwe_checklist_memory.py",
    )
    return str(next((candidate for candidate in candidates if candidate.is_file()), candidates[0]))


FAULT_PROFILE_SCRIPT = _fault_profile_script()


def read_file(path: str | None, default: str = "") -> str:
    if not path or not os.path.isfile(path):
        return default
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return f.read()


def load_fault_profile() -> str:
    """Run the unified agent-fault CLI and return this subject's top rules.

    Returns empty string on failure. Logs reason to stderr so silent disable
    (caused by interpreter mismatch, regex drift, or CLI breakage)
    surfaces in pipeline logs instead of vanishing.

    Symmetric with .claude/hooks/inject-fault-profile.sh: same data source
    (iwe_memory.db via the unified CLI), filtered to CRITICAL/MAJOR
    with n>=3.
    """
    subject_kind = os.environ.get("IWE_FAULT_SUBJECT_KIND", "")
    subject_id = os.environ.get("IWE_FAULT_SUBJECT_ID", "")
    if subject_kind not in {"personality", "runtime", "system"} or not subject_id:
        print("[INFO] fault-profile: explicit subject is not configured — skipped", file=sys.stderr)
        return ""
    if not os.path.isfile(FAULT_PROFILE_SCRIPT):
        print(f"[INFO] fault-profile: {FAULT_PROFILE_SCRIPT} not found — skipped",
              file=sys.stderr)
        return ""
    try:
        child_env = os.environ.copy()
        if (
            not child_env.get("IWE_WORKSPACE")
            and not child_env.get("WORKSPACE_DIR")
            and PIPELINE_WORKSPACE is not None
        ):
            # The governance pipeline derives IWE_ROOT from its own physical
            # location. Adapt that trusted runtime fact to the canonical CLI's
            # unchanged IWE_WORKSPACE → WORKSPACE_DIR → HOME/IWE contract.
            child_env["IWE_WORKSPACE"] = str(PIPELINE_WORKSPACE)
        result = subprocess.run(
            [
                sys.executable,
                FAULT_PROFILE_SCRIPT,
                "remind",
                "--protocol",
                "open",
                "--subject-kind",
                subject_kind,
                "--subject-id",
                subject_id,
            ],
            env=child_env,
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode != 0:
            print(f"[WARN] fault-profile: unified CLI exit={result.returncode}, "
                  f"stderr={result.stderr.strip()[:200]}", file=sys.stderr)
            return ""
        lines = [
            line for line in result.stdout.splitlines()
            if re.match(r"^🔴 \[(CRITICAL|MAJOR) \| n=\d+\]", line)
        ]
        if not lines:
            print("[WARN] fault-profile: unified CLI output had 0 lines "
                  "matching CRITICAL/MAJOR n>=3 regex — possible format drift",
                  file=sys.stderr)
            return ""
        return "\n".join(lines[:3])
    except Exception as e:
        print(f"[WARN] fault-profile: load failed ({type(e).__name__}: {e})",
              file=sys.stderr)
        return ""


def extract_active_wps(wp_registry_text: str) -> str:
    lines = []
    for line in wp_registry_text.splitlines():
        if any(s in line for s in ("🔄", "⏳", "🔴", "🟡", "🟠")):
            lines.append(line)
    return "\n".join(lines[:50])


def rebuild_compact_dashboard(text: str) -> str:
    """Перестроить блок РП в Compact Dashboard из готовой секции 'План на сегодня'
    (топ-7 по приоритету), а не из алфавитного sweep активных РП.

    Compact dashboard рождается в скаффолде ДО наполнения плана, поэтому скаффолд
    берёт sweep по порядку РП (РП без активности вместо фокуса дня). Здесь, после
    наполнения, план уже известен — берём его топ-7. WP-5 Ф 2026-06-11 П1.

    План пуст (не наполнен) → текст возвращается без изменений (fallback на scaffold).
    """
    lines = text.split("\n")

    # 1. Собрать топ-7 строк-РП из таблицы 'План на сегодня'
    plan_rows = []
    in_plan = False
    for ln in lines:
        if "План на сегодня" in ln:
            in_plan = True
            continue
        if not in_plan:
            continue
        s = ln.strip()
        if s.startswith("|") and "**" in s and "🚦" not in s:
            plan_rows.append(s)
            if len(plan_rows) >= 7:
                break
        elif plan_rows and not s.startswith("|"):
            break  # таблица закончилась (Бюджет дня / пустая строка / </details>)
    if not plan_rows:
        return text

    # 2. Компактные строки: | флаг | # краткое-название |
    compact = ["**Сегодня (топ-7 по приоритету):**"]
    for row in plan_rows:
        cols = [c.strip() for c in row.strip("|").split("|")]
        if len(cols) < 3:
            continue
        flag, num, name = cols[0], cols[1], cols[2]
        short = name.split(" — ")[0].strip()
        if len(short) > 60:
            short = short[:57] + "…"
        compact.append(f"| {flag} | {num} {short} |")

    # 3. Заменить старый подблок РП внутри Compact Dashboard на compact
    out = []
    in_dash = False
    skipping = False
    for ln in lines:
        if "---COMPACT-DASHBOARD---" in ln:
            in_dash = True
            out.append(ln)
            continue
        if "---END-COMPACT-DASHBOARD---" in ln:
            in_dash = False
            skipping = False
            out.append(ln)
            continue
        s = ln.strip()
        if in_dash and s.startswith("**Сегодня"):
            out.extend(compact)
            skipping = True
            continue
        if skipping:
            if s == "":
                skipping = False
                out.append(ln)
            continue  # пропускаем старые строки таблицы
        out.append(ln)
    return "\n".join(out)


def _dashboard_today_iso() -> str:
    """Сегодня по московскому календарю -- дата, под которой dashboard_worker.py
    пишет ночной снимок (запуск 07:30 MSK, WP-417 Ф-cutover-switch 2026-09-02).
    Заменяет _panel_yesterday_iso() -- старая панель считала за ВЧЕРА (target_date
    в panel_worker.py), PD-dashboard пишет файл под датой самого запуска."""
    from datetime import datetime, timezone
    try:
        from zoneinfo import ZoneInfo
        now = datetime.now(ZoneInfo("Europe/Moscow"))
    except Exception:  # noqa: BLE001 — zoneinfo нет → Москва = UTC+3 (без DST с 2014)
        from datetime import timedelta
        now = datetime.now(timezone.utc) + timedelta(hours=3)
    return now.date().isoformat()


def _strip_panel_block(text: str, begin: str, end: str) -> str:
    """Вырезать прежний блок табло (идемпотентность). Нет блока → текст без изменений."""
    start = text.find(begin)
    if start == -1:
        return text
    stop = text.find(end, start)
    if stop == -1:
        return text
    stop += len(end)
    after = stop + 1 if text[stop:stop + 1] == "\n" else stop  # съесть хвостовой \n
    return text[:start] + text[after:]


GATE_METRICS_SCRIPT = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "gate-metrics.sh"
)
GATE_SECTION_BEGIN = "<summary><b>Gate-метрики"
GATE_SECTION_END = "</details>"


def inject_gate_metrics(text: str) -> str:
    """Run gate-metrics.sh and replace Gate-метрики section body with actual output.

    Idempotent: replaces on every run. Degrades gracefully if script/log absent.
    Gate log lives at ~/.iwe/gate-decisions.jsonl — only present on Mac.
    """
    gate_log = os.path.expanduser("~/.iwe/gate-decisions.jsonl")
    if not os.path.isfile(gate_log):
        print("[inject_gate_metrics] gate log absent — skipping", file=sys.stderr)
        return text
    if not os.path.isfile(GATE_METRICS_SCRIPT):
        print(f"[inject_gate_metrics] {GATE_METRICS_SCRIPT} not found — skipping", file=sys.stderr)
        return text

    try:
        r = subprocess.run(
            ["bash", GATE_METRICS_SCRIPT],
            capture_output=True, text=True, timeout=10,
        )
        output = r.stdout.strip()
        if not output:
            print("[inject_gate_metrics] empty output — skipping", file=sys.stderr)
            return text
    except Exception as e:
        print(f"[inject_gate_metrics] failed: {e}", file=sys.stderr)
        return text

    # Find <summary><b>Gate-метрики then </summary> then </details>
    # Replace everything between </summary> and </details> with gate output.
    idx = text.find(GATE_SECTION_BEGIN)
    if idx == -1:
        return text
    summary_end = text.find("</summary>", idx)
    if summary_end == -1:
        return text
    summary_end += len("</summary>")
    close = text.find(GATE_SECTION_END, summary_end)
    if close == -1:
        return text

    new_body = "\n\n" + output + "\n\n"
    return text[:summary_end] + new_body + text[close:]


def inject_panel_tile(text: str) -> str:
    """Врезать тайл табло (WP-417 Ф-cutover-switch, 2026-09-02) в Compact Dashboard
    перед END-маркером.

    Источник -- PD-dashboard (git, ночной писатель dashboard_worker.py), не
    panel.db/Neon (старый WP-417 Ф3.4 источник superseded архитектурным пивотом
    18.08-01.09, см. inbox/WP-417/WP-417.md "Актуализация и решение пилота о
    составе табло"). Идемпотентно -- старый блок <!-- panel-tile --> вырезается
    и заменяется свежим (повторный Day Open не дублирует). Деградирует мягко:
    нет PD-dashboard/файла на сегодня -> тайл пропускается, открытие дня не
    падает (P4: причина в лог). Общий scaffold не трогаем -- врезка только в
    локальном пайплайне ${IWE_GOVERNANCE_REPO:-DS-strategy}.
    """
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
    try:
        from dashboard_render import (
            PANEL_BEGIN, PANEL_END, read_dashboard_snapshot, render_dashboard_panel_block,
        )
    except Exception:  # noqa: BLE001 — dashboard-модули недоступны → тайл просто не показываем
        print("[inject_panel_tile] dashboard-модули недоступны — тайл пропущен", file=sys.stderr)
        return text

    marker = "---END-COMPACT-DASHBOARD---"
    if marker not in text:
        return text  # нет дашборда (необычный scaffold) — некуда врезать

    try:
        snapshot = read_dashboard_snapshot(_fault_profile_workspace())
    except Exception:  # noqa: BLE001 — PD-dashboard недоступен → тайл пропускаем, день не валим
        print("[inject_panel_tile] чтение PD-dashboard не удалось — тайл пропущен", file=sys.stderr)
        return text

    block = render_dashboard_panel_block(snapshot, _dashboard_today_iso())
    text = _strip_panel_block(text, PANEL_BEGIN, PANEL_END)
    idx = text.find(marker)
    return text[:idx] + block + "\n" + text[idx:]


def parse_frontmatter(path: str) -> dict:
    """Parse YAML frontmatter from a markdown file, top-level keys as strings.

    Uses a real YAML parser: the previous line-by-line version conflated nested
    keys with top-level ones — a WP card with `phases:` sub-keys like
    `Ф-x: superseded` overwrote the top-level `status: in_progress`, so WP-149
    was misread as closed and dropped from the DayPlan (2026-07-01).
    """
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError:
        return {}
    if not text.startswith("---"):
        return {}
    # Frontmatter is the block between the first two `---` fences.
    parts = text.split("\n---", 1)
    body = parts[0][3:] if parts else ""
    try:
        data = yaml.safe_load(body) or {}
        if isinstance(data, dict):
            # Normalize scalar top-level values to strings; callers expect .get()->str.
            return {k: ("" if v is None else str(v)) for k, v in data.items()}
    except yaml.YAMLError:
        pass
    # Fallback: some WP cards have unquoted prose in frontmatter that breaks strict
    # YAML. Scan top-level keys only (no leading indent) so nested `status:` under
    # `phases:` can't clobber the real one, and a malformed tail is tolerated.
    return _parse_toplevel_lines(body)


def _parse_toplevel_lines(body: str) -> dict:
    result = {}
    for line in body.splitlines():
        if not line or line[0] in " \t#":
            continue  # skip indented (nested) lines, blanks, comments
        if ":" in line:
            key, val = line.split(":", 1)
            result[key.strip()] = val.strip().strip("\"'")
    return result


def collect_wp_facts(wp_dir: str) -> list[dict]:
    """Collect active WP facts from frontmatter of WP-*.md files."""
    facts = []
    if not os.path.isdir(wp_dir):
        return facts
    for path in wp_card_paths(wp_dir):
        fm = parse_frontmatter(path)
        status = fm.get("status", "").lower()
        if status not in ("in_progress", "active", "pending"):
            continue
        wp_id = fm.get("wp", "")
        if not wp_id:
            m = re.search(r"WP-(\d+)", os.path.basename(path))
            if m:
                wp_id = m.group(1)
        wp_id = re.sub(r"^WP-", "", str(wp_id))
        # Budget field fallback: budget_h → budget_hours → budget
        budget = fm.get("budget_h") or fm.get("budget_hours") or fm.get("budget", "")
        facts.append({
            "id": f"WP-{wp_id}" if wp_id else "WP-??",
            "title": fm.get("title", ""),
            "status": status,
            "priority": fm.get("priority", ""),
            "budget_h": budget,
        })
    return facts


def _strip_leading_details(content: str) -> str:
    """Drop leading <details...> lines the LLM wrapped around its answer.

    The canonical opening tag lives in the section header line, so any <details>
    the LLM prepends is a duplicate with no <summary> — browsers render it as the
    literal word "Details". Loops because the LLM occasionally stacks two openers.
    """
    stripped = content.lstrip("\n")
    while stripped.lower().startswith("<details"):
        first_nl = stripped.find("\n")
        if first_nl == -1:
            return ""
        stripped = stripped[first_nl + 1:].lstrip("\n")
    return stripped


def _drop_trailing_closers(content: str, extra: int) -> str:
    """Remove `extra` trailing </details> tags the LLM emitted beyond the original.

    Excess closers close the outer <details> early and orphan every section below,
    so the DayPlan tail silently disappears. Strips from the end, where stray
    closers accumulate.
    """
    lines = content.rstrip().split("\n")
    kept = []
    for line in reversed(lines):
        if extra > 0 and line.strip() == "</details>":
            extra -= 1
            continue
        kept.append(line)
    return "\n".join(reversed(kept))


def has_bare_details(text: str) -> bool:
    """True if any <details> opener lacks a <summary> within the next few lines.

    A bare <details> is the "Details" rendering bug. Used as a post-fill gate so a
    regression blocks the commit instead of reaching the pilot.
    """
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if line.strip().lower().startswith("<details"):
            window = " ".join(lines[i + 1:i + 4]).lower()
            if "<summary>" not in window:
                return True
    return False


def split_into_chunks(text: str) -> list[dict]:
    """Разбить текст на чанки по заголовкам ## или <details>."""
    chunks = []
    current_lines = []
    current_header = "preamble"

    for line in text.splitlines(keepends=True):
        if line.startswith("## ") or line.strip().startswith("<details"):
            if current_lines:
                chunks.append({"header": current_header, "lines": current_lines, "has_pending": "<!-- PENDING" in "".join(current_lines)})
            current_header = line.strip()
            current_lines = [line]
        else:
            current_lines.append(line)

    if current_lines:
        chunks.append({"header": current_header, "lines": current_lines, "has_pending": "<!-- PENDING" in "".join(current_lines)})
    return chunks


def build_section_prompt(header: str, section_content: str, weekplan: str,
                         active_wps: str, calendar: str, cp_profile: str,
                         fault_profile: str = "", fleeting_notes: str = "") -> str:
    parts = ["Ты — утренний ассистент пилота IWE."]
    if fault_profile:
        parts += [
            "",
            "=== ПРОФИЛЬ ПОВТОРЯЮЩИХСЯ ОШИБОК АГЕНТА (n>=3 за историю сессий) ===",
            "Применять при заполнении секции. Источник: WP-316 (Session Memory).",
            fault_profile,
            "",
        ]
    parts += [
        "Тебе дана ОДНА секция DayPlan с маркерами <!-- PENDING: описание --> или <!-- PENDING -->.",
        "ЗАДАЧА: замени КАЖДЫЙ маркер в этой секции на реальный, конкретный контент.",
        "",
        "ПРАВИЛА:",
        "1. Пиши конкретно, без общих фраз.",
        "2. Ссылайся на реальные WP-номера из контекста.",
        "3. Если данных нет — напиши 'Нет данных' и удали маркер.",
        "4. Не меняй структуру markdown (таблицы, списки, жирный текст).",
        "4a. Если секция начинается с <details> — обязательно сохрани <summary>...</summary> (если есть) и закрывающий </details> в конце секции.",
        "5. Верни ТОЛЬКО содержимое секции — БЕЗ заголовка секции.",
        "6. Если секция содержит таблицу — заполни ячейки с PENDING, остальные не трогай.",
        "6a. Для таблицы 'Разбор заметок': ячейки в столбце 'Заметка' — ссылки вида [«текст»](../inbox/fleeting-notes.md) БЕЗ якоря (bold-текст не создаёт GitHub-якорей). Не добавляй #якорь. Не оставляй голый текст без ссылки.",
        "6b. Для секции 'Мир': если есть блок '**Вывод:**' с PENDING — заполни 2-4 предложениями: какие новости релевантны активным РП из WeekPlan. Без общих фраз, конкретика по WP-номерам.",
        "6c. Для таблицы 'Разбор заметок': ЗАПРЕЩЕНО выдумывать названия заметок. Используй ТОЛЬКО заголовки из 'КОНТЕКСТ: Fleeting Notes' ниже. Если контекст пустой или содержит только frontmatter — напиши 'нет заметок' в столбец 'Заметка'.",
        "",
        "=== КОНТЕКСТ: WeekPlan ===",
        weekplan[:6000],
        "",
        "=== КОНТЕКСТ: Активные WP ===",
        active_wps or "Нет активных WP.",
        "",
    ]
    if calendar:
        parts += ["=== КОНТЕКСТ: Календарь ===", calendar[:1500], ""]
    if cp_profile:
        parts += ["=== КОНТЕКСТ: Профиль пилота ===", cp_profile[:800], ""]
    if fleeting_notes:
        parts += ["=== КОНТЕКСТ: Fleeting Notes (источник заметок для таблицы 'Разбор заметок') ===",
                  fleeting_notes[:3000], ""]
    parts += [
        f"=== СЕКЦИЯ: {header} ===",
        section_content,
        "",
        "Верни ТОЛЬКО содержимое секции (без заголовка) со всеми заменами.",
        "Не оборачивай ответ в ```markdown ```.",
    ]
    return "\n".join(parts)


def build_today_plan_prompt(header: str, section_content: str, weekplan: str,
                            wp_facts: list[dict], calendar: str, cp_profile: str,
                            fault_profile: str = "") -> str:
    """Consolidated prompt for today_plan with JSON facts."""
    facts_json = json.dumps(wp_facts, ensure_ascii=False, indent=2)
    parts = ["Ты — утренний ассистент пилота IWE."]
    if fault_profile:
        parts += [
            "",
            "=== ПРОФИЛЬ ПОВТОРЯЮЩИХСЯ ОШИБОК АГЕНТА (n>=3 за историю сессий) ===",
            "Применять при заполнении секции. Источник: WP-316 (Session Memory).",
            fault_profile,
            "",
        ]
    parts += [
        "Тебе дана ОДНА секция DayPlan: 'План на сегодня' с маркерами <!-- PENDING: описание --> или <!-- PENDING -->.",
        "ЗАДАЧА: замени КАЖДЫЙ маркер на реальный, конкретный контент.",
        "",
        "КРИТИЧЕСКИ ВАЖНО (инварианты):",
        "1. Ниже передан СПИСОК АКТИВНЫХ РП в виде JSON. Это ЕДИНСТВЕННЫЙ источник состава РП, статусов и часов.",
        "2. Таблица 'План на сегодня' ДОЛЖНА содержать РОВНО те РП, что есть в JSON. НЕ добавляй новые. НЕ убирай существующие.",
        "3. Статусы и часы (budget_h) берутся verbatim из JSON. Не инферируй и не меняй их из WeekPlan или других источников.",
        "4. Ты можешь адаптировать только: приоритизацию (🔴/🟡/🟢), формулировки колонки 'Результат', порядок строк.",
        "5. Бюджет дня должен строго соответствовать сумме часов из JSON + mandatory_daily_wps.",
        "6. Не меняй структуру markdown (таблицы, списки, жирный текст).",
        "7. Верни ТОЛЬКО содержимое секции — БЕЗ заголовка секции.",
        "8. Audit-trail для carry-over: после строки '**Carry-over из Day Close вчера:**' воспроизведи ВЕСЬ список из WeekReport ('Не выполнено (carry-over ...)') или вчерашнего DayPlan ('Завтра начать с'). Если какой-то пункт carry-over НЕ попал в таблицу плана — оставь его в самой строке carry-over с пометкой `(отложено: <причина>)` в круглых скобках сразу после пункта. Возможные причины: 'нет WP-ID — ad-hoc задача, не проходит JSON-fact pipeline' / 'условный carry-over \"если бюджет\", дневной бюджет заполнен другими РП' / 'WP в JSON, но статус — done/blocked'. НЕ выкидывай пункт молча — у пилота должен оставаться след. ВАЖНО: пункты с пометкой '(отложено: ...)' живут ТОЛЬКО в строке carry-over (текстовом следе), их часы НЕ входят в Бюджет дня (инвариант 5 остаётся в силе: бюджет = сумма часов JSON-фактов + mandatory_daily_wps).",
        "",
        "=== JSON-ФАКТЫ: Активные РП (источник — frontmatter WP-*.md) ===",
        facts_json,
        "",
        "=== КОНТЕКСТ: WeekPlan ===",
        weekplan[:6000],
        "",
    ]
    if calendar:
        parts += ["=== КОНТЕКСТ: Календарь ===", calendar[:1500], ""]
    if cp_profile:
        parts += ["=== КОНТЕКСТ: Профиль пилота ===", cp_profile[:800], ""]
    parts += [
        f"=== СЕКЦИЯ: {header} ===",
        section_content,
        "",
        "Верни ТОЛЬКО содержимое секции (без заголовка) со всеми заменами.",
        "Не оборачивай ответ в ```markdown ```.",
    ]
    return "\n".join(parts)


def call_proxy(prompt: str, proxy_url: str, proxy_secret: str | None,
               temperature: float | None = None) -> str:
    payload = {
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": 2048,
        "verification_class": "closed-loop",
    }
    if temperature is not None:
        payload["temperature"] = temperature
    headers = {"Content-Type": "application/json"}
    if proxy_secret:
        headers["X-IWE-Internal-Secret"] = proxy_secret

    req = urllib.request.Request(
        f"{proxy_url.rstrip('/')}/v1/messages",
        data=json.dumps(payload).encode("utf-8"),
        headers=headers,
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=SECTION_TIMEOUT_S) as resp:
        data = json.loads(resp.read().decode("utf-8"))
        for block in data.get("content", []):
            if block.get("type") == "text":
                return block.get("text", "")
        return data.get("text", "")


def fill_chunk(chunk: dict, weekplan: str, active_wps: str, calendar: str,
               cp_profile: str, proxy_url: str, proxy_secret: str | None,
               wp_facts: list[dict] | None = None,
               fault_profile: str = "",
               fleeting_notes: str = "") -> str:
    header = chunk["header"]
    content = "".join(chunk["lines"][1:])  # без заголовка

    # Consolidated prompt with JSON facts for today_plan.
    # `header` is usually the bare "<details>"/"<details open>" tag (chunking
    # stores the <summary> title in `content`, not `header`) — checking
    # `header` alone means this branch never fires for that shape, and the
    # plan table falls through to the generic per-section prompt, which
    # leaves the scaffold's example placeholders (N/NNN/X) unreplaced instead
    # of computing a real seq/hours value per WP. Checking `content` alone
    # would instead miss a plain "## План на сегодня" heading (chunk header
    # can carry the title directly there) if the body never repeats the
    # phrase — Codex review, WP-484 backfill-regression-fix session, 31.08.
    # Checking both covers each chunking shape without betting on which one
    # is live. Regressed and re-fixed three times in a consumer's installed
    # copy (2026-07-09, then 26.08, then 31.08) — each time only that copy
    # was patched, so this canonical source kept re-seeding the bug on the
    # next backfill; fixed here too (WP-484, peer-session with Codex, same
    # day) to close that loop.
    is_today_plan = (
        "План на сегодня" in content or "today_plan" in content.lower()
        or "План на сегодня" in header or "today_plan" in header.lower()
    )
    if is_today_plan and wp_facts:
        prompt = build_today_plan_prompt(header, content, weekplan, wp_facts,
                                         calendar, cp_profile, fault_profile)
        response = call_proxy(prompt, proxy_url, proxy_secret, temperature=0.0)
    else:
        prompt = build_section_prompt(header, content, weekplan, active_wps,
                                      calendar, cp_profile, fault_profile,
                                      fleeting_notes=fleeting_notes)
        response = call_proxy(prompt, proxy_url, proxy_secret)

    if not response.strip():
        raise RuntimeError(f"Empty response for section {header}")
    return response


def main() -> None:
    parser = argparse.ArgumentParser(description="WP-356 per-section LLM DayPlan filler")
    parser.add_argument("--scaffold", required=True)
    parser.add_argument("--weekplan", required=True)
    parser.add_argument("--wp-registry", required=True)
    parser.add_argument("--wp-dir", default=None)
    parser.add_argument("--cp-profile", default=None)
    parser.add_argument("--calendar", default=None)
    parser.add_argument("--fleeting-notes", default=None, dest="fleeting_notes")
    parser.add_argument("--out", required=True)
    parser.add_argument("--proxy-url", default=os.getenv("LLM_PROXY_URL", DEFAULT_PROXY_URL))
    parser.add_argument("--proxy-secret", default=os.getenv("LLM_PROXY_SECRET", None))
    args = parser.parse_args()

    scaffold = read_file(args.scaffold)
    if "<!-- PENDING" not in scaffold:
        print("[INFO] No PENDING markers — nothing to fill.")
        Path(args.out).write_text(scaffold, encoding="utf-8")
        return

    weekplan = read_file(args.weekplan)
    wp_registry = read_file(args.wp_registry)
    calendar = read_file(args.calendar)
    cp_profile = read_file(args.cp_profile)
    fleeting_notes = read_file(args.fleeting_notes)
    active_wps = extract_active_wps(wp_registry)

    # Collect structured WP facts from frontmatter
    wp_dir = args.wp_dir
    if not wp_dir:
        wp_dir = os.path.join(os.path.dirname(args.wp_registry), "..", "inbox")
        wp_dir = os.path.normpath(wp_dir)
    wp_facts = collect_wp_facts(wp_dir)
    if wp_facts:
        print(f"[INFO] Collected {len(wp_facts)} WP facts from {wp_dir}", file=sys.stderr)

    fault_profile = load_fault_profile()
    if fault_profile:
        n_rules = len(fault_profile.splitlines())
        print(f"[INFO] Loaded fault profile ({n_rules} rules)", file=sys.stderr)

    chunks = split_into_chunks(scaffold)
    filled_chunks = []
    failed_sections = []

    for chunk in chunks:
        if not chunk["has_pending"]:
            filled_chunks.append(chunk)
            continue
        try:
            new_content = fill_chunk(chunk, weekplan, active_wps, calendar, cp_profile,
                                     args.proxy_url, args.proxy_secret, wp_facts,
                                     fault_profile, fleeting_notes=fleeting_notes)
            # Structural tag protection: restore canonical <summary>, drop LLM-wrapped
            # <details>, and balance </details> so nesting stays valid.
            original_text = "".join(chunk["lines"])
            header_line = chunk["lines"][0]
            # Always restore canonical <summary> from scaffold — LLM may omit or alter it.
            # re.sub removes whatever the LLM produced; we then prepend the original.
            # If LLM dropped </summary> (malformed), regex doesn't match → prepend still runs,
            # browser renders first <summary> (canonical) and ignores malformed tail.
            if len(chunk["lines"]) > 1:
                second_line = chunk["lines"][1]
                if second_line.strip().startswith("<summary>"):
                    nc = re.sub(r"<summary>.*?</summary>", "", new_content, count=1, flags=re.DOTALL).lstrip("\n")
                    # Strip the LLM's own <details> opener from `nc` here, while it's still
                    # leading (this is what the LLM wrapped its whole answer in, summary and
                    # all). Doing this AFTER prepending `second_line` below is too late: the
                    # combined string then starts with the canonical <summary>, not <details>,
                    # so _strip_leading_details silently no-ops and the LLM's opener survives
                    # as an orphaned bare <details> right after the summary (found 2026-07-02,
                    # 8 sections in one DayPlan) — its matching closer is still counted as
                    # "balanced" against the header's opener further down, so the header's own
                    # <details> never gets closed and every section after it renders nested.
                    nc = _strip_leading_details(nc)
                    new_content = second_line + "\n" + nc
            # Strip every leading <details...> line the LLM wrapped its answer in. header_line
            # already carries the canonical opening tag; a leftover bare <details> without a
            # <summary> renders as the literal word "Details". Loop, because the LLM sometimes
            # emits two opening tags in a row.
            new_content = _strip_leading_details(new_content)
            # Balance </details> both ways. LLM may drop nested closers (add missing) or emit
            # extras that close the outer block early and orphan the sections below (drop extras).
            original_details_count = original_text.count("</details>")
            new_details_count = new_content.count("</details>")
            if new_details_count < original_details_count:
                new_content = new_content.rstrip() + "\n</details>\n" * (original_details_count - new_details_count)
            elif new_details_count > original_details_count:
                new_content = _drop_trailing_closers(new_content, new_details_count - original_details_count)
            # Reconstruct chunk: keep header, replace content
            new_lines = [header_line]  # header
            new_lines.append(new_content)
            # Ensure trailing newline if original had it
            if chunk["lines"] and chunk["lines"][-1].endswith("\n") and not new_content.endswith("\n"):
                new_lines.append("\n")
            chunk["lines"] = new_lines
            filled_chunks.append(chunk)
            print(f"[OK] Filled: {chunk['header'][:60]}", file=sys.stderr)
        except Exception as e:
            print(f"[WARN] Failed section {chunk['header'][:60]}: {e}", file=sys.stderr)
            failed_sections.append(chunk["header"])
            filled_chunks.append(chunk)  # keep original with PENDING

    # Reassemble
    result_lines = []
    for chunk in filled_chunks:
        result_lines.extend(chunk["lines"])
    result = "".join(result_lines)

    # WP-5 Ф 2026-06-11 П1: Compact Dashboard — топ-7 из готового плана, не sweep
    result = rebuild_compact_dashboard(result)
    # WP-417 Ф3.4: тайл табло за вчера — ПОСЛЕ rebuild (иначе он сотрёт блок), локально
    result = inject_panel_tile(result)
    # Gate-метрики: заменить тело секции реальным выводом gate-metrics.sh (только Mac)
    result = inject_gate_metrics(result)

    # Sanity: if result is much shorter than scaffold, something went wrong
    if len(result) < len(scaffold) * 0.5:
        print("[ERROR] Result too short, aborting.", file=sys.stderr)
        sys.exit(1)

    # Atomic write
    out_path = Path(args.out)
    tmp = out_path.with_suffix(out_path.suffix + ".tmp")
    tmp.write_text(result, encoding="utf-8")
    tmp.rename(out_path)

    # Gate: a bare <details> without <summary> renders as the word "Details" in the
    # pilot's DayPlan. Exit 2 so day-open-checks blocks the commit until it's fixed.
    if has_bare_details(result):
        print("[WARN] Bare <details> without <summary> detected — 'Details' rendering bug.", file=sys.stderr)
        sys.exit(2)

    if failed_sections:
        print(f"[WARN] Sections not filled: {failed_sections}", file=sys.stderr)
        sys.exit(2)  # partial fill — checks will catch remaining PENDING

    print(f"[OK] Written to {args.out}")


if __name__ == "__main__":
    main()
