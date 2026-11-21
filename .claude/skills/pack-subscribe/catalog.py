#!/usr/bin/env python3
"""Pack catalog reader for the /pack-subscribe skill.

Merges the user's own catalog with the catalog shipped next to this file,
drops entries that must never be offered, and answers three questions the
skill asks deterministically:

    catalog.py list [--workspace DIR] [--format tsv|json]
        Storefront: every offerable entry, with source and connection state.
    catalog.py show NAME [--workspace DIR]
        One entry as JSON, or a refusal with a reason (see exit codes).
    catalog.py validate FILE
        Check a catalog file against the schema; list every problem.

Sources, highest priority first (an entry with the same name from a higher
source replaces the lower one):
    1. <workspace>/extensions/pack-catalog.yaml   (user-owned, survives updates)
    2. pack_catalog_url in <workspace>/params.yaml (https URL or local path)
    3. pack-catalog.yaml next to this script        (shipped with the template)

Exit codes:
    0 ok; 1 validation problems; 2 usage or read error;
    3 the entry is internal-only and is never connected;
    4 no such entry in the catalog.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.request
from dataclasses import dataclass
from pathlib import Path

import yaml

SHIPPED = Path(__file__).resolve().parent / "pack-catalog.yaml"
USER_CATALOG = Path("extensions") / "pack-catalog.yaml"
PARAMS_KEY = "pack_catalog_url"

REQUIRED = ("name", "owner", "domain", "description", "url", "access")
ACCESS_VALUES = ("open", "by-subscription")
INTERNAL_ONLY = "internal-only"
# The search skills discover local packs by the PACK-* glob, so a name
# without the prefix would be cloned but never searched.
NAME_RE = re.compile(r"^PACK-[A-Za-z0-9][A-Za-z0-9._-]*$")
# Only https: other git transports (ext::, file://, ssh with options) can run
# commands or read local files when a catalog comes from someone else.
URL_RE = re.compile(r"^https://[A-Za-z0-9.-]+/[^\s]+$")
FETCH_TIMEOUT_S = 10
FETCH_LIMIT_BYTES = 1_000_000

EXIT_OK, EXIT_INVALID, EXIT_USAGE, EXIT_INTERNAL, EXIT_MISSING = 0, 1, 2, 3, 4


class CatalogError(Exception):
    """A catalog source cannot be read or parsed."""


@dataclass
class Source:
    label: str
    text: str


def warn(message: str) -> None:
    print(f"[pack-catalog] {message}", file=sys.stderr)


def entry_problems(entry: object) -> list[str]:
    """Schema problems of one entry; an empty list means the entry is valid."""
    if not isinstance(entry, dict):
        return ["entry is not a mapping"]
    problems = []
    for key in REQUIRED:
        value = entry.get(key)
        if not isinstance(value, str) or not value.strip():
            problems.append(f"missing or empty field '{key}'")
    name = entry.get("name")
    if isinstance(name, str) and name and not NAME_RE.match(name):
        problems.append(f"name '{name}' must match {NAME_RE.pattern}")
    url = entry.get("url")
    if isinstance(url, str) and url and not URL_RE.match(url):
        problems.append(f"url '{url}' must be an https:// address")
    access = entry.get("access")
    if isinstance(access, str) and access and access not in ACCESS_VALUES:
        problems.append(f"access '{access}' must be one of {', '.join(ACCESS_VALUES)}")
    for key in ("audience", "offered"):
        if key in entry and not isinstance(entry[key], str):
            problems.append(f"field '{key}' must be a string")
    return problems


def parse_catalog(text: str, label: str) -> list[object]:
    try:
        data = yaml.safe_load(text)
    except yaml.YAMLError as exc:
        raise CatalogError(f"{label}: not valid YAML ({exc})") from exc
    if not isinstance(data, dict) or not isinstance(data.get("packs"), list):
        raise CatalogError(f"{label}: top level must be a mapping with a 'packs' list")
    return data["packs"]


def fetch_url(url: str) -> str:
    request = urllib.request.Request(url, headers={"User-Agent": "iwe-pack-subscribe"})
    with urllib.request.urlopen(request, timeout=FETCH_TIMEOUT_S) as response:
        body = response.read(FETCH_LIMIT_BYTES + 1)
    if len(body) > FETCH_LIMIT_BYTES:
        raise CatalogError(f"{url}: larger than {FETCH_LIMIT_BYTES} bytes")
    return body.decode("utf-8")


def params_source(workspace: Path) -> Source | None:
    params = workspace / "params.yaml"
    if not params.is_file():
        return None
    try:
        data = yaml.safe_load(params.read_text(encoding="utf-8")) or {}
    except (OSError, yaml.YAMLError) as exc:
        warn(f"params.yaml is not readable, {PARAMS_KEY} ignored: {exc}")
        return None
    value = data.get(PARAMS_KEY) if isinstance(data, dict) else None
    if not value:
        return None
    if not isinstance(value, str):
        warn(f"{PARAMS_KEY} in params.yaml must be a string, ignored")
        return None
    if value.startswith("https://"):
        try:
            return Source(f"{PARAMS_KEY} ({value})", fetch_url(value))
        except (OSError, CatalogError, UnicodeDecodeError) as exc:
            warn(f"{PARAMS_KEY} not downloaded, skipped: {exc}")
            return None
    if "://" in value:
        warn(f"{PARAMS_KEY} must be an https:// address or a local path, ignored: {value}")
        return None
    path = Path(os.path.expanduser(value))
    if not path.is_absolute():
        path = workspace / path
    try:
        return Source(f"{PARAMS_KEY} ({path})", path.read_text(encoding="utf-8"))
    except OSError as exc:
        warn(f"{PARAMS_KEY} file not readable, skipped: {exc}")
        return None


def collect_sources(workspace: Path) -> list[Source]:
    """User sources first, the shipped catalog last; unreadable user sources are skipped."""
    sources = []
    user_file = workspace / USER_CATALOG
    if user_file.is_file():
        try:
            sources.append(Source(str(USER_CATALOG), user_file.read_text(encoding="utf-8")))
        except OSError as exc:
            warn(f"{USER_CATALOG} not readable, skipped: {exc}")
    from_params = params_source(workspace)
    if from_params:
        sources.append(from_params)
    try:
        sources.append(Source("shipped", SHIPPED.read_text(encoding="utf-8")))
    except OSError as exc:
        raise CatalogError(f"shipped catalog not readable: {exc}") from exc
    return sources


def merge(sources: list[Source]) -> tuple[list[dict], set[str]]:
    """Merged valid entries (first source wins by name) and names marked internal-only.

    Internal-only names are collected from every source, so a lower-priority
    source cannot reopen an entry that a higher one closed, and vice versa.
    """
    merged: dict[str, dict] = {}
    internal: set[str] = set()
    for source in sources:
        try:
            entries = parse_catalog(source.text, source.label)
        except CatalogError as exc:
            if source.label == "shipped":
                raise
            warn(f"{exc}; source skipped")
            continue
        for index, entry in enumerate(entries):
            problems = entry_problems(entry)
            if problems:
                warn(f"{source.label}, entry #{index + 1} skipped: {'; '.join(problems)}")
                continue
            name = entry["name"]
            if entry.get("offered") == INTERNAL_ONLY:
                internal.add(name)
            if name not in merged:
                merged[name] = dict(entry, source=source.label)
    return list(merged.values()), internal


def load(workspace: Path) -> tuple[list[dict], set[str]]:
    entries, internal = merge(collect_sources(workspace))
    for entry in entries:
        entry["connected"] = (workspace / entry["name"] / ".git").exists()
    return entries, internal


def cmd_list(args: argparse.Namespace) -> int:
    entries, internal = load(args.workspace)
    offerable = [e for e in entries if e["name"] not in internal]
    if args.format == "json":
        print(json.dumps(offerable, ensure_ascii=False, indent=2))
        return EXIT_OK
    columns = ("name", "domain", "owner", "access", "audience", "connected", "source", "description", "url")
    print("\t".join(columns))
    for entry in offerable:
        row = [str(entry.get(c, "")) for c in columns]
        print("\t".join(cell.replace("\t", " ") for cell in row))
    return EXIT_OK


def cmd_show(args: argparse.Namespace) -> int:
    entries, internal = load(args.workspace)
    # Checked before the lookup: an internal entry is refused even when the
    # exact name is asked for and even when its repository is public.
    if args.name in internal:
        print(f"{args.name}: internal-only, never connected by subscription", file=sys.stderr)
        return EXIT_INTERNAL
    for entry in entries:
        if entry["name"] == args.name:
            print(json.dumps(entry, ensure_ascii=False, indent=2))
            return EXIT_OK
    print(f"{args.name}: not in the catalog", file=sys.stderr)
    return EXIT_MISSING


def cmd_validate(args: argparse.Namespace) -> int:
    try:
        entries = parse_catalog(args.file.read_text(encoding="utf-8"), str(args.file))
    except (OSError, CatalogError) as exc:
        print(f"INVALID: {exc}")
        return EXIT_INVALID
    problems = []
    seen: set[str] = set()
    for index, entry in enumerate(entries):
        problems += [f"entry #{index + 1}: {p}" for p in entry_problems(entry)]
        name = entry.get("name") if isinstance(entry, dict) else None
        if isinstance(name, str):
            if name in seen:
                problems.append(f"entry #{index + 1}: duplicate name '{name}'")
            seen.add(name)
    for problem in problems:
        print(f"INVALID: {problem}")
    if problems:
        return EXIT_INVALID
    print(f"OK: {args.file} ({len(entries)} entries)")
    return EXIT_OK


def default_workspace() -> Path:
    return Path(os.environ.get("IWE_WORKSPACE") or Path.home() / "IWE")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    p_list = sub.add_parser("list", help="storefront of offerable entries")
    p_list.add_argument("--workspace", type=Path, default=default_workspace())
    p_list.add_argument("--format", choices=("tsv", "json"), default="tsv")
    p_list.set_defaults(func=cmd_list)
    p_show = sub.add_parser("show", help="one entry or a refusal")
    p_show.add_argument("name")
    p_show.add_argument("--workspace", type=Path, default=default_workspace())
    p_show.set_defaults(func=cmd_show)
    p_validate = sub.add_parser("validate", help="check a catalog file")
    p_validate.add_argument("file", type=Path)
    p_validate.set_defaults(func=cmd_validate)
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except CatalogError as exc:
        print(f"[pack-catalog] {exc}", file=sys.stderr)
        return EXIT_USAGE


if __name__ == "__main__":
    sys.exit(main())
