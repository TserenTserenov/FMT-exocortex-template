#!/usr/bin/env bash
# test_issue_1350_audit.sh — iwe-audit section 3b must not advise
# `check-seed-drift.sh --fix` for a stale seed snapshot without the SNAPSHOT
# marker: --fix skips such files, so the advice fixed nothing (issue #1350).
# A stale snapshot that carries the marker still gets the --fix advice.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AUDIT="$ROOT/scripts/iwe-audit.sh"

FAIL=0
pass() { echo "  ✅ PASS: $*"; }
fail() { echo "  ❌ FAIL: $*"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FMT="$TMP/root/FMT-exocortex-template"
SEED="$FMT/seed/strategy/scripts"
EXEC="$TMP/exec"
MARKER='# SNAPSHOT — synced manually via script-promote.sh from FMT-exocortex-template/scripts/. Do not edit here directly.'
mkdir -p "$FMT/scripts/lib" "$SEED/lib" "$EXEC/lib"
for rel in day-open-scaffold.sh day-open-pipeline.sh lib/common.sh; do
    printf '#!/bin/bash\necho %s v2\n' "$rel" > "$FMT/scripts/$rel"
    cp "$FMT/scripts/$rel" "$EXEC/$rel"
done
printf '#!/bin/bash\n%s\necho day-open-scaffold.sh v1\n' "$MARKER" > "$SEED/day-open-scaffold.sh"
printf '#!/bin/bash\n%s\necho day-open-pipeline.sh v2\n' "$MARKER" > "$SEED/day-open-pipeline.sh"
printf '#!/bin/bash\necho lib/common.sh v1\n' > "$SEED/lib/common.sh"

IWE_ROOT="$TMP/root" IWE_SCRIPTS="$EXEC" bash "$AUDIT" > "$TMP/out" 2>&1
SECTION=$(sed -n '/^## 3b\./,/^## 4\./p' "$TMP/out")

if printf '%s\n' "$SECTION" | grep -q 'lib/common.sh` отстал.*не несёт маркер SNAPSHOT' && \
   ! printf '%s\n' "$SECTION" | grep 'lib/common.sh` отстал' | grep -q 'обновить снимок:'; then
    pass "unmarked stale snapshot is not sent to check-seed-drift.sh --fix"
else
    fail "unmarked stale snapshot still gets the --fix advice: $(printf '%s\n' "$SECTION" | grep 'lib/common.sh')"
fi
if printf '%s\n' "$SECTION" | grep 'day-open-scaffold.sh` отстал' | grep -q 'обновить снимок:.*check-seed-drift.sh.* --fix'; then
    pass "marked stale snapshot keeps the --fix advice"
else
    fail "marked stale snapshot lost the --fix advice: $(printf '%s\n' "$SECTION" | grep 'day-open-scaffold')"
fi
if printf '%s\n' "$SECTION" | grep -q 'day-open-pipeline.sh` совпадает'; then
    pass "a synced snapshot is still reported as in sync"
else
    fail "synced snapshot is not reported as in sync"
fi

[ "$FAIL" -eq 0 ] && echo "PASS: issue #1350 audit seed advice" || { echo "FAIL: issue #1350 has $FAIL violation(s)"; exit 1; }
