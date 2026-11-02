#!/usr/bin/env python3
# see ADR-001-local-llm-stack.md (WP-404, Phase 2)
# Search pipeline: once every two weeks it checks the catalog against mlx-community trends.
# Outputs a digest of candidates that are not yet in the catalog. Read-only, no side effects.
# Run: python3 model-monitor.py [--catalog model-catalog.yaml]
import argparse
import json
import os
import sys
import urllib.error
import urllib.request

import yaml

HF_TIMEOUT_S = 15


def load_catalog(path):
    with open(path, encoding="utf-8") as f:
        return yaml.safe_load(f)


def hf_source(catalog):
    for s in catalog.get("sources", []):
        if s.get("name") == "hf-mlx-community" and s.get("api"):
            return s["api"]
    return None


def fetch_trending(api_url):
    req = urllib.request.Request(api_url, headers={"User-Agent": "iwe-model-monitor"})
    with urllib.request.urlopen(req, timeout=HF_TIMEOUT_S) as resp:
        return json.load(resp)


def active_id(catalog):
    for m in catalog.get("models", []):
        if m.get("status") == "active":
            return m["id"]
    return "—"


def digest(catalog, trending):
    known = {m["id"] for m in catalog.get("models", [])}
    fresh = [m for m in trending if m.get("id") not in known]
    return active_id(catalog), known, fresh


def main():
    ap = argparse.ArgumentParser()
    here = os.path.dirname(os.path.abspath(__file__))
    ap.add_argument("--catalog", default=os.path.join(here, "model-catalog.yaml"))
    args = ap.parse_args()

    catalog = load_catalog(args.catalog)
    api = hf_source(catalog)
    if not api:
        print("в каталоге нет источника hf-mlx-community — нечего опрашивать", file=sys.stderr)
        return 2

    print(f"Активная модель: {active_id(catalog)}")
    print(f"В каталоге моделей: {len(catalog.get('models', []))}")
    try:
        trending = fetch_trending(api)
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as e:
        print(f"\n[potentially stale] источник недоступен или вернул мусор ({e}) — дайджест не собран", file=sys.stderr)
        return 1

    if not isinstance(trending, list):   # 200 + an error object instead of an array (rate-limit / API change)
        print(f"\n[potentially stale] источник вернул не список ({type(trending).__name__}) — дайджест не собран", file=sys.stderr)
        return 1

    _, _, fresh = digest(catalog, trending)
    print(f"\nТрендовых mlx-community моделей получено: {len(trending)}")
    print(f"Новых (нет в каталоге): {len(fresh)}\n")
    for m in fresh[:10]:
        mid = m.get("id", "?")
        dl = m.get("downloads", 0)
        likes = m.get("likes", 0)
        print(f"  • {mid}  (загрузок {dl}, лайков {likes})")
    if fresh:
        print("\nЕсть кандидаты для сверки. Решение о добавлении в каталог — за пилотом (ручная сверка по LMArena).")
    else:
        print("Новых кандидатов нет — каталог актуален.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
