#!/usr/bin/env bash
# Regression for the clear-defect findings of issue #1010 (red team of the 0.41.1 candidate):
#  F3  stale/repair copy of a skill spec keeps its USER-SPACE block
#  F5  strategy-session step 0 names the offline way out
#  F7  zero-change update branches run the CLAUDE.md conflict gate BEFORE clearing .update-incomplete
#  F11 setup.sh never asks "run validation now?" under SETUP_CI or without a terminal
#  F14 GNU-first `stat -c %Y` (GNU `stat -f %m` succeeds with file-system lines)
#  F16 validate-template.yml declares least-privilege token permissions
# (F6 is covered by test_issue_1006_minor_findings.sh, F17 by setup/test-update-step0-staged-rename.sh.)
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
fails=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*" >&2; fails=$((fails + 1)); }

echo "== F3 USER-SPACE kept by the stale/repair copy of a skill"
for fn in hash_file backup_rule_before_overwrite rule_was_safe_to_update copy_platform_file_preserving_user_space; do
  eval "$(awk -v sig="$fn() {" '$0 == sig {c=1} c {print} c && /^}$/ {exit}' "$ROOT/update.sh")"
done
declare -F copy_platform_file_preserving_user_space >/dev/null || { echo "FATAL: cannot extract copy_platform_file_preserving_user_space" >&2; exit 2; }
WORKSPACE_DIR="$TMP/ws"; RULES_BACKUP_RUN=""
mkdir -p "$TMP/src" "$TMP/ws/.claude/skills/demo"
printf '# Demo skill v2\n' > "$TMP/src/SKILL.md"
printf '# Demo skill v1\n\n<!-- USER-SPACE -->\nMY-LOCAL-NOTE\n<!-- /USER-SPACE -->\n' > "$TMP/ws/.claude/skills/demo/SKILL.md"
copy_platform_file_preserving_user_space "$TMP/src/SKILL.md" "$TMP/ws/.claude/skills/demo/SKILL.md" ".claude/skills/demo/SKILL.md" >/dev/null 2>&1
out="$TMP/ws/.claude/skills/demo/SKILL.md"
if grep -q 'Demo skill v2' "$out" && grep -q 'MY-LOCAL-NOTE' "$out"; then pass "new platform text and the USER-SPACE block"; else fail "USER-SPACE block lost: $(tr '\n' '|' < "$out")"; fi

echo "== F5 offline hint in strategy-session step 0"
grep -q 'Офлайн (нет сети' "$ROOT/.claude/skills/strategy-session/SKILL.md" && pass "offline way out named" || fail "no offline way out in step 0"

echo "== F7 conflict gate before the marker is cleared"
check_order() {  # LABEL START_PATTERN
  local label="$1" start="$2" gate fin
  gate=$(awk -v s="$start" 'index($0,s){f=1} f&&/^[[:space:]]+claude_conflict_gate$/{print NR; exit}' "$ROOT/update.sh")
  fin=$(awk -v s="$start" 'index($0,s){f=1} f&&/^[[:space:]]+finish_update_transaction$/{print NR; exit}' "$ROOT/update.sh")
  if [ -n "$gate" ] && [ -n "$fin" ] && [ "$gate" -lt "$fin" ]; then pass "$label: gate (line $gate) before finish (line $fin)"; else fail "$label: gate=$gate finish=$fin"; fi
}
check_order "download-hiccup branch" 'Same three calls, same order, as the branch below.'
check_order "zero-change branch" 'Evgenii Red Team review 2026-08-19 (defect #3): repair_pass() below'

echo "== F11 setup.sh validation prompt is guarded"
if awk '/read -p "Запустить проверку сейчас/{print prev; exit} {prev=prev"\n"$0; sub(/^.*\n.*\n.*\n/,"",prev)}' "$ROOT/setup.sh" | grep -q 'SETUP_CI'; then
  pass "SETUP_CI guards the prompt"
else
  fail "the validation prompt is not guarded by SETUP_CI"
fi

echo "== F14 GNU-first stat"
bad=$(git -C "$ROOT" grep -nE 'stat -f %m [^|]*\|\| *stat -c %Y' -- '*.sh' 2>/dev/null || true)
[ -z "$bad" ] && pass "no BSD-first 'stat -f %m || stat -c %Y' left" || fail "BSD-first stat: $(printf '%s' "$bad" | head -2 | tr '\n' ' ')"
eval "$(awk '$0 == "stat_mtime() {" {c=1} c {print} c && /^}$/ {exit}' "$ROOT/scripts/iwe-backup-check.sh")"
# A GNU-like stat: `-f` is "file system status" (succeeds, several lines), `-c %Y` is the mtime.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/stat" <<'STAT'
#!/bin/sh
case "$1" in
  -f) printf 'File: "x"\nID: 0 Namelen: 255\n'; exit 0 ;;
  -c) printf '1700000000\n'; exit 0 ;;
esac
exit 1
STAT
chmod +x "$TMP/bin/stat"
got=$(PATH="$TMP/bin:$PATH" stat_mtime "$TMP/f" 2>/dev/null)
[ "$got" = 1700000000 ] && pass "stat_mtime asks GNU stat for the mtime (-c %Y) first" || fail "stat_mtime printed '$got'"

echo "== F16 workflow permissions"
grep -qE '^permissions:' "$ROOT/.github/workflows/validate-template.yml" && pass "top-level permissions present" || fail "validate-template.yml has no top-level permissions"

echo
if [ "$fails" -eq 0 ]; then echo "PASS: #1010"; else echo "FAILED: $fails check(s)"; exit 1; fi
