#!/usr/bin/env python3
# see DP.SC.160, DP.ROLE.058
"""
Keyword-based task classifier for IWE Artifactor skill.

Exit codes:
  0 — keyword match, JSON on stdout (schema_version 3, WP-575 Ф2)
  1 — INSUFFICIENT_INPUT (< 5 words)
  2 — NO_KEYWORD_MATCH (needs LLM fallback)
  3 — CONFIG_ERROR (PACK-digital-platform установлен, но result-kinds-registry.yaml
      в нём не читается/пуст/повреждён — fail-closed, не тихий откат к schema 1.
      Если PACK-digital-platform целиком не установлен — issue #1231, штатно для
      обычной установки шаблона — это не CONFIG_ERROR, а result_kind_resolution:
      "unresolved" с expected_result_kind: None)

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

result_type (WP-575 Ф2, hard-distinctions.md №36, консенсус пир-сессии
2026-09-11-14-wp575-artefaktor-tip с Codex): "system" | "episteme" | "unresolved" —
Исполнитель (агент/скрипт/сервис — действующее) vs Информационный объект
(документ/знание/правило — читаемое). Независимая ось от kind_id — пятый
элемент кортежа KEYWORD_MAP, курируется вручную по смыслу КАЖДОЙ ЗАПИСИ
(один task_type может встречаться с разным result_type у разных ключевых
слов — например "миграция" и "реализация плана" оба дают task_type
wp_implement, но result_type "system" и "unresolved" соответственно, т.к.
результат зависит от конкретной фразы, не только от task_type). НЕ
выводится из kind_id runtime-вычислением (кортеж kind_id/task_type/class
присваивается ОДНОВРЕМЕННО в той же записи, значит вывод из него нарушил бы
требование «раньше имени и класса»; проверка: WorkDone-записи расходятся по
result_type — day_open=episteme, bot_fix=system — значит оси не совпадают).
"unresolved" — тип неочевиден по смыслу самого task_type (пример: wp_finish/
wp_close/wp_implement из "миграция" исключение — там результат может быть
и кодом, и документом в зависимости от конкретного РП) — форсирует уточнение
у пилота на WP Gate, не угадывается (тот же принцип, что hypothesis_relation:
"unclassified").
"""

import os
import sys
import json
import re

# The registry is a sibling repository PACK-digital-platform (see the same resolution
# pattern in DS-strategy/scripts/check-result-kind.py). IWE_ROOT: explicit env
# override, otherwise the parent of this file two levels above scripts/
# (standard layout {{WORKSPACE_DIR}}/scripts/artifactor.py next to {{WORKSPACE_DIR}}/PACK-digital-platform).
PACK_ROOT_REL = "PACK-digital-platform"
PACK_REGISTRY_REL = os.path.join(
    PACK_ROOT_REL, "pack", "digital-platform", "result-kinds-registry.yaml"
)
KIND_ID_LINE_RE = re.compile(r"^\s+-\s+kind_id:\s*(\S+)\s*$")


class RegistryPackMissing(Exception):
    """PACK-digital-platform сам не установлен — issue #1231: авторский Pack не
    входит в шаблон, значит это штатное состояние обычной установки, не порча."""


def resolve_iwe_root():
    return os.environ.get("IWE_ROOT") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def resolve_registry_path():
    return os.path.join(resolve_iwe_root(), PACK_REGISTRY_REL)


def load_registry_kind_ids():
    """Line-based, stdlib-only извлечение множества kind_id (без gate_ready —
    это забота /verify, не классификатора). Возвращает set() или None при
    ошибке чтения/порче файла (вызывающий код решает, CONFIG_ERROR это или
    нет). Поднимает RegistryPackMissing, если PACK-digital-platform целиком
    не установлен — это отдельный от порчи случай (issue #1231): Pack
    авторский и в шаблон не входит, у обычного пользователя его нет."""
    path = resolve_registry_path()
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.readlines()
    except FileNotFoundError:
        pack_root = os.path.join(resolve_iwe_root(), PACK_ROOT_REL)
        if not os.path.isdir(pack_root):
            raise RegistryPackMissing(pack_root) from None
        return None  # Pack is installed but the registry file is missing from it -- corruption, CONFIG_ERROR
    except OSError:
        return None
    ids = {m.group(1) for line in lines if (m := KIND_ID_LINE_RE.match(line))}
    return ids or None

