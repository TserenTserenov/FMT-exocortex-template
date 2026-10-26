#!/usr/bin/env bash
# Regression for issue #1279 (part b): while the governance canon is frozen, the
# memory backup exocortex/ is published through an isolated worktree and the
# governance repo's own ds-publish.sh (scripts/exocortex-publish.sh); the canon
# checkout is never written. Nothing is stubbed: the "network" is a local bare
# origin, and a gateway failure is an origin that has been moved away.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PUBLISHER="$ROOT/scripts/exocortex-publish.sh"
DAY_CLOSE="$ROOT/scripts/day-close.sh"
HOOK="$ROOT/.claude/hooks/memory-exocortex-sync.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/iwe-1279-exo-publish.XXXXXX")"

# Runs below swap HOME; keep a --user PyYAML visible (issue #1342).
PYTHONUSERBASE="${PYTHONUSERBASE:-$(python3 -m site --user-base 2>/dev/null)}"
export PYTHONUSERBASE
unset IWE_SESSIONS_ROOT IWE_FROZEN_CANONICAL_PATH IWE_CANONICAL_OWNER IWE_RUNTIME_DIR \
      IWE_EXOCORTEX_DS_PUBLISH IWE_EXOCORTEX_PUBLISH_BRANCH IWE_EXOCORTEX_PUBLISH_STALE_HOURS \
      IWE_EXOCORTEX_TRIGGER_MIN_INTERVAL

