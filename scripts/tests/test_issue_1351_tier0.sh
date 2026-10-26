#!/usr/bin/env bash
# test_issue_1351_tier0.sh — iwe-backup-check: only the workspace is a
# mandatory tier0 source (issue #1351). Sources of agents that are not
# installed (Codex config, git-credentials store) must not raise a critical;
# an override entry with the same path replaces the default one; the
# workspace is resolved from --root, not from a literal ~/IWE.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK="$ROOT/scripts/iwe-backup-check.sh"

FAIL=0
pass() { echo "  ✅ PASS: $*"; }
fail() { echo "  ❌ FAIL: $*"; FAIL=$((FAIL + 1)); }

# The check runs under a fake HOME; keep the real user site-packages visible
# so a `pip install --user` PyYAML is still importable (same trap as #1342).
PYTHONUSERBASE="${PYTHONUSERBASE:-$(python3 -m site --user-base 2>/dev/null)}"
export PYTHONUSERBASE

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAKE_HOME="$TMP/home"
WS="$TMP/notes"            # deliberately not $HOME/IWE (#1336 layout)
mkdir -p "$FAKE_HOME" "$WS/DS-strategy"

run_check() {
    HOME="$FAKE_HOME" bash "$CHECK" --root "$WS" --no-icloud > "$TMP/out" 2>&1
}

run_check
if grep -q 'tier0 (невосстановимые данные) не найдено' "$TMP/out"; then
    fail "missing optional tier0 sources raised a critical: $(grep 'tier0' "$TMP/out" | tail -1)"
else
    pass "missing Codex config / git-credentials / Claude paths are not critical"
fi
if grep -qF "| tier0_unique | \`$(cd "$WS" && pwd -P)\` | есть |" "$TMP/out"; then
    pass "the workspace row is resolved from --root, not from ~/IWE"
else
    fail "the workspace row does not point to --root"
fi

cat > "$FAKE_HOME/.iwe-backup-sources.local.yaml" <<'EOF'
tier0_unique:
  - path: "${HOME}/.codex/config.toml"
    optional: false
    note: "user says Codex is installed here"
EOF
run_check
if grep -q '1 обязательный(х) источник(а) уровня tier0' "$TMP/out" && \
   [ "$(grep -c '\.codex/config\.toml' "$TMP/out")" -eq 1 ]; then
    pass "an override with the same path replaces the default entry (one row, now mandatory)"
else
    fail "override did not replace the default .codex/config.toml entry"
fi

cat > "$FAKE_HOME/.iwe-backup-sources.local.yaml" <<'EOF'
tier0_unique:
  - path: "${WORKSPACE_DIR}"
    optional: true
  - path: "${HOME}/must-exist"
EOF
run_check
if grep -q 'НЕ НАЙДЕНО (обязательный)' "$TMP/out" && grep -q 'must-exist' "$TMP/out"; then
    pass "an override source without optional stays mandatory"
else
    fail "a mandatory override source is not reported as missing"
fi
WS_ROW=$(grep -F "| tier0_unique | \`$(cd "$WS" && pwd -P)\` |" "$TMP/out" || true)
if [ "$(printf '%s\n' "$WS_ROW" | grep -c .)" -eq 1 ]; then
    pass "override of the workspace entry keeps a single workspace row"
else
    fail "workspace entry duplicated or lost after override"
fi

# iwe-backup-run.sh reads the same file: ${WORKSPACE_DIR} must expand there
# too, or the workspace silently drops out of the restic snapshot. A fake
# restic records the backup arguments.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/restic" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    backup) printf '%s\n' "$@" > "$RESTIC_ARGS_LOG"
            echo '{"message_type":"summary","snapshot_id":"fake123"}' ;;
esac
exit 0
EOF
chmod +x "$TMP/bin/restic"
cat > "$FAKE_HOME/.iwe-backup-sources.local.yaml" <<'EOF'
tier1_scheduled:
EOF
RUN_RC=0
HOME="$FAKE_HOME" IWE_ROOT="$WS" PATH="$TMP/bin:$PATH" RESTIC_ARGS_LOG="$TMP/restic.args" \
    bash "$ROOT/scripts/iwe-backup-run.sh" > "$TMP/run.out" 2>&1 || RUN_RC=$?
if [ "$RUN_RC" -eq 0 ] && grep -qxF "$WS" "$TMP/restic.args" 2>/dev/null; then
    pass "backup-run snapshots the --root workspace and tolerates an empty override tier"
else
    fail "backup-run did not pass the workspace to restic (rc=$RUN_RC): $(tail -3 "$TMP/run.out" | tr '\n' ' ')"
fi

[ "$FAIL" -eq 0 ] && echo "PASS: issue #1351 tier0 optional sources" || { echo "FAIL: issue #1351 has $FAIL violation(s)"; exit 1; }
