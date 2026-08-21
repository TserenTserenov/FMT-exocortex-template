#!/bin/bash
# test-day-open-delivery-closure.sh — WP-529 F7 acceptance test for the Day Open
# delivery contract: every runtime dependency of scripts/day-open-pipeline.sh
# must resolve inside the delivery root (template scripts/ + seed mirror), with
# transitive closure over python imports and shell sources — not just the files
# someone remembered to list. Spec: peer sessions 2026-08-20-42 (5-point fixture
# spec) and 2026-08-21-17 (baseline->promote->green protocol, codex amendments:
# dynamic call sites, +x/shebang, manifest duplicates, extension-graph strict
# xfail until ArchGate Q1).
#
# Bash 3.2 compatible on purpose (macOS /bin/bash): no declare -A, no mapfile.
#
# Usage: bash setup/test-day-open-delivery-closure.sh

set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SELF_DIR")"
PIPELINE="$REPO_ROOT/scripts/day-open-pipeline.sh"
SEED_SCRIPTS="$REPO_ROOT/seed/strategy/scripts"
MANIFEST="$REPO_ROOT/update-manifest.json"

FAIL_COUNT=0
PASS_COUNT=0
XFAIL_COUNT=0
fail() { echo "  ❌ FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
pass() { echo "  ✅ PASS: $*"; PASS_COUNT=$((PASS_COUNT + 1)); }
xfail() { echo "  ⏸  XFAIL (expected until ArchGate): $*"; XFAIL_COUNT=$((XFAIL_COUNT + 1)); }

[ -f "$PIPELINE" ] || { echo "FATAL: $PIPELINE not found" >&2; exit 2; }

# --- 1. Closure of $DS_STRATEGY/scripts/ references in the pipeline ----------
# Dynamic extraction (codex amendment: no hand-kept list): every literal
# $DS_STRATEGY/scripts/<path> the pipeline mentions, in any call form (direct,
# bash -c, heredoc) — the literal is what delivery must satisfy.
echo "=== 1. Pipeline references resolve inside the delivery root ==="
STRATEGY_REFS=$(grep -o '\$DS_STRATEGY/scripts/[a-zA-Z0-9._/-]*' "$PIPELINE" | sed 's|^\$DS_STRATEGY/||' | sort -u)
# An empty extraction means the regex no longer matches the pipeline (variable
# renamed, quoting changed) — every section below would loop zero times and the
# test would pass while checking nothing (cold review 2026-08-21-17, High).
if [ -z "$STRATEGY_REFS" ]; then
  fail "no \$DS_STRATEGY/scripts/ references extracted from pipeline — extraction regex broken"
fi
for rel in $STRATEGY_REFS; do
  f="$REPO_ROOT/$rel"
  if [ -f "$f" ]; then
    pass "delivered: $rel"
  else
    fail "referenced by pipeline but NOT delivered in template: $rel"
    continue
  fi
  case "$rel" in
    *.sh)
      [ -x "$f" ] && pass "executable bit: $rel" || fail "missing +x: $rel"
      head -1 "$f" | grep -q '^#!' && pass "shebang: $rel" || fail "missing shebang: $rel"
      ;;
  esac
  # Seed mirror: the pipeline itself ships in seed for fresh installs, so every
  # $DS_STRATEGY-relative dependency must ship there too (2026-08-20-42, theme 4:
  # update path and seed are two separate delivery axes).
  if [ -f "$SEED_SCRIPTS/$rel" ] || [ -f "$SEED_SCRIPTS/${rel#scripts/}" ]; then
    pass "seed mirror: $rel"
  else
    fail "not mirrored into seed/strategy/: $rel"
  fi
done

# --- 2. Transitive closure: python imports and shell sources ------------------
echo "=== 2. Transitive closure (imports / sources) ==="
LIB_PY_MODULES=""
if [ -d "$REPO_ROOT/scripts/lib" ]; then
  LIB_PY_MODULES=$(ls "$REPO_ROOT/scripts/lib"/*.py 2>/dev/null | sed 's|.*/||; s|\.py$||')
fi
for rel in $STRATEGY_REFS; do
  f="$REPO_ROOT/$rel"
  [ -f "$f" ] || continue
  case "$rel" in
    *.py)
      # Local module imports (scripts/lib/*.py style: from X import / import X).
      IMPORTS=$(grep -E '^[[:space:]]*(from|import)[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*' "$f" | sed -E 's/^[[:space:]]*(from|import)[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*).*/\2/' | sort -u)
      for mod in $IMPORTS; do
        # Only local lib modules are delivery obligations; stdlib/3rd-party are not.
        libfile="$REPO_ROOT/scripts/lib/$mod.py"
        if echo "$IMPORTS" | grep -q "^$mod$" && [ -f "$libfile" ]; then
          pass "local import satisfied: $rel -> lib/$mod.py"
          [ -f "$SEED_SCRIPTS/lib/$mod.py" ] && pass "seed mirror: lib/$mod.py" || fail "lib/$mod.py not mirrored into seed"
        else
          # Missing local module is only a failure if some scripts/lib/<mod>.py
          # exists nowhere AND the import is known-local (wp_inbox, ledger_path
          # naming convention: module files we deliver under scripts/lib/).
          case "$mod" in
            wp_inbox|ledger_path)
              [ -f "$libfile" ] || fail "local import NOT delivered: $rel imports $mod (expected scripts/lib/$mod.py)"
              ;;
          esac
        fi
      done
      ;;
    *.sh)
      SOURCES=$(grep -oE '(source|\.)[[:space:]]+"?\$?[A-Za-z_{}]*/?(scripts/)?lib/[a-zA-Z0-9._-]+\.sh' "$f" | grep -o 'lib/[a-zA-Z0-9._-]*\.sh' | sort -u)
      for libref in $SOURCES; do
        if [ -f "$REPO_ROOT/scripts/$libref" ]; then
          pass "shell source satisfied: $rel -> $libref"
          [ -f "$SEED_SCRIPTS/$libref" ] && pass "seed mirror: $libref" || fail "$libref not mirrored into seed"
        else
          fail "shell source NOT delivered: $rel sources $libref"
        fi
      done
      ;;
  esac
