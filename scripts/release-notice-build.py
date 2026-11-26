#!/usr/bin/env python3
"""Build and check the Telegram release announcement for subscribers (WP-529).

Input: CHANGELOG entries of the released versions in the notify window (plain text,
as extracted by .github/workflows/notify-update.yml). Output: notice.json and
notice.html in --out-dir. The bot only validates the HTML boundary and delivers it.

Pipeline: generate items as JSON (model) -> render HTML (code, escaped) ->
program checks -> editor check (model cites the source entry for every item, the
code verifies the quote) -> one regeneration with the editor's remarks -> otherwise
the short deterministic notice (version + release link + how to update).

Models are called through OpenRouter (OPENROUTER_API_KEY, the same secret as
translate-sync). Without the key the short notice is produced; the build never
fails on the model, only on bad input.
"""

import argparse
import html
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

REPO_URL = "https://github.com/TserenTserenov/FMT-exocortex-template"
GENERATOR_MODEL = "anthropic/claude-opus-5.5"
EDITOR_MODEL = "anthropic/claude-sonnet-5.5"
OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"
# Attribution headers give the standard (non-strict) OpenRouter rate limit, as in translate.py.
OPENROUTER_HEADERS = {
    "HTTP-Referer": REPO_URL,
    "X-Title": "IWE Release Notice",
}
REQUEST_TIMEOUT_S = 300
MAX_MESSAGE_CHARS = 3500  # Telegram limit is 4096; headroom for the bot boundary check
MAX_ITEM_TEXT_CHARS = 180
MAX_SUMMARY_CHARS = 220
MIN_ITEMS, MAX_ITEMS = 3, 5
# Commands, flags and file names do not belong in a notice for users (pilot decision 25.11.2026).
TECHNICAL_TOKENS = re.compile(r"`|--[A-Za-z]|\b(?:git|bash|sh|python3?)\s+-|\b[\w./-]+\.(?:sh|py|json|yaml|md)\b|\bgit\s+\w")

HOW_TO_UPDATE = (
    "<b>Как обновить:</b> скажите своему Claude <i>«обнови мой экзокортекс»</i> "
    "или выполните в терминале <code>bash update.sh</code>"
)

ITEMS_SCHEMA = {
    "type": "object",
    "properties": {
        "summary": {"type": "string"},
        "items": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "title": {"type": "string"},
                    "text": {"type": "string"},
                    "source_index": {"type": "integer"},
                },
                "required": ["title", "text", "source_index"],
                "additionalProperties": False,
            },
        },
    },
    "required": ["summary", "items"],
    "additionalProperties": False,
}

EDITOR_SCHEMA = {
    "type": "object",
    "properties": {
        "items": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "number": {"type": "integer"},
                    "supported": {"type": "boolean"},
                    "quote": {"type": "string"},
                    "problems": {"type": "array", "items": {"type": "string"}},
                },
                "required": ["number", "supported", "quote", "problems"],
                "additionalProperties": False,
            },
        },
        "summary_ok": {"type": "boolean"},
        "summary_problems": {"type": "array", "items": {"type": "string"}},
        "ok": {"type": "boolean"},
    },
    "required": ["items", "summary_ok", "summary_problems", "ok"],
    "additionalProperties": False,
}

