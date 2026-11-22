#!/usr/bin/env python3
# see ADR-001-local-llm-stack.md (WP404, Phase2)
# Local model lifecycle: analysis -> testing -> active -> archived.
# Source of truth — model-catalog.yaml (edited with comments preserved).
# "Downloaded" verified via HuggingFace cache HuggingFace (actual fact, not a flag).
#
# Commands:
#   list                 list models by the four states + download fact
#   active               print id the active model id (for the server)
#   use <id>             make active (previous active -> testing)
#   archive <id>         move to archive
#   set <id> <status>    transition to an arbitrary state
#   add <id> [--status S --params-b N --min-ram-gb M --note T]
import argparse
import os
import sys

from ruamel.yaml import YAML

STATES = ("analysis", "testing", "active", "archived")
HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_CATALOG = os.path.join(HERE, "model-catalog.yaml")
yaml = YAML()  # round-trip by default: comments and order are preserved
yaml.width = 4096  # do not wrap long lines (URL source)


def load(path):
    with open(path, encoding="utf-8") as f:
        return yaml.load(f)


def save(path, data):
    tmp = path + ".tmp"   # atomically: write to a temp file, then replace (the catalog will not be corrupted on failure)
    with open(tmp, "w", encoding="utf-8") as f:
        yaml.dump(data, f)
    os.replace(tmp, path)


def models(data):
    return data.get("models", [])


def find(data, model_id):
    for m in models(data):
        if m.get("id") == model_id:
            return m
    return None


def is_downloaded(model_id):
    # HF caches as hub/models--<org>--<name>
    hf = os.environ.get("HF_HOME", os.path.expanduser("~/.cache/huggingface"))
    slug = "models--" + model_id.replace("/", "--")
    return os.path.isdir(os.path.join(hf, "hub", slug))


def cmd_list(data, _args):
    by_state = {s: [] for s in STATES}
    for m in models(data):
        by_state.get(m.get("status", "analysis"), by_state["analysis"]).append(m)
    titles = {
        "analysis": "Under analysis (under consideration)",
        "testing": "For testing (downloaded)",
        "active": "Active (in use)",
        "archived": "Archived",
    }
    for s in STATES:
        print(f"\n{titles[s]}:")
        if not by_state[s]:
            print("  —")
        for m in by_state[s]:
            mid = m.get("id", "?")
            mark = "downloaded" if is_downloaded(mid) else "not downloaded"
            print(f"  • {mid}  ({m.get('params_b','?')}B, {mark})")
    return 0


def cmd_active(data, _args):
    actives = [m for m in models(data) if m.get("status") == "active"]
    if len(actives) > 1:
        ids = ", ".join(m.get("id", "?") for m in actives)
        print(f"warning: in catalog {len(actives)} active ({ids}) — taking the first one", file=sys.stderr)
    if actives:
        print(actives[0]["id"])
        return 0
    for m in models(data):  # fallback: recommended
        if m.get("recommended"):
            print(m["id"])
            return 0
    sys.exit("catalog contains neither an active, nor a recommended model")


def set_status(data, model_id, status):
    if status not in STATES:
        sys.exit(f"unknown status: {status} (from {STATES})")
    m = find(data, model_id)
    if not m:
        sys.exit(f"model not in catalog: {model_id} (add it via add)")
    if status == "active":
        for other in models(data):
            if other.get("status") == "active" and other.get("id") != model_id:
                other["status"] = "testing"  # the previous active model remains downloaded
    m["status"] = status


def cmd_use(data, args):
    set_status(data, args.id, "active")
    return 0


def cmd_archive(data, args):
    set_status(data, args.id, "archived")
    return 0


def cmd_set(data, args):
    set_status(data, args.id, args.status)
    return 0


def cmd_add(data, args):
    if find(data, args.id):
        sys.exit(f"already in catalog: {args.id}")
    entry = {"id": args.id, "status": "analysis"}
    if args.params_b is not None:
        entry["params_b"] = args.params_b
    if args.min_ram_gb is not None:
        entry["min_ram_gb"] = args.min_ram_gb
    if args.note:
        entry["note"] = args.note
    models(data).append(entry)
    set_status(data, args.id, args.status)  # through invariant: --status active demotes the previous one
    return 0


WRITERS = {"use", "archive", "set", "add"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--catalog", default=DEFAULT_CATALOG)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list")
    sub.add_parser("active")
    p_use = sub.add_parser("use"); p_use.add_argument("id")
    p_arch = sub.add_parser("archive"); p_arch.add_argument("id")
    p_set = sub.add_parser("set"); p_set.add_argument("id"); p_set.add_argument("status")
    p_add = sub.add_parser("add")
    p_add.add_argument("id")
    p_add.add_argument("--status", default="analysis")
    p_add.add_argument("--params-b", type=int, dest="params_b")
    p_add.add_argument("--min-ram-gb", type=int, dest="min_ram_gb")
    p_add.add_argument("--note")
    args = ap.parse_args()

    data = load(args.catalog)
    rc = {
        "list": cmd_list, "active": cmd_active, "use": cmd_use,
        "archive": cmd_archive, "set": cmd_set, "add": cmd_add,
    }[args.cmd](data, args)
    if args.cmd in WRITERS:
        save(args.catalog, data)
    return rc


if __name__ == "__main__":
    sys.exit(main())
