#!/usr/bin/env bash
# test_kimi_standalone_preflight.sh -- WP-524 (21.11): the template preflight
# ignored --wp and printed no MARKER line, while kimi-peer-writer (step 0a)
# calls it with --wp and rebuilds its semaphore from that line. It must pick
# the conversation's own semaphore by filters, never by recency alone, and its
# MARKER must lead the skill back to exactly the semaphore it validated.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
PREFLIGHT="$ROOT_DIR/scripts/kimi-standalone-preflight.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/kimi-preflight.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT
SESS="$TEST_ROOT/.iwe-runtime/sessions"
MARKERS="$TEST_ROOT/.iwe-runtime"
mkdir -p "$SESS"

make_sem() { # <session_id> <wp> <slug> [file-name id, defaults to session_id]
    printf -- '---\nagent: kimi\nwp: %s\nslug: %s\nsession_id: %s\n---\n' "$2" "$3" "$1" > "$SESS/kimi-${4:-$1}.open"
}
run() { IWE_ROOT="$TEST_ROOT" bash "$PREFLIGHT" "$@"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
markers() { find "$MARKERS" -maxdepth 1 -name 'kimi-standalone-*.marker' | wc -l | tr -d ' '; }

make_sem aaa WP-1 slug-a
touch -t 202601010000 "$SESS/kimi-aaa.open"
make_sem bbb WP-2 slug-b

# Legacy call: newest semaphore, with a warning on stderr.
out=$(run 2>"$TEST_ROOT/legacy.err") || fail "legacy call must still succeed"
grep -q 'kimi-bbb.open' <<< "$out" || fail "legacy call must pick the newest semaphore, got: $out"
grep -q 'WARNING' "$TEST_ROOT/legacy.err" || fail "legacy call must warn that the pick may be foreign"
echo "OK: unscoped call keeps the newest-semaphore pick and warns"

# --wp picks the older semaphore of its own WP, not the newest one.
rm -f "$MARKERS"/kimi-standalone-*.marker
out=$(run --wp WP-1 2>"$TEST_ROOT/wp1.err") || fail "--wp WP-1 must succeed"
grep -q 'kimi-aaa.open' <<< "$out" || fail "--wp WP-1 must pick kimi-aaa.open, got: $out"
grep -q 'stale' "$TEST_ROOT/wp1.err" || fail "a semaphore from 2026-01-01 must be reported stale (mtime read wrong?)"
echo "OK: --wp selects by WP, not by recency; old mtime reads as stale"

# Skill contract: exactly one MARKER line, the file exists, and the skill's own
# sed formula rebuilds the path of the semaphore that was validated.
[ "$(grep -c '^MARKER: ' <<< "$out")" -eq 1 ] || fail "expected exactly one MARKER line, got: $out"
marker_path=$(sed -n 's/^MARKER: //p' <<< "$out")
[ -f "$marker_path" ] || fail "MARKER points at a missing file: $marker_path"
recovered_id=$(sed -E 's#.*kimi-standalone-(.*)\.marker$#\1#' <<< "MARKER: $marker_path")
[ "$SESS/kimi-${recovered_id}.open" = "$SESS/kimi-aaa.open" ] || fail "skill would recover kimi-${recovered_id}.open, not kimi-aaa.open"
echo "OK: MARKER line leads the skill back to the validated semaphore"

# Zero matches fail closed, without a marker and with the IWE_SCRIPTS hint.
rm -f "$MARKERS"/kimi-standalone-*.marker
if run --wp WP-9 >/dev/null 2>"$TEST_ROOT/none.err"; then fail "--wp WP-9 has no semaphore and must fail"; fi
[ "$(markers)" -eq 0 ] || fail "a refused preflight must not write a marker"
grep -qF 'bash "${IWE_SCRIPTS:-$HOME/IWE/scripts}/session-guard.sh" open --wp WP-9' "$TEST_ROOT/none.err" \
    || fail "refusal hint must use the IWE_SCRIPTS form: $(cat "$TEST_ROOT/none.err")"
echo "OK: no match fails closed with no marker and an IWE_SCRIPTS hint"

# Two semaphores for one WP: refuse to guess; --slug disambiguates.
make_sem ccc WP-1 slug-c
if run --wp WP-1 >/dev/null 2>&1; then fail "two WP-1 semaphores must fail closed"; fi
[ "$(markers)" -eq 0 ] || fail "an ambiguous preflight must not write a marker"
out=$(run --wp WP-1 --slug slug-c 2>/dev/null) || fail "--wp WP-1 --slug slug-c must succeed"
grep -q 'kimi-ccc.open' <<< "$out" || fail "--slug must narrow to kimi-ccc.open, got: $out"
echo "OK: several matches fail closed; --slug narrows to one"

# session_id that does not name its own file: refuse, no marker.
rm -f "$MARKERS"/kimi-standalone-*.marker
make_sem other-id WP-3 slug-d ddd
if run --wp WP-3 >/dev/null 2>"$TEST_ROOT/mismatch.err"; then fail "session_id/file-name mismatch must fail"; fi
[ "$(markers)" -eq 0 ] || fail "a mismatched semaphore must not produce a marker"
grep -q 'does not match its file name' "$TEST_ROOT/mismatch.err" || fail "mismatch refusal must say why"
echo "OK: a session_id that does not name its file is refused without a marker"

# Housekeeping semaphore of a scheduled task run (named after its reason, not
# its id): found by --slug, accepted; a renamed one is refused.
rm -f "$MARKERS"/kimi-standalone-*.marker
printf -- '---\nagent: kimi\nhousekeeping: sched-T1\nslug: sched-T1\nsession_id: hk111\n---\n' > "$SESS/kimi-housekeeping-sched-T1.open"
out=$(run --slug sched-T1 2>/dev/null) || fail "--slug sched-T1 must accept the housekeeping semaphore"
grep -q 'kimi-housekeeping-sched-T1.open' <<< "$out" || fail "--slug sched-T1 must pick the housekeeping semaphore, got: $out"
[ "$(grep -c '^MARKER: ' <<< "$out")" -eq 1 ] || fail "housekeeping pick must still print one MARKER line"
printf -- '---\nagent: kimi\nhousekeeping: sched-T2\nslug: sched-T2\nsession_id: hk222\n---\n' > "$SESS/kimi-housekeeping-other.open"
rm -f "$MARKERS"/kimi-standalone-*.marker
if run --slug sched-T2 >/dev/null 2>&1; then fail "a housekeeping semaphore not named after its reason must fail"; fi
[ "$(markers)" -eq 0 ] || fail "a misnamed housekeeping semaphore must not produce a marker"
echo "OK: housekeeping semaphore is accepted by its reason name, a misnamed one is refused"

# Empty filter value must not fall back to the unscoped pick.
if run --wp "" >/dev/null 2>&1; then fail "--wp with an empty value must fail"; fi
echo "OK: empty filter value is refused"

echo "PASS: kimi-standalone-preflight resolves its own semaphore by filters and hands the skill a matching MARKER"
