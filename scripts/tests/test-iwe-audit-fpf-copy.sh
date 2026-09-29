#!/usr/bin/env bash
# WP-5 F57: the installation audit must tell the operator when the FPF copy is
# missing, lacks the author's usage instruction (USING-FPF.md) or is stale, and
# must count each as a warning (never a hard failure: the copy is optional).
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Guard the wiring itself: the function must be called from the audit body.
[ "$(grep -c '^report_fpf_copy_state$' "$ROOT/scripts/iwe-audit.sh")" -eq 1 ] \
    || { echo 'audit does not call report_fpf_copy_state exactly once' >&2; exit 1; }

eval "$(awk '
  /^report_fpf_copy_state\(\)/ { capture=1 }
  capture { print }
  capture && /^}/ { exit }
' "$ROOT/scripts/iwe-audit.sh")"
declare -F report_fpf_copy_state >/dev/null

export GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_NOSYSTEM=1
: > "$GIT_CONFIG_GLOBAL"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

fail() { echo "FAIL: $*" >&2; exit 1; }

make_copy() {  # $1 = seconds since epoch of the commit, $2 = "with" or "without" USING-FPF.md
    rm -rf "$IWE_ROOT/FPF"
    mkdir -p "$IWE_ROOT/FPF"
    git -C "$IWE_ROOT/FPF" init -q
    echo spec > "$IWE_ROOT/FPF/FPF-Spec.md"
    [ "$2" = with ] && echo instruction > "$IWE_ROOT/FPF/USING-FPF.md"
    git -C "$IWE_ROOT/FPF" add FPF-Spec.md
    [ "$2" = with ] && git -C "$IWE_ROOT/FPF" add USING-FPF.md
    GIT_AUTHOR_DATE="@$1 +0000" GIT_COMMITTER_DATE="@$1 +0000" \
        git -C "$IWE_ROOT/FPF" commit -q -m copy
}

IWE_ROOT="$TMP/ws"
mkdir -p "$IWE_ROOT"
NOW=$(date +%s)

# 1. No copy at all -> one warning that names the copy.
UPD_WARN=0
out=$(report_fpf_copy_state)
grep -q 'не найдена' <<<"$out" || fail "case 1: no 'не найдена': $out"
UPD_WARN=0; report_fpf_copy_state >/dev/null
[ "$UPD_WARN" -eq 1 ] || fail "case 1: expected 1 warning, got $UPD_WARN"

# 2. Fresh copy with the instruction -> two ok lines, no warnings.
make_copy "$NOW" with
UPD_WARN=0
out=$(report_fpf_copy_state)
grep -q 'USING-FPF.md.*на месте' <<<"$out" || fail "case 2: instruction not confirmed: $out"
grep -q 'свежая' <<<"$out" || fail "case 2: freshness not confirmed: $out"
UPD_WARN=0; report_fpf_copy_state >/dev/null
[ "$UPD_WARN" -eq 0 ] || fail "case 2: expected 0 warnings, got $UPD_WARN"

# 3. Fresh copy without the instruction -> one warning pointing at update.sh.
make_copy "$NOW" without
UPD_WARN=0
out=$(report_fpf_copy_state)
grep -q 'нет .USING-FPF.md' <<<"$out" || fail "case 3: missing instruction not reported: $out"
grep -q 'update.sh' <<<"$out" || fail "case 3: no remedy: $out"
UPD_WARN=0; report_fpf_copy_state >/dev/null
[ "$UPD_WARN" -eq 1 ] || fail "case 3: expected 1 warning, got $UPD_WARN"

# 4. Copy with the instruction but 45 days old -> one staleness warning.
make_copy "$((NOW - 45 * 86400))" with
out=$(report_fpf_copy_state)
grep -q 'старше 30 дней' <<<"$out" || fail "case 4: staleness not reported: $out"
UPD_WARN=0; report_fpf_copy_state >/dev/null
[ "$UPD_WARN" -eq 1 ] || fail "case 4: expected 1 warning, got $UPD_WARN"

# 5. Exactly 29 days old is still fresh (boundary).
make_copy "$((NOW - 29 * 86400))" with
UPD_WARN=0; report_fpf_copy_state >/dev/null
[ "$UPD_WARN" -eq 0 ] || fail "case 5: 29-day-old copy flagged stale"

echo "PASS: 5 cases"