FAIL=0
fail() { echo "  ❌ FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
pass() { echo "  ✅ PASS: $*"; }

cleanup() {
    local rc=$?
    rm -rf -- "$TEST_ROOT"
    exit "$rc"
}
trap cleanup EXIT INT TERM

WS="$TEST_ROOT/ws"
ORIGIN="$TEST_ROOT/origin.git"
CANON="$WS/governance"
MEM="$TEST_ROOT/memory"
RUNTIME="$WS/.iwe-runtime"
STATUS="$RUNTIME/state/exocortex-publish.status"
mkdir -p "$WS/home" "$WS/extensions" "$MEM"

g() { git -c init.defaultBranch=main -c user.name=t -c user.email=t@example.invalid "$@"; }

# --- origin with one commit; exocortex/agent-fault-profile is another writer's data ---
g init -q --bare "$ORIGIN"
g -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
SEED="$TEST_ROOT/seed"
g clone -q "$ORIGIN" "$SEED" 2>/dev/null
mkdir -p "$SEED/scripts" "$SEED/exocortex/agent-fault-profile"
cp "$ROOT/seed/strategy/scripts/ds-publish.sh" "$SEED/scripts/ds-publish.sh"
echo "# governance" > "$SEED/README.md"
echo "fault profile" > "$SEED/exocortex/agent-fault-profile/profile.md"
g -C "$SEED" add README.md scripts/ds-publish.sh exocortex/agent-fault-profile/profile.md
g -C "$SEED" commit -q -m init
g -C "$SEED" push -q origin HEAD:main

g clone -q "$ORIGIN" "$CANON" 2>/dev/null
git -C "$CANON" config user.name tester
git -C "$CANON" config user.email tester@example.invalid
CANON_HEAD0=$(git -C "$CANON" rev-parse HEAD)

echo "memory one" > "$MEM/MEMORY.md"
echo "k: v" > "$MEM/notes.yaml"
echo "ext one" > "$WS/extensions/custom.md"

run_env() {
    env HOME="$WS/home" WORKSPACE_DIR="$WS" IWE_ROOT="$WS" IWE_WORKSPACE="$WS" \
        IWE_TEMPLATE="$ROOT" IWE_SCRIPTS="$ROOT/scripts" \
        GOVERNANCE_REPO=governance IWE_GOVERNANCE_REPO=governance \
        IWE_MEMORY_SRC="$MEM" IWE_DAY_CLOSE_LOG="$WS/logs/day-close.log" "$@"
}

origin_file() { git -C "$ORIGIN" show "main:$1" 2>/dev/null; }
status_of() { sed -n "s/^$1=//p" "$STATUS" 2>/dev/null | tail -n 1; }

# Clean status (no new, changed or deleted files) and the same HEAD; until the
# test itself pulls the canon (T8) exocortex/ must not exist there at all.
canon_untouched() {
    [ -z "$(git -C "$CANON" status --porcelain --untracked-files=all)" ] \
        && [ "$(git -C "$CANON" rev-parse HEAD)" = "$CANON_HEAD0" ] \
        && { [ -n "${CANON_PULLED:-}" ] || [ ! -e "$CANON/exocortex/MEMORY.md" ]; }
}

# Background publishes are awaited through their observable result: the status
# file gets a new attempt_id (empty before the first attempt).
status_mark() { status_of attempt_id; }
wait_status_after() {
    local prev="$1" i=0 cur
    while [ "$i" -lt 120 ]; do
        cur=$(status_mark)
        if [ -n "$cur" ] && [ "$cur" != "$prev" ]; then
            # give the publisher a moment to release its lock after writing the status
            sleep 1; return 0
        fi
        sleep 0.5; i=$((i + 1))
    done
    return 1
}

# --- T1: Day Close step 1 under default freeze: canon untouched, publish in background ---
MARK=$(status_mark)
OUT=$(run_env bash "$DAY_CLOSE" --backup 2>&1); RC=$?
wait_status_after "$MARK"
if [ "$RC" -eq 0 ] && canon_untouched; then
    pass "T1a: day-close --backup under freeze leaves the canon checkout untouched (rc=0)"
else
    fail "T1a: canon written or rc=$RC: $(git -C "$CANON" status --porcelain | head -n 3) out=[$OUT]"
fi
if [ "$(origin_file exocortex/MEMORY.md)" = "memory one" ] \
   && [ "$(origin_file exocortex/extensions/custom.md)" = "ext one" ] \
   && [ "$(origin_file exocortex/agent-fault-profile/profile.md)" = "fault profile" ] \
   && [ "$(status_of result)" = ok ] \
   && [ "$(status_of published_sha)" = "$(git -C "$ORIGIN" rev-parse main)" ]; then
    pass "T1b: exocortex/ (memory + extensions) published to origin/main via the isolated worktree; other writers' roots kept; status ok with the published sha"
else
    fail "T1b: origin MEMORY=[$(origin_file exocortex/MEMORY.md)] ext=[$(origin_file exocortex/extensions/custom.md)] status=[$(cat "$STATUS" 2>/dev/null)] out=[$OUT]"
fi
if echo "$OUT" | grep -q "снимок памяти сохранён"; then
    pass "T1c: Day Close says the snapshot is saved and the publish was started"
else
    fail "T1c: expected the snapshot message, out=[$OUT]"
fi
BAD=$(git -C "$ORIGIN" log --format=%H main | while read -r c; do
    git -C "$ORIGIN" diff-tree --no-commit-id --name-only -r "$c" | grep -v '^exocortex/' | grep -v '^README.md$\|^scripts/ds-publish.sh$\|^$'
done)
if [ -z "$BAD" ] && ! git -C "$ORIGIN" ls-tree -r --name-only main | grep -q 'day-close-backup.lock\|day-close-backup-quarantine'; then
    pass "T1d: the backup commit touches only exocortex/ and carries no local lock/quarantine files"
else
    fail "T1d: stray paths on origin: [$BAD]"
fi

# --- T2: gateway failure (origin unreachable): fail recorded, snapshot kept, canon untouched ---
mv "$ORIGIN" "$ORIGIN.away"
echo "memory two" > "$MEM/MEMORY.md"
OUT=$(run_env bash "$PUBLISHER" run 2>&1); RC=$?
SNAP_MEM=$(cat "$RUNTIME/exocortex-publish/snapshot/MEMORY.md" 2>/dev/null)
ST_OUT=$(run_env bash "$PUBLISHER" status 2>&1); ST_RC=$?
if [ "$RC" -ne 0 ] && [ "$(status_of result)" = fail ] && [ "$SNAP_MEM" = "memory two" ] \
   && [ "$ST_RC" -eq 3 ] && echo "$ST_OUT" | grep -q "НЕ удалась" && canon_untouched; then
    pass "T2: origin unreachable — status=fail recorded ($(status_of reason | cut -c1-60)...), snapshot kept, canon untouched"
else
    fail "T2: rc=$RC status=[$(cat "$STATUS" 2>/dev/null)] snap=[$SNAP_MEM] st_rc=$ST_RC out=[$OUT]"
fi
MARK=$(status_mark)
OUT=$(run_env bash "$DAY_CLOSE" --backup 2>&1); RC=$?
wait_status_after "$MARK"
if echo "$OUT" | grep -q "НЕ удалась" && canon_untouched; then
    pass "T2b: Day Close surfaces the last publish failure instead of hiding it (rc=$RC)"
else
    fail "T2b: failure not surfaced, out=[$OUT]"
fi
mv "$ORIGIN.away" "$ORIGIN"

# --- T3: next run after the fix publishes the kept snapshot ---
OUT=$(run_env bash "$PUBLISHER" publish 2>&1); RC=$?
if [ "$RC" -eq 0 ] && [ "$(origin_file exocortex/MEMORY.md)" = "memory two" ] && [ "$(status_of result)" = ok ] && canon_untouched; then
    pass "T3: retry after restoring origin publishes the kept snapshot"
else
    fail "T3: rc=$RC origin=[$(origin_file exocortex/MEMORY.md)] status=[$(cat "$STATUS" 2>/dev/null)] out=[$OUT]"
fi

# --- T4: deletion goes through day-close's ownership manifest ---
rm -f "$MEM/notes.yaml"
OUT=$(run_env bash "$PUBLISHER" run 2>&1); RC=$?
if [ "$RC" -eq 0 ] && ! git -C "$ORIGIN" cat-file -e main:exocortex/notes.yaml 2>/dev/null \
   && [ "$(origin_file exocortex/agent-fault-profile/profile.md)" = "fault profile" ]; then
    pass "T4: a memory file removed at the source is pruned on origin; preserved roots stay"
else
    fail "T4: rc=$RC notes.yaml still on origin or profile lost, out=[$OUT]"
fi

# --- T5: two concurrent runs: no interleaving, no corrupted commit ---
echo "memory three" > "$MEM/MEMORY.md"
BEFORE=$(git -C "$ORIGIN" rev-parse main)
run_env bash "$PUBLISHER" run > "$TEST_ROOT/c1.out" 2>&1 & P1=$!
run_env bash "$PUBLISHER" run > "$TEST_ROOT/c2.out" 2>&1 & P2=$!
wait "$P1"; R1=$?; wait "$P2"; R2=$?
NEW=$(git -C "$ORIGIN" rev-list "$BEFORE..main")
MERGES=$(git -C "$ORIGIN" rev-list --merges "$BEFORE..main")
STRAY=$(for c in $NEW; do git -C "$ORIGIN" diff-tree --no-commit-id --name-only -r "$c" | grep -v '^exocortex/'; done)
if [ "$R1" -eq 0 ] && [ "$R2" -eq 0 ] && [ "$(origin_file exocortex/MEMORY.md)" = "memory three" ] \
   && [ -z "$MERGES" ] && [ -z "$STRAY" ] && [ "$(echo "$NEW" | grep -c .)" -le 2 ] \
   && git -C "$ORIGIN" fsck --no-progress >/dev/null 2>&1 && canon_untouched; then
    pass "T5: concurrent runs serialize or queue cleanly ($(echo "$NEW" | grep -c .) new commit(s), only exocortex/)"
else
    fail "T5: r1=$R1 r2=$R2 new=[$NEW] merges=[$MERGES] stray=[$STRAY] c1=[$(cat "$TEST_ROOT/c1.out")] c2=[$(cat "$TEST_ROOT/c2.out")]"
fi

# --- T6: the memory hook under freeze triggers the same publish, canon untouched ---
echo "memory four" > "$MEM/MEMORY.md"
EVENT=$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$MEM/MEMORY.md")
MARK=$(status_mark)
OUT=$(printf '%s' "$EVENT" | run_env IWE_EXOCORTEX_PUBLISH_MIN_INTERVAL=0 IWE_EXOCORTEX_TRIGGER_MIN_INTERVAL=0 bash "$HOOK" 2>&1); RC=$?
wait_status_after "$MARK"
if [ "$RC" -eq 0 ] && [ "$(origin_file exocortex/MEMORY.md)" = "memory four" ] && canon_untouched; then
    pass "T6: hook under freeze — exocortex/ published via the isolated worktree, canon untouched, hook exit 0"
else
    fail "T6: rc=$RC origin=[$(origin_file exocortex/MEMORY.md)] out=[$OUT] log=[$(tail -n 5 "$RUNTIME/exocortex-publish/publish.log" 2>/dev/null)]"
fi

# Another host / a canonical-owner run publishes into exocortex/ through its own clone.
OTHER="$TEST_ROOT/other-host"
g clone -q "$ORIGIN" "$OTHER" 2>/dev/null
other_push() {  # <message>
    g -C "$OTHER" add --all -- exocortex scripts >/dev/null 2>&1
    g -C "$OTHER" commit -q -m "$1" && g -C "$OTHER" push -q origin HEAD:main
}
sha_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }

