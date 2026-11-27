#!/bin/bash
# test-update-modified-skill.sh — what update.sh does when the pilot has edited a platform
# skill spec outside its USER-SPACE block (issue #1689).
#
# Runs the REAL update.sh against a sandbox, with the same fixtures as
# setup/test-update-modified-hook.sh: its own SCRIPT_DIR/WORKSPACE_DIR under a temp dir, a
# fake HOME passed only to the child process, a curl shim serving fixture "upstream" content,
# and stubs for launchctl/systemctl/crontab. The skill is the real day-close SKILL.md.
#
# Scenario A: the template clone is already at the upstream version; the pilot appended a line
#   outside USER-SPACE in the workspace copy. repair_pass() runs its "stale repair".
# Scenario B: upstream ships a new skill version; the pilot appended a line outside USER-SPACE.
#   Step 5 propagation writes the new version.
# Scenario C: upstream ships a new skill version; the workspace copy is the old template plus a
#   USER-SPACE block — nothing outside the block to keep.
#
# Expected (issue #1689; before it the line was lost silently, with no copy):
#   - the workspace copy becomes the upstream text plus the pilot's USER-SPACE block;
#   - the pilot's whole previous copy is kept under .backups/skills-pre-update/<run>/ byte for
#     byte, and a "⚠ … прежняя версия: <copy>" line and the final summary name the skill;
#   - a second run changes no file and keeps no new copy;
#   - C: the USER-SPACE block is carried over silently, with no copy and no warning.
#
# Usage:
#   bash setup/test-update-modified-skill.sh
#   KEEP=1 bash setup/test-update-modified-skill.sh   # keep the temp dir for inspection

set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_DIR="$(dirname "$SELF_DIR")"
SKILL=".claude/skills/day-close/SKILL.md"
USER_LINE="# USER EDIT SKILL outside USER-SPACE"
USER_BLOCK=$'<!-- USER-SPACE -->\npilot note kept by every update\n<!-- /USER-SPACE -->'
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/iwe-modified-skill-test.XXXXXX")"

