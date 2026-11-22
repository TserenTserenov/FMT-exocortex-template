#!/usr/bin/env python3
"""
generate-rules-registry.py — build rules-registry.yaml from PACK-agent-rules/rules/AR.NNN.md.

Parses frontmatter each rule file, validates required fields,
builds dependency graph, outputs single yaml registry for rule-engine.sh.

Usage: python3 generate-rules-registry.py [--validate]
Output: ~/IWE/.claude/rules-registry.yaml
"""

import os
import re
import sys
import yaml
from pathlib import Path

PACK_DIR = Path.home() / "IWE" / "PACK-agent-rules" / "rules"
OUTPUT = Path.home() / "IWE" / ".claude" / "rules-registry.yaml"

REQUIRED_FIELDS = {"id", "name", "type", "priority", "status", "triggers", "tests", "hook"}
VALID_TYPES = {"structural", "behavioural", "procedural"}
VALID_STATUSES = {"active", "draft", "deprecated", "superseded"}
# WP-295 Phase5: deterministic step pre/post-conditions. Optional, backward-compatible.
VALID_ON_FAIL = {"warn", "block"}

def parse_frontmatter(filepath):
    """Extract YAML frontmatter from markdown file."""
    content = filepath.read_text(encoding="utf-8")
    match = re.match(r'^---\n(.*?)\n---\n', content, re.DOTALL)
    if not match:
        return None
    try:
        return yaml.safe_load(match.group(1))
    except yaml.YAMLError as e:
        print(f"ERROR: invalid YAML in {filepath.name}: {e}", file=sys.stderr)
        return None

def validate_rule(rule, filename):
    """Validate required fields and value correctness."""
    errors = []
    missing = REQUIRED_FIELDS - set(rule.keys())
    if missing:
        errors.append(f"{filename}: missing fields {missing}")

    if rule.get("type") not in VALID_TYPES:
        errors.append(f"{filename}: invalid type '{rule.get('type')}', expected {VALID_TYPES}")

    if rule.get("status") not in VALID_STATUSES:
        errors.append(f"{filename}: invalid status '{rule.get('status')}'")

    priority = rule.get("priority")
    if not isinstance(priority, int) or priority < 1 or priority > 15:
        errors.append(f"{filename}: priority must be int 1-15, got {priority}")

    rule_type = rule.get("type")
    if rule_type == "structural" and (priority or 99) > 5:
        errors.append(f"{filename}: structural rule must have priority 1-5")
    if rule_type == "behavioural" and ((priority or 0) < 6 or (priority or 0) > 10):
        errors.append(f"{filename}: behavioural rule must have priority 6-10")
    if rule_type == "procedural" and ((priority or 0) < 11 or (priority or 0) > 15):
        errors.append(f"{filename}: procedural rule must have priority 11-15")

    tests = rule.get("tests", {})
    if not isinstance(tests, dict):
        # Legacy format `tests: [...]` (list) does not carry positive/negative semantics positive/negative —
        # mark as invalid, do NOT coerce. Without this .get() raises AttributeError
        # and crashes the entire generator (WP-419, peer-session 2026-06-14-03).
        errors.append(f"{filename}: tests must be a dict with positive+negative keys, got {type(tests).__name__}")
    elif not tests.get("positive") or not tests.get("negative"):
        errors.append(f"{filename}: must have both positive and negative tests")

    # WP-295 Phase5: optional pre/post-conditions. When present, each must be a mapping
    # with a non-empty 'check' (named deterministic check resolved by rule-engine.sh)
    # and 'on_fail' in {warn, block}. Absent field = no conditions (backward-compatible).
    errors.extend(validate_conditions(rule, filename))

    return errors


def validate_conditions(rule, filename):
    """Validate optional pre_conditions / post_conditions structure (WP-295 Phase5)."""
    errors = []
    for field in ("pre_conditions", "post_conditions"):
        conds = rule.get(field)
        if conds is None:
            continue
        if not isinstance(conds, list):
            errors.append(f"{filename}: {field} must be a list, got {type(conds).__name__}")
            continue
        for i, cond in enumerate(conds):
            if not isinstance(cond, dict):
                errors.append(f"{filename}: {field}[{i}] must be a mapping with 'check' and 'on_fail'")
                continue
            if not cond.get("check"):
                errors.append(f"{filename}: {field}[{i}] missing non-empty 'check'")
            if cond.get("on_fail") not in VALID_ON_FAIL:
                errors.append(f"{filename}: {field}[{i}] on_fail must be one of {sorted(VALID_ON_FAIL)}, got {cond.get('on_fail')!r}")
    return errors

def validate_cross_refs(rules):
    """WP-272 Phase2.5 (R23 audit F5): verify that all conflicts_with / depends_on /
    superseded_by reference existing rules."""
    errors = []
    rule_ids = {r["id"] for r in rules}
    for r in rules:
        for ref_field in ("conflicts_with", "depends_on"):
            for ref_id in r.get(ref_field, []) or []:
                if ref_id and ref_id not in rule_ids:
                    errors.append(f"{r['id']}: {ref_field} references non-existent rule '{ref_id}'")
        sup = r.get("superseded_by")
        if sup and sup not in rule_ids:
            errors.append(f"{r['id']}: superseded_by references non-existent rule '{sup}'")
    return errors


