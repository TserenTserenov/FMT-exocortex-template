#!/usr/bin/env bash
# Regression coverage for issue #1010 (two update.sh fixes), end to end.
#
# Runs the REAL update.sh against a sandboxed SCRIPT_DIR/WORKSPACE_DIR with a
# curl shim serving fixture "upstream" files and a fixture manifest — same
# harness approach as setup/test-update-issue-226.sh (copied, not sourced:
# that file runs its scenarios on load).
#
# F10: a .claude/skills/*/SKILL.md carrying a <!-- USER-SPACE --> block was
#      reported as "updated" on every run — the change detector compared the
#      raw local hash (with the user block) to the upstream hash.
#   F10-a: two runs against the same upstream → second run does not list the
#          skill as updated, file bytes unchanged, user block intact.
#   F10-b: upstream body changes → next run updates it once, new body lands,
#          user block intact.
# F9:  a deprecated_files path still tracked by git in the local template
#      clone was deleted, leaving a tracked deletion behind. It must now stay
#      (with an "отслеживаются git" line); an UNtracked deprecated file is
#      still removed (control).
#
# Usage: bash scripts/tests/test_issue_1010_update_idem.sh   (KEEP=1 keeps the sandbox)

set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
UPDATE_SH_REAL="$REPO_ROOT/update.sh"

# HOME is swapped for every update.sh run below; pin the real user site so a
# `pip install --user` PyYAML stays importable (issue #1342, same trick as
# test_issue_536_day_close_backup.sh).
PYTHONUSERBASE="${PYTHONUSERBASE:-$(python3 -m site --user-base 2>/dev/null)}"
export PYTHONUSERBASE

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "  ✅ PASS: $*"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "  ❌ FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/iwe-issue-1010.XXXXXX")"
cleanup() { [ "${KEEP:-0}" = "1" ] && echo "sandbox kept: $TEST_ROOT" || rm -rf "$TEST_ROOT"; }
trap cleanup EXIT

FAKE_HOME="$TEST_ROOT/fake-home"
UPSTREAM="$TEST_ROOT/upstream"
WORKSPACE_DIR="$TEST_ROOT/repo"
SCRIPT_DIR="$WORKSPACE_DIR/FMT-exocortex-template"
SHIM_DIR="$TEST_ROOT/shim"
SKILL=".claude/skills/demo/SKILL.md"
DEP_TRACKED="scripts/tests/old_test.sh"
DEP_UNTRACKED="scripts/tests/old_untracked.sh"
DEP_SKILL=".claude/skills/oldskill/SKILL.md"
mkdir -p "$FAKE_HOME" "$UPSTREAM/.claude/skills/demo" "$SHIM_DIR"

# ------------------------------------------------------------------
# Fixture: upstream tree + manifest
# ------------------------------------------------------------------
write_upstream_skill() {
    # $1 = body line that distinguishes upstream versions
    cat > "$UPSTREAM/$SKILL" <<EOF
---
name: demo
description: Demo skill for issue 1010
---

# Demo skill

$1

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
EOF
}

