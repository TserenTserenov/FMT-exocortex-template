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
MAX_ITEM_TEXT_CHARS = 300
MIN_ITEMS, MAX_ITEMS = 4, 6

HOW_TO_UPDATE = (
    "<b>Как обновить:</b> скажите своему Claude <i>«обнови мой экзокортекс»</i> "
    "или выполните в терминале <code>bash update.sh</code>"
)

ITEMS_SCHEMA = {
    "type": "object",
    "properties": {
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
        }
    },
    "required": ["items"],
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
        "ok": {"type": "boolean"},
    },
    "required": ["items", "ok"],
    "additionalProperties": False,
}

GENERATOR_PROMPT = """Ты пишешь анонс нового выпуска IWE (шаблон рабочей среды для Claude Code) для подписчиков в Telegram.
Читатель — пользователь, не разработчик: ему важно, что стало лучше для него.

Тебе дан пронумерованный список записей журнала изменений. Выбери от {min_items} до {max_items} самых заметных для пользователя изменений (если записей меньше — сколько есть) и для каждого напиши:
- title: 2–5 слов, суть изменения;
- text: одно-два предложения о пользе для пользователя, до {max_chars} символов;
- source_index: номер записи журнала, на которой основан пункт.

Правила:
- Только то, что есть в выбранной записи. Ничего не добавляй от себя, не обобщай сверх записи.
- Без внутренних имён: номеров РП и PR, имён файлов, скриптов, переменных, хуков.
- Простой грамотный русский язык. Без разметки — только текст.
- Один пункт — одна запись; разные пункты — разные записи."""

EDITOR_PROMPT = """Ты редактор анонса выпуска. Проверь каждый пункт анонса по записи журнала изменений, на которую он ссылается.

Для каждого пункта верни:
- number: номер пункта анонса;
- supported: true, только если всё сказанное в пункте прямо следует из этой записи и смысл не искажён;
- quote: дословная цитата из записи (5–25 слов), на которой держится пункт; копируй символы точно;
- problems: список проблем — орфография, искажение смысла, утверждение без опоры в записи, внутренние имена, обрыв текста. Пустой, если проблем нет.
ok: true, только если у всех пунктов supported=true и problems пуст."""


class NoticeError(Exception):
    """Generation or editing failed; the caller falls back to the short notice."""


def parse_entries(text: str) -> list[str]:
    """Top-level CHANGELOG bullets ("- " / "* "), continuation lines joined."""
    entries: list[str] = []
    for line in text.splitlines():
        if re.match(r"^[-*]\s+", line):
            entries.append(re.sub(r"^[-*]\s+", "", line).strip())
        elif entries and line.startswith((" ", "\t")) and line.strip():
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


def render(version: str, items: list[dict]) -> str:
    lines = [f"{n}. <b>{_text(item['title'])}</b> — {_text(item['text'])}" for n, item in enumerate(items, 1)]
    return (
        f"{header(version)}\n\n" + "\n\n".join(lines) + "\n\n"
        f'<a href="{release_url(version)}">Все изменения выпуска</a>\n\n'
        f"{HOW_TO_UPDATE}"
    )


def program_problems(items: list[dict], entries: list[str], message: str) -> list[str]:
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
    if len(message) > MAX_MESSAGE_CHARS:
        problems.append(f"сообщение длиннее {MAX_MESSAGE_CHARS} символов")
    return problems


def _normalize(text: str) -> str:
    """Compare quotes by words: CHANGELOG markdown and typography do not count."""
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"[`*_«»\"„“”]", "", text.replace("ё", "е"))
    return " ".join(text.split()).casefold()


def editor_problems(verdict: dict, items: list[dict], entries: list[str]) -> tuple[list[str], list[str]]:
    """Return (problems, remarks): every reason to reject, and the part the generator can fix.

    The editor is trusted only where its quote is really found in the cited entry.
    A missing or unfound quote rejects the attempt but is the editor's fault, so it
    is not sent back to the generator as a remark.
    """
    remarks, editor_faults = [], []
    by_number = {row["number"]: row for row in verdict["items"]}
    for n, item in enumerate(items, 1):
        row = by_number.get(n)
        if row is None:
            editor_faults.append(f"пункт {n}: редактор не проверил")
            continue
        remarks.extend(f"пункт {n}: {p}" for p in row["problems"])
        if not row["supported"]:
            remarks.append(f"пункт {n}: нет опоры в записи журнала")
        source = entries[item["source_index"] - 1] if 1 <= item["source_index"] <= len(entries) else ""
        if not row["quote"].strip() or _normalize(row["quote"]) not in _normalize(source):
            editor_faults.append(f"пункт {n}: цитата редактора не найдена в записи {item['source_index']}")
    if not verdict["ok"] and not remarks and not editor_faults:
        editor_faults.append("редактор не одобрил текст без замечаний")
    return remarks + editor_faults, remarks


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


def generate(client, entries: list[str], remarks: list[str]) -> list[dict]:
    user = "Записи журнала изменений:\n\n" + numbered(entries)
    if remarks:
        user += "\n\nПредыдущий вариант отклонён. Исправь замечания:\n" + "\n".join(f"- {r}" for r in remarks)
    system = GENERATOR_PROMPT.format(min_items=MIN_ITEMS, max_items=MAX_ITEMS, max_chars=MAX_ITEM_TEXT_CHARS)
    return ask_json(client, GENERATOR_MODEL, system, user, ITEMS_SCHEMA)["items"]


def review(client, items: list[dict], entries: list[str]) -> dict:
    blocks = []
    for n, item in enumerate(items, 1):
        idx = item["source_index"]
        source = entries[idx - 1] if 1 <= idx <= len(entries) else "(нет такой записи)"
        blocks.append(f"Пункт {n}: {item['title']} — {item['text']}\nЗапись {idx}: {source}")
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
            items = generate(client, entries, remarks)
            message = render(version, items)
            attempt.update(items=items, program=program_problems(items, entries, message))
            if not attempt["program"]:
                verdict = review(client, items, entries)
                problems, editor_remarks = editor_problems(verdict, items, entries)
                attempt.update(editor=verdict, editor_problems=problems, editor_remarks=editor_remarks)
        except NoticeError as exc:
            attempt["error"] = str(exc)
            attempts.append(attempt)
            remarks = []
            continue
        attempts.append(attempt)
        if not attempt["program"] and not attempt["editor_problems"]:
            return {"kind": "built", "message_html": message, "attempts": attempts}
        remarks = attempt["program"] or attempt["editor_remarks"]
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