FAIL_COUNT=0
PASS_COUNT=0
fail() { echo "  ❌ FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
pass() { echo "  ✅ PASS: $*"; PASS_COUNT=$((PASS_COUNT + 1)); }

# shellcheck disable=SC2329  # invoked by the trap below
cleanup() { local rc=$?; [ "${KEEP:-0}" = "1" ] || rm -rf "$TEST_ROOT"; exit "$rc"; }
trap cleanup EXIT INT TERM

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# tree_digest DIR — one line per file (path, sha256, executable bit), .git excluded.
tree_digest() {
    (cd "$1" && find . -path ./FMT-exocortex-template/.git -prune -o -type f -print | LC_ALL=C sort |
        while IFS= read -r f; do
            x=-; [ -x "$f" ] && x=x
            printf '%s %s %s\n' "$(sha256_of "$f")" "$x" "$f"
        done)
}

if [ ! -f "$TEMPLATE_DIR/$SKILL" ]; then
    echo "  ❌ $SKILL is missing from the template" >&2
    exit 1
fi

# ------------------------------------------------------------------
# Fixtures
# ------------------------------------------------------------------
FAKE_HOME="$TEST_ROOT/fake-home"
UPSTREAM="$TEST_ROOT/upstream"
SCRIPT_DIR="$TEST_ROOT/repo/FMT-exocortex-template"
WORKSPACE_DIR="$TEST_ROOT/repo"
STUB_DIR="$TEST_ROOT/stubs"
mkdir -p "$FAKE_HOME" "$UPSTREAM/$(dirname "$SKILL")" "$STUB_DIR" \
    "$SCRIPT_DIR/$(dirname "$SKILL")" "$SCRIPT_DIR/.claude/lib" "$SCRIPT_DIR/scripts/lib" \
    "$WORKSPACE_DIR/$(dirname "$SKILL")"

cp "$TEMPLATE_DIR/$SKILL" "$UPSTREAM/$SKILL"
cat > "$UPSTREAM/CLAUDE.md" <<'EOF'
# Template CLAUDE.md

## 1. Platform section

Upstream content.
EOF

write_upstream_manifest() {
    mkdir -p "$UPSTREAM/setup/lib"
    cp "$TEMPLATE_DIR/setup/lib/apply-op.sh" "$UPSTREAM/setup/lib/apply-op.sh"
    python3 - "$UPSTREAM" "$SKILL" <<'PY'
import hashlib, json, sys
from pathlib import Path
root, skill = Path(sys.argv[1]), sys.argv[2]
entry = lambda p: {"path": p, "sha256": hashlib.sha256((root / p).read_bytes()).hexdigest()}
manifest = {"schema_version": 2, "version": "0.99.0-test-modified-skill",
            "files": [entry("CLAUDE.md"), entry(skill), entry("setup/lib/apply-op.sh")], "deprecated_files": []}
(root / "update-manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
PY
}

# set_clone_skill FILE MESSAGE — the template clone holds FILE as the installed skill version.
set_clone_skill() {
    cp "$1" "$SCRIPT_DIR/$SKILL"
    python3 - "$SCRIPT_DIR" "$SKILL" <<'PY'
import hashlib, json, sys
from pathlib import Path
root, skill = Path(sys.argv[1]), sys.argv[2]
m = json.loads((root / "update-manifest.json").read_text(encoding="utf-8"))
for e in m["files"]:
    if e["path"] == skill:
        e["sha256"] = hashlib.sha256((root / skill).read_bytes()).hexdigest()
(root / "update-manifest.json").write_text(json.dumps(m), encoding="utf-8")
PY
    git -C "$SCRIPT_DIR" add -- "$SKILL" update-manifest.json
    git -C "$SCRIPT_DIR" commit -q -m "$2"
}

write_upstream_manifest
cp "$TEMPLATE_DIR/update.sh" "$SCRIPT_DIR/update.sh"
cp "$TEMPLATE_DIR/.claude/lib/frontmatter.sh" "$SCRIPT_DIR/.claude/lib/frontmatter.sh"
cp "$TEMPLATE_DIR/scripts/lib/common.sh" "$SCRIPT_DIR/scripts/lib/common.sh"
chmod +x "$SCRIPT_DIR/update.sh"
cp "$UPSTREAM/CLAUDE.md" "$SCRIPT_DIR/CLAUDE.md"
cp "$UPSTREAM/CLAUDE.md" "$SCRIPT_DIR/.claude.md.base"
cp "$UPSTREAM/$SKILL" "$SCRIPT_DIR/$SKILL"
cp "$UPSTREAM/update-manifest.json" "$SCRIPT_DIR/update-manifest.json"
mkdir -p "$SCRIPT_DIR/setup/lib"
cp "$UPSTREAM/setup/lib/apply-op.sh" "$SCRIPT_DIR/setup/lib/apply-op.sh"

cat > "$WORKSPACE_DIR/.exocortex.env" <<'EOF'
GOVERNANCE_REPO="pilot-governance"
EOF
cp "$UPSTREAM/CLAUDE.md" "$WORKSPACE_DIR/CLAUDE.md"
cp "$UPSTREAM/CLAUDE.md" "$WORKSPACE_DIR/.claude.md.base"

git -C "$SCRIPT_DIR" init -q -b main 2>/dev/null || git -C "$SCRIPT_DIR" init -q
git -C "$SCRIPT_DIR" config user.email t@t
git -C "$SCRIPT_DIR" config user.name t
git -C "$SCRIPT_DIR" add -- update.sh update-manifest.json CLAUDE.md .claude.md.base "$SKILL" \
    .claude/lib/frontmatter.sh scripts/lib/common.sh setup/lib/apply-op.sh
git -C "$SCRIPT_DIR" commit -q -m "at upstream version"

# with_user_block FILE OUT — FILE with its shipped USER-SPACE block replaced by the pilot's
# one, laid out the way update.sh does it (reinject_user_section): shipped block dropped,
# trailing blank lines squashed, the pilot's block appended after one blank line.
with_user_block() {
    { perl -0pe 's/^<!-- USER-SPACE -->.*?^<!-- \/USER-SPACE -->//ms; s/\n+$/\n/' "$1"
      printf '\n%s\n' "$USER_BLOCK"; } > "$2"
}

# user_edit BASE — the workspace copy is BASE with the USER-SPACE block and the pilot's own
# line outside it; the exact bytes are kept for comparison with the backup.
user_edit() {
    with_user_block "$1" "$WORKSPACE_DIR/$SKILL"
    printf '%s\n' "$USER_LINE" >> "$WORKSPACE_DIR/$SKILL"
    cp "$WORKSPACE_DIR/$SKILL" "$TEST_ROOT/user-skill.md"
}

for tool in launchctl systemctl crontab; do
    cat > "$STUB_DIR/$tool" <<EOF
#!/bin/bash
echo "$tool \$*" >> "$TEST_ROOT/scheduler-calls.log"
exit 1
EOF
    chmod +x "$STUB_DIR/$tool"
done

# curl shim: same contract as the shim in test-update-modified-hook.sh.
cat > "$STUB_DIR/curl" <<SHIMEOF
#!/bin/bash
serve() {
    local rel="\${1#*/main/}"
    case "\$rel" in
        update.sh) cp "$SCRIPT_DIR/update.sh" "\$2" ;;
        *) [ -f "$UPSTREAM/\$rel" ] && cp "$UPSTREAM/\$rel" "\$2" \\
               || { echo "curl: (22) The requested URL returned error: 404" >&2; return 22; } ;;
    esac
}
if [ "\${1:-}" = "--help" ] && [ "\${2:-}" = "all" ]; then
    printf -- '  --parallel \\n  --parallel-max <num>\\n  --remove-on-error \\n'
    exit 0
