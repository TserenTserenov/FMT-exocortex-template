#!/usr/bin/env bash
# cp1251-smoke.sh — issue #1114 phase 1: run a small representative subset of
# platform Python scripts with PYTHONIOENCODING=cp1251 (the Windows console
# encoding the issue is about) and assert none of them crashes with a
# Unicode*Error. Safe on a bare runner: read-only, no network, writes only
# into a mktemp sandbox.
#
# Included candidates:
#   - scripts/check-manifest-coverage.py — full run against the real manifest
#     (read-only; already fixed: reconfigures stdout to UTF-8 and opens with
#     encoding=), plus its no-arg usage path (exit 2 = usage, not a crash).
#   - scripts/wp-list.py --list-cards against an empty temp workspace —
#     read-only, ASCII output.
#
# Excluded candidates (from the issue's already-fixed list), with reasons:
#   - scripts/wp-list.py --help — still crashes under cp1251: argparse prints
#     the module docstring, which contains '→'. Phase 1 is a gate against NEW
#     violations, not a mass fix; including it would keep this smoke red.
#   - setup/integration-contract-validator.sh inline python — the validator is
#     a full-repo audit that needs jq and a full checkout; not a small
#     bare-safe subset (its own CI jobs already run it on every push).
#   - scripts/day-close.sh — no safe --help/no-arg/dry path: the default run
#     executes backup + reindex + linear sync (network) + session writes.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# python-resolver contract: no bare python3 — resolve via find-python3.sh
# (stdlib suffices for the covered scripts).
PYTHON3=$("$ROOT/scripts/lib/find-python3.sh" --stdlib-only) || {
  echo "FAIL: python3 not found (find-python3.sh)" >&2
  exit 1
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/DS-strategy/inbox"

FAILURES=0

# run_case <name> <expected-exit> <cmd...> — fails on Unicode*Error/Traceback
# in output or on an unexpected exit code.
run_case() {
  local name="$1" expected="$2"
  shift 2
  local out code
  out=$(PYTHONIOENCODING=cp1251 "$@" 2>&1) && code=0 || code=$?
  if printf '%s\n' "$out" | grep -qE 'UnicodeEncodeError|UnicodeDecodeError|Traceback'; then
    echo "  FAIL: $name — Unicode crash under cp1251:"
    printf '%s\n' "$out" | tail -5
    FAILURES=$((FAILURES + 1))
    return
  fi
  if [ "$code" -ne "$expected" ]; then
    echo "  FAIL: $name — ожидался exit $expected, получен $code:"
    printf '%s\n' "$out" | tail -5
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "  ok: $name"
}

run_case "check-manifest-coverage.py full run" 0 \
  bash -c 'git ls-files | "$1" scripts/check-manifest-coverage.py update-manifest.json' _ "$PYTHON3"
run_case "check-manifest-coverage.py no-arg usage (exit 2, not a crash)" 2 \
  "$PYTHON3" scripts/check-manifest-coverage.py
run_case "wp-list.py --list-cards on empty temp workspace" 0 \
  "$PYTHON3" scripts/wp-list.py --list-cards --iwe-root "$TMP" --governance-repo DS-strategy

echo ""
if [ "$FAILURES" -eq 0 ]; then
  echo "PASS: cp1251 smoke — no Unicode*Error in the covered scripts"
  exit 0
else
  echo "FAIL: $FAILURES cp1251 smoke cases failed"
  exit 1
fi