write_manifest() {
    # $1 = manifest version
    python3 - "$UPSTREAM" "$1" "$SKILL" "$DEP_TRACKED" "$DEP_UNTRACKED" "$DEP_SKILL" <<'PY'
import hashlib, json, sys
from pathlib import Path
root, version, skill, dep_tracked, dep_untracked, dep_skill = sys.argv[1:7]
root = Path(root)
manifest = {
    "schema_version": 2,
    "version": version,
    "files": [{"path": skill, "sha256": hashlib.sha256((root / skill).read_bytes()).hexdigest()}],
    "deprecated_files": [
        {"path": dep_tracked, "reason": "test: replaced"},
        {"path": dep_untracked, "reason": "test: replaced"},
        {"path": dep_skill, "reason": "test: replaced"},
    ],
}
(root / "update-manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
PY
}

write_upstream_skill "Upstream body v1."
write_manifest "0.99.0-test-1010a"

# ------------------------------------------------------------------
# Fixture: SCRIPT_DIR (local template clone, a git repo) + workspace
# ------------------------------------------------------------------
mkdir -p "$SCRIPT_DIR/.claude/lib" "$SCRIPT_DIR/scripts/lib" "$SCRIPT_DIR/scripts/tests" \
    "$SCRIPT_DIR/.claude/skills/demo"
cp "$UPDATE_SH_REAL" "$SCRIPT_DIR/update.sh"
chmod +x "$SCRIPT_DIR/update.sh"
cp "$REPO_ROOT/.claude/lib/frontmatter.sh" "$SCRIPT_DIR/.claude/lib/frontmatter.sh"
cp "$REPO_ROOT/scripts/lib/common.sh" "$SCRIPT_DIR/scripts/lib/common.sh"
printf 'GOVERNANCE_REPO="pilot-governance"\n' > "$WORKSPACE_DIR/.exocortex.env"
# update.sh refuses to run without CLAUDE.md at the template root; not in the
# fixture manifest, so no run touches it.
printf '# Template CLAUDE.md\n' > "$SCRIPT_DIR/CLAUDE.md"

USER_BLOCK='<!-- USER-SPACE -->
## Мои правила
- pilot rule: always answer in haiku
<!-- /USER-SPACE -->'
printf '%s\n' "$USER_BLOCK" > "$TEST_ROOT/user-block.expected"

# Local SKILL.md = upstream with the shipped empty block replaced by the
# user's block — exactly what a previous update.sh run would have written.
python3 - "$UPSTREAM/$SKILL" "$SCRIPT_DIR/$SKILL" "$TEST_ROOT/user-block.expected" <<'PY'
import re, sys
src, dst, block = sys.argv[1:4]
text = open(src, encoding="utf-8").read()
text = re.sub(r"^<!-- USER-SPACE -->.*?^<!-- /USER-SPACE -->", "", text, flags=re.S | re.M)
text = text.rstrip("\n") + "\n"
open(dst, "w", encoding="utf-8").write(text + "\n" + open(block, encoding="utf-8").read())
PY
cp "$SCRIPT_DIR/$SKILL" "$TEST_ROOT/skill.initial"

printf '#!/usr/bin/env bash\necho old tracked test\n' > "$SCRIPT_DIR/$DEP_TRACKED"
mkdir -p "$SCRIPT_DIR/$(dirname "$DEP_SKILL")" "$WORKSPACE_DIR/$(dirname "$DEP_SKILL")"
printf -- '---\nname: oldskill\n---\nold\n' > "$SCRIPT_DIR/$DEP_SKILL"
cp "$SCRIPT_DIR/$DEP_SKILL" "$WORKSPACE_DIR/$DEP_SKILL"
git -C "$SCRIPT_DIR" init -q
git -C "$SCRIPT_DIR" config user.email t@t
git -C "$SCRIPT_DIR" config user.name t
git -C "$SCRIPT_DIR" add -A
git -C "$SCRIPT_DIR" commit -q -m init
# Untracked deprecated file appears after the commit (control for F9).
printf '#!/usr/bin/env bash\necho old untracked test\n' > "$SCRIPT_DIR/$DEP_UNTRACKED"

# ------------------------------------------------------------------
# curl shim (single-file -o mode, --help all probe, -K batch mode)
# ------------------------------------------------------------------
cat > "$SHIM_DIR/curl" <<SHIMEOF
#!/usr/bin/env bash
simulate_one_transfer() {
    local u="\$1" o="\$2"
    local rel="\${u#*/main/}"
    if [ "\$rel" = "update.sh" ]; then
        cp "$SCRIPT_DIR/update.sh" "\$o"
    else
        local src="$UPSTREAM/\$rel"
        [ -f "\$src" ] && cp "\$src" "\$o" || { echo "curl: (22) The requested URL returned error: 404" >&2; return 22; }
    fi
}
if [ "\${1:-}" = "--help" ] && [ "\${2:-}" = "all" ]; then
    printf -- '  --parallel \\n  --parallel-max <num>\\n  --remove-on-error \\n'
    exit 0
fi
url="" out="" cfgfile=""
args=("\$@")
for ((i=0; i<\${#args[@]}; i++)); do
    case "\${args[i]}" in
        http*) url="\${args[i]}" ;;
        -o) out="\${args[i+1]}" ;;
        -K) cfgfile="\${args[i+1]}" ;;
    esac
done
if [ -n "\$cfgfile" ]; then
    had_error=0 pending_url=""
    while IFS= read -r line || [ -n "\$line" ]; do
        case "\$line" in
            'url = '*) pending_url=\$(printf '%s' "\$line" | sed -e 's/^url = "//' -e 's/"\$//') ;;
            'output = '*)
                pending_out=\$(printf '%s' "\$line" | sed -e 's/^output = "//' -e 's/"\$//')
                simulate_one_transfer "\$pending_url" "\$pending_out" || had_error=1
                pending_url="" ;;
        esac
    done < "\$cfgfile"
    exit "\$had_error"