fi
url="" out="" cfg=""
args=("\$@")
for ((i=0; i<\${#args[@]}; i++)); do
    case "\${args[i]}" in
        http*) url="\${args[i]}" ;;
        -o) out="\${args[i+1]}" ;;
        -K) cfg="\${args[i+1]}" ;;
    esac
done
if [ -n "\$cfg" ]; then
    rc=0 pending=""
    while IFS= read -r line || [ -n "\$line" ]; do
        case "\$line" in
            'url = '*) pending=\$(printf '%s' "\$line" | sed -e 's/^url = "//' -e 's/"\$//') ;;
            'output = '*) o=\$(printf '%s' "\$line" | sed -e 's/^output = "//' -e 's/"\$//')
                          serve "\$pending" "\$o" || rc=22; pending="" ;;
        esac
    done < "\$cfg"
    exit "\$rc"
fi
serve "\$url" "\$out"
SHIMEOF
chmod +x "$STUB_DIR/curl"

run_update() {  # $1 = log file; HOME and PATH are overridden for the child only
    env HOME="$FAKE_HOME" PATH="$STUB_DIR:$PATH" IWE_UPDATE_CHANNEL=main \
        bash "$SCRIPT_DIR/update.sh" --yes > "$1" 2>&1
}

check_rc() {  # $1 = exit code, $2 = pass text, $3 = fail text
    if [ "$1" -eq 0 ]; then pass "$2"; else fail "$3"; fi
}

skill_line() { grep -F "$SKILL" "$1" || true; }
backup_copies() { find "$WORKSPACE_DIR/.backups/skills-pre-update" -type f -name SKILL.md 2>/dev/null; }

# check_result SCENARIO — the workspace copy is the upstream text plus the USER-SPACE block.
check_result() {
    with_user_block "$UPSTREAM/$SKILL" "$TEST_ROOT/expected.md"
    if cmp -s "$TEST_ROOT/expected.md" "$WORKSPACE_DIR/$SKILL"; then
        pass "$1: workspace copy == upstream text + the pilot's USER-SPACE block"
    else
        fail "$1: workspace copy differs from upstream + USER-SPACE block: $(diff "$TEST_ROOT/expected.md" "$WORKSPACE_DIR/$SKILL" | head -5 | tr '\n' '|')"
    fi
}

# check_backup SCENARIO LOG — the assertions shared by A and B.
check_backup() {
    local s="$1" log="$2" backups
    check_result "$s"
    backups=$(backup_copies)
    if [ "$(printf '%s\n' "$backups" | grep -c .)" -eq 1 ] && cmp -s "$backups" "$TEST_ROOT/user-skill.md" \
        && grep -qxF "$USER_LINE" "$backups"; then
        pass "$s: the pilot's previous copy, with the line outside USER-SPACE, is kept at ${backups#"$WORKSPACE_DIR"/}"
    else
        fail "$s: expected exactly one byte-equal copy of the pilot's version, found: ${backups:-none}"
    fi
    if skill_line "$log" | grep -q '⚠.*не только блоком USER-SPACE.*прежняя версия: .*skills-pre-update'; then
        pass "$s: warning line names the skill and its copy"
    else
        fail "$s: no warning naming the copy; skill lines: $(skill_line "$log")"
    fi
    if grep -q 'Скиллы, отличавшиеся от шаблона не только блоком USER-SPACE, заменены версией шаблона (1)' "$log"; then
        pass "$s: final summary reports the replaced skill"
    else
        fail "$s: final summary does not report the replaced skill"
    fi
}

# check_second_run SCENARIO — a repeated update changes nothing and keeps no new copy.
check_second_run() {
    local s="$1" before="$TEST_ROOT/tree-$1-before.txt" after="$TEST_ROOT/tree-$1-after.txt" rc
    tree_digest "$WORKSPACE_DIR" > "$before"
    run_update "$TEST_ROOT/out-$s-2.log"; rc=$?
    tree_digest "$WORKSPACE_DIR" > "$after"
    check_rc "$rc" "$s: second run exits 0" "$s: second run exit $rc"
    if diff -q "$before" "$after" >/dev/null; then
        pass "$s: second run changes no file and keeps no new copy"
    else
        fail "$s: second run changed files:"; diff "$before" "$after" >&2
    fi
}