# The third element is the expected kind_id (WP-481 Phase 7), the fourth is the
# artifact name, the fifth is result_type (WP-575 Phase 2: "system" | "episteme" |
# "unresolved", see the module docstring). All values live in one map:
# separate parallel dictionaries would silently drift from the routing.
# None/"unresolved" + an entry in SPECIAL_RESOLUTION are for deliberate exceptions
# (peer_session, spec_writing, and entries with an ambiguous result_type), not
# "forgot to fill in".
KEYWORD_MAP = {
    # trivial -- WorkDone: a deterministic trace of a completed protocol
    "day-open": ("day_open", "trivial", "WorkDone", "План дня", "episteme"),
    "day open": ("day_open", "trivial", "WorkDone", "План дня", "episteme"),
    "открывай день": ("day_open", "trivial", "WorkDone", "План дня", "episteme"),
    "week-close": ("week_close", "trivial", "WorkDone", "Итоги недели", "episteme"),
    "week close": ("week_close", "trivial", "WorkDone", "Итоги недели", "episteme"),
    "закрывай неделю": ("week_close", "trivial", "WorkDone", "Итоги недели", "episteme"),
    "month-close": ("month_close", "trivial", "WorkDone", "Итоги месяца", "episteme"),
    "пир-сесси": ("peer_session", "trivial", None, "Отчёт пир-сессии", "unresolved"),  # stem matches «пир-сессия/-ии/-ию/-ией»; SPECIAL_RESOLUTION: deferred-to-session; result_type тоже неизвестен до Decision Gate внутри сессии
    "пир сесси": ("peer_session", "trivial", None, "Отчёт пир-сессии", "unresolved"),
    # closed-loop
    "бот упал": ("bot_fix", "closed-loop", "WorkDone", "Бот", "system"),
    "ошибк бота": ("bot_fix", "closed-loop", "WorkDone", "Бот", "system"),     # matches «ошибка» and «ошибки»
    "фиксы": ("bug_fix", "closed-loop", "WorkDone", "Патч кода", "system"),
    "устранить": ("bug_fix", "closed-loop", "WorkDone", "Патч кода", "system"),
    "доделать рп": ("wp_finish", "closed-loop", "WorkDone", "Файлы фазы РП", "unresolved"),  # the result depends on the specific WP -- code or a document
    "хвосты рп": ("wp_finish", "closed-loop", "WorkDone", "Файлы фазы РП", "unresolved"),
    "закрыть рп": ("wp_close", "closed-loop", "WorkDone", "Отчёт о закрытии РП", "unresolved"),
    "передать андрею": ("wp_close", "closed-loop", "WorkDone", "Файлы РП", "unresolved"),
    "актуализация wp": ("wp_actualize", "closed-loop", "WorkDone", "Карточка РП", "episteme"),
    "ревью рп": ("code_review", "closed-loop", "Episteme", "Отчёт ревью", "episteme"),
    "ревью работы": ("code_review", "closed-loop", "Episteme", "Отчёт ревью", "episteme"),
    "разбор ke": ("ke_review", "closed-loop", "ChoiceResult", "Решение по кандидатам знаний", "episteme"),  # R15 accept/reject/defer, not a graph of claims
    "триаж": ("wp_triage", "closed-loop", "ChoiceResult", "Решение по триажу РП", "episteme"),
    "реализация плана": ("wp_implement", "closed-loop", "WorkDone", "Рабочие пакеты из плана", "unresolved"),  # the plan already existed; WPs appear, as code or a document
    "миграция": ("wp_implement", "closed-loop", "WorkDone", "Данные в целевом контуре", "system"),
    "создай pack": ("pack_create", "closed-loop", "Episteme", "Паспорт Pack", "episteme"),
    "новый pack": ("pack_create", "closed-loop", "Episteme", "Паспорт Pack", "episteme"),
    "ротация секретов": ("ops_security", "closed-loop", "WorkDone", "Секреты в хранилище", "system"),
    "fmt remaining": ("fmt_deploy", "closed-loop", "WorkDone", "Файлы шаблона FMT", "system"),
    # open-loop
    "диагностика": ("diagnosis", "open-loop", "Episteme", "Отчёт диагностики", "episteme"),
    "темы для пост": ("content_plan", "open-loop", "ChoiceResult", "План публикаций", "episteme"),   # matches «поста» and «постов»; выбор темы+аудитории+дня, не просто перечень
    "темы, идеи": ("content_plan", "open-loop", "ChoiceResult", "План публикаций", "episteme"),
    "темы идеи": ("content_plan", "open-loop", "ChoiceResult", "План публикаций", "episteme"),
    "сценарии тз": ("spec_writing", "open-loop", None, "Задание на сценарии", "episteme"),  # SPECIAL_RESOLUTION: unresolved kind — ни один из 6 kind-ов не подходит (найдено на WP-421); result_type при этом однозначен (документ)
    "стратег": ("strategy", "open-loop", "ChoiceResult", "Документ стратегии", "episteme"),
    # problem-framing
    "придумать": ("design", "problem-framing", "ProblemCard", "Карточка проблемы", "episteme"),
    "что-то с": ("design", "problem-framing", "ProblemCard", "Карточка проблемы", "episteme"),
    "надо что-то": ("design", "problem-framing", "ProblemCard", "Карточка проблемы", "episteme"),
}

