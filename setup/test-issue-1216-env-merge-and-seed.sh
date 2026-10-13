#!/usr/bin/env bash
# issue #1216: Claude Code only grants TodoWrite/TaskCreate/... to models newer
# than Sonnet 4.6 when CLAUDE_CODE_ENABLE_TODO_TOOLS=1 is set in settings.json's
# "env" block. The skills that depend on those tools called the gap a "normal,
# depends on client build" situation instead of naming the actual cause.
# Two parts fixed:
#   1. The shipped .claude/settings.json now carries the env var (benefits a
#      fresh seed).
#   2. settings-merge-preview.py's merge_settings() used to treat "env" as an
#      opaque whole-object key: any workspace env dict not byte-identical to
#      the template's (the common case -- a workspace routinely has its own
#      unrelated env keys) was flagged as a single "env" conflict instead of
#      adding just the missing key, so an existing install's settings merge
#      would never pick up the new var without a manual resolution. merge_env()
#      now merges per-key, same semantics as the existing merge_permissions().
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERGER="$ROOT/.claude/scripts/settings-merge-preview.py"
SETTINGS="$ROOT/.claude/settings.json"

fail=0
pass() { echo "  ✅ PASS: $*"; }
fail_test() { echo "  ❌ FAIL: $*" >&2; fail=1; }

python3 -c "
import json
d = json.load(open('$SETTINGS'))
assert d.get('env', {}).get('CLAUDE_CODE_ENABLE_TODO_TOOLS') == '1', d.get('env')
" 2>/dev/null && pass "shipped settings.json carries CLAUDE_CODE_ENABLE_TODO_TOOLS=1" \
  || fail_test "shipped settings.json missing CLAUDE_CODE_ENABLE_TODO_TOOLS=1"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/iwe-1216-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

# Workspace env dict has its own unrelated key, no overlap with the template's.
cat > "$TEST_ROOT/workspace-no-overlap.json" <<'EOF'
{"permissions": {"defaultMode": "default", "allow": []}, "hooks": {}, "env": {"SOME_OTHER_VAR": "x"}}
EOF
cat > "$TEST_ROOT/template.json" <<'EOF'
{"permissions": {"defaultMode": "default", "allow": []}, "hooks": {}, "env": {"CLAUDE_CODE_ENABLE_TODO_TOOLS": "1"}}
EOF
python3 "$MERGER" "$TEST_ROOT/template.json" "$TEST_ROOT/workspace-no-overlap.json" "$TEST_ROOT/preview1.json" >/tmp/iwe-1216-report1.json
python3 -c "
import json
d = json.load(open('$TEST_ROOT/preview1.json'))
assert d['env'] == {'SOME_OTHER_VAR': 'x', 'CLAUDE_CODE_ENABLE_TODO_TOOLS': '1'}, d['env']
report = json.load(open('/tmp/iwe-1216-report1.json'))
assert report['conflicts'] == [], report['conflicts']
" 2>/dev/null && pass "missing env key is added without flagging the whole env dict as a conflict" \
  || fail_test "merge did not add CLAUDE_CODE_ENABLE_TODO_TOOLS or raised a spurious conflict"

# Workspace already set the SAME key to a DIFFERENT value: must be flagged, not
# silently overwritten (same policy as merge_permissions for a differing key).
cat > "$TEST_ROOT/workspace-conflict.json" <<'EOF'
{"permissions": {"defaultMode": "default", "allow": []}, "hooks": {}, "env": {"CLAUDE_CODE_ENABLE_TODO_TOOLS": "0"}}
EOF
python3 "$MERGER" "$TEST_ROOT/template.json" "$TEST_ROOT/workspace-conflict.json" "$TEST_ROOT/preview2.json" >/tmp/iwe-1216-report2.json
python3 -c "
import json
d = json.load(open('$TEST_ROOT/preview2.json'))
assert d['env']['CLAUDE_CODE_ENABLE_TODO_TOOLS'] == '0', d['env']
report = json.load(open('/tmp/iwe-1216-report2.json'))
assert 'env.CLAUDE_CODE_ENABLE_TODO_TOOLS' in report['conflicts'], report['conflicts']
" 2>/dev/null && pass "user's deliberately different env value is kept and the differing key is flagged" \
  || fail_test "conflicting env key was overwritten or not flagged"
rm -f /tmp/iwe-1216-report1.json /tmp/iwe-1216-report2.json

exit "$fail"
