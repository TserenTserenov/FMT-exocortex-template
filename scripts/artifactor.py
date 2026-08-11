#!/usr/bin/env python3
# see DP.SC.160, DP.ROLE.058
"""
Keyword-based task classifier for IWE Artifactor skill.

Exit codes:
  0 — keyword match, JSON on stdout (schema_version 2, WP-481 Ф7 шаги 3-4)
  1 — INSUFFICIENT_INPUT (< 5 words)
  2 — NO_KEYWORD_MATCH (needs LLM fallback)
  3 — CONFIG_ERROR (result-kinds-registry.yaml в PACK-digital-platform
      не читается/повреждён — fail-closed, не тихий откат к schema 1)

expected_result_kind (WP-481 Ф7, консенсус пир-сессии
2026-08-05-14-codex-wp481-f7-impl): дискриминатор ожидаемого kind-а результата
из открытого реестра PACK-digital-platform/pack/digital-platform/
result-kinds-registry.yaml. Карта task_type → kind_id — третий элемент
кортежа в KEYWORD_MAP (не отдельный параллельный словарь, чтобы не разошлась
с ним), согласована построчно (не выводится из class — одному verification_class
соответствует несколько kind-ов). Отсутствие подходящего kind-а в реестре
(проверено на живом случае: spec_writing/«сценарии ТЗ» не равно
MethodDescription) → result_kind_resolution: "unresolved", НЕ подмена
ближайшим kind-ом (анти-утечка в супертип, тот же принцип, что в реестре).
peer_session — намеренно "deferred-to-session": мета-триггер старта процесса,
не заявка на конкретный результат (решается на Decision Gate внутри сессии).
"""

import os
import sys
import json
import re

# Реестр — сиблинг-репозиторий PACK-digital-platform (см. тот же паттерн
# резолва в DS-strategy/scripts/check-result-kind.py). IWE_ROOT: явный env
# override, иначе родитель этого файла на два уровня выше scripts/
# (штатная раскладка {{WORKSPACE_DIR}}/scripts/artifactor.py рядом с {{WORKSPACE_DIR}}/PACK-digital-platform).
PACK_REGISTRY_REL = os.path.join(
    "PACK-digital-platform", "pack", "digital-platform", "result-kinds-registry.yaml"
)
KIND_ID_LINE_RE = re.compile(r"^\s+-\s+kind_id:\s*(\S+)\s*$")


def resolve_registry_path():
    iwe_root = os.environ.get("IWE_ROOT") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    return os.path.join(iwe_root, PACK_REGISTRY_REL)


def load_registry_kind_ids():
    """Line-based, stdlib-only извлечение множества kind_id (без gate_ready —
    это забота /verify, не классификатора). Возвращает set() или None при
    отсутствии/ошибке чтения файла (вызывающий код решает, CONFIG_ERROR это
    или нет)."""
    path = resolve_registry_path()
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.readlines()
    except OSError:
        return None
    ids = {m.group(1) for line in lines if (m := KIND_ID_LINE_RE.match(line))}
    return ids or None

# Третий элемент — expected kind_id (WP-481 Ф7). Единственный источник карты
# task_type → kind_id: держать её здесь, не в параллельном словаре, который
# может разойтись с KEYWORD_MAP. None + запись в SPECIAL_RESOLUTION — для двух
# осознанных исключений (peer_session, spec_writing), не «забыли заполнить».
KEYWORD_MAP = {
    # trivial — WorkDone: детерминированный трейс завершённого протокола
    "day-open": ("day_open", "trivial", "WorkDone"),
    "day open": ("day_open", "trivial", "WorkDone"),
    "открывай день": ("day_open", "trivial", "WorkDone"),
    "week-close": ("week_close", "trivial", "WorkDone"),
    "week close": ("week_close", "trivial", "WorkDone"),
    "закрывай неделю": ("week_close", "trivial", "WorkDone"),
    "month-close": ("month_close", "trivial", "WorkDone"),
    "peer-сессия": ("peer_session", "trivial", None),  # SPECIAL_RESOLUTION: deferred-to-session
    "peer сессия": ("peer_session", "trivial", None),
    # closed-loop
    "бот упал": ("bot_fix", "closed-loop", "WorkDone"),
    "ошибк бота": ("bot_fix", "closed-loop", "WorkDone"),     # matches «ошибка» and «ошибки»
    "фиксы": ("bug_fix", "closed-loop", "WorkDone"),
    "устранить": ("bug_fix", "closed-loop", "WorkDone"),
    "доделать рп": ("wp_finish", "closed-loop", "WorkDone"),
    "хвосты рп": ("wp_finish", "closed-loop", "WorkDone"),
    "закрыть рп": ("wp_close", "closed-loop", "WorkDone"),
    "передать андрею": ("wp_close", "closed-loop", "WorkDone"),
    "актуализация wp": ("wp_actualize", "closed-loop", "WorkDone"),
    "ревью рп": ("code_review", "closed-loop", "Episteme"),
    "ревью работы": ("code_review", "closed-loop", "Episteme"),
    "разбор ke": ("ke_review", "closed-loop", "ChoiceResult"),  # R15 accept/reject/defer, не граф claim'ов
    "триаж": ("wp_triage", "closed-loop", "ChoiceResult"),
    "реализация плана": ("wp_implement", "closed-loop", "WorkDone"),
    "миграция": ("wp_implement", "closed-loop", "WorkDone"),
    "создай pack": ("pack_create", "closed-loop", "Episteme"),
    "новый pack": ("pack_create", "closed-loop", "Episteme"),
    "ротация секретов": ("ops_security", "closed-loop", "WorkDone"),
    "fmt remaining": ("fmt_deploy", "closed-loop", "WorkDone"),
    # open-loop
    "диагностика": ("diagnosis", "open-loop", "Episteme"),
    "темы для пост": ("content_plan", "open-loop", "ChoiceResult"),   # matches «поста» and «постов»; выбор темы+аудитории+дня, не просто перечень
    "темы, идеи": ("content_plan", "open-loop", "ChoiceResult"),
    "темы идеи": ("content_plan", "open-loop", "ChoiceResult"),
    "сценарии тз": ("spec_writing", "open-loop", None),  # SPECIAL_RESOLUTION: unresolved — ни один из 6 kind-ов не подходит (найдено на WP-421)
    "стратег": ("strategy", "open-loop", "ChoiceResult"),
    # problem-framing
    "придумать": ("design", "problem-framing", "ProblemCard"),
    "что-то с": ("design", "problem-framing", "ProblemCard"),
    "надо что-то": ("design", "problem-framing", "ProblemCard"),
}

