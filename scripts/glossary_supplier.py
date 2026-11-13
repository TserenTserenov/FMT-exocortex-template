# see WP-617 Ф4 (daily terms snapshot refresh)
"""Supplier of translation terms: refresh the graph snapshot and prepare the merge request.

Runs in .github/workflows/glossary-supplier.yml after scripts/fetch-glossary-concepts.py.
Never runs in translate-sync.yml: publication reads files only (decision D').

``refresh``
    Builds the snapshot from the gateway walk with the same filter as
    scripts/export-glossary-snapshot.py, then applies the local-glossary rules
    agreed in peer-session 2026-11-07-07:

    * a graph term whose English name differs from a local row is left out of the
      snapshot (with every concept of the same Russian name) and listed under
      ``conflict_local`` in the passport — the local row
      may be a pilot decision not yet moved to the graph, so the graph does not
      silently win; the rest of the update is not held back;
    * a local row the snapshot now covers with the same English name is removed,
      unless it is stricter than the tier the graph gives (it then only raises the tier).

    Writes nothing when neither the snapshot rows nor the local glossary changed
    (a new ``as_of`` alone is not a change). Otherwise writes the files, checks that
    scripts/glossary_source.py loads them and writes the merge-request description.

``changelog``
    Adds the [Unreleased] entry the changelog gate requires, referencing the merge request.
"""

from __future__ import annotations

import argparse
import csv
import importlib.util
import io
import json
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

import yaml
from glossary_source import (
    LOCAL_DEFAULT_TIER,
    GlossaryError,
    _graph_terms,
    _key,
    load_glossary,
)

SCRIPTS = Path(__file__).resolve().parent
EXPORTER_PATH = SCRIPTS / "export-glossary-snapshot.py"
CHANGELOG_MARKER = "WP-617, #"
# GitHub rejects a pull request body over 65 536 characters; a long list is cut, the files hold the rest.
MAX_LISTED_ROWS = 100


