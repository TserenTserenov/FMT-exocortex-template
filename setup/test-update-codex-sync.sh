#!/bin/bash
# End-to-end regression: update.sh delivers Codex runtime without clobbering
# user-owned config and repairs a missing deployed skill on a no-change rerun.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
UPDATE_REAL="$(dirname "$SELF_DIR")/update.sh"
TEST_ROOT="${CODEX_UPDATE_WORKSPACE:-/tmp/iwe-codex-update-test-$$}"
FAKE_HOME="$TEST_ROOT/home"
PASS=0
FAIL=0

pass() { echo "  ✅ PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
cleanup() { local rc=$?; [ "${KEEP:-0}" = "1" ] || rm -rf "$TEST_ROOT"; exit "$rc"; }
trap cleanup EXIT INT TERM

UPSTREAM="$TEST_ROOT/upstream"
SCRIPT_DIR="$TEST_ROOT/workspace/FMT-exocortex-template"
WORKSPACE_DIR="$TEST_ROOT/workspace"
mkdir -p "$UPSTREAM/.claude/lib" "$UPSTREAM/.agents/skills/demo" "$UPSTREAM/.codex/hooks" \
         "$SCRIPT_DIR/.claude/lib" "$SCRIPT_DIR/.agents/skills/demo" "$SCRIPT_DIR/.codex/hooks" \
         "$WORKSPACE_DIR/.agents/skills/demo" "$WORKSPACE_DIR/.codex" "$FAKE_HOME"

cp "$UPDATE_REAL" "$SCRIPT_DIR/update.sh"
cp "$(dirname "$SELF_DIR")/.claude/lib/frontmatter.sh" "$SCRIPT_DIR/.claude/lib/frontmatter.sh"
cp "$SCRIPT_DIR/.claude/lib/frontmatter.sh" "$UPSTREAM/.claude/lib/frontmatter.sh"
chmod +x "$SCRIPT_DIR/update.sh"

cat > "$SCRIPT_DIR/CLAUDE.md" <<'EOF'
# Test instructions
EOF
cp "$SCRIPT_DIR/CLAUDE.md" "$UPSTREAM/CLAUDE.md"
cp "$SCRIPT_DIR/CLAUDE.md" "$SCRIPT_DIR/.claude.md.base"

cat > "$SCRIPT_DIR/AGENTS.md" <<'EOF'
# Agents old
EOF
cat > "$UPSTREAM/AGENTS.md" <<'EOF'
# Agents new
EOF
cat > "$WORKSPACE_DIR/AGENTS.md" <<'EOF'
# Agents old

<!-- USER-SPACE -->
Keep my local instruction.
<!-- /USER-SPACE -->
EOF

echo "skill old" > "$SCRIPT_DIR/.agents/skills/demo/SKILL.md"
echo "skill new" > "$UPSTREAM/.agents/skills/demo/SKILL.md"
echo "skill deployed old" > "$WORKSPACE_DIR/.agents/skills/demo/SKILL.md"
echo "hook old" > "$SCRIPT_DIR/.codex/hooks/guard.sh"
echo "hook new" > "$UPSTREAM/.codex/hooks/guard.sh"
echo 'model = "old-template"' > "$SCRIPT_DIR/.codex/config.toml"
echo 'model = "new-template"' > "$UPSTREAM/.codex/config.toml"
echo '{"hooks": ["old"]}' > "$SCRIPT_DIR/.codex/hooks.json"
echo '{"hooks": ["new"]}' > "$UPSTREAM/.codex/hooks.json"

# These workspace files are L4 and must survive even when template copies change.
echo 'model = "user-secret-profile"' > "$WORKSPACE_DIR/.codex/config.toml"
echo '{"hooks": ["user-local-hook"]}' > "$WORKSPACE_DIR/.codex/hooks.json"

python3 -c "
import json
paths = ['CLAUDE.md', 'AGENTS.md', '.claude/lib/frontmatter.sh',
         '.agents/skills/demo/SKILL.md', '.codex/hooks/guard.sh',
         '.codex/config.toml', '.codex/hooks.json']
json.dump({'version':'9.9.9-codex-test', 'files':[{'path':p} for p in paths]},
          open('$UPSTREAM/update-manifest.json','w'))
"

git -C "$SCRIPT_DIR" init -q
git -C "$SCRIPT_DIR" config user.email test@example.invalid
git -C "$SCRIPT_DIR" config user.name test
git -C "$SCRIPT_DIR" add -A
git -C "$SCRIPT_DIR" commit -q -m init
git -C "$SCRIPT_DIR" branch -M main

SHIM="$TEST_ROOT/shim"
mkdir -p "$SHIM"
cat > "$SHIM/curl" <<EOF
#!/bin/bash
url="" out=""
args=("\$@")
for ((i=0; i<\${#args[@]}; i++)); do
  case "\${args[i]}" in http*) url="\${args[i]}" ;; -o) out="\${args[i+1]}" ;; esac
done
rel="\${url#*/main/}"
if [ "\$rel" = update.sh ]; then cp "$SCRIPT_DIR/update.sh" "\$out"; else cp "$UPSTREAM/\$rel" "\$out"; fi
EOF
chmod +x "$SHIM/curl"

run_update() {
    PATH="$SHIM:$PATH" HOME="$FAKE_HOME" bash "$SCRIPT_DIR/update.sh" --yes > "$TEST_ROOT/update.log" 2>&1
}

if run_update; then pass "update.sh completed"; else fail "update.sh failed (see $TEST_ROOT/update.log)"; fi

grep -q "Agents new" "$WORKSPACE_DIR/AGENTS.md" && \
grep -q "Keep my local instruction" "$WORKSPACE_DIR/AGENTS.md" \
    && pass "AGENTS.md updated with USER-SPACE preserved" \
    || fail "AGENTS.md delivery lost platform or user content"
grep -q "skill new" "$WORKSPACE_DIR/.agents/skills/demo/SKILL.md" \
    && pass "Codex skill updated" || fail "Codex skill was not updated"
grep -q "hook new" "$WORKSPACE_DIR/.codex/hooks/guard.sh" \
    && pass "Codex platform hook updated" || fail "Codex platform hook was not updated"
grep -q "user-secret-profile" "$WORKSPACE_DIR/.codex/config.toml" \
    && pass "user config.toml preserved" || fail "user config.toml was overwritten"
grep -q "user-local-hook" "$WORKSPACE_DIR/.codex/hooks.json" \
    && pass "user hooks.json preserved" || fail "user hooks.json was overwritten"

# The local template now equals upstream. Removing only the deployed skill must
# exercise repair_pass on TOTAL_CHANGES=0.
rm -f "$WORKSPACE_DIR/.agents/skills/demo/SKILL.md"
if run_update && grep -q "skill new" "$WORKSPACE_DIR/.agents/skills/demo/SKILL.md"; then
    pass "missing Codex skill repaired on no-change rerun"
else
    fail "repair-pass did not restore missing Codex skill"
fi

echo "Codex update sync: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