VALID_RESULT_TYPES = ("system", "episteme", "unresolved")
for _kw, _entry in KEYWORD_MAP.items():
    if _entry[4] not in VALID_RESULT_TYPES:
        raise AssertionError(f"KEYWORD_MAP[{_kw!r}]: invalid result_type {_entry[4]!r}")
del _kw, _entry

# task_type → why expected_result_kind = None. The only legitimate
# ground for None is one of these two reasons, not "forgot to decide".
SPECIAL_RESOLUTION = {
    "peer_session": "deferred-to-session",  # a meta-trigger for starting a process, the kind is decided at the Decision Gate inside the session
    "spec_writing": "unresolved",           # none of the 6 kinds covers it -- do not substitute the nearest one (anti-leak into a supertype)
}

BUDGET_BY_CLASS = {
    "trivial": "~0.5h",
    "closed-loop": "~2h",
    "open-loop": "~3h",
    "problem-framing": "?",
}


def classify(
    text: str,
) -> tuple[str, str, str | None, str, str] | tuple[None, None, None, None, None]:
    """Return (task_type, cls, kind_id, artifact, result_type) or five None values.

    kind_id may be None (see SPECIAL_RESOLUTION) even when task_type matched.
    """
    lower = text.lower()
    for kw, (task_type, cls, kind_id, artifact, result_type) in KEYWORD_MAP.items():
        if kw in lower:
            return task_type, cls, kind_id, artifact, result_type
    return None, None, None, None, None


def resolve_result_kind(task_type: str, kind_id: str | None) -> tuple[str | None, str]:
    """Проверить kind_id членством в живом реестре (ловит дрейф KEYWORD_MAP
    vs реестра, не только доверяет хардкоду). Возвращает (expected_result_kind,
    result_kind_resolution). PACK-digital-platform не установлен (issue #1231,
    штатно для обычной установки шаблона) → result_kind_resolution: "unresolved".
    Pack установлен, но реестр в нём нечитаем/пуст/повреждён → CONFIG_ERROR
    (exit 3), не тихий откат к schema 1 — тот же fail-closed принцип, что в
    check-result-kind.py."""
    if kind_id is None:
        reason = SPECIAL_RESOLUTION.get(task_type)
        if reason is None:
            raise AssertionError(f"KEYWORD_MAP: {task_type!r} имеет kind_id=None без записи в SPECIAL_RESOLUTION")
        return None, reason

    try:
        registry_ids = load_registry_kind_ids()
    except RegistryPackMissing as exc:
        print(
            f"WARNING: PACK-digital-platform не установлен ({exc}) — "
            "expected_result_kind не резолвится, result_kind_resolution=unresolved",
            file=sys.stderr,
        )
        return None, "unresolved"
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
    task_type, cls, kind_id, artifact, result_type = classify(text)
    if task_type is not None:
        expected_result_kind, result_kind_resolution = resolve_result_kind(task_type, kind_id)
        result = {
            "task_type": task_type,
            "class": cls,
            "artifact": artifact,
            "budget_estimate": BUDGET_BY_CLASS.get(cls, "?"),
            "confidence": "high",
            "routing_tag": task_type,
            "resolution_path": "keyword",
            "schema_version": 3,
            "result_type": result_type,
            "expected_result_kind": expected_result_kind,
            "result_kind_resolution": result_kind_resolution,
            # The strategic link is not derived from keywords: the Artifactor
            # passes the mandatory question to the WP Gate, and does not assign an H-NNN.
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