done

# --- 2b. Pipeline-own dependencies invisible to $DS_STRATEGY extraction -------
# find-python3.sh is sourced via $(dirname BASH_SOURCE)/lib/ — not a
# $DS_STRATEGY literal, so section 1 never sees it; without this check its
# deletion would go unnoticed (RESOLVED_PY silently falls back to python3).
echo "=== 2b. Resolver delivery (BASH_SOURCE-relative dependency) ==="
if [ -f "$REPO_ROOT/scripts/lib/find-python3.sh" ] && [ -x "$REPO_ROOT/scripts/lib/find-python3.sh" ]; then
  pass "delivered + executable: scripts/lib/find-python3.sh"
else
  fail "scripts/lib/find-python3.sh missing or not executable"
fi
[ -f "$SEED_SCRIPTS/lib/find-python3.sh" ] && pass "seed mirror: lib/find-python3.sh" || fail "lib/find-python3.sh not mirrored into seed"
if [ -f "$MANIFEST" ]; then
  n=$(grep -c '"scripts/lib/find-python3.sh"' "$MANIFEST") || true
  [ "$n" -eq 1 ] && pass "manifest exactly once: scripts/lib/find-python3.sh" || fail "manifest entries for scripts/lib/find-python3.sh: $n (expected 1)"
fi

# --- 3. Entry points run from a foreign cwd with a clean PYTHONPATH -----------
echo "=== 3. Foreign-cwd smoke (clean PYTHONPATH) ==="
RESOLVED_PY=""
[ -x "$REPO_ROOT/scripts/lib/find-python3.sh" ] && RESOLVED_PY=$("$REPO_ROOT/scripts/lib/find-python3.sh" 2>/dev/null) || true
[ -n "$RESOLVED_PY" ] || RESOLVED_PY="python3"
SMOKE_DIR="/tmp/iwe-dayopen-closure-smoke-$$"
mkdir -p "$SMOKE_DIR"
for rel in $STRATEGY_REFS; do
  f="$REPO_ROOT/$rel"
  [ -f "$f" ] || continue
  case "$rel" in
    scripts/day-open-*.py)
      if (cd "$SMOKE_DIR" && PYTHONPATH= "$RESOLVED_PY" "$f" --help >/dev/null 2>&1); then
        pass "runs from foreign cwd: $rel --help"
      else
        fail "broken from foreign cwd (import/path error?): $rel --help"
      fi
      ;;
  esac
done
rm -rf "$SMOKE_DIR"

# --- 4. Manifest: each delivered closure file present, no duplicate entries ---
echo "=== 4. update-manifest.json coverage ==="
if [ -f "$MANIFEST" ]; then
  for rel in $STRATEGY_REFS; do
    [ -f "$REPO_ROOT/$rel" ] || continue
    n=$(grep -c "\"$rel\"" "$MANIFEST") || true
    if [ "$n" -eq 1 ]; then
      pass "manifest exactly once: $rel"
    elif [ "$n" -eq 0 ]; then
      fail "missing from manifest: $rel"
    else
      fail "duplicate manifest entries ($n): $rel"
    fi
  done
else
  fail "update-manifest.json not found"
fi

# --- 5. Extension graph: strict xfail until ArchGate question 1 ---------------
# The before/core/after/checks hook order is NOT implemented yet by design —
# ArchGate question 1 (WP-529 F7, peer session 2026-08-20-42 §4). If a dispatcher
# appears, this XPASS must fail loudly so the test is consciously updated with
# the decided contract, never silently blessed (no unnoticed XPASS).
echo "=== 5. Extension graph (ArchGate Q1) ==="
if grep -qE 'load-extensions\.sh[[:space:]]+day-open|extension-graph' "$PIPELINE"; then
  fail "XPASS: extension dispatcher appeared in pipeline — update this test per ArchGate Q1 decision before merging"
else
  xfail "extension-graph before/core/after/checks not dispatched by pipeline — ArchGate Q1 pending"
fi

# --- 6. Workspace-root references: inventory only (ArchGate question 2) -------
echo "=== 6. \$IWE-root references (out of contract until ArchGate Q2) ==="
grep -o '\$IWE/scripts/[a-zA-Z0-9._/-]*' "$PIPELINE" | sort -u | sed 's/^/  ℹ️  /'

echo
echo "Result: $PASS_COUNT PASS, $FAIL_COUNT FAIL, $XFAIL_COUNT XFAIL"
[ "$FAIL_COUNT" -eq 0 ] && exit 0 || exit 1