GENERATOR_PROMPT = """Ты пишешь анонс нового выпуска IWE (шаблон рабочей среды для Claude Code) для подписчиков в Telegram.
Стиль — заметки о выпуске у крупных вендоров (Apple, Notion, Linear): коротко, по делу, без внутренней кухни. Читатель — пользователь, не разработчик.

Тебе дан пронумерованный список записей журнала изменений. Верни:
- summary: ОДНО короткое предложение (до {max_summary} символов) о теме всего выпуска. Честно по составу записей: если в основном исправления ошибок и надёжность, так и скажи («Этот выпуск посвящён исправлению ошибок и повышению надёжности: …») и назови главное. Не называй выпуск большим или важным и не обещай новых возможностей, если их нет среди выбранных записей.
- items: от {min_items} до {max_items} самых заметных для пользователя изменений (если записей меньше, сколько есть). Для каждого:
  - title: 2–4 слова, суть;
  - text: ОДНО короткое предложение (до {max_chars} символов): что теперь работает иначе или что исправлено, словами пользователя;
  - source_index: номер записи журнала, на которой основан пункт.

Правила:
- Только то, что есть в выбранной записи. Ничего не добавляй от себя, не обобщай сверх записи.
- Никаких команд, флагов, имён файлов, программ, переменных и технических терминов (git, хуки, API, названия режимов и т. п.), номеров РП и PR. Если запись техническая, назови её последствие для человека обычными словами («агент больше не просит подтверждения при записи в память»).
- Оговорки и условия не перечисляй: подробности есть в описании выпуска по ссылке.
- Простой грамотный русский, активный залог. Без разметки, только текст.
- Один пункт одна запись; разные пункты разные записи."""

EDITOR_PROMPT = """Ты редактор анонса выпуска. Проверь каждый пункт анонса по записи журнала изменений, на которую он ссылается.

Для каждого пункта верни:
- number: номер пункта анонса;
- supported: true, только если всё сказанное в пункте прямо следует из этой записи и смысл не искажён.
  Упрощение и опущенные подробности — не проблема: анонс короче журнала. Проблема — только утверждение, которого в записи нет или которое ей противоречит;
- quote: дословная цитата из записи (5–25 слов), на которой держится пункт; копируй символы точно;
- problems: список проблем — орфография, искажение смысла, утверждение без опоры в записи, внутренние имена, обрыв текста. Не считай проблемой то, что пункт короче записи. Пустой, если проблем нет.
Дополнительно проверь «Сводку выпуска» (одно предложение о теме всего выпуска) по ВСЕМ записям журнала:
- summary_ok: true, только если сводка честно описывает состав записей (например, «посвящён исправлению ошибок» — только если исправления действительно преобладают), не обещает ничего сверх записей, не содержит команд, имён файлов и технических терминов и состоит из одного предложения;
- summary_problems: список проблем, пустой, если их нет.
Если сводки нет, верни summary_ok: true и пустой список.
Проблема пункта — также команда, флаг, имя файла или технический термин в тексте пункта, и текст длиннее одного предложения.
ok: true, только если у всех пунктов supported=true, problems пуст и summary_ok=true."""


class NoticeError(Exception):
    """Generation or editing failed; the caller falls back to the short notice."""


# Handoff fields under an entry (WP-529 Phase 252, scripts/check-changelog-fields.py):
# goal/result codes, check and rollback commands are for testers, not for the
# user-facing notice, so they never reach the generator or the editor.
HANDOFF_FIELD = re.compile(r"^\s+[-*]\s+(Цель:|Как проверить:|Как откатить:)")


def parse_entries(text: str) -> list[str]:
    """Top-level CHANGELOG bullets ("- " / "* "), continuation lines joined."""
    entries: list[str] = []
    in_field = False  # inside a handoff field, including its wrapped lines
    for line in text.splitlines():
        if re.match(r"^[-*]\s+", line):
            entries.append(re.sub(r"^[-*]\s+", "", line).strip())
            in_field = False
        elif HANDOFF_FIELD.match(line):
            in_field = True
        elif re.match(r"^\s+[-*]\s+", line):
            in_field = False
            if entries:
                entries[-1] += " " + line.strip()
        elif entries and not in_field and line.startswith((" ", "\t")) and line.strip():
            entries[-1] += " " + line.strip()
    return [entry for entry in entries if entry]


def release_url(version: str) -> str:
    return f"{REPO_URL}/releases/tag/v{version}"


def header(version: str) -> str:
    return f"🔄 <b>Обновление шаблона IWE {html.escape(version)}</b>"


