#!/usr/bin/env python3
"""Postman address book: validate and resolve (WP-418 F9, DP.ROLE.044 section 5).

The book (scripts/postman-address-book.yaml) lists kinds of addressees: how a
sender names one, where the address is, which executor delivers there. User
additions come from params.yaml, key `postman_addressees`; they may add kinds,
never redefine the template ones.

Usage:
  postman-address-book.py check   [--book PATH] [--params PATH]
  postman-address-book.py resolve NAME [--book PATH] [--params PATH]

check   exit 0 valid, 1 invalid (every problem on stderr).
resolve prints one JSON object: kind, delivery, address_kind (path|store),
        address, executor, semantics, status, closed (true when the
        closed-address rule fired); exit 1 if no kind matches the name or the
        book is invalid.

Environment: IWE_WORKSPACE (default {{WORKSPACE_DIR}}) and IWE_GOVERNANCE_REPO (the
governance repository folder) fill {governance_repo}.
"""
import argparse
import json
import os
import re
import string
import sys
from pathlib import Path

import yaml

SCHEMA_VERSION = 1
DELIVERIES = {"internal", "external"}
SEMANTICS = {"idempotent", "atomic-dedup", "dedup-journal", "none"}
STATUSES = {"exists", "target"}
REQUIRED = ("kind", "title", "delivery", "name_pattern", "address", "executor",
            "semantics", "accepts", "who_may_write", "status")
ADDRESS_PREFIXES = ("path:", "store:")
EXECUTOR_PREFIXES = ("script:", "external:")
# A pointer book must not carry literal personal addresses or secrets.
FORBIDDEN = [
    (re.compile(r"[\w.+-]+@[\w-]+\.[\w.-]+"), "адрес почты"),
    (re.compile(r"(?<![\w{])-?\d{6,}(?![\w}])"), "длинное число (похоже на номер чата)"),
    (re.compile(r"\b(sk-|ghp_|gho_|xox[bp]-|AKIA)[A-Za-z0-9]"), "похоже на ключ доступа"),
    (re.compile(r"\b\d{6,}:[A-Za-z0-9_-]{20,}"), "похоже на токен бота"),
]

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_BOOK = ROOT / "scripts" / "postman-address-book.yaml"
DEFAULT_PARAMS = ROOT / "params.yaml"


def load_yaml(path: Path):
    try:
        return yaml.safe_load(path.read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError) as exc:
        raise SystemExit(f"postman-address-book: не прочитан {path}: {exc}")


def load_rows(book_path: Path, params_path: Path) -> tuple[list[dict], list[str]]:
    """Template rows plus user rows; problems with the files themselves."""
    problems = []
    book = load_yaml(book_path) or {}
    if book.get("schema_version") != SCHEMA_VERSION:
        problems.append(f"{book_path.name}: schema_version {book.get('schema_version')!r}, ожидается {SCHEMA_VERSION}")
    rows = [dict(r, _origin="книга") for r in book.get("addressees") or []]
    if params_path.is_file():
        user = (load_yaml(params_path) or {}).get("postman_addressees") or []
        if not isinstance(user, list):
            problems.append("params.yaml: postman_addressees должен быть списком")
            user = []
        rows += [dict(r, _origin="params.yaml") for r in user]
    return rows, problems


def strings_of(value):
    if isinstance(value, dict):
        for v in value.values():
            yield from strings_of(v)
    elif isinstance(value, list):
        for v in value:
            yield from strings_of(v)
    elif isinstance(value, str):
        yield value