# --- T7 (#536 ownership): origin-only entries survive; an owned file removed at
#     the source is pruned only while its bytes still match origin's manifest ---
echo "owned one" > "$MEM/owned.md"
echo "owned two" > "$MEM/edited-elsewhere.md"
OUT=$(run_env bash "$PUBLISHER" run 2>&1); RC=$?
g -C "$OTHER" pull -q --ff-only origin main
mkdir -p "$OTHER/exocortex/rules"
echo "foreign" > "$OTHER/exocortex/foreign.md"
echo "foreign rule" > "$OTHER/exocortex/rules/x.md"
echo "changed on the other host" > "$OTHER/exocortex/edited-elsewhere.md"
OWNED_RECORDED=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["files"].get("owned.md",""))' "$OTHER/exocortex/.day-close-backup-manifest.json" 2>/dev/null)
other_push "other host: foreign files"
rm -f "$MEM/owned.md" "$MEM/edited-elsewhere.md"
OUT=$(run_env bash "$PUBLISHER" run 2>&1); RC=$?
if [ "$RC" -eq 0 ] && [ "$(origin_file exocortex/foreign.md)" = "foreign" ] \
   && [ "$(origin_file exocortex/rules/x.md)" = "foreign rule" ] \
   && [ -n "$OWNED_RECORDED" ] && ! git -C "$ORIGIN" cat-file -e main:exocortex/owned.md 2>/dev/null \
   && [ "$(origin_file exocortex/edited-elsewhere.md)" = "changed on the other host" ] && canon_untouched; then
    pass "T7: origin-only foreign.md and rules/x.md survive; owned.md (hash matches origin's manifest) pruned; an owned file changed elsewhere is kept"
