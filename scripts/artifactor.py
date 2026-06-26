#!/usr/bin/env python3
"""Keyword-fast classifier for /artifactor.

Exit contract:
  0 -> stdout JSON
  1 -> stdout INSUFFICIENT_INPUT
  2 -> stdout NO_KEYWORD_MATCH
"""

from __future__ import annotations

import json
import re
import sys
from dataclasses import dataclass


@dataclass(frozen=True)
class Rule:
    keywords: tuple[str, ...]
    task_type: str
    klass: str
    artifact: str
    budget: str


RULES: tuple[Rule, ...] = (
    Rule(("day open", "day-open", "открыть день", "открывай день"), "day_open", "trivial", "План дня", "~0.5h"),
    Rule(("day close", "day-close", "закрыть день", "закрой день"), "day_close", "trivial", "Отчёт дня", "~0.5h"),
    Rule(("week close", "week-close", "закрыть неделю", "закрой неделю"), "week_close", "trivial", "Отчёт недели", "~0.5h"),
    Rule(("month close", "month-close", "закрыть месяц", "закрой месяц"), "month_close", "trivial", "Отчёт месяца", "~0.5h"),
    Rule(("verify", "верифиц", "проверь по чеклист", "проверка по чеклист"), "verify", "closed-loop", "Отчёт верификации", "~2h"),
    Rule(("audit", "аудит", "проаудируй", "проверить документац"), "audit", "closed-loop", "Отчёт аудита", "~2h"),
    Rule(("bug", "ошибка", "баг", "почини", "исправь", "исправить", "не работает", "падает"), "bug_fix", "closed-loop", "Исправление ошибки", "~2h"),
    Rule(("refactor", "рефактор", "почисти код", "упростить код"), "refactor", "closed-loop", "Рефакторинг кода", "~2h"),
    Rule(("создай скилл", "новый скилл", "skill-creator"), "skill_creation", "open-loop", "Новый скилл", "~3h"),
    Rule(("pack", "новый пак", "создай пак", "pack-new"), "pack_creation", "open-loop", "Паспорт предметной области", "~3h"),
    Rule(("стратег", "стратегичес", "приоритет", "что важно"), "strategy_session", "problem-framing", "Стратегическая рамка", "?"),
    Rule(("разбери", "исследуй", "разобраться", "понять почему"), "investigation", "open-loop", "Отчёт исследования", "~3h"),
)


def normalize(text: str) -> str:
    return " ".join(text.lower().replace("ё", "е").split())


def word_count(text: str) -> int:
    return len(re.findall(r"[\w/-]+", text, flags=re.UNICODE))


def emit(rule: Rule) -> None:
    payload = {
        "task_type": rule.task_type,
        "class": rule.klass,
        "artifact": rule.artifact,
        "budget_estimate": rule.budget,
        "confidence": "high",
        "routing_tag": rule.task_type,
        "resolution_path": "keyword",
    }
    print(json.dumps(payload, ensure_ascii=False))


def main(argv: list[str]) -> int:
    if any(arg in {"-h", "--help"} for arg in argv):
        print("Usage: artifactor.py '<raw pilot request>'")
        return 0

    request = " ".join(argv).strip()
    if word_count(request) < 5:
        print("INSUFFICIENT_INPUT")
        return 1

    text = normalize(request)
    for rule in RULES:
        if any(keyword in text for keyword in rule.keywords):
            emit(rule)
            return 0

    print("NO_KEYWORD_MATCH")
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
