#!/usr/bin/env python3
# see DP.SC.160, DP.ROLE.058
"""
Keyword-based task classifier for IWE Artifactor skill.

Exit codes:
  0 — keyword match, JSON on stdout
  1 — INSUFFICIENT_INPUT (< 5 words)
  2 — NO_KEYWORD_MATCH (needs LLM fallback)
"""

import sys
import json

KEYWORD_MAP = {
    # trivial
    "day-open": ("day_open", "trivial"),
    "day open": ("day_open", "trivial"),
    "открывай день": ("day_open", "trivial"),
    "week-close": ("week_close", "trivial"),
    "week close": ("week_close", "trivial"),
    "закрывай неделю": ("week_close", "trivial"),
    "month-close": ("month_close", "trivial"),
    "peer-сессия": ("peer_session", "trivial"),
    "peer сессия": ("peer_session", "trivial"),
    # closed-loop
    "бот упал": ("bot_fix", "closed-loop"),
    "ошибк бота": ("bot_fix", "closed-loop"),     # matches «ошибка» and «ошибки»
    "фиксы": ("bug_fix", "closed-loop"),
    "устранить": ("bug_fix", "closed-loop"),
    "доделать рп": ("wp_finish", "closed-loop"),
    "хвосты рп": ("wp_finish", "closed-loop"),
    "закрыть рп": ("wp_close", "closed-loop"),
    "передать андрею": ("wp_close", "closed-loop"),
    "актуализация wp": ("wp_actualize", "closed-loop"),
    "ревью рп": ("code_review", "closed-loop"),
    "ревью работы": ("code_review", "closed-loop"),
    "разбор ke": ("ke_review", "closed-loop"),
    "триаж": ("wp_triage", "closed-loop"),
    "реализация плана": ("wp_implement", "closed-loop"),
    "миграция": ("wp_implement", "closed-loop"),
    "создай pack": ("pack_create", "closed-loop"),
    "новый pack": ("pack_create", "closed-loop"),
    "ротация секретов": ("ops_security", "closed-loop"),
    "fmt remaining": ("fmt_deploy", "closed-loop"),
    # open-loop
    "диагностика": ("diagnosis", "open-loop"),
    "темы для пост": ("content_plan", "open-loop"),   # matches «поста» and «постов»
    "темы, идеи": ("content_plan", "open-loop"),
    "темы идеи": ("content_plan", "open-loop"),
    "сценарии тз": ("spec_writing", "open-loop"),
    "стратег": ("strategy", "open-loop"),
    # problem-framing
    "придумать": ("design", "problem-framing"),
    "что-то с": ("design", "problem-framing"),
    "надо что-то": ("design", "problem-framing"),
}

BUDGET_BY_CLASS = {
    "trivial": "~0.5h",
    "closed-loop": "~2h",
    "open-loop": "~3h",
    "problem-framing": "?",
}


def classify(text: str) -> tuple[str, str]:
    """Return (task_type, cls) or (None, None)."""
    lower = text.lower()
    for kw, (task_type, cls) in KEYWORD_MAP.items():
        if kw in lower:
            return task_type, cls
    return None, None


def main() -> None:
    if len(sys.argv) > 1:
        text = " ".join(sys.argv[1:])
    else:
        text = sys.stdin.read()

    text = text.strip()

    # Keyword check first — short protocol triggers (e.g. "day-open") must be recognised
    # before the length guard fires.
    task_type, cls = classify(text)
    if task_type is not None:
        result = {
            "task_type": task_type,
            "class": cls,
            "artifact": "",
            "budget_estimate": BUDGET_BY_CLASS.get(cls, "?"),
            "confidence": "high",
            "routing_tag": task_type,
            "resolution_path": "keyword",
        }
        print(json.dumps(result, ensure_ascii=False))
        sys.exit(0)

    if len(text.split()) < 5:
        print("INSUFFICIENT_INPUT")
        sys.exit(1)

    print("NO_KEYWORD_MATCH")
    sys.exit(2)


if __name__ == "__main__":
    main()
