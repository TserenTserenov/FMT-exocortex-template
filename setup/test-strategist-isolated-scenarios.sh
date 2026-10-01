#!/bin/bash
# test-strategist-isolated-scenarios.sh -- WP-530 Ф72 acceptance test for the isolated scenario mode
# of roles/strategist/scripts/strategist.sh (isolated_begin / isolated_verify / isolated_finish and
# the note-review wiring). A scheduled scenario used to write straight into the shared governance
# checkout; in the isolated mode it runs in a throwaway worktree of origin/main, the canonical
# checkout is only read, the result is checked against the scenario's allowlist and published from
# the copy, and the copy is removed only after a publication.
#
# Two layers, both against a throwaway bare origin:
#   A. the REAL functions cut out of the runner by name (function-level cases);
#   B. the REAL runner end to end (`strategist.sh note-review`) with a stub AI_CLI.
# STRATEGIST_SCRIPT_UNDER_TEST points the test at a mutated copy of the runner (mutation runs).
#
# Usage: bash setup/test-strategist-isolated-scenarios.sh

set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SELF_DIR")"
SCRIPT="${STRATEGIST_SCRIPT_UNDER_TEST:-$REPO_ROOT/roles/strategist/scripts/strategist.sh}"
TEST_ROOT="$(cd -P "$(mktemp -d "${TMPDIR:-/tmp}/iwe-strategist-isolated-test.XXXXXX")" && pwd -P)"

# repo-owned python programs are resolved through the template's single resolver (WP-529 F6)
PY3="$(bash "$REPO_ROOT/scripts/lib/find-python3.sh" --stdlib-only)" || { echo "no python3 for the cleanup contract cases" >&2; exit 2; }

FAIL_COUNT=0
PASS_COUNT=0
fail() { echo "  ❌ FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
pass() { echo "  ✅ PASS: $*"; PASS_COUNT=$((PASS_COUNT + 1)); }
check() {  # <description> <expected> <actual>
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}

cleanup() { local rc=$?; [ "${KEEP:-0}" = "1" ] || rm -rf "$TEST_ROOT"; exit "$rc"; }
trap cleanup EXIT INT TERM

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=t@test GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=t@test
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export DELIVERY_FETCH_PAUSE=0

extract_block() {  # <start regex> <end regex, first match at or after start>
    local start end
    start=$(grep -n -m1 "$1" "$SCRIPT" | cut -d: -f1)
    [ -n "$start" ] || { echo "cannot find '$1' in $SCRIPT" >&2; exit 2; }
    end=$(awk -v s="$start" -v pat="$2" 'NR >= s && $0 ~ pat { print NR; exit }' "$SCRIPT")
    sed -n "${start},${end}p" "$SCRIPT"
}
extract_until() {  # <start regex> <stop regex, exclusive>
    awk -v start="$1" -v stop="$2" '$0 ~ start { on = 1 } on && $0 ~ stop { exit } on { print }' "$SCRIPT"
}
TIMEOUT_SHIM='command -v timeout >/dev/null 2>&1 || timeout() { shift; "$@"; }'
FUNCTIONS="$TIMEOUT_SHIM
$(extract_block '^log() {' '^}')
$(extract_block '^publish_commit_or_explain() {' '^}')
$(extract_block '^fetch_delivery_origin() {' '^}')
$(extract_until '^ISOLATION_BLOCKED_RC=' '^log_size_bytes')"

# ---------------------------------------------------------------------------------------------
# fixture: bare origin, canonical checkout <home>/IWE/DS-strategy, fake publisher tracked in the repo
# ---------------------------------------------------------------------------------------------
CASE_N=0
make_env() {
    CASE_N=$((CASE_N + 1))
    E="$TEST_ROOT/case$CASE_N"
    HOME_DIR="$E/home"; WSROOT="$HOME_DIR/IWE"; CANON="$WSROOT/DS-strategy"
    ORIGIN="$E/origin.git"; ISO_TMP="$E/iso"; TMPD="$E/tmp"; PUBLOG="$E/publish.log"
    LOG="$E/run.log"
    mkdir -p "$WSROOT" "$ISO_TMP" "$TMPD" "$E/bin" "$E/shim"
    git init -q --bare -b main "$ORIGIN"
    git clone -q "$ORIGIN" "$CANON" 2>/dev/null
    mkdir -p "$CANON/inbox" "$CANON/archive/notes" "$CANON/docs" "$CANON/scripts" "$CANON/exocortex"
    cat > "$CANON/inbox/fleeting-notes.md" <<'EOF'
---
title: Fleeting
---

# Fleeting

> notes

---

**Bold new note**

---

**Already proposed note** ✅предложено

---

Plain old note
<sub>1 янв, 10:00</sub>
EOF
    printf '# Archive\n' > "$CANON/archive/notes/Notes-Archive.md"
    printf 'other\n' > "$CANON/docs/other.md"
    printf 'strategy_day: %s\n' "$(date +%A | tr '[:upper:]' '[:lower:]')" > "$CANON/exocortex/day-rhythm-config.yaml"
    cat > "$CANON/scripts/ds-publish.sh" <<'EOF'
#!/bin/bash
# test double of the publisher: args <repo> normal --reason R --from-commit SHA
repo="$1"; sha=""
while [ $# -gt 0 ]; do [ "$1" = "--from-commit" ] && sha="$2"; shift; done
echo "$repo" >> "$PUBLOG"
[ "${FAKE_PUBLISH_FAIL:-0}" = 1 ] && exit "${FAKE_PUBLISH_RC:-1}"
git -C "$repo" push -q origin "$sha:refs/heads/main"
EOF
    git -C "$CANON" add -A && git -C "$CANON" commit -q -m seed && git -C "$CANON" push -q origin HEAD:main
    BASE=$(git -C "$ORIGIN" rev-parse main)
    CANON_HEAD=$(git -C "$CANON" rev-parse HEAD)
    printf '#!/bin/bash\nexit 0\n' > "$E/shim/osascript"; cp "$E/shim/osascript" "$E/shim/notify-send"
    chmod +x "$E/shim/osascript" "$E/shim/notify-send"
    # the notifier doubles must win over any real desktop notifier on the test PATH
    check "notifier double takes precedence" "$E/shim/osascript" "$(PATH="$E/shim:$PATH" command -v osascript)"
    # stub model: STUB_MODE picks what it does inside its working directory
    cat > "$E/bin/ai-stub" <<'EOF'
#!/bin/bash
pwd > "$STUB_CWD_FILE"
printf '%s\n' "$@" > "$STUB_ARGS_FILE"
case "${STUB_MODE:-noop}" in
    noop) ;;
    outside-file) echo x > docs/new-outside.md ;;
    outside-edit) echo x >> docs/other.md ;;
    commit-outside) echo x > docs/committed-outside.md; git add docs/committed-outside.md; git commit -q -m "model commit" ;;
    commit-inside) echo x >> inbox/fleeting-notes.md; git add inbox/fleeting-notes.md; git commit -q -m "model commit" ;;
    # a healthy Note-Review (#961): the new note is marked, its bold stays
    mark-proposed) sed 's/^\*\*Bold new note\*\*$/**Bold new note** ✅предложено/' inbox/fleeting-notes.md > "$TMPDIR/fleeting.marked" && cat "$TMPDIR/fleeting.marked" > inbox/fleeting-notes.md ;;
    fail) exit 3 ;;
