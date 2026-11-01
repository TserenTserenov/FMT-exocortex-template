#!/usr/bin/env python3
"""Обойти инструмент concept_list шлюза и записать вход для export-glossary-snapshot.py (WP-5 Ф67).

Секрет сервисного ключа читается из переменной окружения GLOSSARY_EXPORTER_SERVICE_SECRET.
После обхода проверяются контрольные коды из эталона (inbox/WP-5/f67-nabor-priemki-shluza.md)
и полнота: число строк равно concepts - hidden_by_closed_sources_count из graph_stats.
Расхождение — обход повторяется (граф мог измениться), после исчерпания попыток файл не пишется.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.request
from collections.abc import Callable
from pathlib import Path

ENDPOINT = "https://knowledge-mcp.aisystant.workers.dev/mcp"
SECRET_ENV = "GLOSSARY_EXPORTER_SERVICE_SECRET"
AUTH_HEADER = "X-IWE-Service-Auth"
# Край Cloudflare отдаёт 403 запросам без собственного User-Agent.
USER_AGENT = "iwe-glossary-exporter/1"
PAGE_LIMIT = 500
MAX_ATTEMPTS = 3
RULES_VERSION = "name-en-publishable/1"

# Эталон набора приёмки: код -> (name_en, name_en_publishable) либо None, если в графе его нет.
CONTROLS: dict[str, tuple[str | None, bool] | None] = {
    "ZP.1": ("Axiomaticity", True),
    "U.Entity": ("Entity", True),
    "ECO.FM.001": ("ECO.FM.001", True),
    "MIM.M.024": (None, False),
    "ECO.PRIN.001": None,
}

Transport = Callable[[dict], dict]


class FetchError(Exception):
    """Обход не дал проверенного входа. Файл не пишется."""


def http_transport(secret: str, endpoint: str = ENDPOINT) -> Transport:
    def post(payload: dict) -> dict:
        request = urllib.request.Request(
            endpoint,
            data=json.dumps(payload).encode("utf-8"),
            headers={
                "Content-Type": "application/json",
                "Accept": "application/json",
                AUTH_HEADER: secret,
                "User-Agent": USER_AGENT,
            },
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=120) as response:
            return json.loads(response.read().decode("utf-8"))

    return post


def call_tool(post: Transport, name: str, arguments: dict) -> dict:
    response = post(
        {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": name, "arguments": arguments}}
    )
    if response.get("error"):
        raise FetchError(f"{name}: {response['error'].get('message')}")
    return json.loads(response["result"]["content"][0]["text"])


def walk_pages(post: Transport) -> tuple[list[dict], str]:
    rows: list[dict] = []
    as_of = ""
    after_id = 0
    while True:
        page = call_tool(post, "concept_list", {"after_id": after_id, "limit": PAGE_LIMIT})
        rows.extend(page["rows"])
        as_of = page["as_of"]
        after_id = page["next_after_id"]
        if after_id is None:
            return rows, as_of


def check_controls(rows: list[dict]) -> None:
    by_code = {row["code"]: row for row in rows}
    for code, expected in CONTROLS.items():
        row = by_code.get(code)
        if expected is None:
            if row is not None:
                raise FetchError(f"контрольный код {code} виден через шлюз, а в эталоне его нет")
            continue
        if row is None:
            raise FetchError(f"контрольный код {code} не виден через шлюз")
        name_en, publishable = expected
        got = (row["name_en"], row["name_en_publishable"])
        if got != (name_en, publishable):
            raise FetchError(f"контрольный код {code}: ожидалось {expected}, получено {got}")
    versions = {row["name_en_publishable_rules_version"] for row in rows}
    if versions != {RULES_VERSION}:
        raise FetchError(f"версии правил в обходе: {sorted(map(str, versions))}, ожидалась {RULES_VERSION}")


def completeness_error(rows: list[dict], stats: dict) -> str | None:
    expected_rows = stats["concepts"] - stats["hidden_by_closed_sources_count"]
    expected_publishable = stats["name_en_publishable_count"] - stats["name_en_publishable_hidden_count"]
    publishable = sum(1 for row in rows if row["name_en_publishable"] is True)
    if len(rows) != expected_rows or publishable != expected_publishable:
        return (
            f"строк {len(rows)} вместо {expected_rows}, публикуемых {publishable} вместо {expected_publishable}"
        )
    return None


def fetch_payload(post: Transport) -> dict:
    last_error = ""
    for _ in range(MAX_ATTEMPTS):
        stats_before = call_tool(post, "graph_stats", {})
        rows, as_of = walk_pages(post)
        check_controls(rows)
        stats_after = call_tool(post, "graph_stats", {})
        last_error = completeness_error(rows, stats_before) or completeness_error(rows, stats_after) or ""
        if not last_error:
            return {
                "as_of": as_of,
                "rows": [{**{k: v for k, v in row.items() if k != "name"}, "name_ru": row["name"]} for row in rows],
            }
    raise FetchError(f"снимок неполный после {MAX_ATTEMPTS} обходов: {last_error}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Обход concept_list для выгрузки снимка терминов")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args(argv)
    secret = os.environ.get(SECRET_ENV, "")
    if not secret:
        print(f"fetch-glossary-concepts: нет переменной {SECRET_ENV}", file=sys.stderr)
        return 2
    try:
        payload = fetch_payload(http_transport(secret))
    except (FetchError, OSError, KeyError, ValueError) as exc:
        print(f"fetch-glossary-concepts: {exc}", file=sys.stderr)
        return 2
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
    print(f"rows={len(payload['rows'])} as_of={payload['as_of']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
