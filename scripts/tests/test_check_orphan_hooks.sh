#!/usr/bin/env bash
# Regression test for check-orphan-hooks.sh (issues #310, #323):
# both recognition paths must work — the `claude-hook: false` header marker
# (libraries/CLIs that are not hooks by contract) and the .orphan-allowlist
# (real hooks deliberately left unregistered). A genuine orphan must still fail.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/../check-orphan-hooks.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

FAILED=0
fail() { echo "FAIL: $1"; FAILED=$((FAILED + 1)); }

mkdir -p "$TMP/.claude/hooks"

cat > "$TMP/.claude/settings.json" <<'EOF'
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"$CLAUDE_PROJECT_DIR/.claude/hooks/hook-connected.sh"}]}]}}
EOF

cat > "$TMP/.claude/hooks/hook-connected.sh" <<'EOF'
#!/bin/bash
bash "$(dirname "$0")/hook-transitive.sh"
EOF

cat > "$TMP/.claude/hooks/hook-transitive.sh" <<'EOF'
#!/bin/bash
exit 0
EOF

cat > "$TMP/.claude/hooks/hook-library.sh" <<'EOF'
#!/bin/bash
# claude-hook: false — test library, must be recognized by the header marker
exit 0
EOF

# Marker below the head -3 contract boundary must NOT count as a library —
# such a file stays an orphan (guards against burying the marker deep in a file).
cat > "$TMP/.claude/hooks/hook-late-marker.sh" <<'EOF'
#!/bin/bash
# just a comment
# another comment
# claude-hook: false — too late, line 4 is outside the contract
exit 0
EOF

cat > "$TMP/.claude/hooks/hook-allowed.sh" <<'EOF'
#!/bin/bash
exit 0
EOF

echo "hook-allowed.sh  # deliberately unregistered (test)" > "$TMP/.claude/hooks/.orphan-allowlist"

# --- Run 1: the late-marker file is present, so the guard must fail on it,
#     while marker and allowlist recognition keep working ---
OUT=$(bash "$GUARD" "$TMP" 2>&1)
RC=$?
[ "$RC" -eq 1 ] || fail "run 1 expected exit 1 (late marker = orphan), got $RC ($OUT)"
echo "$OUT" | grep -q "LIBRARY: hook-library.sh" || fail "run 1: header marker not recognized"
echo "$OUT" | grep -q "ALLOWED: hook-allowed.sh" || fail "run 1: allowlist entry not recognized"
echo "$OUT" | grep -q "FAIL: hook-late-marker.sh" || fail "run 1: marker on line 4 must NOT count (head -3 contract)"

# --- Run 2: with the late-marker file removed, everything is accounted for -> PASS ---
rm "$TMP/.claude/hooks/hook-late-marker.sh"
OUT=$(bash "$GUARD" "$TMP" 2>&1)
RC=$?
[ "$RC" -eq 0 ] || fail "run 2 expected exit 0, got $RC ($OUT)"
echo "$OUT" | grep -q "^PASS:" || fail "run 2: no PASS summary"

# --- Run 3: a genuine orphan must still fail ---
cat > "$TMP/.claude/hooks/hook-orphan.sh" <<'EOF'
#!/bin/bash
exit 0
EOF

OUT=$(bash "$GUARD" "$TMP" 2>&1)
RC=$?
[ "$RC" -eq 1 ] || fail "run 3 expected exit 1, got $RC ($OUT)"
echo "$OUT" | grep -q "FAIL: hook-orphan.sh" || fail "run 3: orphan not reported"
echo "$OUT" | grep -q "LIBRARY: hook-library.sh" || fail "run 3: marker recognition lost when an orphan exists"

if [ "$FAILED" -eq 0 ]; then
    echo "OK: check-orphan-hooks recognizes marker + allowlist and still fails a real orphan"
    exit 0
fi
exit 1
