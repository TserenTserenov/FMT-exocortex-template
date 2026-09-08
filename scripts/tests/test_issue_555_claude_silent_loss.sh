#!/usr/bin/env bash
# Regression coverage for issue #555: a "clean" `git merge-file` exit (no
# <<<<<<< markers) can still make a pilot's customized CLAUDE.md line vanish
# from the result — reported live with a stale `.claude.md.base`. The exact
# diff3 trigger was not reliably reproducible in isolation (every synthetic
# base/current/new combination tried during triage produced real conflict
# markers instead), so the fix does not try to prevent the specific
# diff3 behavior — it verifies the OUTCOME via detect_claude_silent_loss():
# every line the pilot added/changed relative to base must still be present
# in the merge result, regardless of exit code or markers.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT

pass_count=0
pass() { echo "  ✅ PASS: $*"; pass_count=$((pass_count + 1)); }
fail() { echo "  ❌ FAIL: $*" >&2; exit 1; }

# Load only the function under test — sourcing update.sh would execute the
# updater (same isolation pattern as test_update_install_path_guard.sh).
eval "$(awk '
  /^detect_claude_silent_loss\(\)/ { capture=1 }
  capture { print }
  capture && /^}/ { exit }
' "$ROOT/update.sh")"
declare -F detect_claude_silent_loss >/dev/null

echo "--- pilot line silently dropped by the merge (no conflict markers) ---"
cat >"$TMP/base.md" <<'EOF'
- **Obsidian:** старая формулировка про vault.
EOF
cat >"$TMP/before.md" <<'EOF'
- **Без Obsidian (DS-strategy):** просмотр через VS Code.
EOF
# Simulates a "clean" merge result that dropped the pilot's line entirely —
# constructed directly rather than via git merge-file, because every
# realistic base/current/new triple tried during triage produced real
# conflict markers instead of a silent drop (diff3 IS good at this in the
# cases actually tested). The guard must catch the outcome either way.
cat >"$TMP/merged-lossy.md" <<'EOF'
- **Obsidian:** поддерживаемый vault — отдельный governance-репозиторий `DS-strategy`.
EOF
out=$(detect_claude_silent_loss "$TMP/base.md" "$TMP/before.md" "$TMP/merged-lossy.md" 2>"$TMP/warnings.txt")
if [ "$out" = "1" ] && grep -qF "Без Obsidian" "$TMP/warnings.txt"; then
  pass "lossy merge detected: count=1, warning names the exact pilot line"
else
  fail "expected count=1 with a named warning, got count='$out', warnings: $(cat "$TMP/warnings.txt")"
fi

echo "--- clean merge that genuinely preserved the pilot line ---"
cat >"$TMP/merged-clean.md" <<'EOF'
- **Локальный контекст:** описание платформы.
- **Без Obsidian (DS-strategy):** просмотр через VS Code.
- **Комментарии кода:** только EN.
EOF
out=$(detect_claude_silent_loss "$TMP/base.md" "$TMP/before.md" "$TMP/merged-clean.md" 2>"$TMP/warnings-clean.txt")
if [ "$out" = "0" ] && [ ! -s "$TMP/warnings-clean.txt" ]; then
  pass "genuinely clean merge reports zero loss and stays silent"
else
  fail "expected count=0 with no warnings, got count='$out', warnings: $(cat "$TMP/warnings-clean.txt")"
fi

echo "--- pilot never customized the file (before == base) — nothing to lose ---"
cp "$TMP/base.md" "$TMP/before-unchanged.md"
out=$(detect_claude_silent_loss "$TMP/base.md" "$TMP/before-unchanged.md" "$TMP/merged-lossy.md" 2>"$TMP/warnings-unchanged.txt")
if [ "$out" = "0" ]; then
  pass "no pilot customization → nothing flagged even though merged differs from base"
else
  fail "expected count=0 (nothing pilot-authored to lose), got count='$out'"
fi

echo "issue-555 CLAUDE.md silent-loss guard: $pass_count checks passed"