# ------------------------------------------------------------------
# Scenario A: template clone at upstream, pilot edited the workspace skill
# ------------------------------------------------------------------
echo "--- Scenario A: edited skill, template already up to date ---"
user_edit "$UPSTREAM/$SKILL"
run_update "$TEST_ROOT/out-A-1.log"; RC=$?
check_rc "$RC" "A: first run exits 0" "A: first run exit $RC"
if grep -Fq "⟲ $SKILL → workspace (stale repair)" "$TEST_ROOT/out-A-1.log"; then
    pass "A: progress line '⟲ $SKILL → workspace (stale repair)'"
else
    fail "A: progress line missing; skill lines: $(skill_line "$TEST_ROOT/out-A-1.log")"
fi
check_backup A "$TEST_ROOT/out-A-1.log"
check_second_run A

# ------------------------------------------------------------------
# Scenario B: upstream ships a new skill version, pilot edited the workspace skill
# ------------------------------------------------------------------
echo "--- Scenario B: edited skill, upstream ships a new version ---"
rm -rf "$WORKSPACE_DIR/.backups"
{ cat "$TEMPLATE_DIR/$SKILL"; printf '\nold platform line\n'; } > "$TEST_ROOT/old-skill.md"
set_clone_skill "$TEST_ROOT/old-skill.md" "old skill version"
user_edit "$TEST_ROOT/old-skill.md"
{ cat "$TEMPLATE_DIR/$SKILL"; printf '\nnew platform line\n'; } > "$UPSTREAM/$SKILL"
write_upstream_manifest
run_update "$TEST_ROOT/out-B-1.log"; RC=$?
check_rc "$RC" "B: first run exits 0" "B: first run exit $RC"
if grep -Fq "✓ $SKILL → workspace (блок USER-SPACE перенесён)" "$TEST_ROOT/out-B-1.log"; then
    pass "B: progress line names the carried USER-SPACE block, not full protection"
else
    fail "B: progress line missing; skill lines: $(skill_line "$TEST_ROOT/out-B-1.log")"
fi
if grep -q 'USER-SPACE preserved' "$TEST_ROOT/out-B-1.log"; then
    fail "B: the log still says '(USER-SPACE preserved)'"
else
    pass "B: the log no longer says '(USER-SPACE preserved)'"
fi
check_backup B "$TEST_ROOT/out-B-1.log"
check_second_run B

# ------------------------------------------------------------------
# Scenario C: upstream ships a new skill version, the workspace copy is the old one + block
# ------------------------------------------------------------------
echo "--- Scenario C: untouched skill with a USER-SPACE block, upstream ships a new version ---"
rm -rf "$WORKSPACE_DIR/.backups"
set_clone_skill "$UPSTREAM/$SKILL" "skill at previous upstream"
with_user_block "$UPSTREAM/$SKILL" "$WORKSPACE_DIR/$SKILL"
{ cat "$TEMPLATE_DIR/$SKILL"; printf '\nnewer platform line\n'; } > "$UPSTREAM/$SKILL"
write_upstream_manifest
run_update "$TEST_ROOT/out-C-1.log"; RC=$?
check_rc "$RC" "C: run exits 0" "C: run exit $RC"
check_result C
if [ -z "$(backup_copies)" ]; then
    pass "C: no copy kept for a skill with nothing outside USER-SPACE"
else
    fail "C: a copy was kept: $(backup_copies | head -3)"
fi
if skill_line "$TEST_ROOT/out-C-1.log" | grep -q '⚠' || grep -q 'Скиллы, отличавшиеся' "$TEST_ROOT/out-C-1.log"; then
    fail "C: warning printed for an untouched skill: $(skill_line "$TEST_ROOT/out-C-1.log")"
else
    pass "C: no warning for an untouched skill"
fi
check_second_run C

if [ -s "$TEST_ROOT/scheduler-calls.log" ]; then
    echo "  ℹ scheduler stubs were called: $(sort -u "$TEST_ROOT/scheduler-calls.log" | tr '\n' ';')"
fi

echo ""
echo "  Итог: $PASS_COUNT PASS, $FAIL_COUNT FAIL"
if [ "$FAIL_COUNT" -gt 0 ] && [ "${KEEP:-0}" != "1" ]; then
    echo "  (KEEP=1 оставит $TEST_ROOT для разбора)"
fi
exit "$FAIL_COUNT"
