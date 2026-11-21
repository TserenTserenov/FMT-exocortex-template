#!/usr/bin/env python3
"""Build the urgent security notice for subscribers from new [security] CHANGELOG lines (WP-529 F275).

Input (stdin): the lines printed by `scripts/changelog-diff-lines.sh <base> --security-only`.
Output (stdout): plain text for the bot's /api/template-update (the bot escapes it and appends
the commit link). Deterministic, no model: the urgent path must not depend on a provider.

Why: on the 0.42.1 release merge the workflow sent eleven developer entries verbatim (about
17 000 characters); the bot cut the message at Telegram's 4096 limit mid-sentence. The notice
now names each topic once with its entry count and PR numbers, says what the reader should do,
and always fits one message.
"""

import re
import sys

CHANGELOG_URL = "https://github.com/TserenTserenov/FMT-exocortex-template/blob/main/CHANGELOG.md"
MAX_MESSAGE_CHARS = 3500  # Telegram limit is 4096; headroom for the bot's commit link
MAX_TOPIC_CHARS = 90
MAX_TOPICS = 8

ENTRY_RE = re.compile(r"^- \[security\]\s+(?:\((#\d+)\)\s+)?(.*)$")
# The topic is the entry's subject: text before the first code path in parentheses
# ("Проверка опасных команд агента (`.claude/hooks/...`) ..."), else before the first sentence end.
CODE_PAREN_RE = re.compile(r"\s*\(`")
SENTENCE_END_RE = re.compile(r"[.:;](\s|$)")

HOW_TO_ACT = (
    "Что делать: обычная установка получает эти исправления с ближайшим выпуском шаблона. "
    "Когда придёт анонс выпуска, скажите своему Claude «обнови мой экзокортекс»."
)


def shorten(text: str, limit: int) -> str:
    """Cut at a word boundary and mark the cut, never mid-word."""
    if len(text) <= limit:
        return text
    cut = text[: limit - 1]
    space = cut.rfind(" ")
    if space > limit // 2:
        cut = cut[:space]
    return cut.rstrip(" ,—-") + "…"


def topic_of(body: str) -> str:
    match = CODE_PAREN_RE.search(body)
    if match:
        subject = body[: match.start()]
    else:
        end = SENTENCE_END_RE.search(body)
        subject = body[: end.start()] if end else body
    subject = re.sub(r"`([^`]*)`", r"\1", subject).strip()
    return shorten(subject, MAX_TOPIC_CHARS) or "Исправление защиты"


def parse(lines: list[str]) -> list[tuple[str, list[str]]]:
    """Group entries by topic in first-seen order; a repeated (PR, topic) entry counts once."""
    topics: dict[str, list[str]] = {}
    seen: set[tuple[str, str]] = set()
    for line in lines:
        match = ENTRY_RE.match(line.strip())
        if not match:
            continue
        pr, body = match.group(1) or "", match.group(2)
        topic = topic_of(body)
        if pr and (pr, topic) in seen:
            continue
        seen.add((pr, topic))
        topics.setdefault(topic, []).append(pr)
    return list(topics.items())


def render(groups: list[tuple[str, list[str]]]) -> str:
    total = sum(len(prs) for _, prs in groups)
    rows = []
    for topic, prs in groups[:MAX_TOPICS]:
        numbers = ", ".join(pr for pr in prs if pr)
        rows.append(f"• {topic} — {len(prs)}" + (f" ({numbers})" if numbers else ""))
    rest = groups[MAX_TOPICS:]
    if rest:
        rows.append(f"• и ещё тем: {len(rest)}, исправлений: {sum(len(prs) for _, prs in rest)}")
    text = "\n".join(
        [f"🔒 Исправления защиты IWE: {total}", "", "В шаблон влиты исправления защиты:", *rows, "",
         HOW_TO_ACT, "", f"Подробности — в журнале изменений: {CHANGELOG_URL}"]
    )
    # Topic and PR caps keep the text far below the limit; a breach is a builder bug, not a cut.
    if len(text) > MAX_MESSAGE_CHARS:
        raise ValueError(f"security notice is {len(text)} characters, limit {MAX_MESSAGE_CHARS}")
    return text


def main() -> int:
    groups = parse(sys.stdin.read().splitlines())
    if not groups:
        print("security-notice-build: no [security] entries on stdin", file=sys.stderr)
        return 1
    print(render(groups))
    return 0


if __name__ == "__main__":
    sys.exit(main())
