#!/usr/bin/env python3
# see ADR-001-local-llm-stack.md (WP404, Phase2)
# Discovery pipeline: checks the catalog against mlx-community trends every two weeks mlx-community.
# Outputs a digest of candidates, that are not yet in the catalog. Read-only, without side effects.
# Usage: python3 model-monitor.py [--catalog model-catalog.yaml]
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
        print("catalog has no hf-mlx-community source — nothing to query hf-mlx-community — nothing to query", file=sys.stderr)
        return 2

    print(f"Active model: {active_id(catalog)}")
    print(f"Models in catalog: {len(catalog.get('models', []))}")
    try:
        trending = fetch_trending(api)
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as e:
        print(f"\n[potentially stale] source unavailable or returned garbage ({e}) — digest not collected", file=sys.stderr)
        return 1

    if not isinstance(trending, list):   # 200 + error object instead of array (rate-limit/API change API)
        print(f"\n[potentially stale] source returned a non-list ({type(trending).__name__}) — digest not collected", file=sys.stderr)
        return 1

    _, _, fresh = digest(catalog, trending)
    print(f"\nTrending mlx-community mlx-community models retrieved: {len(trending)}")
    print(f"New (not in catalog): {len(fresh)}\n")
    for m in fresh[:10]:
        mid = m.get("id", "?")
        dl = m.get("downloads", 0)
        likes = m.get("likes", 0)
        print(f"  • {mid}  (downloads {dl}, likes {likes})")
    if fresh:
        print("\nCandidates available for review. Decision to add to catalog — up to the pilot (manual review via LMArena).")
    else:
        print("No new candidates — catalog is up to date — catalog is up to date.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
