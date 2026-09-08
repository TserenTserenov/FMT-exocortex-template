#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Load only the guard under test; sourcing update.sh would execute the updater.
eval "$(awk '
  /^validate_no_install_values_in_applied_additions\(\)/ { capture=1 }
  capture { print }
  capture && /^}/ { exit }
' "$ROOT/update.sh")"
declare -F validate_no_install_values_in_applied_additions >/dev/null

SCRIPT_DIR="$TMP/template"
WORKSPACE_DIR="$TMP/workspace"
TMPDIR_UPDATE="$TMP/update-payload"
INTEGRITY_TAINTED=false
MANIFEST="$TMP/target-manifest.json"
PY_BIN=""
py_available() { return 1; }
UPSTREAM="$TMP/upstream.git"
mkdir -p "$SCRIPT_DIR" "$WORKSPACE_DIR" "$TMPDIR_UPDATE/files"
printf '%s\n' '{"files":[]}' > "$MANIFEST"
git init -q --bare "$UPSTREAM"
git -C "$SCRIPT_DIR" init -q
git -C "$SCRIPT_DIR" config user.email test@example.invalid
git -C "$SCRIPT_DIR" config user.name 'Install path guard test'
git -C "$SCRIPT_DIR" remote add origin "$UPSTREAM"

cat >"$WORKSPACE_DIR/.exocortex.env" <<EOF
WORKSPACE_DIR=$WORKSPACE_DIR
HOME_DIR=/root
USER_NAME=root
CLAUDE_PATH=/root/.claude
IWE_TEMPLATE=$SCRIPT_DIR
IWE_RUNTIME=$WORKSPACE_DIR/.iwe-runtime
EOF

# A target-release line that equals an install path is canonical and must not
# be blocked. The verified downloaded payload, not local branch history, is
# the provenance source (issue #524).
cat >"$SCRIPT_DIR/existing.md" <<'EOF'
The container user has HOME=/root and stores Claude config in /root/.claude.
EOF
git -C "$SCRIPT_DIR" add existing.md
git -C "$SCRIPT_DIR" commit -qm baseline
git -C "$SCRIPT_DIR" push -q origin HEAD:main
git -C "$SCRIPT_DIR" branch -q --set-upstream-to=origin/main 2>/dev/null ||
    git -C "$SCRIPT_DIR" branch -q -u origin/main
printf 'Safe update line.\n' >>"$SCRIPT_DIR/existing.md"
cp "$SCRIPT_DIR/existing.md" "$TMPDIR_UPDATE/files/existing.md"
APPLIED_PATHS=(existing.md)
validate_no_install_values_in_applied_additions

# A value newly introduced by the updater must still block the commit.
printf 'Leaked workspace: %s\n' "$WORKSPACE_DIR" >"$SCRIPT_DIR/leak.md"
APPLIED_PATHS=(existing.md)
validate_no_install_values_in_applied_additions

# Once the leaking path belongs to this updater run, the guard must reject it.
APPLIED_PATHS=(existing.md leak.md)
if validate_no_install_values_in_applied_additions 2>"$TMP/guard.err"; then
    echo 'guard accepted a newly added install value' >&2
    exit 1
fi
grep -Fq 'install-value WORKSPACE_DIR' "$TMP/guard.err"
grep -Fq 'leak.md' "$TMP/guard.err"
if grep -Fq -- "$WORKSPACE_DIR" "$TMP/guard.err"; then
    echo 'guard disclosed the install value in diagnostics' >&2
    exit 1
fi

# Content beginning with "++ " appears as "+++ " in a patch. It must not be
# mistaken for the file header; a spaced filename also exercises path handling.
printf '++ %s/no-newline' "$WORKSPACE_DIR" >"$SCRIPT_DIR/prefix leak.md"
APPLIED_PATHS=(leak.md 'prefix leak.md')
if validate_no_install_values_in_applied_additions 2>"$TMP/prefix-guard.err"; then
    echo 'guard accepted header-like content containing an install value' >&2
    exit 1
fi
grep -Fq 'leak.md' "$TMP/prefix-guard.err"
grep -Fq 'prefix leak.md' "$TMP/prefix-guard.err"
if grep -Fq -- "$WORKSPACE_DIR" "$TMP/prefix-guard.err"; then
    echo 'guard disclosed the header-like install value in diagnostics' >&2
    exit 1
fi

# Deleting a leaked value makes the tree safer and must not be rejected.
git -C "$SCRIPT_DIR" checkout -q -- .
printf 'legacy %s\nkeep\n' "$WORKSPACE_DIR" >"$SCRIPT_DIR/remove-leak.md"
git -C "$SCRIPT_DIR" add remove-leak.md
git -C "$SCRIPT_DIR" commit -qm 'add legacy fixture'
grep -v 'legacy' "$SCRIPT_DIR/remove-leak.md" >"$TMP/cleaned"
mv "$TMP/cleaned" "$SCRIPT_DIR/remove-leak.md"
APPLIED_PATHS=(remove-leak.md)
validate_no_install_values_in_applied_additions

# A safe manifest-only update is accepted and does not need staging.
printf '{"version":"0.0.1"}\n' >"$SCRIPT_DIR/update-manifest.json"
APPLIED_PATHS=(update-manifest.json)
validate_no_install_values_in_applied_additions

# Ignored unrelated files are outside APPLIED_PATHS and cannot poison the guard.
printf 'ignored.md\n' >"$SCRIPT_DIR/.gitignore"
printf 'Leaked workspace: %s\n' "$WORKSPACE_DIR" >"$SCRIPT_DIR/ignored.md"
APPLIED_PATHS=(update-manifest.json)
validate_no_install_values_in_applied_additions

# issue #397: CLAUDE_PATH defaults to a bare command name ("claude"), not a path.
# The word "claude" legitimately appears in unrelated delivered content (comments,
# claude-peer-adapter.sh mentions, etc.) — the guard must not treat a bare command
# name as a leaked install value, only genuine paths (containing "/").
git -C "$SCRIPT_DIR" checkout -q -- . 2>/dev/null || true
git -C "$SCRIPT_DIR" clean -qfd 2>/dev/null || true
cat >"$WORKSPACE_DIR/.exocortex.env" <<EOF
WORKSPACE_DIR=$WORKSPACE_DIR
HOME_DIR=/root
USER_NAME=root
CLAUDE_PATH=claude
IWE_TEMPLATE=$SCRIPT_DIR
IWE_RUNTIME=$WORKSPACE_DIR/.iwe-runtime
EOF
printf 'See scripts/claude-peer-adapter.sh for the Claude peer contract.\n' >"$SCRIPT_DIR/bare-claude.md"
APPLIED_PATHS=(bare-claude.md)
validate_no_install_values_in_applied_additions

echo 'PASS: install-path guard accepts only exact lines from verified update targets'