def validate_no_cycles(rules):
    """WP-272 Phase4 closure (audit VR.R.002, 27 Apr): verify, that the graph depends_on
    is acyclic (DFS with coloring). A cycle = design error: A → B → A
    means, that one of the directions is wrong direction'directions is incorrect (one of the rules — is a special case of another
    or the dependency points in the wrong direction)."""
    errors = []
    graph = {r["id"]: list(r.get("depends_on") or []) for r in rules}
    WHITE, GRAY, BLACK = 0, 1, 2
    color = {rid: WHITE for rid in graph}

    def dfs(node, path):
        if color[node] == GRAY:
            cycle = path[path.index(node):] + [node]
            errors.append(f"cycle detected in depends_on: {' → '.join(cycle)}")
            return
        if color[node] == BLACK:
            return
        color[node] = GRAY
        for nbr in graph.get(node, []):
            if nbr in graph:
                dfs(nbr, path + [node])
        color[node] = BLACK

    for rid in graph:
        if color[rid] == WHITE:
            dfs(rid, [])
    return errors


def build_registry(skip_invalid=False):
    """skip_invalid=False (--validate): any error → exit 2, registry is not written (strict gate).
    skip_invalid=True (generate): invalid rules are skipped with a warning, registry
    is assembled from valid rules. Without this a single drifted file (legacy tests format tests) blocked
    regeneration of the entire registry — the generator had been dead since 8 May (WP-419, peer-session 2026-06-14-03)."""
    rules = []
    invalid_errors = []   # per-file: invalid file is skipped

    if not PACK_DIR.exists():
        print(f"ERROR: PACK-agent-rules/rules/ not found at {PACK_DIR}", file=sys.stderr)
        sys.exit(1)

    for rule_file in sorted(PACK_DIR.glob("AR.*.md")):
        fm = parse_frontmatter(rule_file)
        if not fm:
            invalid_errors.append(f"{rule_file.name}: no frontmatter")
            continue

        errors = validate_rule(fm, rule_file.name)
        if errors:
            invalid_errors.extend(errors)
            continue

        # `related` sometimes formatted as a list instead of a dict — we normalize it, otherwise .get() crashes.
        related = fm.get("related", {})
        if not isinstance(related, dict):
            related = {}

        rules.append({
            "id": fm["id"],
            "name": fm["name"],
            "type": fm["type"],
            "priority": fm["priority"],
            "status": fm["status"],
            "triggers": fm["triggers"],
            "applies_when": fm.get("applies_when", "true"),
            "exceptions": fm.get("exceptions", []),
            "hook": fm["hook"],
            "pre_conditions": fm.get("pre_conditions", []),
            "post_conditions": fm.get("post_conditions", []),
            "conflicts_with": related.get("conflicts_with", []),
            "depends_on": related.get("depends_on", []),
            "superseded_by": related.get("superseded_by"),
            "source_file": str(rule_file.relative_to(Path.home() / "IWE")),
        })

    # Cross-ref + cycle: counted only over the collected valid rules.
    # depends_on pointing to a skipped (invalid) rule → warning, not a blocker (in skip-mode).
    ref_errors = validate_cross_refs(rules) + validate_no_cycles(rules)

    if not skip_invalid:
        all_errors = invalid_errors + ref_errors
        if all_errors:
            print("Validation errors:", file=sys.stderr)
            for e in all_errors:
                print(f"  {e}", file=sys.stderr)
            sys.exit(2)
    else:
        if invalid_errors:
            print(f"⚠️  invalid rules skipped: {len(invalid_errors)} (see. below; fixed separately — rules registry resync)", file=sys.stderr)
            for e in invalid_errors:
                print(f"  (skipped) {e}", file=sys.stderr)
        if ref_errors:
            print(f"⚠️  cross-ref/cycle warnings: {len(ref_errors)} (reference to a skipped rule — not a blocker)", file=sys.stderr)
            for e in ref_errors:
                print(f"  (warn) {e}", file=sys.stderr)

    rules.sort(key=lambda r: r["priority"])

    return {
        "schema_version": "1.0",
        "generated_at": "auto",
        "source": "PACK-agent-rules/rules/",
        "rule_count": len(rules),
        "rules": rules,
    }

def main():
    validate_only = "--validate" in sys.argv

    # generate: skip-invalid (best-effort registry built from valid rules); --validate: strict gate
    registry = build_registry(skip_invalid=not validate_only)

    if validate_only:
        print(f"OK: {registry['rule_count']} rules validated")
        return

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    with OUTPUT.open("w", encoding="utf-8") as f:
        yaml.safe_dump(registry, f, allow_unicode=True, sort_keys=False, default_flow_style=False)

    print(f"OK: registry generated → {OUTPUT}")
    print(f"     {registry['rule_count']} rules")
    types = {}
    for r in registry["rules"]:
        types[r["type"]] = types.get(r["type"], 0) + 1
    for t, n in types.items():
        print(f"     {t}: {n}")

if __name__ == "__main__":
    main()
