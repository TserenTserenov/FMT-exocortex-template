#!/usr/bin/env bash
# Regression for issue #1401 (second half): the memory backup is published from
# several machines into one exocortex/. A memory file another machine changed
# since this machine's last publish must not be overwritten silently; it is
# skipped and reported, and clears when the copies match or after `accept`.
# Nothing is stubbed: origin is a local bare repo, "another machine" is a
# second clone pushing to it.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PUBLISHER="$ROOT/scripts/exocortex-publish.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/iwe-1401-divergence.XXXXXX")"

PYTHONUSERBASE="${PYTHONUSERBASE:-$(python3 -m site --user-base 2>/dev/null || true)}"
export PYTHONUSERBASE
unset IWE_SESSIONS_ROOT IWE_FROZEN_CANONICAL_PATH IWE_CANONICAL_OWNER IWE_RUNTIME_DIR \
      IWE_EXOCORTEX_DS_PUBLISH IWE_EXOCORTEX_PUBLISH_BRANCH IWE_EXOCORTEX_PUBLISH_STALE_HOURS \
      IWE_EXOCORTEX_TRIGGER_MIN_INTERVAL

FAIL=0
fail() { echo "  ❌ FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
pass() { echo "  ✅ PASS: $*"; }
trap 'rm -rf -- "$TEST_ROOT"' EXIT INT TERM

WS="$TEST_ROOT/ws"
ORIGIN="$TEST_ROOT/origin.git"
CANON="$WS/governance"
MEM="$TEST_ROOT/memory"
OTHER="$TEST_ROOT/other-machine"
STATUS="$WS/.iwe-runtime/state/exocortex-publish.status"
mkdir -p "$WS/home" "$MEM"

g() { git -c init.defaultBranch=main -c user.name=t -c user.email=t@example.invalid "$@"; }

g init -q --bare "$ORIGIN"
g -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
SEED="$TEST_ROOT/seed"
g clone -q "$ORIGIN" "$SEED" 2>/dev/null
mkdir -p "$SEED/scripts"
cp "$ROOT/seed/strategy/scripts/ds-publish.sh" "$SEED/scripts/ds-publish.sh"
echo "# governance" > "$SEED/README.md"
g -C "$SEED" add README.md scripts/ds-publish.sh
g -C "$SEED" commit -q -m init
g -C "$SEED" push -q origin HEAD:main
g clone -q "$ORIGIN" "$CANON" 2>/dev/null

echo "memory v1" > "$MEM/MEMORY.md"
echo "notes v1" > "$MEM/notes.md"

publish() {
    env HOME="$WS/home" WORKSPACE_DIR="$WS" IWE_ROOT="$WS" IWE_WORKSPACE="$WS" \
        IWE_TEMPLATE="$ROOT" IWE_SCRIPTS="$ROOT/scripts" \
        GOVERNANCE_REPO=governance IWE_GOVERNANCE_REPO=governance \
        IWE_MEMORY_SRC="$MEM" IWE_DAY_CLOSE_LOG="$WS/logs/day-close.log" \
        bash "$PUBLISHER" "$@"
}
origin_file() { git -C "$ORIGIN" show "main:exocortex/$1" 2>/dev/null; }
status_of() { sed -n "s/^$1=//p" "$STATUS" 2>/dev/null | tail -n 1; }

# Another machine edits exocortex/<file> on origin.
other_machine_writes() {
    rm -rf "$OTHER"
    g clone -q "$ORIGIN" "$OTHER" 2>/dev/null
    echo "$2" > "$OTHER/exocortex/$1"
    g -C "$OTHER" commit -q -am "other machine: $1"
    g -C "$OTHER" push -q origin HEAD:main
}

# --- T1: first publish has no base yet: published as before, nothing flagged ---
OUT=$(publish run 2>&1); RC=$?
if [ "$RC" -eq 0 ] && [ "$(origin_file MEMORY.md)" = "memory v1" ] \
   && [ "$(origin_file notes.md)" = "notes v1" ] && [ -z "$(status_of diverged)" ]; then
    pass "T1: first publish sends both files, nothing flagged"
else
    fail "T1: rc=$RC MEMORY=[$(origin_file MEMORY.md)] diverged=[$(status_of diverged)] out=[$OUT]"
fi

# --- T2: only another machine changed notes.md: ours must not revert it ---
other_machine_writes notes.md "notes from other machine"
echo "memory v2" > "$MEM/MEMORY.md"
OUT=$(publish run 2>&1); RC=$?
ST=$(publish status 2>&1); ST_RC=$?
if [ "$RC" -eq 0 ] && [ "$(origin_file notes.md)" = "notes from other machine" ] \
   && [ "$(origin_file MEMORY.md)" = "memory v2" ] \
   && [ "$ST_RC" -eq 3 ] && echo "$ST" | grep -q "notes.md (правила другая машина)"; then
    pass "T2: another machine's edit of notes.md kept on origin, our MEMORY.md published, status warns (rc 3)"
else
    fail "T2: rc=$RC notes=[$(origin_file notes.md)] MEMORY=[$(origin_file MEMORY.md)] st_rc=$ST_RC st=[$ST] out=[$OUT]"
fi

# --- T3: taking the other version unchanged clears the flag by itself ---
cp "$MEM/notes.md" "$TEST_ROOT/notes.ours"
origin_file notes.md > "$MEM/notes.md"
OUT=$(publish run 2>&1); RC=$?
ST=$(publish status 2>&1); ST_RC=$?
if [ "$RC" -eq 0 ] && [ "$ST_RC" -eq 0 ] && [ -z "$(status_of diverged)" ]; then
    pass "T3: copies match again — flag cleared without accept"
else
    fail "T3: rc=$RC st_rc=$ST_RC st=[$ST]"
fi

# --- T4: both machines changed MEMORY.md: neither side overwritten, flagged as both ---
other_machine_writes MEMORY.md "memory from other machine"
echo "memory v3 ours" > "$MEM/MEMORY.md"
OUT=$(publish run 2>&1); RC=$?
ST=$(publish status 2>&1); ST_RC=$?
if [ "$RC" -eq 0 ] && [ "$(origin_file MEMORY.md)" = "memory from other machine" ] \
   && [ "$(cat "$MEM/MEMORY.md")" = "memory v3 ours" ] \
   && [ "$ST_RC" -eq 3 ] && echo "$ST" | grep -q "MEMORY.md (правили обе машины)"; then
    pass "T4: both sides changed MEMORY.md — origin keeps theirs, ours untouched locally, flagged as both"
else
    fail "T4: rc=$RC origin=[$(origin_file MEMORY.md)] st_rc=$ST_RC st=[$ST] out=[$OUT]"
fi

# --- T5: the flag repeats on every publish until resolved (no silent base advance) ---
OUT=$(publish run 2>&1)
if [ "$(origin_file MEMORY.md)" = "memory from other machine" ] \
   && echo "$(status_of diverged)" | grep -q "MEMORY.md"; then
    pass "T5: second publish still keeps theirs and still flags MEMORY.md"
else
    fail "T5: origin=[$(origin_file MEMORY.md)] diverged=[$(status_of diverged)] out=[$OUT]"
fi

# --- T6: after merging, accept publishes our merged copy and clears the flag ---
echo "memory merged" > "$MEM/MEMORY.md"
ACC=$(publish accept MEMORY.md 2>&1); ACC_RC=$?
OUT=$(publish run 2>&1); RC=$?
ST=$(publish status 2>&1); ST_RC=$?
if [ "$ACC_RC" -eq 0 ] && [ "$RC" -eq 0 ] && [ "$(origin_file MEMORY.md)" = "memory merged" ] \
   && [ "$ST_RC" -eq 0 ] && [ -z "$(status_of diverged)" ]; then
    pass "T6: accept + publish sends the merged MEMORY.md, status clean"
else
    fail "T6: acc_rc=$ACC_RC acc=[$ACC] rc=$RC origin=[$(origin_file MEMORY.md)] st_rc=$ST_RC st=[$ST]"
fi

# --- T7: accept of a file origin does not have fails loudly ---
ACC=$(publish accept no-such.md 2>&1); ACC_RC=$?
if [ "$ACC_RC" -ne 0 ] && echo "$ACC" | grep -q "no-such.md нет"; then
    pass "T7: accept of an unknown file fails with a message"
else
    fail "T7: acc_rc=$ACC_RC acc=[$ACC]"
fi

# --- T8: a failed publish does not advance the base ---
other_machine_writes notes.md "notes from other machine v2"
mv "$ORIGIN" "$ORIGIN.away"
publish run >/dev/null 2>&1
mv "$ORIGIN.away" "$ORIGIN"
OUT=$(publish run 2>&1); RC=$?
if [ "$RC" -eq 0 ] && [ "$(origin_file notes.md)" = "notes from other machine v2" ] \
   && echo "$(status_of diverged)" | grep -q "notes.md"; then
    pass "T8: after a failed attempt the next publish still protects the other machine's edit"
else
    fail "T8: rc=$RC notes=[$(origin_file notes.md)] diverged=[$(status_of diverged)] out=[$OUT]"
fi

BASE_FILE="$WS/.iwe-runtime/exocortex-publish/published-base.json"
sha_of() { python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'; }

# --- T9: upgrade without a base file: the base is rebuilt from the commit this
# machine published last, so the other machine's notes.md is still protected,
# and stays protected after a further publish of other files ---
rm -f "$BASE_FILE"
OUT=$(publish run 2>&1); RC=$?
echo "memory after upgrade" > "$MEM/MEMORY.md"
OUT2=$(publish run 2>&1); RC2=$?
if [ "$RC" -eq 0 ] && [ "$RC2" -eq 0 ] && [ "$(origin_file notes.md)" = "notes from other machine v2" ] \
   && [ "$(origin_file MEMORY.md)" = "memory after upgrade" ] \
   && echo "$(status_of diverged)" | grep -q "notes.md"; then
    pass "T9: no base file — rebuilt from our last published commit; other machine's edit kept across two publishes"
else
    fail "T9: rc=$RC/$RC2 notes=[$(origin_file notes.md)] MEMORY=[$(origin_file MEMORY.md)] diverged=[$(status_of diverged)] out=[$OUT2]"
fi

# --- T10: a corrupt base file behaves like a missing one, never like "no check" ---
echo "{broken" > "$BASE_FILE"
OUT=$(publish run 2>&1); RC=$?
if [ "$RC" -eq 0 ] && [ "$(origin_file notes.md)" = "notes from other machine v2" ] \
   && echo "$(status_of diverged)" | grep -q "notes.md"; then
    pass "T10: corrupt base — other machine's edit still kept and flagged"
else
    fail "T10: rc=$RC notes=[$(origin_file notes.md)] diverged=[$(status_of diverged)] out=[$OUT]"
fi

# --- T11: origin's manifest keeps origin's hash for the skipped file ---
MANIFEST_HASH=$(origin_file .day-close-backup-manifest.json | python3 -c 'import json, sys; print(json.load(sys.stdin)["files"]["notes.md"])')
if [ "$MANIFEST_HASH" = "$(origin_file notes.md | sha_of)" ]; then
    pass "T11: published manifest records origin's notes.md hash, not ours"
else
    fail "T11: manifest=[$MANIFEST_HASH] origin=[$(origin_file notes.md | sha_of)]"
fi

# --- T12: a machine that never published does not overwrite differing files ---
rm -f "$BASE_FILE"
sed -i.bak 's/^published_sha=.*/published_sha=/' "$STATUS" && rm -f "$STATUS.bak"
echo "memory of a new machine" > "$MEM/MEMORY.md"
OUT=$(publish run 2>&1); RC=$?
if [ "$RC" -eq 0 ] && [ "$(origin_file MEMORY.md)" = "memory after upgrade" ] \
   && echo "$(status_of diverged)" | grep -q "MEMORY.md (правили обе машины)"; then
    pass "T12: never-published machine — differing MEMORY.md kept on origin, flagged as both"
else
    fail "T12: rc=$RC MEMORY=[$(origin_file MEMORY.md)] diverged=[$(status_of diverged)] out=[$OUT]"
fi

# --- T13: accept refuses a path that is not a file under exocortex/ ---
ACC=$(publish accept ../README.md 2>&1); ACC_RC=$?
if [ "$ACC_RC" -ne 0 ] && ! grep -q 'README' "$BASE_FILE" 2>/dev/null; then
    pass "T13: accept of ../README.md refused, base untouched"
else
    fail "T13: acc_rc=$ACC_RC acc=[$ACC] base=[$(cat "$BASE_FILE" 2>/dev/null)]"
fi

echo
if [ "$FAIL" -eq 0 ]; then
    echo "test_issue_1401_memory_divergence: all checks passed"
else
    echo "test_issue_1401_memory_divergence: $FAIL check(s) failed" >&2
    exit 1
fi
