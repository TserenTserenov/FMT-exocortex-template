#!/usr/bin/env bash
# test_issue_851_cyrillic_slug.sh — regression for issue #851.
#
# create-wp.sh's slug generator used to read the piped title via
# sys.stdin.read(), leaving decoding to Python's platform-default stdin
# codec. On Windows Git Bash that default is not guaranteed to be UTF-8 even
# though the pipe itself carries UTF-8 bytes -- a Cyrillic title decoded to
# mojibake, transliterated to nothing the lookup table recognized, and
# collapsed to a degenerate dash-only slug. This test exercises the real
# block extracted from create-wp.sh, not a re-typed copy, against:
#   1. an ordinary Cyrillic title -- must still transliterate correctly;
#   2. malformed (non-UTF-8) bytes -- must not crash, decode is lossy but
#      safe (errors='replace');
#   3. an empty/whitespace-only title -- must fall through to the bash
#      fallback slug, not silently produce an empty SLUG.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TARGET="$ROOT/scripts/create-wp.sh"

fail=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

# Extracts the real "Slug из title" block (TITLE -> SLUG) by unique markers.
extract_slug_block() {
    awk '
        /^# --- Slug из title \(если не задан\) ---$/{found=1}
        found{print}
        found && /^fi$/{exit}
    ' "$TARGET"
}

BLOCK=$(extract_slug_block)
if [ -z "$BLOCK" ]; then
    bad "could not extract the slug block from create-wp.sh — markers moved?"
    echo "Result: $fail FAIL"
    exit 1
fi
BLOCK_FILE=$(mktemp)
printf '%s\n' "$BLOCK" > "$BLOCK_FILE"
trap 'rm -f "$BLOCK_FILE"' EXIT

# --- 1. Ordinary Cyrillic title transliterates correctly ---
SLUG=""
TITLE="Восстановление персонального руководства"
# shellcheck source=/dev/null
source "$BLOCK_FILE"
if [ "$SLUG" = "vosstanovlenie-personalnogo-rukovodstva" ]; then
    ok "Cyrillic title transliterates to the expected slug"
else
    bad "Cyrillic title produced unexpected slug: '$SLUG'"
fi

# --- 2. Malformed (non-UTF-8) bytes do not crash and do not produce a
# silently-empty slug: errors='replace' still yields transliterable ASCII
# around the replacement characters, and the empty-result fallback covers
# the case where nothing usable survives. ---
SLUG=""
# 0xFF is invalid as a UTF-8 continuation/lead byte on its own.
TITLE=$(printf 'Test \xFF Title')
source "$BLOCK_FILE"
if [ -n "$SLUG" ]; then
    ok "malformed bytes do not crash the slug generator and still yield a non-empty slug ('$SLUG')"
else
    bad "malformed bytes produced an empty slug instead of falling back"
fi

# --- 3. Empty/whitespace-only title falls back to the bash-based slug,
# instead of silently keeping SLUG empty (issue #851: an empty result from
# a *successful* python3 run used to slip past the old `|| echo ...`
# fallback, which only fired on a non-zero exit). ---
SLUG=""
TITLE="   "
source "$BLOCK_FILE"
if [ -n "$SLUG" ]; then
    ok "whitespace-only title falls back to the bash slug generator ('$SLUG')"
else
    bad "whitespace-only title left SLUG empty — no fallback fired"
fi

# --- 4. An explicitly-passed --slug (SLUG already set) is left untouched ---
SLUG="explicit-slug"
TITLE="Восстановление персонального руководства"
source "$BLOCK_FILE"
if [ "$SLUG" = "explicit-slug" ]; then
    ok "explicit --slug is not overwritten by the title-derived one"
else
    bad "explicit --slug was overwritten: '$SLUG'"
fi

if [ "$fail" -gt 0 ]; then
    echo "FAIL: $fail проверок упало"
    exit 1
fi
echo "PASS: create-wp.sh slug generator handles Cyrillic input safely (issue #851)"