else
    fail "T7: rc=$RC foreign=[$(origin_file exocortex/foreign.md)] rules=[$(origin_file exocortex/rules/x.md)] owned=[$(origin_file exocortex/owned.md)] recorded=[$OWNED_RECORDED] edited=[$(origin_file exocortex/edited-elsewhere.md)] out=[$OUT]"
fi

# --- T8: the canon's ds-publish.sh predates the version stamp (#1230) and rejects
#     --exact-commit — the template's stamped seed copy is used instead ---
g -C "$OTHER" pull -q --ff-only origin main
cat > "$OTHER/scripts/ds-publish.sh" <<'LEGACY'
#!/usr/bin/env bash
# legacy publisher without a version stamp
echo called >> "${LEGACY_CALLS:-/dev/null}"
for a in "$@"; do [ "$a" = --exact-commit ] && { echo "usage: unknown option --exact-commit" >&2; exit 1; }; done
exit 1
LEGACY
other_push "legacy unstamped ds-publish"
git -C "$CANON" pull -q --ff-only origin main
CANON_HEAD0=$(git -C "$CANON" rev-parse HEAD); CANON_PULLED=1
echo "memory five" > "$MEM/MEMORY.md"
OUT=$(run_env LEGACY_CALLS="$TEST_ROOT/legacy-calls" bash "$PUBLISHER" run 2>&1); RC=$?
if grep -q '^# ds-publish version:' "$CANON/scripts/ds-publish.sh"; then
    fail "T8: setup error — the canon still carries a stamped ds-publish.sh"
elif [ "$RC" -eq 0 ] && [ "$(origin_file exocortex/MEMORY.md)" = "memory five" ] && [ ! -e "$TEST_ROOT/legacy-calls" ] && canon_untouched; then
    pass "T8: unstamped canon ds-publish.sh is bypassed; the template's stamped copy published"