def _load_exporter():
    spec = importlib.util.spec_from_file_location("export_glossary_snapshot", EXPORTER_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


EXPORTER = _load_exporter()


class SupplierError(Exception):
    """The supplier cannot prepare a trustworthy update. Nothing is written."""


@dataclass
class Refresh:
    changed: bool
    conflicts: list[dict] = field(default_factory=list)
    body: str = ""
    # True when the conflict list is not the one the pilot was already told about.
    announce: bool = False


def read_rows(path: Path) -> list[dict[str, str]]:
    with path.open(encoding="utf-8", newline="") as handle:
        return list(csv.DictReader(handle))


def local_conflicts(included: list[dict], local_rows: list[dict[str, str]]) -> list[dict]:
    """Graph rows whose Russian name is in the local glossary under another English name."""
    # Same reading as the loader: a local row without both names is not a term and cannot conflict.
    local_en = {}
    for row in local_rows:
        ru, en = (row.get("term_ru") or "").strip(), (row.get("term_en") or "").strip()
        if ru and en:
            local_en[_key(ru)] = en
    conflicts = []
    for item in included:
        local = local_en.get(_key(item["term_ru"]))
        if local is not None and local != item["term_en"]:
            conflicts.append(
                {"code": item["code"], "term_ru": item["term_ru"], "term_en_graph": item["term_en"], "term_en_local": local}
            )
    return conflicts


def local_rows_to_drop(snapshot_rows: list[dict], local_rows: list[dict[str, str]], tier_by_level: dict) -> list[str]:
    """Russian names of local rows the snapshot now serves with the same English name and no stricter tier."""
    graph, _conflicted = _graph_terms(snapshot_rows, tier_by_level, notes=[])
    drop = []
    for row in local_rows:
        ru = (row.get("term_ru") or "").strip()
        graph_term = graph.get(_key(ru))
        if graph_term is None or graph_term.term_en != (row.get("term_en") or "").strip():
            continue
        tier_raw = (row.get("tier") or "").strip()
        tier = int(tier_raw) if tier_raw.isdigit() else LOCAL_DEFAULT_TIER
        if tier >= graph_term.tier:
            drop.append(ru)
    return drop


def without_local_rows(text: str, drop: list[str]) -> str:
    """Remove rows by Russian name, keeping every other line byte for byte (csv rewriting would requote them).

    Physical lines are split on newline only; the csv reader reports how many of them each record used,
    so a quoted line break or an exotic separator inside a field never leaves a fragment behind.
    """
    keys = {_key(ru) for ru in drop}
    lines = io.StringIO(text, newline="").readlines()
    reader = csv.reader(iter(lines))
    kept: list[str] = []
    consumed = 0
    for index, record in enumerate(reader):
        span = lines[consumed : reader.line_num]
        consumed = reader.line_num
        if index == 0 or not record or _key(record[0]) not in keys:
            kept.extend(span)
    kept.extend(lines[consumed:])
    return "".join(kept)


def snapshot_diff(old_rows: list[dict], new_rows: list[dict]) -> dict[str, list]:
    old = {r["code"]: r for r in old_rows}
    new = {r["code"]: r for r in new_rows}
    changed = [
        (old[c], new[c])
        for c in sorted(old.keys() & new.keys())
        if (old[c]["term_ru"], old[c]["term_en"]) != (new[c]["term_ru"], new[c]["term_en"])
    ]
    return {
        "added": [new[c] for c in sorted(new.keys() - old.keys())],
        "removed": [old[c] for c in sorted(old.keys() - new.keys())],
        "changed": changed,
    }


def _stats_line(old_meta: dict, new_meta: dict) -> str:
    old_stats, new_stats = old_meta.get("graph_stats") or {}, new_meta.get("graph_stats") or {}
    if not new_stats:
        return "Счётчики графа: нет данных."
    parts = [f"{key}: {old_stats.get(key, '—')} → {value}" for key, value in new_stats.items()]
    return "Счётчики графа (было → стало): " + "; ".join(parts) + "."


def _listed(lines: list[str]) -> list[str]:
    """First MAX_LISTED_ROWS lines of a section, then how many were left out."""
    if len(lines) <= MAX_LISTED_ROWS:
        return lines
    return lines[:MAX_LISTED_ROWS] + [f"- … и ещё {len(lines) - MAX_LISTED_ROWS} (полный список — в файлах запроса)"]


def render_body(diff: dict, conflicts: list[dict], dropped: list[str], old_meta: dict, new_meta: dict) -> str:
    lines = [
        "Ежедневное обновление снимка терминов перевода из графа понятий (WP-617 Ф4).",
        "",
        f"Снимок на {new_meta['as_of']}: терминов {old_meta.get('included', '—')} → {new_meta['included']}.",
        _stats_line(old_meta, new_meta),
        "",
    ]
    if conflicts:
        lines += ["## Требует решения", "", "Английское имя в графе расходится с ручным словарём. Понятие не вошло в снимок, перевод пока берёт имя из ручного словаря. Поправьте имя в графе или удалите строку ручного словаря — понятие войдёт в следующий снимок.", ""]
        lines += _listed(
            [f"- `{c['code']}` «{c['term_ru']}»: граф `{c['term_en_graph']}`, ручной словарь `{c['term_en_local']}`" for c in conflicts]
        )
        lines.append("")
    for title, rows in (("Появились", diff["added"]), ("Исчезли", diff["removed"])):
        if rows:
            listed = _listed([f"- `{r['code']}` «{r['term_ru']}» → {r['term_en']}" for r in rows])
            lines += [f"## {title} ({len(rows)})", ""] + listed + [""]
    if diff["changed"]:
        lines += [f"## Изменились ({len(diff['changed'])})", ""]
        lines += _listed(
            [f"- `{new['code']}` «{old['term_ru']}» → {old['term_en']} ⇒ «{new['term_ru']}» → {new['term_en']}" for old, new in diff["changed"]]
        )
        lines.append("")
    if dropped:
        lines += [f"## Убрано из ручного словаря ({len(dropped)})", "", "Граф даёт то же английское имя и не мягче по проверке.", ""]
        lines += _listed([f"- «{ru}»" for ru in dropped]) + [""]
    lines.append("Слияние — решение приёмщика; без него перевод продолжает работать на прежнем снимке.")
    lines.append(
        "Если после слияния другого запроса этот стал конфликтным, запустите задание вручную (Run workflow): "
        "оно пересоберёт ветку от свежего main."
    )
    return "\n".join(lines) + "\n"


def _check_loads(manifest: dict, staged_snapshot: Path, staged_local: Path) -> None:
    """The merge request must not break translation: same loader, same rules, run on the staged files."""
    staged_manifest = {
        **manifest,
        "glossary": {**manifest["glossary"], "snapshot": staged_snapshot.name, "local": staged_local.name},
    }
    load_glossary(staged_manifest, staged_snapshot.parent)


def refresh(root: Path, payload: dict, allowlist_path: Path, announced_meta: dict | None = None) -> Refresh:
    """Rebuild snapshot and local glossary; write them only if they changed and still load.

    ``announced_meta`` is the passport the pilot last saw in an open merge request; without it, main's.
    """
    manifest = yaml.safe_load((root / "translation-manifest.yaml").read_text(encoding="utf-8"))
    cfg = manifest["glossary"]
    snapshot_path, local_path = root / cfg["snapshot"], root / cfg["local"]
    meta_path = snapshot_path.with_suffix(".meta.json")
    tier_by_level = {str(k): int(v) for k, v in cfg["tier_by_level"].items()}

    old_rows = read_rows(snapshot_path)
    old_meta = json.loads(meta_path.read_text(encoding="utf-8"))
    # newline="": the local file keeps its own line endings (the template file is CRLF).
    with local_path.open(encoding="utf-8", newline="") as handle:
        local_text = handle.read()
    local_rows = read_rows(local_path)

    allowlist = EXPORTER.load_allowlist(allowlist_path)
    included, excluded, as_of = EXPORTER.build_rows(payload, allowlist)
    conflicts = local_conflicts(included, local_rows)
    # The whole Russian name waits for the pilot, not only the disagreeing concept: a second concept with the
    # same name and the local English would make the local row a duplicate the loader refuses.
    conflict_keys = {_key(c["term_ru"]) for c in conflicts}
    held = [item for item in included if _key(item["term_ru"]) in conflict_keys]
    included = [item for item in included if _key(item["term_ru"]) not in conflict_keys]
    if held:
        excluded["conflict-local"] += len(held)
    meta = EXPORTER.build_meta(payload, included, excluded, as_of, allowlist_path)
    if conflicts:
        meta["conflict_local"] = conflicts

    dropped = local_rows_to_drop(included, local_rows, tier_by_level)
    new_local_text = without_local_rows(local_text, dropped)
    announce = bool(conflicts) and conflicts != (announced_meta or old_meta).get("conflict_local", [])
    # Staged next to the target: os.replace cannot cross filesystems.
    with tempfile.TemporaryDirectory(dir=snapshot_path.parent) as tmp:
        staged = Path(tmp) / snapshot_path.name
        staged_local = Path(tmp) / local_path.name
        EXPORTER.write_snapshot(included, meta, staged)
        with staged_local.open("w", encoding="utf-8", newline="") as handle:
            handle.write(new_local_text)
        # A new conflict may leave the snapshot rows untouched (the concept never was in it);
        # it still has to reach the pilot, so a changed conflict list is a change too.
        unchanged = (
            staged.read_bytes() == snapshot_path.read_bytes()
            and new_local_text == local_text
            and conflicts == old_meta.get("conflict_local", [])
        )
        if unchanged:
            return Refresh(changed=False, conflicts=conflicts)
        _check_loads(manifest, staged, staged_local)
        staged.replace(snapshot_path)
        staged.with_suffix(".meta.json").replace(meta_path)
        staged_local.replace(local_path)

    body = render_body(snapshot_diff(old_rows, included), conflicts, dropped, old_meta, meta)
    return Refresh(changed=True, conflicts=conflicts, body=body, announce=announce)


def add_changelog_entry(text: str, pr: int) -> str:
    """Insert the supplier entry under [Unreleased] → ### Changed; unchanged if already there."""
    # The three sub-bullets are the handoff fields required by scripts/check-changelog-fields.py
    # (Changelog Gate, WP-529 Ф252); need 93 is the one the translation glossary entries already use.
    entry = (
        "- [optional] Снимок терминов графа понятий для перевода шаблона на английский обновлён "
        f"поставщиком терминов перевода (`translation/glossary-snapshot.csv`; {CHANGELOG_MARKER}{pr}).\n"
        "  - Цель: 93 · Результат: служебное — словарь перевода обновлён из графа понятий; "
        "у пользователя шаблона поведение не меняется\n"
        "  - Как проверить: `python3 -m pytest scripts/tests/test_glossary_source.py` проходит на снимке; "
        f"разница по терминам — в описании запроса #{pr}\n"
        f"  - Как откатить: не сливать запрос #{pr} или git revert его слияния; "
        "перевод продолжает работать на прежнем снимке\n"
    )
    lines = text.splitlines(keepends=True)
    start = next((i for i, line in enumerate(lines) if line.startswith("## [Unreleased]")), None)
    if start is None:
        raise SupplierError("CHANGELOG.md has no [Unreleased] section")
    end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("## [")), len(lines))
    if any(f"{CHANGELOG_MARKER}{pr})" in line for line in lines[start:end]):
        return text
    changed_at = next((i for i in range(start + 1, end) if lines[i].rstrip("\n") == "### Changed"), None)
    if changed_at is None:
        return "".join(lines[: start + 1] + ["\n", "### Changed\n", "\n", entry] + lines[start + 1 :])
    return "".join(lines[: changed_at + 1] + ["\n", entry] + lines[changed_at + 1 :])


