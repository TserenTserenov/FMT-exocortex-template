#!/usr/bin/env bash
# session-guard-audit-validate-orz-batch-smoke.sh -- ported from
# ~/IWE/scripts/tests/ (root commit 2779845553, WP-484 line AC, 31.08).
# validate_orz()'s "git tracked" and "frontmatter/sections" checks were
# rewritten to avoid one grep/sed/git/python3 subprocess per ORZ file --
# see the comments at those checks in session-guard.sh for the measured
# cost this replaces. This test extracts validate_orz() in isolation and
# checks both the batch path (tracked-set-file given, used by `audit`) and
# the fallback path (used by `close`) against the same fixtures.

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d /private/tmp/session-guard-validate-orz-batch.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT

extract_fn() {
    sed -n "/^${1}() {/,/^}/p" "$GUARD"
}

REPO="$TEST_ROOT/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name test

run_validate() {
    # args: orz-relpath agent [tracked-set-file]
    local orz="$REPO/$1" agent="$2" tracked_set="${3:-}"
    bash -c '
        '"$(extract_fn validate_orz)"$'\n
        validate_orz "$1" "$2" "$3" "$4"
    ' _ "$orz" "$agent" "$REPO" "$tracked_set"
}

fail=0
check() {
    local desc="$1" expected_errors="$2"; shift 2
    local out rc=0
    out=$(run_validate "$@" 2>&1) || rc=$?
    if [ "$rc" -ne "$expected_errors" ]; then
        echo "FAIL ($desc): expected $expected_errors errors, got rc=$rc: $out" >&2
        fail=1
    else
        echo "OK: $desc"
    fi
}

# --- Fixture A: complete, valid, tracked ORZ file ---
cat > "$REPO/good.md" <<'EOF'
---
date: 2026-08-31
type: peer-session
wp: WP-484
agent: claude-code
duration_h: 1.0
artifacts: [report.md]
---

## Главный инсайт

x

## Контекст

x

## Достигнуто

x

## Ключевые решения

x
EOF
git -C "$REPO" add good.md
git -C "$REPO" commit -q -m good

git -C "$REPO" ls-files > "$TEST_ROOT/tracked.txt"

check "complete tracked file, no tracked-set (fallback/close path), matching agent" 0 good.md claude-code
check "complete tracked file, batch path (audit), matching agent" 0 good.md claude-code "$TEST_ROOT/tracked.txt"
check "complete tracked file, batch path (audit), empty agent (no-op comparison, WP-484 AC fix)" 0 good.md "" "$TEST_ROOT/tracked.txt"
check "complete tracked file, batch path, mismatched real agent DOES flag (regression guard for the WP-484 AC bug: passing 'unknown' broke this)" 1 good.md some-other-agent "$TEST_ROOT/tracked.txt"

cat > "$REPO/kimi-headless.md" <<'EOF'
---
date: 2026-08-31
type: peer-session
wp: WP-484
agent: kimi-headless
duration_h: 1.0
artifacts: [report.md]
---

## Главный инсайт

x

## Контекст

x

## Достигнуто

x

## Ключевые решения

x
EOF
git -C "$REPO" add kimi-headless.md
git -C "$REPO" commit -q -m kimi-headless
git -C "$REPO" ls-files > "$TEST_ROOT/tracked1b.txt"
check "kimi/kimi-headless alias accepted, batch path" 0 kimi-headless.md kimi "$TEST_ROOT/tracked1b.txt"

# --- Fixture B: missing keys and sections ---
cat > "$REPO/bad.md" <<'EOF'
---
date: 2026-08-31
agent: claude-code
---

## Контекст

x
EOF
git -C "$REPO" add bad.md
git -C "$REPO" commit -q -m bad
git -C "$REPO" ls-files > "$TEST_ROOT/tracked2.txt"
# 3 missing keys (type, wp, duration_h, artifacts = 4) + 3 missing sections
# (Главный инсайт, Достигнуто, Ключевые решения) = 7
check "missing keys/sections, fallback path" 7 bad.md claude-code
check "missing keys/sections, batch path" 7 bad.md claude-code "$TEST_ROOT/tracked2.txt"

# --- Fixture C: Kimi's edge case (round 3) -- key with no preceding blank
# line before it (right after the opening '---', which is the only real
# shape ORZ files ever have, but test the boundary explicitly). ---
cat > "$REPO/edge.md" <<'EOF'
---
date: 2026-08-31
type: t
wp: WP-1
duration_h: 1
artifacts: []
agent: claude-code
---

## Главный инсайт
x
## Контекст
x
## Достигнуто
x
## Ключевые решения
x
EOF
git -C "$REPO" add edge.md
git -C "$REPO" commit -q -m edge
git -C "$REPO" ls-files > "$TEST_ROOT/tracked3.txt"
check "all keys present starting right after '---', batch path" 0 edge.md claude-code "$TEST_ROOT/tracked3.txt"

# --- Fixture D: untracked file, present in remote-refs (fallback promotion
# path -- must still work identically through the batch path). ---
mkdir -p "$REPO/.git/refs/remotes/origin"
git -C "$REPO" rev-parse HEAD > "$REPO/.git/refs/remotes/origin/main"
git -C "$REPO" rm -q --cached good.md
git -C "$REPO" ls-files > "$TEST_ROOT/tracked4.txt"
check "untracked-but-published file, batch path takes remote-refs fallback, still 0 errors" 0 good.md claude-code "$TEST_ROOT/tracked4.txt"

if [ "$fail" -ne 0 ]; then
    echo "FAIL: session-guard-audit-validate-orz-batch-smoke" >&2
    exit 1
fi
echo "PASS: session-guard audit validate_orz batch/fallback equivalence"