else
    fail "T8: rc=$RC origin=[$(origin_file exocortex/MEMORY.md)] legacy-called=$([ -e "$TEST_ROOT/legacy-calls" ] && echo yes || echo no) out=[$OUT]"
fi

# --- T9: a snapshot waiting longer than STALE_HOURS for a successful publish is
#     reported (exit 3) even when the last recorded status is still "ok" ---
ST_OUT=$(run_env bash "$PUBLISHER" status 2>&1); ST_OK_RC=$?
sleep 1
touch "$RUNTIME/exocortex-publish/snapshot.stamp"
ST_OUT=$(run_env IWE_EXOCORTEX_PUBLISH_STALE_HOURS=0 bash "$PUBLISHER" status 2>&1); ST_RC=$?
if [ "$ST_OK_RC" -eq 0 ] && [ "$(status_of result)" = ok ] && [ "$ST_RC" -eq 3 ] && echo "$ST_OUT" | grep -q "не опубликован дольше"; then
    pass "T9: status=ok but the snapshot is unpublished past the limit — status exits 3 and says so"
else
    fail "T9: ok_rc=$ST_OK_RC rc=$ST_RC out=[$ST_OUT]"
fi

# --- T10: a background publish survives a group kill of its caller ---
echo "memory six" > "$MEM/MEMORY.md"
run_env bash "$PUBLISHER" snapshot >/dev/null 2>&1
MARK=$(status_mark)
perl -e 'setpgrp(0, 0); exec @ARGV' bash -c '"$@" >/dev/null 2>&1; sleep 30' _ \
    env HOME="$WS/home" WORKSPACE_DIR="$WS" IWE_ROOT="$WS" IWE_WORKSPACE="$WS" IWE_TEMPLATE="$ROOT" \
    IWE_SCRIPTS="$ROOT/scripts" GOVERNANCE_REPO=governance IWE_GOVERNANCE_REPO=governance IWE_MEMORY_SRC="$MEM" \
    bash "$PUBLISHER" publish --background &
CALLER=$!
sleep 0.3
kill -TERM -- "-$CALLER" 2>/dev/null; wait "$CALLER" 2>/dev/null
wait_status_after "$MARK"
if [ "$(status_mark)" != "$MARK" ] && [ "$(origin_file exocortex/MEMORY.md)" = "memory six" ]; then
    pass "T10: caller's process group killed right after the launch — the detached publish still finished"
else
    fail "T10: publish did not survive the group kill: origin=[$(origin_file exocortex/MEMORY.md)] log=[$(tail -n 3 "$RUNTIME/exocortex-publish/publish.log")]"
fi

# --- T11: hook throttling — no launch while a run is alive (it gets run.pending),
#     none within the trigger interval ---
EVENT=$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$MEM/MEMORY.md")
echo "$$" > "$RUNTIME/exocortex-publish/run.active"
rm -f "$RUNTIME/exocortex-publish/run.pending"
OUT=$(printf '%s' "$EVENT" | run_env IWE_EXOCORTEX_TRIGGER_MIN_INTERVAL=0 bash "$HOOK" 2>&1); RC=$?
ACTIVE_OK=0; [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ -f "$RUNTIME/exocortex-publish/run.pending" ] && ACTIVE_OK=1
rm -f "$RUNTIME/exocortex-publish/run.active" "$RUNTIME/exocortex-publish/run.pending"
touch "$RUNTIME/exocortex-publish/trigger.stamp"
OUT2=$(printf '%s' "$EVENT" | run_env IWE_EXOCORTEX_TRIGGER_MIN_INTERVAL=3600 bash "$HOOK" 2>&1); RC2=$?
if [ "$ACTIVE_OK" = 1 ] && [ "$RC2" -eq 0 ] && [ -z "$OUT2" ]; then
    pass "T11: hook does not launch while a run is alive (leaves run.pending) or within the trigger interval"
else
    fail "T11: active_ok=$ACTIVE_OK out=[$OUT] rc2=$RC2 out2=[$OUT2]"
fi

if [ "$FAIL" -eq 0 ]; then
    echo "test_issue_1279_exo_publish: ALL PASS"
    exit 0
fi
echo "test_issue_1279_exo_publish: $FAIL FAILURE(S)"
exit 1