def short_notice(version: str) -> str:
    return (
        f"{header(version)}\n\n"
        f'Что изменилось — <a href="{release_url(version)}">в описании выпуска</a>.\n\n'
        f"{HOW_TO_UPDATE}"
    )


def _text(value: str) -> str:
    # quote=False: Telegram needs only <, >, & escaped; &#x27; for ' is noise.
    return html.escape(value.strip(), quote=False)


def render(version: str, items: list[dict], summary: str = "") -> str:
    lines = [f"{n}. <b>{_text(item['title'])}</b> — {_text(item['text'])}" for n, item in enumerate(items, 1)]
    lead = f"{_text(summary)}\n\n" if summary.strip() else ""
    return (
        f"{header(version)}\n\n{lead}" + "\n\n".join(lines) + "\n\n"
        f'<a href="{release_url(version)}">Все изменения выпуска</a>\n\n'
        f"{HOW_TO_UPDATE}"
    )


def program_problems(items: list[dict], entries: list[str], message: str, summary: str = "") -> list[str]:
    """Deterministic checks of the generated items and the rendered message."""
    problems = []
    expected_min = min(MIN_ITEMS, len(entries))
    if not expected_min <= len(items) <= MAX_ITEMS:
        problems.append(f"пунктов {len(items)}, нужно от {expected_min} до {MAX_ITEMS}")
    indexes = [item["source_index"] for item in items]
    if len(set(indexes)) != len(indexes):
        problems.append("два пункта ссылаются на одну запись")
    for n, item in enumerate(items, 1):
        if not 1 <= item["source_index"] <= len(entries):
            problems.append(f"пункт {n}: нет записи с номером {item['source_index']}")
        if not item["title"].strip() or not item["text"].strip():
            problems.append(f"пункт {n}: пустой заголовок или текст")
        if len(item["text"]) > MAX_ITEM_TEXT_CHARS:
            problems.append(f"пункт {n}: текст длиннее {MAX_ITEM_TEXT_CHARS} символов")
        if "```" in item["title"] + item["text"]:
            problems.append(f"пункт {n}: служебная разметка")
        if TECHNICAL_TOKENS.search(item["title"] + " " + item["text"]):
            problems.append(f"пункт {n}: команда или имя файла в тексте для пользователя")
    if len(summary) > MAX_SUMMARY_CHARS:
        problems.append(f"сводка длиннее {MAX_SUMMARY_CHARS} символов")
    if TECHNICAL_TOKENS.search(summary):
        problems.append("сводка: команда или имя файла в тексте для пользователя")
    if len(message) > MAX_MESSAGE_CHARS:
        problems.append(f"сообщение длиннее {MAX_MESSAGE_CHARS} символов")
    return problems


def _normalize(text: str) -> str:
    """Compare quotes by words: CHANGELOG markdown and typography do not count."""
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"[`*_«»\"„“”]", "", text.replace("ё", "е"))
    return " ".join(text.split()).casefold()


def editor_problems(verdict: dict, items: list[dict], entries: list[str], summary: str = "") -> tuple[list[str], list[str], set[int]]:
    """Return (problems, remarks, rejected): every reason to reject, the part the generator
    can fix, and the numbers of items that are not confirmed.

    The editor is trusted only where its quote is really found in the cited entry.
    A missing or unfound quote rejects the item but is the editor's fault, so it
    is not sent back to the generator as a remark.
    """
    remarks, editor_faults, rejected = [], [], set()
    if summary and (verdict.get("summary_ok", True) is False or verdict.get("summary_problems")):
        remarks.extend(f"сводка: {p}" for p in verdict.get("summary_problems", []))
        if not verdict.get("summary_problems"):
            remarks.append("сводка: редактор не подтвердил её по записям журнала")
    by_number = {row["number"]: row for row in verdict["items"]}
    for n, item in enumerate(items, 1):
        row = by_number.get(n)
        if row is None:
            editor_faults.append(f"пункт {n}: редактор не проверил")
            rejected.add(n)
            continue
        item_remarks = [f"пункт {n}: {p}" for p in row["problems"]]
        if not row["supported"]:
            item_remarks.append(f"пункт {n}: нет опоры в записи журнала")
        source = entries[item["source_index"] - 1] if 1 <= item["source_index"] <= len(entries) else ""
        quote_found = row["quote"].strip() and _normalize(row["quote"]) in _normalize(source)
        if not quote_found:
            editor_faults.append(f"пункт {n}: цитата редактора не найдена в записи {item['source_index']}")
        if item_remarks or not quote_found:
            rejected.add(n)
        remarks.extend(item_remarks)
    if not verdict["ok"] and not remarks and not editor_faults:
        editor_faults.append("редактор не одобрил текст без замечаний")
        rejected.update(range(1, len(items) + 1))
    return remarks + editor_faults, remarks, rejected


