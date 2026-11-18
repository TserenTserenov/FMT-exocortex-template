#!/usr/bin/env python3
"""
generate-diagnose-skill.py

SoT: shared/rubrics/form-089.yaml
SKILL.md: содержит рубрики статически (в Шагах 2-4).
Этот скрипт НЕ генерирует SKILL.md — он проверяет, что вопросы из YAML
присутствуют в SKILL.md (drift detection).

Usage:
  python scripts/generate-diagnose-skill.py --check  # verify sync, exit 1 if stale
"""
import argparse
import pathlib
import sys
import yaml

REPO_ROOT = pathlib.Path(__file__).parent.parent
YAML_PATH = REPO_ROOT / "shared" / "rubrics" / "form-089.yaml"
SKILL_PATH = REPO_ROOT / ".claude" / "skills" / "diagnose" / "SKILL.md"


def check():
    if not YAML_PATH.exists():
        print(f"ERROR: YAML not found: {YAML_PATH}", file=sys.stderr)
        sys.exit(1)

    if not SKILL_PATH.exists():
        print(f"ERROR: SKILL.md not found: {SKILL_PATH}", file=sys.stderr)
        sys.exit(1)

    try:
        data = yaml.safe_load(YAML_PATH.read_text(encoding="utf-8"))
    except yaml.YAMLError as e:
        print(f"ERROR: Invalid YAML in {YAML_PATH}: {e}", file=sys.stderr)
        sys.exit(1)
    skill_text = SKILL_PATH.read_text(encoding="utf-8")

    missing = []

    # Check phase 1 questions
    for slot_key, slot in data.get("slots", {}).items():
        question = slot["question"].strip()
        if question not in skill_text:
            missing.append(f"Phase 1 question missing: {slot_key}")
        # Check scale labels
        for val, label in slot.get("scale", {}).items():
            if label not in skill_text:
                missing.append(f"Scale label missing: {slot_key} level {val}")

    # Check drill-down questions
    for slot_key, slot in data.get("drill_down", {}).items():
        question = slot["question"].strip()
        if question not in skill_text:
            missing.append(f"Drill-down missing: {slot_key}")
        for val, label in slot.get("scale", {}).items():
            if label not in skill_text:
                missing.append(f"Drill-down scale missing: {slot_key} level {val}")

    # Check scoring formulas
    scoring = data.get("scoring", {})
    formulas = [
        scoring.get("stage_formula", ""),
        scoring.get("bottleneck_formula", ""),
    ]
    for formula in formulas:
        if formula and formula not in skill_text:
            missing.append(f"Formula missing: {formula}")

    if missing:
        print("ERROR: diagnose/SKILL.md is stale.", file=sys.stderr)
        for m in missing:
            print(f"  - {m}", file=sys.stderr)
        print("       Update SKILL.md to match shared/rubrics/form-089.yaml", file=sys.stderr)
        sys.exit(1)

    print("OK: diagnose/SKILL.md is in sync with YAML.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="Verify sync without writing")
    args = parser.parse_args()

    if args.check:
        check()
    else:
        print("INFO: This script only supports --check mode.")
        print("      SKILL.md contains rubrics statically; YAML is SoT for drift detection.")
        print("      Run with --check to verify sync.")
