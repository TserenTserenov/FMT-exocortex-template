#!/usr/bin/env bash
# routing: utility  deterministic=true
# check-seed-drift.sh — seed/strategy/scripts/ snapshots have not drifted from scripts/
#
# Found WP-5 (2026-07-22, Ubuntu-audit P3): seed-copies day-open-pipeline.sh/
# day-open-scaffold.sh had diverged from scripts/ by hundreds of lines without any warning —
# a new user received the old pipeline (failed on anti-cheat check
# «Bottleneck of the week», archiving after Checks instead of before). Synchronization is manual
# (script-promote.sh does not write to seed/), drifts silently.
#
# Convention: a file in seed/, marked with the line "# SNAPSHOT — synced manually
# via script-promote.sh from IWE/scripts/. Do not edit here
# directly." — must be byte-for-byte identical to scripts/<basename> after
# subtracting that single marker line. A file without the marker is not checked — is not checked
# (does not claim synchronicity, e.g.. seed-only scripts).
#
# Usage: bash scripts/check-seed-drift.sh [--fix] [FMT_DIR]
#
# issue #347: the guard printed the instruction «copy manually, preserving the marker line
# line» — a manual step after every edit to the source file, and that step was not being performed:
# the snapshot was lagging behind by three consecutive fixes. --fix performs the same operation automatically.

set -uo pipefail

FIX=false
ARGS=()
for arg in "$@"; do
    case "$arg" in
        --fix) FIX=true ;;
        *)     ARGS+=("$arg") ;;
    esac
done

FMT_DIR="${ARGS[0]:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SEED_DIR="$FMT_DIR/seed/strategy/scripts"
SCRIPTS_DIR="$FMT_DIR/scripts"
MARKER="# SNAPSHOT — synced manually via script-promote.sh from IWE/scripts/. Do not edit here directly."

if [ ! -d "$SEED_DIR" ]; then
    echo "SKIP: $SEED_DIR not found"
    exit 0
fi

fail=0
checked=0
while IFS= read -r -d '' f; do
    rel="${f#"$SEED_DIR"/}"
    if ! grep -qF "$MARKER" "$f"; then
        continue
    fi
    src="$SCRIPTS_DIR/$rel"
    if [ ! -f "$src" ]; then
        echo "FAIL: $rel is marked SNAPSHOT, but scripts/$rel is missing"
        fail=1
        continue
    fi
    checked=$((checked + 1))
    if ! diff -q <(grep -vF "$MARKER" "$f") "$src" >/dev/null 2>&1; then
        if $FIX; then
            # Marker goes back on line 2, right after the shebang — the same place the
            # convention above expects it and the same place grep -vF strips it from.
            # Built in a temp file first: redirecting straight into "$f" truncates the
            # snapshot before anything is read, so a failure would leave it empty while
            # the script still printed FIXED and returned 0.
            tmp_snapshot="${f}.new.$$"
            if { head -1 "$src"; printf '%s\n' "$MARKER"; tail -n +2 "$src"; } > "$tmp_snapshot" \
               && diff -q <(grep -vF "$MARKER" "$tmp_snapshot") "$src" >/dev/null 2>&1; then
                # Preserve the snapshot's own executable bit, not the source's: a
                # sourced library is 644 in scripts/ but 755 in seed/, and copying the
                # source's mode silently stripped +x there (caught by the repo's
                # pre-commit executable-bit guard).
                [ -x "$f" ] && chmod +x "$tmp_snapshot"
                mv "$tmp_snapshot" "$f"
                echo "FIXED: seed/strategy/scripts/$rel rebuilt from scripts/$rel"
            else
                rm -f "$tmp_snapshot"
                echo "FAIL: failed to rebuild seed/strategy/scripts/$rel — snapshot left unchanged"
                fail=1
            fi
        else
            echo "FAIL: seed/strategy/scripts/$rel has drifted from scripts/$rel"
            echo "  diff:"
            diff <(grep -vF "$MARKER" "$f") "$src" | head -20 | sed 's/^/    /'
            echo "  Fix: bash scripts/check-seed-drift.sh --fix"
            fail=1
        fi
    fi
done < <(find "$SEED_DIR" -type f -print0)

if [ "$checked" -eq 0 ]; then
    echo "SKIP: no file in $SEED_DIR carries the SNAPSHOT marker SNAPSHOT"
    exit 0
fi

if [ "$fail" -eq 0 ]; then
    echo "PASS: $checked seed-snapshot(s) are in sync with scripts/"
fi
exit $fail