def _cmd_refresh(args: argparse.Namespace) -> int:
    try:
        payload = json.loads(args.input.read_text(encoding="utf-8"))
        announced = None
        if args.announced_meta and args.announced_meta.is_file():
            announced = json.loads(args.announced_meta.read_text(encoding="utf-8"))
        result = refresh(args.root, payload, args.allowlist, announced)
    except (OSError, json.JSONDecodeError, yaml.YAMLError, KeyError, EXPORTER.SnapshotError, GlossaryError, SupplierError) as exc:
        print(f"glossary-supplier: {exc}", file=sys.stderr)
        return 2
    if result.changed:
        args.body_out.write_text(result.body, encoding="utf-8")
    print(f"changed={'true' if result.changed else 'false'}")
    print(f"conflicts={len(result.conflicts)}")
    print(f"announce={'true' if result.announce else 'false'}")
    return 0


def _cmd_changelog(args: argparse.Namespace) -> int:
    path = args.root / "CHANGELOG.md"
    try:
        path.write_text(add_changelog_entry(path.read_text(encoding="utf-8"), args.pr), encoding="utf-8")
    except (OSError, SupplierError) as exc:
        print(f"glossary-supplier: {exc}", file=sys.stderr)
        return 2
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Поставщик терминов перевода (WP-617 Ф4)")
    parser.add_argument("--root", type=Path, default=SCRIPTS.parent)
    sub = parser.add_subparsers(dest="command", required=True)
    p_refresh = sub.add_parser("refresh", help="обновить снимок и ручной словарь, описать разницу")
    p_refresh.add_argument("--input", required=True, type=Path, help="вывод fetch-glossary-concepts.py")
    p_refresh.add_argument("--allowlist", type=Path, default=SCRIPTS.parent / "translation" / "glossary-snapshot-allowlist.yaml")
    p_refresh.add_argument("--body-out", required=True, type=Path)
    p_refresh.add_argument(
        "--announced-meta", type=Path, help="паспорт снимка из открытого запроса: о его конфликтах пилот уже знает"
    )
    p_refresh.set_defaults(handler=_cmd_refresh)
    p_log = sub.add_parser("changelog", help="добавить запись [Unreleased] со ссылкой на запрос")
    p_log.add_argument("--pr", required=True, type=int)
    p_log.set_defaults(handler=_cmd_changelog)
    args = parser.parse_args(argv)
    return args.handler(args)


if __name__ == "__main__":
    sys.exit(main())