# task_type → почему expected_result_kind = None. Единственное легитимное
# основание для None — одна из этих двух причин, не «забыли решить».
SPECIAL_RESOLUTION = {
    "peer_session": "deferred-to-session",  # мета-триггер старта процесса, kind решается на Decision Gate внутри сессии
    "spec_writing": "unresolved",           # ни один из 6 kind-ов не покрывает — не подменять ближайшим (анти-утечка в супертип)
}

BUDGET_BY_CLASS = {
    "trivial": "~0.5h",
    "closed-loop": "~2h",
    "open-loop": "~3h",
    "problem-framing": "?",
}


def classify(text: str) -> tuple[str, str, str]:
    """Return (task_type, cls, kind_id) or (None, None, None). kind_id may be
    None (see SPECIAL_RESOLUTION) even when task_type matched."""
    lower = text.lower()
    for kw, (task_type, cls, kind_id) in KEYWORD_MAP.items():
        if kw in lower:
            return task_type, cls, kind_id
    return None, None, None


def resolve_result_kind(task_type: str, kind_id: str | None) -> tuple[str | None, str]:
    """Проверить kind_id членством в живом реестре (ловит дрейф KEYWORD_MAP
    vs реестра, не только доверяет хардкоду). Возвращает (expected_result_kind,
    result_kind_resolution). Реестр нечитаем/пуст → CONFIG_ERROR (exit 3),
    не тихий откат к schema 1 — тот же fail-closed принцип, что в
    check-result-kind.py."""
    if kind_id is None:
        reason = SPECIAL_RESOLUTION.get(task_type)
        if reason is None:
            raise AssertionError(f"KEYWORD_MAP: {task_type!r} имеет kind_id=None без записи в SPECIAL_RESOLUTION")
        return None, reason

    registry_ids = load_registry_kind_ids()
    if registry_ids is None:
        print(
            f"CONFIG_ERROR: реестр не читается по {resolve_registry_path()} "
            f"(IWE_ROOT={os.environ.get('IWE_ROOT') or '<derived>'})",
            file=sys.stderr,
        )
        sys.exit(3)
    if kind_id not in registry_ids:
        print(
            f"CONFIG_ERROR: KEYWORD_MAP ссылается на kind_id {kind_id!r}, "
            f"которого нет в живом реестре ({sorted(registry_ids)}) — дрейф "
            f"artifactor.py vs result-kinds-registry.yaml",
            file=sys.stderr,
        )
        sys.exit(3)
    return kind_id, "static"


def main() -> None:
    if len(sys.argv) > 1:
        text = " ".join(sys.argv[1:])
    else:
        text = sys.stdin.read()

    text = text.strip()

    # Keyword check first — short protocol triggers (e.g. "day-open") must be recognised
    # before the length guard fires.
    task_type, cls, kind_id = classify(text)
    if task_type is not None:
        expected_result_kind, result_kind_resolution = resolve_result_kind(task_type, kind_id)
        result = {
            "task_type": task_type,
            "class": cls,
            "artifact": "",
            "budget_estimate": BUDGET_BY_CLASS.get(cls, "?"),
            "confidence": "high",
            "routing_tag": task_type,
            "resolution_path": "keyword",
            "schema_version": 2,
            "expected_result_kind": expected_result_kind,
            "result_kind_resolution": result_kind_resolution,
            # Стратегическая связь не выводится из ключевых слов: Артефактор
            # передаёт обязательный вопрос в WP Gate, а не приписывает H-NNN.
            "hypothesis_relation": "unclassified",
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
