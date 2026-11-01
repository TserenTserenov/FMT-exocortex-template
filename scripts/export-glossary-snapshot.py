#!/usr/bin/env python3
"""Собрать публичный снимок терминов для перевода шаблона (WP-5 Ф67, решение D').

Вход — JSON с полями шлюза (name_en, name_en_status_raw, name_en_publishable,
name_en_publishable_rules_version). Скрипт не ходит в базу и в сеть.
В снимок попадают только активные понятия из белого списка, с английским
именем статуса «ок» и признаком публикации. Канарейка AR.D.005 обязана
быть во входе и отсеяться фильтром. Нет её на входе или она попала в
снимок — файл не пишется.

Пока боевой снимок не зафиксирован коммитом, translate.py читает
translation/glossary-v0.1.csv.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import re
import sys
import tempfile
from collections import Counter
from pathlib import Path

import yaml

SCHEMA = "glossary-snapshot/1"
PUBLISHABLE_STATUS = "ok"
CYRILLIC_RE = re.compile(r"[А-Яа-яЁё]")
REQUIRED_KEYS = (
    "code",
    "name_ru",
    "level",
    "domain",
    "status",
    "name_en",
    "name_en_status_raw",
    "name_en_publishable",
    "name_en_publishable_rules_version",
)


class SnapshotError(Exception):
    """Выгрузка не может быть опубликована. Файл снимка не пишется."""


def load_allowlist(path: Path) -> dict:
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise SnapshotError(f"белый список не объект: {path}")
    if data.get("schema") != "glossary-snapshot-allowlist/1":
        raise SnapshotError(f"неизвестная схема белого списка: {data.get('schema')}")
    for key in ("levels", "pack_domains", "foundation", "canary_codes"):
        if key not in data:
            raise SnapshotError(f"в белом списке нет поля {key}")
    if not data["canary_codes"]:
        raise SnapshotError("канарейка обязательна: пустой canary_codes")
    return data


def english_name_error(name: object) -> str | None:
    if not isinstance(name, str):
        return "not-a-string"
    text = name.strip()
    if not text:
        return "empty"
    if text != name:
        return "whitespace"
    if len(text) > 200:
        return "too-long"
    if CYRILLIC_RE.search(text):
        return "cyrillic"
    if any(ord(ch) < 32 for ch in text):
        return "control-char"
    return None


def _domain_ok(row: dict, allowlist: dict) -> bool:
    level = row.get("level")
    domain = row.get("domain")
    code = row.get("code")
    if not isinstance(code, str) or not code:
        return False
    if level == "pack":
        if not isinstance(domain, str) or domain not in allowlist["pack_domains"]:
            return False
        return code.startswith(domain + ".")
    for rule in allowlist["foundation"]:
        if rule.get("level") != level:
            continue
        prefix_ok = any(isinstance(code, str) and code.startswith(p) for p in rule.get("code_prefixes", []))
        if not prefix_ok:
            return False
        if domain is None and rule.get("allow_null_domain"):
            return True
        return isinstance(domain, str) and domain in rule.get("domains", [])
    return False


def classify_row(row: dict, allowlist: dict) -> tuple[str, str]:
    """Вернуть (include|exclude|reject, причина)."""
    if not isinstance(row, dict):
        return "reject", "row-not-object"
    missing = [key for key in REQUIRED_KEYS if key not in row]
    if missing:
        return "reject", "missing-field:" + ",".join(missing)
    code = row["code"]
    if not isinstance(code, str) or not code.strip():
        return "reject", "empty-code"
    if not isinstance(row["name_en_publishable"], bool):
        return "reject", "publishable-not-bool"
    if row["status"] != "active":
        return "exclude", "status"
    if row["level"] not in allowlist["levels"]:
        return "exclude", "level"
    if not _domain_ok(row, allowlist):
        return "exclude", "domain"
    if row["name_en_publishable"] is not True:
        return "exclude", "not-publishable"
    if row["name_en_status_raw"] != PUBLISHABLE_STATUS:
        return "reject", "publishable-contradiction"
    name_error = english_name_error(row["name_en"])
    if name_error:
        return "reject", "english:" + name_error
    if not isinstance(row["name_ru"], str) or not row["name_ru"].strip():
        return "reject", "empty-russian"
    version = row["name_en_publishable_rules_version"]
    if not isinstance(version, str) or not version.strip():
        return "reject", "empty-rules-version"
    return "include", "ok"


def build_rows(payload: dict, allowlist: dict) -> tuple[list[dict], Counter, str]:
    if not isinstance(payload, dict):
        raise SnapshotError("вход не объект")
    as_of = payload.get("as_of")
    if not isinstance(as_of, str) or not as_of.strip():
        raise SnapshotError("нет отметки снимка as_of")
    rows = payload.get("rows")
    if not isinstance(rows, list) or not rows:
        raise SnapshotError("пустой список строк: снимок не пишется")
    codes = [row.get("code") if isinstance(row, dict) else None for row in rows]
    for canary in allowlist["canary_codes"]:
        if canary not in codes:
            raise SnapshotError(f"канарейки нет на входе: {canary}")

    included: list[dict] = []
    excluded: Counter = Counter()
    for row in rows:
        kind, reason = classify_row(row, allowlist)
        if kind == "reject":
            code = row.get("code") if isinstance(row, dict) else None
            raise SnapshotError(f"строка {code}: {reason}")
        if kind == "exclude":
            excluded[reason] += 1
            continue
        included.append(
            {
                "code": row["code"],
                "term_ru": row["name_ru"].strip(),
                "term_en": row["name_en"],
                "level": row["level"],
                "domain": "" if row["domain"] is None else row["domain"],
                "name_en_status_raw": row["name_en_status_raw"],
                "rules_version": row["name_en_publishable_rules_version"],
            }
        )

    by_code: dict[str, dict] = {}
    for item in included:
        prev = by_code.get(item["code"])
        if prev is None:
            by_code[item["code"]] = item
            continue
        if (
            prev["term_en"] != item["term_en"]
            or prev["term_ru"] != item["term_ru"]
            or prev["rules_version"] != item["rules_version"]
        ):
            raise SnapshotError(f"противоречивые имена у кода {item['code']}")
    included = [by_code[code] for code in sorted(by_code)]
    versions = {item["rules_version"] for item in included}
    if len(versions) > 1:
        raise SnapshotError("в одном снимке несколько версий списка статусов: " + ", ".join(sorted(versions)))
    if not included:
        raise SnapshotError("после фильтра не осталось ни одной публичной строки")
    for item in included:
        if item["code"] in allowlist["canary_codes"]:
            raise SnapshotError(f"канарейка попала в снимок: {item['code']}")
    return included, excluded, as_of


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_snapshot(included: list[dict], meta: dict, output_csv: Path) -> None:
    output_csv.parent.mkdir(parents=True, exist_ok=True)
    meta_path = output_csv.with_suffix(".meta.json")
    with tempfile.TemporaryDirectory(dir=output_csv.parent) as tmp:
        tmp_csv = Path(tmp) / "snapshot.csv"
        with tmp_csv.open("w", encoding="utf-8", newline="") as handle:
            writer = csv.DictWriter(
                handle,
                fieldnames=(
                    "code",
                    "term_ru",
                    "term_en",
                    "level",
                    "domain",
                    "name_en_status_raw",
                    "rules_version",
                ),
                lineterminator="\n",
            )
            writer.writeheader()
            writer.writerows(included)
        meta["output_sha256"] = _sha256(tmp_csv)
        meta["schema"] = SCHEMA
        tmp_meta = Path(tmp) / "snapshot.meta.json"
        tmp_meta.write_text(json.dumps(meta, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        tmp_csv.replace(output_csv)
        tmp_meta.replace(meta_path)


def export_snapshot(payload: dict, allowlist: dict, allowlist_path: Path, output_csv: Path) -> dict:
    included, excluded, as_of = build_rows(payload, allowlist)
    meta = {
        "as_of": as_of,
        "allowlist_sha256": _sha256(allowlist_path),
        "excluded": dict(sorted(excluded.items())),
        "included": len(included),
        "input_rows": len(payload["rows"]),
        "rules_version": included[0]["rules_version"],
        "schema": SCHEMA,
    }
    write_snapshot(included, meta, output_csv)
    return meta


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Собрать публичный снимок терминов графа")
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--allowlist", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        allowlist = load_allowlist(args.allowlist)
        payload = json.loads(args.input.read_text(encoding="utf-8"))
        meta = export_snapshot(payload, allowlist, args.allowlist, args.output)
    except (OSError, json.JSONDecodeError, yaml.YAMLError, SnapshotError) as exc:
        print(f"export-glossary-snapshot: {exc}", file=sys.stderr)
        return 2
    print(f"included={meta['included']} schema={meta['schema']} rules={meta['rules_version']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
