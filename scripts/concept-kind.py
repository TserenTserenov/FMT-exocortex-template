#!/usr/bin/env python3
"""Look up the kind of a word, or check a text, against the concept-kind registry (РП-388 Ф27).

Source of truth: PACK-digital-platform/pack/digital-platform/concept-kinds-registry.yaml
(the same file build-concept-kinds-tsv.py copies for the A14 detector).

Usage:
  concept-kind.py lookup <word> [--claim <kind>]   kind, test question, basis of a word;
                                                   with --claim also prints the test of the
                                                   claimed kind (the word may be missing)
  concept-kind.py check-text <file|->              warnings on "X — это Y" sentences where Y
                                                   names a kind or a registry term, and on
                                                   part-of claims ("входит в", "часть",
                                                   "состоит из", table columns «Модуль»)
                                                   whose part is not a system

A miss means "kind not established". It is not a draft entry and not a reason to add the word
to the registry: new entries are decided by the pilot.

Every call appends one line to the consultation log (CONCEPT_KIND_LOG, default
~/.claude/logs/concept-kind.log): time, agent, registry hash, mode, query, outcome, claimed kind.
Agent: --agent, else IWE_AGENT / STYLE_AGENT, else "unknown".

Always exits 0 on a valid call: this is a nudge, never a gate.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

try:
    import yaml
except ImportError:
    print("concept-kind: пропуск (нет модуля PyYAML)", file=sys.stderr)
    sys.exit(0)

ROOT = Path(__file__).resolve().parent.parent
REGISTRY = Path(
    os.environ.get(
        "CONCEPT_KINDS_REGISTRY",
        ROOT
        / "PACK-digital-platform/pack/digital-platform/concept-kinds-registry.yaml",
    )
)
LOG = Path(
    os.environ.get("CONCEPT_KIND_LOG", Path.home() / ".claude/logs/concept-kind.log")
)

WORD_RE = re.compile(r"[а-яёa-z0-9]+(?:-[а-яёa-z0-9]+)*", re.IGNORECASE)
# "X — это Y", "X — это уже Y", "X — уже Y", "X — Y", "X, это Y", "X это Y".
CLAIM_RE = re.compile(
    r"(?P<x>[^.!?;:\n—–«»()]{2,120}?)\s*"
    r"(?:[—–]\s*(?P<dash_eto>это\s+)?|,?\s+(?P<eto>это)\s+)"
    r"(?:уже\s+)?(?:всего\s+лишь\s+|просто\s+)?(?P<neg>не\s+|не\s+является\s+)?"
    r"(?P<y>[а-яё]+)",
    re.IGNORECASE,
)
LEADING_FILLERS = {"а", "и", "но", "вот", "так", "то", "ведь", "же", "это"}
# A subject that opens with one of these is an adverbial or a clause, not a noun phrase.
NOT_A_SUBJECT = frozenset(
    [
        "как",
        "если",
        "когда",
        "потом",
        "тогда",
        "раньше",
        "теперь",
        "где",
        "что",
        "чтобы",
        "почему",
        "зачем",
        "сейчас",
        "сегодня",
        "здесь",
        "там",
        "не",
        "в",
        "во",
        "на",
        "из",
        "для",
        "по",
        "при",
        "после",
        "до",
        "с",
        "со",
        "от",
        "к",
        "у",
        "о",
        "об",
        "без",
        "через",
        "между",
    ]
)
# Verb forms ("работает", "работал") share a stem with the kind name "работа".
VERB_END_RE = re.compile(
    r"(?:ет|ют|ит|ят|ут|ать|ять|ить|ться|ется|ются|ал|ала|али|ил|ила|или|ся|сь)$"
)
# Adjectives ("методологическая") share a stem with nouns of the registry.
ADJ_END_RE = re.compile(r"(?:ая|яя|ое|ее|ий|ый|ой|ые|ие|ую|юю)$")
# A bare dash claim ("X — Y") is a definition only for a short noun phrase.
MAX_DASH_SUBJECT_WORDS = 4
CODE_RE = re.compile(r"```.*?```|`[^`\n]*`", re.DOTALL)
QUOTE_RE = re.compile(r"«[^»\n]*»")
# Headings and table rows use the dash as a separator, not as "is a".
LAYOUT_LINE_RE = re.compile(r"^\s*(?:#|\|).*$", re.MULTILINE)
LIST_MARK_RE = re.compile(r"^\s*(?:[-*+]|\d+\.)\s+", re.MULTILINE)

# Part-of claims: only a system is a part of a system (A14). Surface forms: "X входит в Y",
# "X — часть Y", "Y состоит из X, Z", "модули: X, Z" and table columns «Модуль», «Подсистема».
PART_SEGMENT = r"[^.!?;:\n—–«»()|]{2,120}?"
WHOLE = r"(?P<whole>[а-яёa-z][а-яёa-z0-9-]*)"
MEMBER_RE = re.compile(
    rf"(?P<part>{PART_SEGMENT})\s+(?:входит|входят|входил[аио]?)\s+в\s+(?:состав\s+)?{WHOLE}",
    re.IGNORECASE,
)
PART_RE = re.compile(
    rf"(?P<part>{PART_SEGMENT})\s*(?:[—–]\s*(?:это\s+)?|\s+явля[ею]тся\s+)част(?:ь|ью|и)\s+{WHOLE}",
    re.IGNORECASE,
)
CONSISTS_RE = re.compile(
    rf"{WHOLE}\s+состо(?:ит|ят)\s+из\s+(?P<parts>[^.!?;\n]{{2,200}})", re.IGNORECASE
)
SYSTEM_LIST_RE = re.compile(
    r"(?<![а-яё])(?:модули|подсистемы)\s*:\s*(?P<parts>[^.!?;\n]{2,200})", re.IGNORECASE
)
# Wholes that are systems by the pilot's decisions (02.11): a module is a program, database or
# server; the platform and IWE are systems. A step of a method or a work may be an action noun,
# a part of one of these may not.
SYSTEM_WHOLE_RE = re.compile(
    r"^(?:модул|подсистем|платформ|iwe|систем|программ|сервер|бот|шлюз|агент)",
    re.IGNORECASE,
)
PART_COLUMN_RE = re.compile(r"^(?:модул|подсистем|состав|част)", re.IGNORECASE)
SYSTEM_COLUMN_RE = re.compile(r"^(?:модул|подсистем)", re.IGNORECASE)
# Kinds that may be steps of a method or a work ("закрытие дня делится на два этапа").
STEP_KINDS = frozenset(["method", "work", "work_plan", "activity"])
ITEM_SPLIT_RE = re.compile(r",|;|\s+и\s+|<br>")
# A parenthesis in a table cell explains the part, it does not list more parts.
PAREN_RE = re.compile(r"\([^()]*\)")
# Nouns that name an action ("сборка руководств", "синхронизация", "якорение"): a work or
# a method, never a module. Generic -ние/-тие plus explicit stems for -ка and -ция nouns,
# because those endings also form system names ("площадка", "организация").
ACTION_NOUN_RE = re.compile(
    r"(?:[аеяо]ни[еяюй]|ти[еяю])$|^(?:сборк|проверк|доставк|сверк|выгрузк|загрузк|очистк|"
    r"рассылк|установк|настройк|отправк|обработк|разметк|подготовк|оценк|правк|"
    r"синхронизац|публикац|индексац|миграц|архивац|авторизац|верификац|валидац|"
    r"репликац|интеграц|классификац|агрегац|ротац|эскалац)",
    re.IGNORECASE,
)
# -ние words that still name a running system.
ACTION_NOUN_EXCEPTIONS = re.compile(
    r"^(?:приложени|окружени|здани|отделени|подразделени|учреждени|объединени)",
    re.IGNORECASE,
)


def load() -> tuple[dict, str]:
    raw = REGISTRY.read_bytes()
    data = yaml.safe_load(raw.decode("utf-8"))
    return data, hashlib.sha256(raw).hexdigest()[:12]


def kind_index(data: dict) -> dict[str, dict]:
    return {k["id"]: k for k in data["kinds"]}


def term_kind(data: dict, word: str) -> list[dict]:
    """Registry terms whose stem matches the start of the word (the detector's left boundary)."""
    word = word.lower()
    hits = []
    for term in data["terms"]:
        if any(re.match(stem, word) for stem in term.get("stems") or []):
            hits.append(term)
    return hits


def kind_by_name(data: dict, word: str) -> dict | None:
    """Kind whose name ("работа", "метод", ...) the word is an inflected form of."""
    word = word.lower()
    for kind in data["kinds"]:
        if kind["id"] == "ambiguous":
            continue
        head = kind["name"].split()[0]
        prefix = head[:-1] if len(head) > 4 else head[:3]
        if word.startswith(prefix) and len(word) - len(prefix) <= 3:
            return kind
    return None


def resolve_claim(data: dict, name: str) -> dict | None:
    kinds = kind_index(data)
    return kinds.get(name) or kind_by_name(data, name)


def log(
    agent: str, digest: str, mode: str, query: str, outcome: str, claim: str
) -> None:
    try:
        LOG.parent.mkdir(parents=True, exist_ok=True)
        stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")  # noqa: UP017 -- hooks may run macOS python3 3.9
        fields = [stamp, agent, digest, mode, query[:120], outcome, claim or "-"]
        line = "\t".join(" ".join(f.split()) for f in fields)
        with LOG.open("a", encoding="utf-8", errors="replace") as fh:
            fh.write(line + "\n")
    except OSError as err:
        print(f"concept-kind: журнал не записан ({err})", file=sys.stderr)


def describe_kind(kind: dict) -> str:
    return f"род «{kind['name']}» ({kind['id']}): {kind['test']}"


def lookup(data: dict, word: str, claim: str | None) -> tuple[str, list[str]]:
    kinds = kind_index(data)
    hits = term_kind(data, word)
    lines: list[str] = []
    if not hits:
        outcome = "miss"
        lines.append(
            f"«{word}»: в реестре нет — род не установлен (это не повод добавлять слово)."
        )
    elif len({t["kind"] for t in hits}) > 1:
        outcome = "ambiguous"
        lines.append(
            f"«{word}»: несколько записей — уточни, какой объект имеешь в виду:"
        )
        lines += [f"  - {t['term']} → {describe_kind(kinds[t['kind']])}" for t in hits]
    else:
        term = hits[0]
        outcome = "ambiguous" if term["kind"] == "ambiguous" else "hit"
        lines.append(
            f"«{word}» → запись «{term['term']}», {describe_kind(kinds[term['kind']])}"
        )
        lines.append(f"  основание: {term['basis']} (статус {term['status']})")
        for also in term.get("also") or []:
            lines.append(f"  также как {kinds[also['kind']]['name']}: {also['when']}")
        if term.get("prefer"):
            lines.append(f"  слово под уходом, говорить вместо него: {term['prefer']}")
    if claim:
        claimed = resolve_claim(data, claim)
        if claimed is None:
            lines.append(
                f"Заявленный род «{claim}» не найден. Роды: "
                + ", ".join(k["name"] for k in data["kinds"])
            )
        else:
            lines.append(
                f"Проверь «{word}» по вопросу заявленного рода — {describe_kind(claimed)}"
            )
    return outcome, lines


def strip_noise(text: str) -> str:
    text = CODE_RE.sub(" ", text)
    text = QUOTE_RE.sub(" ", text)
    text = LAYOUT_LINE_RE.sub(" ", text)
    return LIST_MARK_RE.sub("", text)


def subject_words(segment: str) -> list[str]:
    words = WORD_RE.findall(segment)
    while words and words[0].lower() in LEADING_FILLERS:
        words.pop(0)
    return words


def claimed_kind(data: dict, y: str) -> dict | None:
    """Kind asserted by the predicate word, or None when it names no single kind."""
    if VERB_END_RE.search(y.lower()) or ADJ_END_RE.search(y.lower()):
        return None
    kind = kind_by_name(data, y)
    if kind is not None:
        return kind
    y_terms = [t for t in term_kind(data, y) if t["kind"] != "ambiguous"]
    if len({t["kind"] for t in y_terms}) != 1:
        return None
    return kind_index(data)[y_terms[0]["kind"]]


def claim_subject(m: re.Match) -> list[str]:
    """Words of a noun-phrase subject, or [] when the match is not an "is a" claim."""
    if m.group("neg"):
        return []
    words = subject_words(m.group("x"))
    if not words or words[0].lower() in NOT_A_SUBJECT:
        return []
    has_eto = bool(m.group("eto") or m.group("dash_eto"))
    if not has_eto and (
        len(words) > MAX_DASH_SUBJECT_WORDS
        or m.group("y")[0].isupper()
        or any(VERB_END_RE.search(w.lower()) for w in words)
        or all(ADJ_END_RE.search(w.lower()) for w in words)
    ):
        return []
    return words


def phrase_terms(data: dict, subject: str) -> list[dict]:
    """Terms whose stem spans several words ("рабочий процесс"), matched on the whole subject."""
    subject = subject.lower()
    return [
        t
        for t in data["terms"]
        if any(
            " " in stem and re.search(rf"(?<![а-яё]){stem}", subject)
            for stem in t.get("stems") or []
        )
    ]


def discouraged_words(data: dict, text: str) -> list[str]:
    """Warnings for terms the pilot retired (registry field `prefer`); quoted and code text is skipped."""
    text = QUOTE_RE.sub(" ", CODE_RE.sub(" ", text)).lower()
    warnings: list[str] = []
    for term in data["terms"]:
        if not term.get("prefer"):
            continue
        for stem in term.get("stems") or []:
            for m in re.finditer(rf"(?<![а-яё]){stem}[а-яё]*", text):
                warnings.append(
                    f"«{m.group(0)}»: слово под уходом (решение пилота). "
                    f"Уточни: {term.get('resolve', 'что именно имеется в виду?')} "
                    f"Говори: {term['prefer']}"
                )
    return warnings


def head_noun(phrase: str) -> str | None:
    """First Cyrillic noun-like word of a phrase; None for code names and empty phrases."""
    for word in subject_words(phrase):
        if not re.match(r"[а-яё]", word, re.IGNORECASE):
            return None
        if ADJ_END_RE.search(word.lower()) or word.lower() in NOT_A_SUBJECT:
            continue
        return word
    return None


def non_system_reason(data: dict, word: str, whole_is_system: bool) -> str | None:
    """Why the word cannot name a part here, or None when it may."""
    kinds = kind_index(data)
    term_kinds = {t["kind"] for t in term_kind(data, word)}
    if term_kinds and "ambiguous" not in term_kinds and "system" not in term_kinds:
        kind = min(term_kinds)
        if kind in STEP_KINDS and not whole_is_system:
            return None
        return describe_kind(kinds[kind])
    if (
        whole_is_system
        and not term_kinds
        and ACTION_NOUN_RE.search(word)
        and not ACTION_NOUN_EXCEPTIONS.match(word)
    ):
        return "названо действие — это работа или метод, не система"
    return None


def part_warning(data: dict, item: str, form: str, whole_is_system: bool) -> str | None:
    word = head_noun(item)
    reason = non_system_reason(data, word, whole_is_system) if word else None
    if reason is None:
        return None
    return (
        f"«{' '.join(item.split())[:80]}» {form}: «{word}» — {reason}. "
        "Частью бывает только система; иначе связь глаголом (работает по, выполняет, хранит)."
    )


def table_part_cells(text: str) -> list[tuple[str, bool]]:
    """Cells of part columns with a flag: True when the column header names system parts."""
    cells: list[tuple[str, bool]] = []
    # None: the next table row is a header.
    columns: list[tuple[int, bool]] | None = None
    for line in text.splitlines():
        if not line.lstrip().startswith("|"):
            columns = None
            continue
        row = [c.strip().strip("*").strip() for c in line.strip().strip("|").split("|")]
        if all(re.fullmatch(r":?-{3,}:?", c) for c in row if c):
            continue
        if columns is None:
            columns = [
                (i, bool(SYSTEM_COLUMN_RE.match(c)))
                for i, c in enumerate(row)
                if PART_COLUMN_RE.match(c)
            ]
            continue
        cells += [(row[i], is_system) for i, is_system in columns if i < len(row)]
    return cells


def part_claims(data: dict, text: str) -> list[str]:
    """Warnings where a non-system is named as a part: prose claims and part columns of tables."""
    text = QUOTE_RE.sub(" ", CODE_RE.sub(" ", text))
    prose = LIST_MARK_RE.sub("", LAYOUT_LINE_RE.sub(" ", text))
    found: list[tuple[str, str, bool]] = []
    for regex, form in (
        (MEMBER_RE, "названо как входящее в"),
        (PART_RE, "названо частью"),
    ):
        for m in regex.finditer(prose):
            is_system = bool(SYSTEM_WHOLE_RE.match(m.group("whole")))
            found.append(
                (
                    m.group("part").split(",")[-1],
                    f"{form} «{m.group('whole')}»",
                    is_system,
                )
            )
    for m in CONSISTS_RE.finditer(prose):
        is_system = bool(SYSTEM_WHOLE_RE.match(m.group("whole")))
        found += [
            (i, "в перечне частей", is_system)
            for i in ITEM_SPLIT_RE.split(m.group("parts"))
        ]
    for m in SYSTEM_LIST_RE.finditer(prose):
        found += [
            (i, "в перечне частей", True) for i in ITEM_SPLIT_RE.split(m.group("parts"))
        ]
    for cell, is_system in table_part_cells(text):
        items = ITEM_SPLIT_RE.split(PAREN_RE.sub(" ", cell))
        found += [(i, "в столбце частей", is_system) for i in items]
    warnings = [
        part_warning(data, item, form, is_system) for item, form, is_system in found
    ]
    return [w for w in warnings if w]


def check_text(data: dict, text: str) -> list[str]:
    kinds = kind_index(data)
    warnings: list[str] = discouraged_words(data, text)
    for m in CLAIM_RE.finditer(strip_noise(text)):
        words = claim_subject(m)
        y = m.group("y")
        y_kind = claimed_kind(data, y) if words else None
        if y_kind is None:
            continue
        subject = " ".join(words[:6])
        x_terms = phrase_terms(data, subject) or next(
            (term_kind(data, w) for w in words if term_kind(data, w)), []
        )
        x_kinds = {t["kind"] for t in x_terms}
        if x_kinds == {y_kind["id"]}:
            continue
        claim = f"«{subject} — {y}»"
        if not x_terms:
            warnings.append(
                f"{claim}: «{subject}» в реестре нет, род не установлен. "
                f"Проверь по вопросу рода — {describe_kind(y_kind)}"
            )
        elif x_kinds == {"ambiguous"}:
            warnings.append(
                f"{claim}: подлежащее неоднозначно — назови объект. "
                f"Затем проверь по вопросу рода — {describe_kind(y_kind)}"
            )
        else:
            x_kind = kinds[min(x_kinds - {"ambiguous"})]
            warnings.append(
                f"{claim}: по реестру подлежащее — {describe_kind(x_kind)} "
                f"Утверждается — {describe_kind(y_kind)}"
            )
    return warnings + part_claims(data, text)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument(
        "--agent",
        default=os.environ.get("IWE_AGENT")
        or os.environ.get("STYLE_AGENT")
        or "unknown",
    )
    sub = parser.add_subparsers(dest="mode", required=True)
    p_lookup = sub.add_parser("lookup")
    p_lookup.add_argument("word")
    p_lookup.add_argument("--claim")
    p_check = sub.add_parser("check-text")
    p_check.add_argument("path")
    args = parser.parse_args()

    try:
        data, digest = load()
    except (OSError, UnicodeDecodeError, yaml.YAMLError) as err:
        print(f"concept-kind: пропуск (реестр не прочитан: {err})", file=sys.stderr)
        return 0
    if args.mode == "lookup":
        outcome, lines = lookup(data, args.word, args.claim)
        print("\n".join(lines))
        log(args.agent, digest, "lookup", args.word, outcome, args.claim or "")
        return 0

    try:
        text = (
            sys.stdin.buffer.read().decode("utf-8", errors="replace")
            if args.path == "-"
            else Path(args.path).read_text(encoding="utf-8", errors="replace")
        )
    except OSError as err:
        print(f"concept-kind: пропуск (файл не прочитан: {err})", file=sys.stderr)
        return 0
    warnings = check_text(data, text)
    for line in warnings:
        print(f"- {line}")
    print(f"Сверка с реестром понятий и родов: предупреждений {len(warnings)}.")
    log(args.agent, digest, "check-text", args.path, f"warnings={len(warnings)}", "")
    return 0


if __name__ == "__main__":
    sys.exit(main())