fi
simulate_one_transfer "\$url" "\$out"
SHIMEOF
chmod +x "$SHIM_DIR/curl"

run_update() {
    # $1 = log name; prints update.sh's exit code
    local rc
    PATH="$SHIM_DIR:$PATH" HOME="$FAKE_HOME" IWE_UPDATE_CHANNEL=main \
        bash "$SCRIPT_DIR/update.sh" --yes > "$TEST_ROOT/$1.log" 2>&1
    rc=$?
    echo "$rc"
}

# Lines update.sh prints for an updated file: the preview "  ~ <path>  — N строк"
# and the apply step "  ~ <path> (USER-SPACE preserved)".
skill_listed_updated() { grep -Eq "^  ~ ${SKILL//./\\.}( |$)" "$1"; }
user_block_of() { sed -n '/^<!-- USER-SPACE -->/,/^<!-- \/USER-SPACE -->/p' "$1"; }

# ------------------------------------------------------------------
# Run 1 + F9 assertions
# ------------------------------------------------------------------
echo "--- Run 1 (F9: deprecated paths) ---"
RC1=$(run_update run1)
[ "$RC1" -eq 0 ] && pass "run 1: update.sh exit 0" || fail "run 1: update.sh exit $RC1 (log: $(tail -5 "$TEST_ROOT/run1.log"))"

if [ -f "$SCRIPT_DIR/$DEP_TRACKED" ]; then
    pass "F9: git-tracked deprecated file kept in the template clone"
else
    fail "F9: git-tracked deprecated file was deleted"
fi
if git -C "$SCRIPT_DIR" status --porcelain -- "$DEP_TRACKED" | grep -q 'D'; then
    fail "F9: clone shows a tracked deletion of $DEP_TRACKED: $(git -C "$SCRIPT_DIR" status --porcelain -- "$DEP_TRACKED")"
else
    pass "F9: git status shows no deletion of $DEP_TRACKED"
fi
if grep -F "отслеживаются git" "$TEST_ROOT/run1.log" | grep -Fq "$DEP_TRACKED"; then
    pass "F9: output reports the kept tracked deprecated file"
else
    fail "F9: no 'отслеживаются git' line naming $DEP_TRACKED in output"
fi
if [ ! -e "$SCRIPT_DIR/$DEP_UNTRACKED" ]; then
    pass "F9 control: untracked deprecated file still removed"
else
    fail "F9 control: untracked deprecated file was not removed"
fi
if [ -f "$SCRIPT_DIR/$DEP_SKILL" ] && [ ! -e "$WORKSPACE_DIR/$DEP_SKILL" ]; then
    pass "F9: tracked deprecated skill kept in the clone, its workspace copy removed"
else
    fail "F9: deprecated skill: clone copy present=$([ -f "$SCRIPT_DIR/$DEP_SKILL" ] && echo y || echo n), workspace copy present=$([ -e "$WORKSPACE_DIR/$DEP_SKILL" ] && echo y || echo n)"
