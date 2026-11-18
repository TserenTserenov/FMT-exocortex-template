#!/usr/bin/env python3
# see DP.SC.160, DP.ROLE.058
"""
Keyword-based task classifier for IWE Artifactor skill.

Exit codes:
  0 — keyword match, JSON on stdout (schema_version 4, WP-575 Ф4)
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

pair_link (WP-575 Ф4, пир-сессия 2026-10-27-06 с Kimi и Codex): связка «документ ↔
производящая система». Документ называет производителя (сессию пилота или
систему), система называет наблюдаемый результат срабатывания. Проверка идёт по
ЗАКАЗАННОМУ результату и по предмету приёмки, а не по всем его будущим экземплярам.
Keyword-путь не рассуждает, поэтому всегда возвращает status
"agent_check_required": потребитель (wp-new) сам проверяет связку по тексту
запроса. Остальные статусы заполняет только LLM-путь скилла (Шаг 2.1).
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

# Statuses of the document <-> producer link (WP-575 Phase 4). Blocking for
# work-product registration: mismatch, needs_result, unresolved (the consumer decides).
VALID_PAIR_STATUSES = (
    "ok",
    "mismatch",
    "recurring_no_producer",
    "needs_result",
    "unresolved",
    "agent_check_required",
)

# The keyword path does not reason: the consumer checks the link against the request text.
KEYWORD_PAIR_LINK = {"status": "agent_check_required", "producer": None, "output": None}

# --- Hard check of the name against the concept-kinds registry (WP-575 Phase 5) ---
# Pilot decision 27.10: block everything the registry did not confirm; the only bypass
# is the --registry-waiver flag of create-wp.sh with a reason in the card.
# A system is compatible with one kind only, "system" (registry rule: only it is called
# a system); a document with description, document, work plan, collection.
# Without the PACK-digital-platform directory and without CONCEPT_KINDS_REGISTRY the
# check is skipped (code 0, "no-pack"): the registry ships with the author's Pack, not
# with the template, the same distinction as issue #1231 makes for the result-kinds registry.
REGISTRY_COMPAT = {
    "system": ("system",),
    "episteme": ("description", "document", "work_plan", "collection"),
}
# A name should start with a noun, the subject of the result (pilot's wish 27.10).
# A first word that is an adjective, pronoun, number, preposition, conjunction or prefix
# («Системный журнал», «Нового реестр», «Для реестра», «Мини реестр») gives a warning
# and requires the AI's answer about the subject of the result; it is not a refusal: the lists
# of endings and function words are incomplete and misfire on nouns («Описание», «Решение», «Пост», «Слой»).
INTRODUCTORY_WORDS = frozenset((
    # pronouns and determiners
    "мой", "моя", "моё", "мои", "наш", "наша", "наше", "наши", "ваш", "ваша", "ваше", "ваши",
    "свой", "своя", "своё", "свои", "этот", "эта", "это", "эти", "тот", "та", "то", "те",
    "один", "одна", "одно", "одни", "весь", "вся", "всё", "все", "всех", "каждый", "любой", "такой",
    "его", "её", "ее", "их", "сам", "сама", "само", "сами", "какой", "какая", "какое", "какие",
    # numerals spelled out
    "два", "две", "три", "четыре", "пять", "шесть", "семь", "восемь", "девять", "десять", "сто",
    "двух", "трёх", "трех", "первый", "второй", "третий",
    # prepositions, conjunctions, particles
    "для", "по", "из", "в", "на", "с", "со", "к", "о", "об", "от", "при", "без", "через", "между",
    "над", "под", "за", "у", "про", "не", "что", "как", "ещё", "еще", "или", "и", "либо", "а", "но",
    # prefixes written as a separate word
    "мини", "микро", "мета", "супер", "ультра", "авто", "пост", "пре", "нано", "макро", "псевдо",
    "квази", "анти", "мульти",
))
# Adjective endings, oblique forms included. Endings that nouns often have
# (им, ем, ом, ым: «режим», «дым») are deliberately left out.
ADJECTIVE_END_RE = re.compile(r"(?:ый|ий|ой|ая|яя|ое|ее|ую|юю|ые|ие|ого|его|ому|ему|ых|их|ыми|ими)$")
NUMERAL_RE = re.compile(r"^\d+(?:-[а-яa-z]+)?$", re.IGNORECASE)
WORD_RE = re.compile(r"[а-яёa-z0-9]+(?:-[а-яёa-z0-9]+)*", re.IGNORECASE)


def load_concept_kinds():
    """Модуль поиска рода (имя файла с дефисом — грузим по пути). Нет PyYAML или
    реестра — исключение: вызывающий превращает его в блок (fail-closed)."""
    import importlib.util

    os.environ.setdefault(
        "CONCEPT_KINDS_REGISTRY",
        os.path.join(resolve_iwe_root(), PACK_ROOT_REL, "pack", "digital-platform",
                     "concept-kinds-registry.yaml"),
    )
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "concept-kind.py")
    spec = importlib.util.spec_from_file_location("concept_kind", path)
    module = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(module)  # without PyYAML the module exits via SystemExit(0)
    except SystemExit as exc:
        raise RuntimeError("нет модуля PyYAML для чтения реестра понятий") from exc
    return module


def name_words(name: str) -> list[str]:
    """Слова всего названия в нижнем регистре. Знаки препинания, скобки и кавычки слова
    не скрывают: голову ищет pick_head, а не обрезка по запятой."""
    return WORD_RE.findall(name.lower())


COORDINATORS = ("и", "или", "либо")


def introductory_word(word: str) -> bool:
    """Слово, с которого название начинаться не должно (не существительное-предмет)."""
    return bool(word in INTRODUCTORY_WORDS or ADJECTIVE_END_RE.search(word) or NUMERAL_RE.match(word))


def stem_remainder(term: dict, word: str) -> int:
    """Сколько букв слова остаётся после основы записи реестра (0 — основа и есть слово)."""
    ends = [re.match(stem, word).end() for stem in term.get("stems") or [] if re.match(stem, word)]
    return len(word) - max(ends) if ends else len(word)


def close_kind_by_name(data: dict, word: str) -> dict | None:
    """Род, чьё название слово повторяет почти точно (падежное окончание, не суффикс
    прилагательного: «описание» — да, «системный» — нет). Как kind_by_name утилиты, но строже."""
    for kind in data["kinds"]:
        if kind["id"] == "ambiguous":
            continue
        head = kind["name"].split()[0]
        prefix = head[:-1] if len(head) > 4 else head[:3]
        if word.startswith(prefix) and len(word) - len(prefix) <= 1:
            return kind
    return None


def ai_verdict(known_kinds, head, outcome, why, result_type, compatible, ai):
    """Слова нет в реестре или оно неоднозначно: решает ИИ по проверочному вопросу
    рода, ответ обязателен и пишется в карточку. Неуверенность (флаг ИИ или
    неоднозначность в реестре) уходит пилоту: без его решения РП не создаётся."""
    kind = (ai.get("kind") or "").strip()
    if not kind:
        return 4, f"{why}; нужен ответ ИИ на проверочный вопрос рода (род и обоснование)"
    if kind not in known_kinds:
        return 4, f"род «{kind}» не из реестра (допустимы: {', '.join(sorted(known_kinds))})"
    if kind not in compatible:
        return 4, f"ответ ИИ: слово «{head}» — род «{kind}», а результат — {result_type} (допустимо: {', '.join(compatible)})"
    answer = (ai.get("answer") or "").strip()
    if not answer:
        return 4, f"нет ответа на проверочный вопрос рода «{kind}»"
    if ai.get("unsure") or outcome == "ambiguous":
        pilot = (ai.get("pilot") or "").strip()
        if not pilot:
            return 5, f"{why}; ИИ не уверен, что «{head}» — род «{kind}»: нужно решение пилота"
        return 0, f"pilot {head}/{kind}: {pilot}"
    return 0, f"ai {head}/{kind}: {answer}"


def registry_verdict(ck, data, digest, name, result_type, compatible, ai):
    """Вердикт по загруженному реестру: (код, пояснение). Любое исключение отсюда
    превращает check_registry в закрытый отказ."""
    words = name_words(name)
    warning = None
    if not words:
        head, outcome, why = "", "ambiguous", "в названии нет слов, по которым можно найти голову"
    else:
        head = words[0]
        warning = None
        if introductory_word(head):
            warning = (f"название начинается не с существительного, а с «{head}»: лучше назвать предмет "
                       f"результата первым словом (не «Системный журнал», а «Журнал системы»)")
        if words[1:2] and words[1] in COORDINATORS:
            outcome, why = "ambiguous", f"составная голова «{' '.join(words[:4])}» не разобрана"
        else:
            # Ask the registry first: «Описание», «Решение» look like adjectives by their
            # ending, but the registry knows their kind, and a conflict with the result type stays hard.
            hits = ck.term_kind(data, head)
            if warning:  # «системный», «платформенный» only start like a registry word
                hits = [t for t in hits if stem_remainder(t, head) <= 2]
            kinds = sorted({t["kind"] for t in hits})
            by_name = close_kind_by_name if warning else ck.kind_by_name
            named_kind = None if hits else by_name(data, head)  # «Система …», «Описание …» (the kind's own name)
            if named_kind is not None:
                hits, kinds = [{"term": named_kind["name"]}], [named_kind["id"]]
            if not hits:
                outcome = "modifier" if warning else "miss"
                why = warning or f"слова «{head}» нет в реестре понятий и родов"
            elif len(kinds) > 1 or kinds == ["ambiguous"]:
                outcome, why = "ambiguous", f"слово «{head}» неоднозначно в реестре ({', '.join(kinds)})"
            elif kinds[0] not in compatible:
                outcome = "conflict"
                why = f"слово «{head}» — род «{kinds[0]}», а результат — {result_type} (допустимо: {', '.join(compatible)})"
            else:
                outcome, why = "hit", f"{hits[0]['term']}/{kinds[0]}"
    if outcome == "hit":
        code, text = 0, f"registry {why}" + (f" ⚠ {warning}" if warning else "")
    elif outcome == "conflict":
        code, text = 4, why
    else:
        known = {k for k in ck.kind_index(data) if k != "ambiguous"}
        code, text = ai_verdict(known, head, outcome, why, result_type, compatible, ai)
        if code == 0 and outcome == "modifier":
            text += f" ⚠ {why}"  # a warning, not a refusal: the AI's answer decides
    ck.log("artifactor", digest, "gate", head, f"{outcome}->{code}", ai.get("kind") or result_type)
    return code, text


def check_registry(result: dict, title: str | None = None, ai: dict | None = None) -> tuple[int, str]:
    """(код, пояснение): 0 — пропущено, 4 — блок, 5 — нужно решение пилота.
    Блок без обхода — только когда реестр знает слово и род противоречит типу результата.
    Пак PACK-digital-platform не установлен и CONCEPT_KINDS_REGISTRY не задан — сверки
    нет (0, «no-pack»), как в issue #1231. Пак есть, а реестр не читается или имеет
    неожиданную структуру — закрытый отказ (4), не трассировка."""
    name = title or result.get("artifact") or ""
    result_type = result.get("result_type")
    compatible = REGISTRY_COMPAT.get(result_type)
    if compatible is None:
        return 4, f"тип результата «{result_type}» не определён (нужен system или episteme)"
    # checked before load_concept_kinds(): without the Pack there is nothing to import or read
    if not os.environ.get("CONCEPT_KINDS_REGISTRY") and not os.path.isdir(
        os.path.join(resolve_iwe_root(), PACK_ROOT_REL)
    ):
        return 0, f"no-pack {PACK_ROOT_REL} не установлен — сверка названия с реестром понятий пропущена"
    try:
        ck = load_concept_kinds()
        data, digest = ck.load()
    except Exception as exc:  # noqa: BLE001 -- any load failure is a refusal, the lock does not open
        return 4, f"реестр понятий не читается или повреждён ({type(exc).__name__}: {exc})"
    try:
        return registry_verdict(ck, data, digest, name, result_type, compatible, ai or {})
    except Exception as exc:  # noqa: BLE001 -- the check's own error must not open the lock
        return 4, f"внутренняя ошибка проверки названия ({type(exc).__name__}: {exc}); реестр загружен"


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


def producer_advice(result: dict, producer: str | None) -> str | None:
    """Рекомендательная (не блокирующая) подсказка для документа: его создаёт
    система, в простом случае — сессия пилота с агентом. Подсказки нет, если
    результат не документ или производитель уже назван (WP-575 Ф5)."""
    if result.get("result_type") != "episteme" or (producer or "").strip():
        return None
    return (
        "Документ не появляется сам: его создаёт система (в простом случае — ваша сессия с агентом). "
        "Назовите производителя флагом --producer: «session» или имя существующей системы. "
        "Если такие документы нужны регулярно, а системы нет, подумайте о системе-производителе отдельным РП."
    )


def run_advice(args: list[str]) -> None:
    """artifactor.py --advice <result.json> [--producer П]: печатает подсказку или ничего; всегда код 0."""
    producer = args[args.index("--producer") + 1] if "--producer" in args and args.index("--producer") + 1 < len(args) else None
    try:
        with open(args[0], encoding="utf-8") as fh:
            advice = producer_advice(json.load(fh), producer)
    except (OSError, json.JSONDecodeError):
        advice = None  # no readable result, nothing to advise: the lock would have refused above
    if advice:
        print(advice)
    sys.exit(0)


def run_registry_check(args: list[str]) -> None:
    """artifactor.py --check-registry <result.json> [--title Т] [--ai-kind К --ai-answer О
    [--ai-unsure] [--pilot-decision Р]]: 0 — REGISTRY_OK <источник> <запись>,
    4 — REGISTRY_BLOCK <причина>, 5 — REGISTRY_ASK <вопрос к пилоту>."""
    def option(flag):
        return args[args.index(flag) + 1] if flag in args and args.index(flag) + 1 < len(args) else None

    ai = {
        "kind": option("--ai-kind"),
        "answer": option("--ai-answer"),
        "unsure": "--ai-unsure" in args,
        "pilot": option("--pilot-decision"),
    }
    try:
        with open(args[0], encoding="utf-8") as fh:
            result = json.load(fh)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"REGISTRY_BLOCK результат Артефактора не читается ({exc})")
        sys.exit(4)
    code, detail = check_registry(result, option("--title"), ai)
    label = {0: "OK", 4: "BLOCK", 5: "ASK"}[code]
    print(f"REGISTRY_{label} {detail}")
    sys.exit(code)


def main() -> None:
    if len(sys.argv) > 2 and sys.argv[1] == "--check-registry":
        run_registry_check(sys.argv[2:])
    if len(sys.argv) > 2 and sys.argv[1] == "--advice":
        run_advice(sys.argv[2:])
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
            "schema_version": 4,
            "result_type": result_type,
            "pair_link": dict(KEYWORD_PAIR_LINK),
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