def row_problems(row: dict, seen: dict) -> list[str]:
    where = f"{row.get('_origin')}: вид {row.get('kind', '?')!r}"
    out = [f"{where}: нет поля {f}" for f in REQUIRED if not row.get(f)]
    if out:
        return out
    kind = row["kind"]
    if not re.fullmatch(r"[a-z][a-z0-9-]*", kind):
        out.append(f"{where}: kind только строчной латиницей, цифрами и дефисом")
    if kind in seen:
        out.append(f"{where}: вид уже задан в {seen[kind]}")
    seen.setdefault(kind, row["_origin"])
    for field, allowed in (("delivery", DELIVERIES), ("semantics", SEMANTICS), ("status", STATUSES)):
        if row[field] not in allowed:
            out.append(f"{where}: {field} = {row[field]!r}, допустимо {sorted(allowed)}")
    try:
        groups = set(re.compile(row["name_pattern"]).groupindex)
    except re.error as exc:
        out.append(f"{where}: name_pattern не разбирается: {exc}")
        groups = set()
    closed = row["closed"] if isinstance(row.get("closed"), dict) else {}
    for template in (row["address"], row["executor"], *closed.values()):
        unknown = {f for _, f, _, _ in string.Formatter().parse(str(template)) if f} - groups - {"governance_repo"}
        if unknown:
            out.append(f"{where}: в {template!r} подстановки {sorted(unknown)} не берутся из name_pattern")
    addresses = [row["address"]] + ([row["closed"].get("address", "")] if isinstance(row.get("closed"), dict) else [])
    for a in addresses:
        if not a.startswith(ADDRESS_PREFIXES):
            out.append(f"{where}: адрес {a!r} должен начинаться с path: или store:")
    if isinstance(row.get("closed"), dict) and not str(row["closed"].get("when", "")).startswith("path-missing:"):
        out.append(f"{where}: closed.when поддерживается только в виде path-missing:<путь>")
    executors = [row["executor"]] + ([row["closed"].get("executor", "")] if isinstance(row.get("closed"), dict) else [])
    for e in executors:
        if not e.startswith(EXECUTOR_PREFIXES):
            out.append(f"{where}: исполнитель {e!r} должен начинаться с script: или external:")
        elif e.startswith("script:") and not (ROOT / e[len("script:"):].split()[0]).is_file():
            out.append(f"{where}: исполнитель {e.split()[0]} не найден")
    if row["delivery"] == "external" and not row["address"].startswith("store:"):
        out.append(f"{where}: адрес человека — только ссылка store:, не путь и не значение")
    for text in strings_of({k: v for k, v in row.items() if k != "name_pattern"}):
        for pattern, label in FORBIDDEN:
            if pattern.search(text):
                out.append(f"{where}: в книге не должно быть значений адресов и секретов ({label}): {text!r}")
    return out


def check(rows: list[dict], file_problems: list[str]) -> list[str]:
    seen: dict = {}
    problems = list(file_problems)
    for row in rows:
        problems += row_problems(row, seen)
    return problems


def fill(template: str, groups: dict) -> str:
    governance = Path(os.environ.get("IWE_WORKSPACE", Path.home() / "IWE")) / os.environ.get("IWE_GOVERNANCE_REPO", "DS-strategy")
    return template.format(governance_repo=governance, **groups)


def resolve(rows: list[dict], name: str) -> dict | None:
    for row in rows:
        m = re.fullmatch(row["name_pattern"], name)
        if not m:
            continue
        groups = m.groupdict()
        target, closed = row, False
        rule = row.get("closed")
        if rule and not Path(fill(rule["when"][len("path-missing:"):], groups)).exists():
            target, closed = rule, True
        address_kind, _, address = fill(target["address"], groups).partition(":")
        return {"kind": row["kind"], "delivery": row["delivery"], "address_kind": address_kind,
                "address": address, "executor": fill(target["executor"], groups),
                "semantics": row["semantics"], "status": row["status"], "closed": closed}
    return None


def main() -> int:
    ap = argparse.ArgumentParser(description="Адресная книга Почтальона: проверка и поиск адреса.")
    ap.add_argument("command", choices=["check", "resolve"])
    ap.add_argument("name", nargs="?")
    ap.add_argument("--book", type=Path, default=DEFAULT_BOOK)
    ap.add_argument("--params", type=Path, default=DEFAULT_PARAMS)
    a = ap.parse_args()
    rows, file_problems = load_rows(a.book, a.params)
    problems = check(rows, file_problems)
    for p in problems:
        print(f"postman-address-book: {p}", file=sys.stderr)
    if problems:
        return 1
    if a.command == "check":
        print(f"адресная книга: видов адресатов {len(rows)}, ошибок нет")
        return 0
    if not a.name:
        ap.error("resolve требует имя адресата")
    found = resolve(rows, a.name)
    if found is None:
        print(f"postman-address-book: адресат {a.name!r} не найден в книге — не поддерживается", file=sys.stderr)
        return 1
    print(json.dumps(found, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