fi
if grep -F "отслеживаются git" "$TEST_ROOT/run1.log" | grep -Fq "$DEP_UNTRACKED"; then
    fail "F9 control: untracked file wrongly reported as git-tracked"
else
    pass "F9 control: untracked file not reported as git-tracked"
fi
cp "$SCRIPT_DIR/$SKILL" "$TEST_ROOT/skill.after1"

# ------------------------------------------------------------------
# Run 2 (same upstream) — F10-a idempotence
# ------------------------------------------------------------------
echo "--- Run 2 (F10-a: same upstream, USER-SPACE skill) ---"
RC2=$(run_update run2)
[ "$RC2" -eq 0 ] && pass "run 2: update.sh exit 0" || fail "run 2: update.sh exit $RC2"

if skill_listed_updated "$TEST_ROOT/run2.log"; then
    fail "F10-a: unchanged-upstream SKILL.md listed as updated on the second run: $(grep -F "$SKILL" "$TEST_ROOT/run2.log" | head -3)"
else
    pass "F10-a: second run does not list SKILL.md as updated"
fi
if cmp -s "$TEST_ROOT/skill.after1" "$SCRIPT_DIR/$SKILL" && cmp -s "$TEST_ROOT/skill.initial" "$SCRIPT_DIR/$SKILL"; then
    pass "F10-a: SKILL.md bytes unchanged across both runs"
else
    fail "F10-a: SKILL.md bytes changed between runs"
fi
if user_block_of "$SCRIPT_DIR/$SKILL" | cmp -s - "$TEST_ROOT/user-block.expected"; then
    pass "F10-a: user block survives byte-for-byte"
else
    fail "F10-a: user block changed: $(user_block_of "$SCRIPT_DIR/$SKILL")"
fi

# ------------------------------------------------------------------
# Run 3 (upstream body changed) — F10-b
# ------------------------------------------------------------------
echo "--- Run 3 (F10-b: upstream body changed) ---"
write_upstream_skill "Upstream body v2 — new instructions."
write_manifest "0.99.1-test-1010b"
RC3=$(run_update run3)
[ "$RC3" -eq 0 ] && pass "run 3: update.sh exit 0" || fail "run 3: update.sh exit $RC3"

if skill_listed_updated "$TEST_ROOT/run3.log"; then
    pass "F10-b: changed-upstream SKILL.md listed as updated"
else
    fail "F10-b: changed-upstream SKILL.md not listed as updated"
fi
if grep -Fq "Upstream body v2 — new instructions." "$SCRIPT_DIR/$SKILL" && \
   ! grep -Fq "Upstream body v1." "$SCRIPT_DIR/$SKILL"; then
    pass "F10-b: new upstream body applied"
else
    fail "F10-b: new upstream body missing or old body left behind"
fi
if user_block_of "$SCRIPT_DIR/$SKILL" | cmp -s - "$TEST_ROOT/user-block.expected"; then
    pass "F10-b: user block preserved through the real update"
else
    fail "F10-b: user block changed: $(user_block_of "$SCRIPT_DIR/$SKILL")"
fi
if [ "$(grep -c '^<!-- USER-SPACE -->$' "$SCRIPT_DIR/$SKILL")" -eq 1 ]; then
    pass "F10-b: exactly one USER-SPACE block after update"
else
    fail "F10-b: USER-SPACE block duplicated or lost"
fi

# Run 4: the freshly updated file is again idempotent (applied once, not every run).
RC4=$(run_update run4)
if [ "$RC4" -eq 0 ] && ! skill_listed_updated "$TEST_ROOT/run4.log"; then
    pass "F10-b: update applied once — the following run lists nothing for SKILL.md"
else
    fail "F10-b: SKILL.md listed again after being updated (rc=$RC4)"
fi

echo ""
echo "passed: $PASS_COUNT, failed: $FAIL_COUNT"
if [ "$FAIL_COUNT" -gt 0 ]; then
    echo "FAIL: issue #1010 update idempotence ($FAIL_COUNT failed)"
    exit 1
fi
echo "PASS: issue #1010 update idempotence"
