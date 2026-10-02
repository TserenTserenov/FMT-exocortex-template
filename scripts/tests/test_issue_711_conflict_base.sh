#!/usr/bin/env bash
# Regression coverage for issue #711: sync_workspace_claude_md() used to
# advance `.claude.md.base` to the new upstream version unconditionally, even
# when the 3-way merge left unresolved <<<<<<< markers in the workspace
# CLAUDE.md. The next run then compared the (already-advanced) base against
# the same upstream file, found no difference, and reported "Всё актуально"
# while the pilot's file still contained literal conflict markers.
#
# This test drives sync_workspace_claude_md() directly across a realistic
# multi-run sequence (peer-session mini-gate, WP-7 Ф116): clean install ->
# genuine conflict -> unresolved repeat run -> manual resolution -> idempotent
# rerun. Each step's outcome is the actual defect surface, not the specific
# diff3 codepath, so the assertions are outcome-based like #555's guard.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT

pass_count=0
pass() { echo "  ✅ PASS: $*"; pass_count=$((pass_count + 1)); }
fail() { echo "  ❌ FAIL: $*" >&2; exit 1; }

# Load only the functions under test — sourcing update.sh would execute the
# updater (same isolation pattern as test_issue_555_claude_silent_loss.sh).
eval "$(awk '
  /^substitute_claude_placeholders\(\)/ { capture=1 }
  capture { print }
  capture && /^}/ { print ""; capture=0 }
' "$ROOT/update.sh")"
eval "$(awk '
  /^detect_claude_silent_loss\(\)/ { capture=1 }
  capture { print }
  capture && /^}/ { print ""; capture=0 }
' "$ROOT/update.sh")"
eval "$(awk '
  /^sync_workspace_claude_md\(\)/ { capture=1 }
  capture { print }
  capture && /^}/ { exit }
' "$ROOT/update.sh")"
declare -F sync_workspace_claude_md >/dev/null

WORKSPACE_DIR="$TMP/workspace"
SCRIPT_DIR="$TMP/template"
TMPDIR_UPDATE="$TMP/tmp"
mkdir -p "$WORKSPACE_DIR" "$SCRIPT_DIR" "$TMPDIR_UPDATE"

run_sync() {
  CLAUDE_CONFLICT_DETECTED=false
  CLAUDE_CONFLICT_FILES=()
  CLAUDE_SILENT_LOSS_FILES=()
  CLAUDE_CONFLICTS=0
  sync_workspace_claude_md >"$TMP/out.txt" 2>&1
  # Both arrays are populated by sync_workspace_claude_md itself — read them
  # here so a real regression (e.g. a conflict that stops getting recorded
  # in CLAUDE_CONFLICT_FILES) shows up in the trace, not just in $out.txt.
  [ "${#CLAUDE_CONFLICT_FILES[@]}" -gt 0 ] && echo "  (conflict files: ${CLAUDE_CONFLICT_FILES[*]})"
  [ "${#CLAUDE_SILENT_LOSS_FILES[@]}" -gt 0 ] && echo "  (silent-loss files: ${CLAUDE_SILENT_LOSS_FILES[*]})"
  return 0
}

echo "--- run 1: first install, no base/current yet ---"
cat >"$SCRIPT_DIR/CLAUDE.md" <<'EOF'
line1 platform
line2 platform
line3 platform
EOF
run_sync
if [ -f "$WORKSPACE_DIR/CLAUDE.md" ] && [ -f "$WORKSPACE_DIR/.claude.md.base" ]; then
  pass "first install seeds workspace CLAUDE.md and base"
else
  fail "expected workspace CLAUDE.md + base to be seeded on first install"
fi

echo "--- run 2: pilot and upstream both change line2 -> genuine conflict ---"
cat >"$WORKSPACE_DIR/CLAUDE.md" <<'EOF'
line1 platform
line2 PILOT EDIT
line3 platform
EOF
cat >"$SCRIPT_DIR/CLAUDE.md" <<'EOF'
line1 platform
line2 UPSTREAM EDIT
line3 platform
EOF
run_sync
if $CLAUDE_CONFLICT_DETECTED && [ "$CLAUDE_CONFLICTS" -eq 1 ] && grep -qF '<<<<<<<' "$WORKSPACE_DIR/CLAUDE.md"; then
  pass "genuine conflict detected, markers written to workspace CLAUDE.md"
else
  fail "expected a detected conflict with markers in workspace file"
fi
BASE_AFTER_CONFLICT=$(cat "$WORKSPACE_DIR/.claude.md.base")

echo "--- run 3 (issue #711 core case): repeat run WITHOUT resolving markers ---"
run_sync
if $CLAUDE_CONFLICT_DETECTED; then
  pass "repeat run on an unresolved conflict still reports a conflict, not 'всё актуально'"
else
  fail "repeat run silently cleared the conflict — this is exactly issue #711"
fi
if grep -qF '<<<<<<<' "$WORKSPACE_DIR/CLAUDE.md"; then
  pass "markers from run 2 are still intact after the unresolved repeat run"
else
  fail "markers vanished or were re-merged into a confusing state on the repeat run"
fi
if [ "$(cat "$WORKSPACE_DIR/.claude.md.base")" = "$BASE_AFTER_CONFLICT" ]; then
  pass "base was NOT advanced while the conflict stayed unresolved"
else
  fail "base advanced despite an unresolved conflict — the exact regression #711 reports"
fi

echo "--- run 4: pilot manually resolves by accepting the upstream line ---"
cat >"$WORKSPACE_DIR/CLAUDE.md" <<'EOF'
line1 platform
line2 UPSTREAM EDIT
line3 platform
EOF
run_sync
if ! $CLAUDE_CONFLICT_DETECTED && [ "$(cat "$WORKSPACE_DIR/CLAUDE.md")" = "$(cat "$SCRIPT_DIR/CLAUDE.md")" ]; then
  pass "manual resolution converges cleanly once markers are gone"
else
  fail "resolution did not converge: conflict_detected=$CLAUDE_CONFLICT_DETECTED"
fi

echo "--- run 5: idempotent rerun with nothing changed ---"
BEFORE_RUN5=$(cat "$WORKSPACE_DIR/CLAUDE.md")
run_sync
if [ "$NEEDS_WS_CLAUDE_SYNC" = "false" ] && [ "$(cat "$WORKSPACE_DIR/CLAUDE.md")" = "$BEFORE_RUN5" ]; then
  pass "converged state is idempotent — no spurious re-sync on an unchanged tree"
else
  fail "expected NEEDS_WS_CLAUDE_SYNC=false and an unchanged file on a no-op rerun"
fi

echo "issue-711 CLAUDE.md base-advance guard: $pass_count checks passed"