def salvage(version: str, attempts: list[dict], entries: list[str]) -> dict | None:
    """After both attempts failed, keep only confirmed items if there are still enough of them."""
    candidates = []
    for attempt in attempts:
        if "rejected" not in attempt:
            continue
        rejected = set(attempt["rejected"])
        kept = [item for n, item in enumerate(attempt["items"], 1) if n not in rejected]
        summary = attempt.get("summary", "") if attempt.get("summary_ok", True) else ""
        message = render(version, kept, summary)
        if not program_problems(kept, entries, message, summary):
            candidates.append((len(kept), message, attempt["rejected"]))
    if not candidates:
        return None
    _, message, dropped = max(candidates, key=lambda c: c[0])
    return {"message_html": message, "dropped": dropped}


def numbered(entries: list[str]) -> str:
    return "\n".join(f"{i}. {entry}" for i, entry in enumerate(entries, 1))


class OpenRouterClient:
    """Chat completions with a strict JSON schema; returns (finish_reason, content)."""

    def __init__(self, api_key: str) -> None:
        self._headers = {"Content-Type": "application/json", "Authorization": f"Bearer {api_key}", **OPENROUTER_HEADERS}

    def chat_json(self, model: str, system: str, user: str, schema: dict) -> tuple[str, str]:
        body = {
            "model": model,
            "max_tokens": 16000,
            "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
            "response_format": {"type": "json_schema", "json_schema": {"name": "answer", "strict": True, "schema": schema}},
            # Route only to providers that honour response_format, never silently drop it.
            "provider": {"require_parameters": True},
        }
        request = urllib.request.Request(OPENROUTER_URL, data=json.dumps(body).encode("utf-8"),
                                         method="POST", headers=self._headers)
        with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT_S) as response:
            payload = json.loads(response.read().decode("utf-8"))
        choice = payload["choices"][0]
        return choice["finish_reason"], choice["message"]["content"] or ""


def ask_json(client, model: str, system: str, user: str, schema: dict) -> dict:
    """One structured call; an unfinished answer is a failure, never a partial text."""
    try:
        finish_reason, text = client.chat_json(model, system, user, schema)
    except (urllib.error.URLError, TimeoutError, KeyError, IndexError, json.JSONDecodeError) as exc:
        raise NoticeError(f"{model}: {type(exc).__name__}: {exc}") from exc
    if finish_reason != "stop":
        raise NoticeError(f"{model}: finish_reason={finish_reason}")
    try:
        return json.loads(text)
    except json.JSONDecodeError as exc:
        raise NoticeError(f"{model}: invalid JSON: {exc}") from exc


def generate(client, entries: list[str], remarks: list[str]) -> tuple[list[dict], str]:
    user = "Записи журнала изменений:\n\n" + numbered(entries)
    if remarks:
        user += "\n\nПредыдущий вариант отклонён. Исправь замечания:\n" + "\n".join(f"- {r}" for r in remarks)
    system = GENERATOR_PROMPT.format(min_items=MIN_ITEMS, max_items=MAX_ITEMS, max_chars=MAX_ITEM_TEXT_CHARS,
                                     max_summary=MAX_SUMMARY_CHARS)
    data = ask_json(client, GENERATOR_MODEL, system, user, ITEMS_SCHEMA)
    return data["items"], str(data.get("summary", "")).strip()


