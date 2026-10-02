#!/usr/bin/env bash
# Regression for issue #1004 (part 1): sync_workspace_claude_md() with an existing workspace
# CLAUDE.md, NO merge base and a <!-- USER-SPACE --> block replaced the file with the template
# version and kept only the block: pilot edits outside it vanished with no copy. Now the old file
# is copied to .backups/claude-md-pre-update/ first and the output names the copy; when the copy
# cannot be made the file stays untouched.
# (Part 2 of #1004, the truncated self-update, is covered by setup/test-update-step0-staged-rename.sh.)
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
fails=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*" >&2; fails=$((fails + 1)); }

for fn in substitute_claude_placeholders detect_claude_silent_loss claude_backup_before_replace sync_workspace_claude_md; do
  eval "$(awk -v sig="$fn() {" '$0 == sig {c=1} c {print} c && /^}$/ {exit}' "$ROOT/update.sh")"
  [ "$fn" = claude_backup_before_replace ] || declare -F "$fn" >/dev/null || { echo "FATAL: cannot extract $fn" >&2; exit 2; }
done
sed_inplace() { sed -i.bak "$@" 2>/dev/null && rm -f "${@: -1}.bak"; }

setup_case() {
  WORKSPACE_DIR="$TMP/$1/ws"; SCRIPT_DIR="$TMP/$1/tpl"; TMPDIR_UPDATE="$TMP/$1/tmp"
  mkdir -p "$WORKSPACE_DIR" "$SCRIPT_DIR" "$TMPDIR_UPDATE"
  printf '# Template v2\n\nnew platform text\n' > "$SCRIPT_DIR/CLAUDE.md"
  printf '# Template v1\n\nMY-OUTSIDE-EDIT in section 9\n\n<!-- USER-SPACE -->\nMY-BLOCK\n<!-- /USER-SPACE -->\n' > "$WORKSPACE_DIR/CLAUDE.md"
  CLAUDE_CONFLICT_DETECTED=false; CLAUDE_CONFLICT_FILES=(); CLAUDE_SILENT_LOSS_FILES=()
  CLAUDE_BASE_MISSING_FILES=(); CLAUDE_CONFLICTS=0
}

echo "== backup is taken before the replacement"
setup_case a
sync_workspace_claude_md > "$TMP/a.out" 2>&1
BK=$(find "$WORKSPACE_DIR/.backups/claude-md-pre-update" -type f 2>/dev/null | head -1)
if [ -n "$BK" ] && grep -q 'MY-OUTSIDE-EDIT' "$BK"; then pass "backup holds the pilot's outside edit"; else fail "no backup with the outside edit ($(cat "$TMP/a.out" | head -5 | tr '\n' ' '))"; fi
grep -q 'MY-BLOCK' "$WORKSPACE_DIR/CLAUDE.md" && pass "USER-SPACE block still kept" || fail "USER-SPACE block lost"
grep -q 'claude-md-pre-update' "$TMP/a.out" && pass "output names the backup" || fail "output does not name the backup"

echo "== a failed backup leaves the file untouched"
setup_case b
mkdir -p "$TMP/b/elsewhere"; ln -s "$TMP/b/elsewhere" "$WORKSPACE_DIR/.backups"
sync_workspace_claude_md > "$TMP/b.out" 2>&1
if grep -q 'MY-OUTSIDE-EDIT' "$WORKSPACE_DIR/CLAUDE.md" && ! grep -q 'new platform text' "$WORKSPACE_DIR/CLAUDE.md"; then
  pass "file kept as is when no backup can be made"
else
  fail "file replaced without a backup"
fi

echo "== the USER-SPACE block is restored with printf, not echo"
if grep -nE 'echo "\$(WS_)?USER_SECTION"' "$ROOT/update.sh" >/dev/null; then
  fail "echo of a user block left: $(grep -nE 'echo "\$(WS_)?USER_SECTION"' "$ROOT/update.sh" | head -1)"
else
  pass "no echo of USER_SECTION / WS_USER_SECTION"
fi

echo
if [ "$fails" -eq 0 ]; then echo "PASS: #1004 CLAUDE.md backup"; else echo "FAILED: $fails check(s)"; exit 1; fi
