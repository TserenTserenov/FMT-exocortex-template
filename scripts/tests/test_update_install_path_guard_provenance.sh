#!/usr/bin/env bash
set -euo pipefail

# issue #524: a target release may introduce a brand-new canonical line that
# happens to equal this installation's path. Provenance must come from the
# manifest-verified target payload, not an older installation fork's history.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

eval "$(awk '
  /^validate_no_install_values_in_applied_additions\(\)/ { capture=1 }
  capture { print }
  capture && /^}/ { exit }
' "$ROOT/update.sh")"
declare -F validate_no_install_values_in_applied_additions >/dev/null

SCRIPT_DIR="$TMP/template"
WORKSPACE_DIR="$TMP/workspace"
TMPDIR_UPDATE="$TMP/target-release"
INTEGRITY_TAINTED=false
mkdir -p "$WORKSPACE_DIR" "$SCRIPT_DIR/docs" "$TMPDIR_UPDATE/files/docs"

cat >"$WORKSPACE_DIR/.exocortex.env" <<EOF
WORKSPACE_DIR=$WORKSPACE_DIR
HOME_DIR=/root
USER_NAME=root
CLAUDE_PATH=/synthetic-test-root/bin/claude
IWE_TEMPLATE=$SCRIPT_DIR
IWE_RUNTIME=$WORKSPACE_DIR/.iwe-runtime
EOF

# The target release introduces this line for the first time. The installed
# fork has no history that could legitimize it; the exact verified target file
# is sufficient provenance.
cat >"$TMPDIR_UPDATE/files/docs/example.md" <<'EOF'
# Example config
A common Claude install path is /synthetic-test-root/bin/claude on a synthetic test machine.
Keep this line stable across releases.
EOF
cp "$TMPDIR_UPDATE/files/docs/example.md" "$SCRIPT_DIR/docs/example.md"
APPLIED_PATHS=(docs/example.md)
if ! validate_no_install_values_in_applied_additions 2>"$TMP/coincidence.err"; then
    echo 'guard rejected a canonical line present verbatim in the verified target release' >&2
    cat "$TMP/coincidence.err" >&2
    exit 1
fi

# An extra byte-identical copy is still local content. Set membership alone
# cannot prove it: target has one occurrence, applied has two.
grep -F '/synthetic-test-root/bin/claude' \
    "$TMPDIR_UPDATE/files/docs/example.md" >> "$SCRIPT_DIR/docs/example.md"
APPLIED_PATHS=(docs/example.md)
if validate_no_install_values_in_applied_additions 2>"$TMP/duplicate.err"; then
    echo 'guard accepted an extra duplicate of a canonical target line' >&2
    exit 1
fi
grep -Fq 'CLAUDE_PATH' "$TMP/duplicate.err"
cp "$TMPDIR_UPDATE/files/docs/example.md" "$SCRIPT_DIR/docs/example.md"

# Negative control: a locally introduced line absent from that exact target
# file must still be blocked.
cat >>"$SCRIPT_DIR/docs/example.md" <<'EOF'
Debug note: my personal claude binary lives at /synthetic-test-root/bin/claude.
EOF
APPLIED_PATHS=(docs/example.md)
if validate_no_install_values_in_applied_additions 2>"$TMP/leak.err"; then
    echo 'guard accepted a genuinely new line containing a leaked install value' >&2
    exit 1
fi
grep -Fq 'CLAUDE_PATH' "$TMP/leak.err"

# Cross-file check: another target file cannot establish provenance.
cat >"$SCRIPT_DIR/docs/other-file.md" <<'EOF'
A common Claude install path is /synthetic-test-root/bin/claude on a synthetic test machine.
EOF
printf 'Safe target content.\n' >"$TMPDIR_UPDATE/files/docs/other-file.md"
APPLIED_PATHS=(docs/other-file.md)
if validate_no_install_values_in_applied_additions 2>"$TMP/crossfile.err"; then
    echo 'guard incorrectly treated another file historical line as provenance for a new file' >&2
    exit 1
fi

# Fail-closed check: missing target bytes cannot establish provenance.
rm -f "$TMPDIR_UPDATE/files/docs/example.md"
APPLIED_PATHS=(docs/example.md)
if validate_no_install_values_in_applied_additions 2>"$TMP/notarget.err"; then
    echo 'guard silently bypassed protection when target bytes are unavailable' >&2
    exit 1
fi

# Tainted/unverified downloads also cannot establish provenance even when the
# bytes happen to match.
cp "$SCRIPT_DIR/docs/example.md" "$TMPDIR_UPDATE/files/docs/example.md"
INTEGRITY_TAINTED=true
if validate_no_install_values_in_applied_additions 2>"$TMP/tainted.err"; then
    echo 'guard accepted target bytes that had no manifest-integrity proof' >&2
    exit 1
fi
INTEGRITY_TAINTED=false

# A fully committed local leak is still caught because the guard scans the
# current bytes of every APPLIED_PATHS entry, not only working-tree diffs.
git init -q "$SCRIPT_DIR"
git -C "$SCRIPT_DIR" config user.email test@example.invalid
git -C "$SCRIPT_DIR" config user.name 'Provenance guard test'
cat >"$SCRIPT_DIR/docs/committed-leak.md" <<'EOF'
This file was fully committed with a leaked path already inside it:
/synthetic-test-root/bin/claude — absent from the target release.
EOF
git -C "$SCRIPT_DIR" add docs/committed-leak.md
git -C "$SCRIPT_DIR" commit -qm 'accidentally committed a leak before update.sh ran the guard'
printf 'Safe target content.\n' >"$TMPDIR_UPDATE/files/docs/committed-leak.md"
APPLIED_PATHS=(docs/committed-leak.md)
if validate_no_install_values_in_applied_additions 2>"$TMP/committed-leak.err"; then
    echo 'guard accepted a fully-committed leak with zero working-tree diff (the Critical review finding)' >&2
    exit 1
fi
grep -Fq 'CLAUDE_PATH' "$TMP/committed-leak.err"

echo 'PASS: install-path guard trusts only exact manifest-verified target bytes'