esac
exit 0
EOF
    chmod +x "$E/bin/ai-stub"
}

origin_commits() { git -C "$ORIGIN" rev-list --count "$BASE..main"; }
origin_paths() { git -C "$ORIGIN" diff --name-only "$BASE" main | sort | tr '\n' ' ' | sed 's/ $//'; }
canon_head() { git -C "$CANON" rev-parse HEAD; }
canon_status() { git -C "$CANON" status --porcelain; }
iso_copies() { ls -d "$ISO_TMP"/iwe-strategist-note-review.*/DS-strategy 2>/dev/null | wc -l | tr -d ' '; }
canon_untouched() {  # <label>
    check "$1: canon HEAD unchanged" "$CANON_HEAD" "$(canon_head)"
    check "$1: canon working tree clean" "" "$(canon_status)"
}

# --- layer A: real functions ---------------------------------------------------------------
# <mutator shell code run inside the copy> [shim dir prepended to PATH]; sets FN_OUT
run_fn() {
    FN_OUT=$(MUTATOR="$1" SHIM="${2:-}" FUNCS="$FUNCTIONS" WORKSPACE="$CANON" LOG_FILE="$LOG" \
        STRATEGIST_ISOLATED_TMPDIR="$ISO_TMP" PUBLOG="$PUBLOG" IWE_GOVERNANCE_REPO=DS-strategy \
        FAKE_PUBLISH_FAIL="${FAKE_PUBLISH_FAIL:-0}" FAKE_PUBLISH_RC="${FAKE_PUBLISH_RC:-1}" ISOLATED_LIST="${ISOLATED_LIST:-}" bash -c '
        [ -z "$SHIM" ] || PATH="$SHIM:$PATH"
        eval "$FUNCS"
        isolated_begin note-review || { echo "begin-failed"; exit 9; }
        cd "$WORKSPACE"
        eval "$MUTATOR"
        rc=0
        isolated_finish "strategist: cleanup" "chore: test cleanup" || rc=$?
        echo "rc=$rc result=$ISOLATED_RESULT"
    ' 2>&1)
}

echo "== A1: enable flag parsing =="
make_env
FLAG_OUT=$(FUNCS="$FUNCTIONS" bash -c '
    eval "$FUNCS"
    for v in "" "note-review" "week-review,note-review" "week-review note-review" "note-review-x" "xnote-review"; do
        STRATEGIST_ISOLATED_SCENARIOS="$v"
        if isolation_enabled note-review; then printf "1"; else printf "0"; fi
    done')
check "flag parsing: empty=off, listed (comma/space)=on, near-miss names=off" "011100" "$FLAG_OUT"

echo "== A2: allowed change is published from the copy =="
make_env
run_fn 'echo more >> inbox/fleeting-notes.md; echo arch >> archive/notes/Notes-Archive.md'
check "allowed change: rc 0 and published" "rc=0 result=published" "$(printf '%s' "$FN_OUT" | tail -1)"
check "allowed change: origin got exactly one commit" "1" "$(origin_commits)"
check "allowed change: commit touches exactly the allowlisted paths" "archive/notes/Notes-Archive.md inbox/fleeting-notes.md" "$(origin_paths)"
check "allowed change: publisher was called from the copy, not the canon" "1" "$(grep -c 'iwe-strategist-note-review' "$PUBLOG")"
check "allowed change: copy removed after publication" "0" "$(iso_copies)"
check "allowed change: copy branch removed" "" "$(git -C "$CANON" branch --list 'strategist/*')"
canon_untouched "allowed change"

echo "== A3: nothing changed =="
make_env
run_fn ':'
check "no changes: rc 0, no_changes" "rc=0 result=no_changes" "$(printf '%s' "$FN_OUT" | tail -1)"
check "no changes: origin unchanged" "0" "$(origin_commits)"
check "no changes: copy removed" "0" "$(iso_copies)"
canon_untouched "no changes"

echo "== A4: path outside the allowlist blocks and keeps the copy =="
make_env
run_fn 'echo more >> inbox/fleeting-notes.md; echo x > docs/new-outside.md'
check "untracked outside path: blocked rc 72" "rc=72 result=blocked" "$(printf '%s' "$FN_OUT" | tail -1)"
check "untracked outside path: origin unchanged" "0" "$(origin_commits)"
check "untracked outside path: copy preserved" "1" "$(iso_copies)"
check "untracked outside path: nothing published at all" "" "$(cat "$PUBLOG" 2>/dev/null)"
canon_untouched "untracked outside path"
make_env
run_fn 'echo x >> docs/other.md'
check "modified tracked outside path: blocked" "rc=72 result=blocked" "$(printf '%s' "$FN_OUT" | tail -1)"
check "modified tracked outside path: copy preserved, origin unchanged" "1/0" "$(iso_copies)/$(origin_commits)"
make_env
run_fn 'rm docs/other.md'
check "deleted outside path: blocked" "rc=72 result=blocked" "$(printf '%s' "$FN_OUT" | tail -1)"

echo "== A4b: an allowed path turned into a symlink blocks =="
make_env
run_fn 'rm inbox/fleeting-notes.md; ln -s /etc/hosts inbox/fleeting-notes.md'
check "symlink on an allowed path: blocked" "rc=72 result=blocked" "$(printf '%s' "$FN_OUT" | tail -1)"
check "symlink on an allowed path: origin unchanged, copy preserved" "0/1" "$(origin_commits)/$(iso_copies)"
canon_untouched "symlink"

echo "== A5: a model commit is normalised, not trusted =="
make_env
run_fn 'echo x > docs/c.md; git add docs/c.md; git commit -q -m "model commit outside"'
check "model committed an outside path: blocked" "rc=72 result=blocked" "$(printf '%s' "$FN_OUT" | tail -1)"
check "model committed an outside path: origin unchanged, copy preserved" "0/1" "$(origin_commits)/$(iso_copies)"
make_env
run_fn 'echo x >> inbox/fleeting-notes.md; git add inbox/fleeting-notes.md; git commit -q -m "model commit inside"'
check "model committed an allowed path: still published" "rc=0 result=published" "$(printf '%s' "$FN_OUT" | tail -1)"
check "model committed an allowed path: origin got exactly one commit (the runner's, not the model's)" "1" "$(origin_commits)"
check "model committed an allowed path: commit message is the runner's" "chore: test cleanup" "$(git -C "$ORIGIN" log -1 --format=%s main)"
make_env
run_fn 'echo x >> inbox/fleeting-notes.md; git checkout -q -b other-branch; git add inbox/fleeting-notes.md; git commit -q -m elsewhere'
check "copy left its branch: blocked" "rc=72 result=blocked" "$(printf '%s' "$FN_OUT" | tail -1)"
check "copy left its branch: origin unchanged, copy preserved" "0/1" "$(origin_commits)/$(iso_copies)"

echo "== A6: git status failure blocks =="
make_env
mkdir -p "$E/gitshim"
REAL_GIT=$(command -v git)
cat > "$E/gitshim/git" <<EOF
#!/bin/bash
for a in "\$@"; do [ "\$a" = status ] && exit 1; done
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$E/gitshim/git"
run_fn 'echo more >> inbox/fleeting-notes.md' "$E/gitshim"
check "git status fails: blocked" "rc=72 result=blocked" "$(printf '%s' "$FN_OUT" | tail -1)"
check "git status fails: origin unchanged, copy preserved" "0/1" "$(origin_commits)/$(iso_copies)"

echo "== A7: publication failure keeps the copy =="
make_env
FAKE_PUBLISH_FAIL=1 run_fn 'echo more >> inbox/fleeting-notes.md'
check "publisher fails (exit 1): its own status passes through, not 72" "rc=1 result=blocked" "$(printf '%s' "$FN_OUT" | tail -1)"
check "publisher fails: origin unchanged, copy preserved" "0/1" "$(origin_commits)/$(iso_copies)"
canon_untouched "publisher fails"
for code in 70 71; do
    make_env
    FAKE_PUBLISH_FAIL=1 FAKE_PUBLISH_RC=$code run_fn 'echo more >> inbox/fleeting-notes.md'
    check "publisher exits $code: $code goes out unchanged" "rc=$code result=blocked" "$(printf '%s' "$FN_OUT" | tail -1)"
    check "publisher exits $code: origin unchanged, copy preserved" "0/1" "$(origin_commits)/$(iso_copies)"
done
make_env
rm -f "$CANON/scripts/ds-publish.sh"; git -C "$CANON" commit -q -am "drop publisher"; git -C "$CANON" push -q origin HEAD:main
BASE=$(git -C "$ORIGIN" rev-parse main); CANON_HEAD=$(canon_head)
run_fn 'echo more >> inbox/fleeting-notes.md'
check "publisher missing in the copy: blocked, copy preserved" "rc=72 result=blocked/1" "$(printf '%s' "$FN_OUT" | tail -1)/$(iso_copies)"

echo "== A7b: commit failure blocks =="
make_env
mkdir -p "$E/gitshim"
cat > "$E/gitshim/git" <<EOF
#!/bin/bash
for a in "\$@"; do [ "\$a" = commit ] && exit 1; done
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$E/gitshim/git"
run_fn 'echo more >> inbox/fleeting-notes.md' "$E/gitshim"
check "git commit fails: blocked" "rc=72 result=blocked" "$(printf '%s' "$FN_OUT" | tail -1)"
check "git commit fails: origin unchanged, copy preserved" "0/1" "$(origin_commits)/$(iso_copies)"

echo "== A8: begin refuses when it cannot start clean =="
make_env
mv "$ORIGIN" "$E/origin.gone"
run_fn ':'
check "origin unreachable: not started" "begin-failed" "$(printf '%s' "$FN_OUT" | tail -1)"
check "origin unreachable: no copy left" "0" "$(iso_copies)"
canon_untouched "origin unreachable"
make_env
NOALLOW_OUT=$(FUNCS="$FUNCTIONS" WORKSPACE="$CANON" LOG_FILE="$LOG" bash -c 'eval "$FUNCS"; isolated_begin week-review; echo "rc=$?"' 2>&1 | tail -1)
check "scenario without allowlist: begin refuses" "rc=1" "$NOALLOW_OUT"

# --- layer B: the real runner end to end ---------------------------------------------------
# <stub mode> <STRATEGIST_ISOLATED_SCENARIOS> [runner argument, default note-review]; sets RC
run_runner() {
    RC=0
    env HOME="$HOME_DIR" IWE_WORKSPACE="$WSROOT" IWE_GOVERNANCE_REPO=DS-strategy IWE_TEMPLATE="${TEMPLATE_OVERRIDE:-$REPO_ROOT}" \
        AI_CLI="$E/bin/ai-stub" STUB_MODE="$1" STUB_CWD_FILE="$E/stub-cwd" STUB_ARGS_FILE="$E/stub-args" PUBLOG="$PUBLOG" \
        STRATEGIST_ISOLATED_SCENARIOS="$2" STRATEGIST_ISOLATED_TMPDIR="$ISO_TMP" TMPDIR="$TMPD" \
        IWE_EXTRACTOR_FEED_LOCK_DIR="$E/feed.lock" TELEGRAM_BOT_TOKEN= TELEGRAM_CHAT_ID= \
        FAKE_PUBLISH_FAIL="${FAKE_PUBLISH_FAIL:-0}" FAKE_PUBLISH_RC="${FAKE_PUBLISH_RC:-1}" PATH="${EXTRA_SHIM:+$EXTRA_SHIM:}$E/shim:$PATH" \
        bash "$SCRIPT" "${3:-note-review}" > "$E/out.txt" 2>&1 || RC=$?
}
fleeting_has_plain() { grep -c 'Plain old note' "$1/inbox/fleeting-notes.md"; }

echo "== B1: isolated note-review, happy path =="
make_env
run_runner noop note-review
check "runner exits 0" "0" "$RC"
check "model ran in the copy, not in the canon" "1" "$(grep -c 'iwe-strategist-note-review' "$E/stub-cwd")"
check "origin got exactly one commit" "1" "$(origin_commits)"
check "the commit touches exactly the two allowlisted files" "archive/notes/Notes-Archive.md inbox/fleeting-notes.md" "$(origin_paths)"
check "cleanup archived the plain note on origin" "0" "$(git -C "$ORIGIN" show main:inbox/fleeting-notes.md | grep -c 'Plain old note')"
check "cleanup left the already proposed note (bold + ✅предложено) on origin, it is not the script's to archive" "1" "$(git -C "$ORIGIN" show main:inbox/fleeting-notes.md | grep -c 'Already proposed note')"
check "cleanup script edited the copy: canon still holds the plain note" "1" "$(fleeting_has_plain "$CANON")"
check "prompt points the model at the copy's workspace" "1" "$(grep -c 'iwe-strategist-note-review.*/workspace/DS-strategy/inbox/' "$E/stub-args" | awk '{print ($1 > 0)}')"
check "prompt never mentions the canonical path" "0" "$(grep -c "$CANON" "$E/stub-args")"
canon_untouched "isolated happy path"
check "copy removed after publication" "0" "$(iso_copies)"

echo "== B2: isolated note-review, model writes outside the allowlist =="
make_env
run_runner outside-file note-review
check "runner exits 72" "72" "$RC"
check "origin unchanged" "0" "$(origin_commits)"
check "copy preserved with the offending file" "1" "$(ls "$ISO_TMP"/iwe-strategist-note-review.*/DS-strategy/docs/new-outside.md 2>/dev/null | wc -l | tr -d ' ')"
canon_untouched "outside-allowlist run"

echo "== B3: isolated note-review, model commits an outside path itself =="
make_env
run_runner commit-outside note-review
check "runner exits 72" "72" "$RC"
check "the model's own commit was not published unverified" "0" "$(origin_commits)"
check "copy preserved" "1" "$(iso_copies)"
canon_untouched "model-commit run"

echo "== B4: isolated note-review, model CLI fails =="
make_env
run_runner fail note-review
check "runner exits with the CLI's code" "3" "$RC"
check "origin unchanged even though cleanup could have run" "0" "$(origin_commits)"
check "copy preserved" "1" "$(iso_copies)"
canon_untouched "CLI failure"

echo "== B5: isolated note-review, publisher fails =="
make_env
FAKE_PUBLISH_FAIL=1 run_runner noop note-review
check "publisher exit 1: runner exits with it" "1" "$RC"
check "origin unchanged, copy preserved" "0/1" "$(origin_commits)/$(iso_copies)"
canon_untouched "publisher failure"
for code in 70 71; do
    make_env
    FAKE_PUBLISH_FAIL=1 FAKE_PUBLISH_RC=$code run_runner noop note-review
    check "publisher exit $code: runner exits $code" "$code" "$RC"
    check "publisher exit $code: origin unchanged, copy preserved" "0/1" "$(origin_commits)/$(iso_copies)"
done

echo "== B6: flag off keeps the legacy path =="
make_env
run_runner noop ""
check "runner exits 0" "0" "$RC"
check "no isolated copy was created" "0" "$(ls "$ISO_TMP" | wc -l | tr -d ' ')"
check "legacy: the cleanup commit is made in the canon" "1" "$([ "$(canon_head)" != "$CANON_HEAD" ] && echo 1 || echo 0)"
check "legacy: the publisher got the canon path" "$CANON" "$(head -1 "$PUBLOG")"
check "legacy: origin got one commit with the two files" "1|archive/notes/Notes-Archive.md inbox/fleeting-notes.md" "$(origin_commits)|$(origin_paths)"
check "legacy: the model ran in the canon" "$CANON" "$(cat "$E/stub-cwd")"
make_env
run_runner outside-file ""
check "legacy: an outside file is NOT blocked (behaviour unchanged)" "0" "$RC"
check "legacy: no isolation lines in the log" "0" "$(grep -c 'ISOLATION' "$HOME_DIR/logs/strategist/"*.log)"

echo "== B7: listing a scenario that has no isolated setup is refused =="
make_env
run_runner noop week-review week-review
check "week-review listed: runner exits 72" "72" "$RC"
check "week-review listed: the model never ran" "0" "$([ -e "$E/stub-cwd" ] && echo 1 || echo 0)"
canon_untouched "week-review listed"
make_env
run_runner noop morning morning
check "morning listed (no isolated setup, no run_claude name match): refused up front, exits 72" "72" "$RC"
check "morning listed: the model never ran" "0" "$([ -e "$E/stub-cwd" ] && echo 1 || echo 0)"
make_env
run_runner noop session-prep morning
check "morning->session-prep listed: refused inside run_claude, exits 72" "72" "$RC"
check "morning->session-prep listed: the model never ran" "0" "$([ -e "$E/stub-cwd" ] && echo 1 || echo 0)"
canon_untouched "session-prep listed"

echo "== B7b: the other scenarios have no allowlist (WP-530 Ф72 V-D): each is refused, none runs un-isolated =="
for scn in day-plan day-close evening strategy-session; do
    make_env
    run_runner noop "$scn" "$scn"
    check "$scn listed: runner exits 72" "72" "$RC"
    check "$scn listed: the model never ran" "0" "$([ -e "$E/stub-cwd" ] && echo 1 || echo 0)"
    check "$scn listed: refused up front for the missing allowlist (not only later inside run_claude)" "1" "$(grep -c "ISOLATION: сценарий $scn указан в STRATEGIST_ISOLATED_SCENARIOS, но списка разрешённых путей" "$HOME_DIR/logs/strategist/"*.log | awk '{print ($1 > 0)}')"
    canon_untouched "$scn listed"
done

# morning on a non-strategy day resolves to day-plan and, with the canonical pipeline present, would
# run day-open-pipeline.sh (no run_claude): a listed day-plan must stop before the pipeline writes
make_pipeline_env() {
    make_env
    printf 'strategy_day: %s\n' "$(date -d 'tomorrow' +%A 2>/dev/null || date -v+1d +%A)" | tr '[:upper:]' '[:lower:]' > "$CANON/exocortex/day-rhythm-config.yaml"
    printf '#!/bin/bash\ntouch "%s"\nexit 0\n' "$E/pipeline-ran" > "$CANON/scripts/day-open-pipeline.sh"
    git -C "$CANON" add -A && git -C "$CANON" commit -q -m "pipeline double" && git -C "$CANON" push -q origin HEAD:main
    BASE=$(git -C "$ORIGIN" rev-parse main); CANON_HEAD=$(canon_head)
}
ran() { [ -e "$1" ] && echo 1 || echo 0; }
make_pipeline_env
run_runner noop "" morning
check "control, flag off: morning runs the canonical pipeline (fixture reaches it)" "0/1" "$RC/$(ran "$E/pipeline-ran")"
make_pipeline_env
run_runner noop note-review morning
check "control, unrelated listing (note-review): the pipeline still runs" "0/1" "$RC/$(ran "$E/pipeline-ran")"
make_pipeline_env
run_runner noop day-plan morning
check "morning->day-plan listed: refused up front, exits 72" "72" "$RC"
check "morning->day-plan listed: the pipeline never ran" "0" "$(ran "$E/pipeline-ran")"
check "morning->day-plan listed: the model never ran" "0" "$(ran "$E/stub-cwd")"
canon_untouched "morning->day-plan listed"

echo "== B7c: week-review keeps its own contract: listed = refused before the guard session, flag off = codes 70/71 =="
# a session-guard double at the runner's fallback location ($IWE_WORKSPACE/scripts/session-guard.sh)
make_week_review_env() {
    make_env
    mkdir -p "$WSROOT/scripts"
    cat > "$WSROOT/scripts/session-guard.sh" <<'EOF'
#!/bin/bash
echo "$*" >> "$GUARD_LOG"
[ "$1" = open ] && exit "${GUARD_OPEN_RC:-0}"
exit 0
EOF
    export GUARD_LOG="$E/guard.log"
}
make_week_review_env
run_runner noop week-review week-review
check "week-review listed: runner exits 72" "72" "$RC"
check "week-review listed: refused up front for the missing allowlist" "1" "$(grep -c "ISOLATION: сценарий week-review указан в STRATEGIST_ISOLATED_SCENARIOS, но списка разрешённых путей" "$HOME_DIR/logs/strategist/"*.log | awk '{print ($1 > 0)}')"
check "week-review listed: no guard session was opened" "0" "$(ran "$GUARD_LOG")"
check "week-review listed: the model never ran" "0" "$(ran "$E/stub-cwd")"
canon_untouched "week-review listed"
make_week_review_env
run_runner noop "" week-review
check "flag off: nothing delivered, the delivery proof still reports 70" "70" "$RC"
check "flag off: the guard session was opened and closed by the runner" "1/1" "$(grep -c '^open --housekeeping' "$GUARD_LOG")/$(grep -c '^close --housekeeping' "$GUARD_LOG")"
check "flag off: the model ran in the canon (legacy path)" "$CANON" "$(cat "$E/stub-cwd")"
check "flag off: no isolated copy was created" "0" "$(ls "$ISO_TMP" | wc -l | tr -d ' ')"
make_week_review_env
GUARD_OPEN_RC=1 run_runner noop "" week-review
check "flag off, guard refuses the session: exit 71, the model never ran" "71/0" "$RC/$(ran "$E/stub-cwd")"
unset GUARD_LOG

echo "== C1: cleanup script in isolated mode has no silent canon fallback =="
CLEANUP_PY="$REPO_ROOT/roles/strategist/scripts/cleanup-processed-notes.py"
run_cleanup() {  # <env assignments...>; sets CRC
    CRC=0
    env HOME="$HOME_DIR" IWE_GOVERNANCE_REPO=DS-strategy "$@" "$PY3" "$CLEANUP_PY" > "$E/cleanup.out" 2>&1 || CRC=$?
}
canon_has_plain() { grep -c 'Plain old note' "$CANON/inbox/fleeting-notes.md"; }
make_env
run_cleanup IWE_CLEANUP_ISOLATED=1
check "isolated, no IWE_CLEANUP_REPO_DIR: refused (non-zero)" "2" "$CRC"
check "isolated, no dir: the canon was not touched" "1" "$(canon_has_plain)"
run_cleanup IWE_CLEANUP_ISOLATED=1 IWE_CLEANUP_REPO_DIR="$CANON"
check "isolated, dir = the canon checkout: refused" "2" "$CRC"
check "isolated, dir = canon: the canon was not touched" "1" "$(canon_has_plain)"
git clone -q "$ORIGIN" "$E/other-clone" 2>/dev/null
run_cleanup IWE_CLEANUP_ISOLATED=1 IWE_CLEANUP_REPO_DIR="$E/other-clone"
check "isolated, dir = an ordinary clone (not a linked worktree): refused" "2" "$CRC"
run_cleanup IWE_CLEANUP_ISOLATED=1 IWE_CLEANUP_REPO_DIR="$E/no-such-dir"
check "isolated, dir missing: refused" "2" "$CRC"
git -C "$CANON" worktree add -q -b cleanup-wt "$E/wt" origin/main
run_cleanup IWE_CLEANUP_ISOLATED=1 IWE_CLEANUP_REPO_DIR="$E/wt"
check "isolated, dir = a linked worktree: runs" "0" "$CRC"
check "isolated worktree run archived the note in the copy only" "0/1" "$(grep -c 'Plain old note' "$E/wt/inbox/fleeting-notes.md")/$(canon_has_plain)"
check "isolated worktree run kept the proposed note in the copy" "1" "$(grep -c 'Already proposed note' "$E/wt/inbox/fleeting-notes.md")"
make_env
run_cleanup
check "not isolated, no dir: legacy default still edits the canon path" "0/0" "$CRC/$(canon_has_plain)"

echo "== B8: a failing cleanup script blocks the isolated run =="
make_failing_cleanup_template() {
    mkdir -p "$E/tmpl/roles/strategist/scripts"
    ln -s "$REPO_ROOT/roles/strategist/prompts" "$E/tmpl/roles/strategist/prompts"
    printf 'import sys\nprint("boom", file=sys.stderr)\nsys.exit(2)\n' > "$E/tmpl/roles/strategist/scripts/cleanup-processed-notes.py"
}
make_env
make_failing_cleanup_template
TEMPLATE_OVERRIDE="$E/tmpl" run_runner noop note-review
check "cleanup script fails: runner exits 72" "72" "$RC"
check "cleanup script fails: origin unchanged, copy preserved" "0/1" "$(origin_commits)/$(iso_copies)"
canon_untouched "cleanup failure"
make_env
make_failing_cleanup_template
TEMPLATE_OVERRIDE="$E/tmpl" run_runner noop ""
check "flag off: the same failing cleanup script is still ignored as before (exit 0)" "0" "$RC"

echo "== B9: errexit is off inside run_claude when called with || : failures must still stop it =="
make_env
mkdir -p "$E/shim-py" "$E/shim-sed" "$E/shim-git"
printf '#!/bin/bash\nexit 1\n' > "$E/shim-py/python3"; chmod +x "$E/shim-py/python3"
cp "$E/shim-py/python3" "$E/shim-sed/sed"
EXTRA_SHIM="$E/shim-py" run_runner noop note-review
check "python3 (date context) fails: runner exits non-zero" "1" "$([ "$RC" -ne 0 ] && echo 1 || echo 0)"
check "python3 fails: the model never ran" "0" "$([ -e "$E/stub-cwd" ] && echo 1 || echo 0)"
check "python3 fails: origin unchanged, copy preserved" "0/1" "$(origin_commits)/$(iso_copies)"
make_env
mkdir -p "$E/shim-cd"
printf '#!/bin/bash\nrm -rf "%s"/iwe-strategist-note-review.*/DS-strategy\nexec /usr/bin/sed "$@"\n' "$ISO_TMP" > "$E/shim-cd/sed"; chmod +x "$E/shim-cd/sed"
EXTRA_SHIM="$E/shim-cd" run_runner noop note-review
check "cd into the copy fails: runner exits non-zero" "1" "$([ "$RC" -ne 0 ] && echo 1 || echo 0)"
check "cd fails: the model never ran" "0" "$([ -e "$E/stub-cwd" ] && echo 1 || echo 0)"
make_env
mkdir -p "$E/shim-sed"; printf '#!/bin/bash\nexit 1\n' > "$E/shim-sed/sed"; chmod +x "$E/shim-sed/sed"
EXTRA_SHIM="$E/shim-sed" run_runner noop note-review
check "sed (prompt read) fails: runner exits non-zero" "1" "$([ "$RC" -ne 0 ] && echo 1 || echo 0)"
check "sed fails: the model never ran" "0" "$([ -e "$E/stub-cwd" ] && echo 1 || echo 0)"
check "sed fails: origin unchanged, copy preserved" "0/1" "$(origin_commits)/$(iso_copies)"

echo "== B10: the canary understands ✅предложено (#961): a healthy run is silent, a run that processed nothing still alarms =="
# The canary used to expect the plain bold count to drop. Since the pilot decision of 2026-07-29 a processed note
# keeps its bold and gets the ✅предложено mark, so every healthy run looked like a failed one and sent a false alarm.
# The model double either marks the new note (healthy) or does nothing; a recording curl double stands for the
# Telegram API, so an alert is observable. The legacy and the isolated path share the canary code: both are run.
log_count() { cat "$HOME_DIR"/logs/strategist/*.log 2>/dev/null | grep -c -- "$1" || true; }
alert_count() { if [ -f "$E/curl.log" ]; then grep -c 'Note-Review canary' "$E/curl.log" || true; else echo 0; fi; }
published_count() { git -C "$ORIGIN" show main:inbox/fleeting-notes.md | grep -c -- "$1" || true; }
make_canary_env() {
    make_env
    mkdir -p "$HOME_DIR/.config/aist"
    printf 'TELEGRAM_BOT_TOKEN=canary-test\nTELEGRAM_CHAT_ID=1\n' > "$HOME_DIR/.config/aist/env"
    printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$E/curl.log" > "$E/shim/curl"
    chmod +x "$E/shim/curl"
}
for scenario_flag in "" "note-review"; do
    mode_label="flag off"; [ -z "$scenario_flag" ] || mode_label="isolated"
    make_canary_env
    run_runner mark-proposed "$scenario_flag" note-review
    check "$mode_label, healthy run (the new note gets ✅предложено): runner exits 0" "0" "$RC"
    check "$mode_label, healthy run: the canary logged no warning" "0" "$(log_count 'WARN: Note-Review')"
    check "$mode_label, healthy run: no canary alert was sent" "0" "$(alert_count)"
    check "$mode_label, healthy run: the marked note is published bold, nothing archived on its own" "1" "$(published_count '^\*\*Bold new note\*\* ✅предложено$')"
    check "$mode_label, healthy run: the earlier proposed note is still in the box" "1" "$(published_count '^\*\*Already proposed note\*\* ✅предложено$')"
    check "$mode_label, healthy run: the plain old note was archived by the safety net, as before" "0" "$(published_count 'Plain old note')"
    make_canary_env
    run_runner noop "$scenario_flag" note-review
    check "$mode_label, control, the model processed nothing: runner exits 0" "0" "$RC"
    check "$mode_label, control: the canary logged its warning" "1" "$(log_count 'WARN: Note-Review')"
    check "$mode_label, control: the canary alert was sent (the recording double is wired in)" "1" "$(alert_count)"
done

echo
echo "Passed: $PASS_COUNT, failed: $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