def review(client, items: list[dict], entries: list[str], summary: str = "") -> dict:
    blocks = []
    for n, item in enumerate(items, 1):
        idx = item["source_index"]
        source = entries[idx - 1] if 1 <= idx <= len(entries) else "(нет такой записи)"
        blocks.append(f"Пункт {n}: {item['title']} — {item['text']}\nЗапись {idx}: {source}")
    if summary:
        blocks.append(f"Сводка выпуска: {summary}\n\nВсе записи журнала:\n{numbered(entries)}")
    return ask_json(client, EDITOR_MODEL, EDITOR_PROMPT, "\n\n".join(blocks), EDITOR_SCHEMA)


def build(version: str, entries: list[str], client) -> dict:
    """Return the notice record: message_html, kind (built|short) and the check trail."""
    attempts: list[dict] = []
    remarks: list[str] = []
    if client is None:
        return {"kind": "short", "message_html": short_notice(version), "reason": "no OPENROUTER_API_KEY", "attempts": attempts}
    for _ in range(2):
        attempt: dict = {"remarks_in": remarks}
        try:
            items, summary = generate(client, entries, remarks)
            message = render(version, items, summary)
            attempt.update(items=items, summary=summary, program=program_problems(items, entries, message, summary))
            if not attempt["program"]:
                verdict = review(client, items, entries, summary)
                problems, editor_remarks, rejected = editor_problems(verdict, items, entries, summary)
                summary_ok = verdict.get("summary_ok", True) is not False and not verdict.get("summary_problems")
                attempt.update(editor=verdict, editor_problems=problems, editor_remarks=editor_remarks,
                               rejected=sorted(rejected), summary_ok=summary_ok)
        except NoticeError as exc:
            attempt["error"] = str(exc)
            attempts.append(attempt)
            remarks = []
            continue
        attempts.append(attempt)
        if not attempt["program"] and not attempt["editor_problems"]:
            return {"kind": "built", "message_html": message, "attempts": attempts}
        remarks = attempt["program"] or attempt["editor_remarks"]
    kept = salvage(version, attempts, entries)
    if kept:
        return {"kind": "built", "message_html": kept["message_html"], "dropped_items": kept["dropped"], "attempts": attempts}
    return {"kind": "short", "message_html": short_notice(version), "reason": "checks failed", "attempts": attempts}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--version", required=True, help="released version, e.g. 0.41.10")
    parser.add_argument("--entries", required=True, type=Path, help="CHANGELOG entries of the notify window")
    parser.add_argument("--out-dir", required=True, type=Path)
    parser.add_argument("--sha", default=os.environ.get("GITHUB_SHA", ""))
    args = parser.parse_args()

    if not re.fullmatch(r"\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?", args.version):
        print(f"release-notice-build: bad version {args.version!r}", file=sys.stderr)
        return 2
    entries = parse_entries(args.entries.read_text(encoding="utf-8"))
    if not entries:
        print("release-notice-build: no CHANGELOG entries", file=sys.stderr)
        return 2

    api_key = os.environ.get("OPENROUTER_API_KEY")
    client = OpenRouterClient(api_key) if api_key else None
    record = {"version": args.version, "sha": args.sha, "source_entries": len(entries), **build(args.version, entries, client)}

    args.out_dir.mkdir(parents=True, exist_ok=True)
    (args.out_dir / "notice.json").write_text(json.dumps(record, ensure_ascii=False, indent=2), encoding="utf-8")
    (args.out_dir / "notice.html").write_text(record["message_html"], encoding="utf-8")
    print(f"release-notice-build: version={args.version} kind={record['kind']} "
          f"attempts={len(record['attempts'])} length={len(record['message_html'])}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
