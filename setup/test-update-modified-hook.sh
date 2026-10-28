#!/bin/bash
# test-update-modified-hook.sh — pins what update.sh does today when the pilot has edited a
# protective hook that is a platform file (WP-529 Ф241 benchmark).
#
# Runs the REAL update.sh against a sandbox: its own SCRIPT_DIR/WORKSPACE_DIR under a temp dir,
# a fake HOME passed only to the child process, a curl shim serving fixture "upstream" content
# (same shape as setup/test-update-issue-226.sh), and stubs for launchctl/systemctl/crontab so
# nothing can reach a real scheduler. The hook is the real .claude/hooks/destructive-guard.sh.
#
# Scenario A: the template clone is already at the upstream version (TOTAL_CHANGES=0), the pilot
#   edited the workspace copy of the hook. update.sh takes the "всё актуально" path, and
#   repair_pass() sees the hash differ from the template and runs its "stale repair".
# Scenario B: upstream ships a new version of the hook, the pilot edited the workspace copy.
#   Step 5 propagation copies the new version over it (copy_platform_file_preserving_user_space).
#
# Observed behaviour pinned here (update.sh at the time of writing):
#   - the platform version overwrites the pilot's edit byte for byte;
#   - NO backup of the pilot's version is kept: backup_rule_before_overwrite() only backs up
#     .claude/rules/*, the .backups/ tree stays empty for a hook;
#   - NO warning: the only line is the ordinary progress line
#     "⟲ .claude/hooks/destructive-guard.sh → workspace (stale repair)" (A) or
#     "✓ .claude/hooks/destructive-guard.sh → workspace" (B), no "⚠";
#   - the executable bit stays set;
#   - a second run changes nothing in the install tree.
# If update.sh starts backing up or warning, the "no backup"/"no warning" checks fail on purpose:
# update the expectations together with the fix.
#
# Usage:
#   bash setup/test-update-modified-hook.sh
#   KEEP=1 bash setup/test-update-modified-hook.sh   # keep the temp dir for inspection

set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_DIR="$(dirname "$SELF_DIR")"
HOOK=".claude/hooks/destructive-guard.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/iwe-modified-hook-test.XXXXXX")"

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

# tree_digest DIR — one line per file (path, sha256, executable bit), .git excluded: git may
# rewrite its own index on a read, which is not a change to the installation.
tree_digest() {
    (cd "$1" && find . -path ./FMT-exocortex-template/.git -prune -o -type f -print | LC_ALL=C sort |
        while IFS= read -r f; do
            x=-; [ -x "$f" ] && x=x
            printf '%s %s %s\n' "$(sha256_of "$f")" "$x" "$f"
        done)
}

if [ ! -f "$TEMPLATE_DIR/$HOOK" ]; then
    echo "  ❌ $HOOK is missing from the template" >&2
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
mkdir -p "$FAKE_HOME" "$UPSTREAM/.claude/hooks" "$STUB_DIR" \
    "$SCRIPT_DIR/.claude/hooks" "$SCRIPT_DIR/.claude/lib" "$SCRIPT_DIR/scripts/lib"

# The upstream hook is the real platform hook, byte for byte.
cp "$TEMPLATE_DIR/$HOOK" "$UPSTREAM/$HOOK"
chmod +x "$UPSTREAM/$HOOK"
cat > "$UPSTREAM/CLAUDE.md" <<'EOF'
# Template CLAUDE.md

## 1. Platform section

Upstream content.
EOF

write_upstream_manifest() {
    python3 - "$UPSTREAM" "$HOOK" <<'PY'
import hashlib, json, sys
from pathlib import Path
root, hook = Path(sys.argv[1]), sys.argv[2]
entry = lambda p: {"path": p, "sha256": hashlib.sha256((root / p).read_bytes()).hexdigest()}
manifest = {"schema_version": 2, "version": "0.99.0-test-modified-hook",
            "files": [entry("CLAUDE.md"), entry(hook)], "deprecated_files": []}
(root / "update-manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
PY
}
write_upstream_manifest

cp "$TEMPLATE_DIR/update.sh" "$SCRIPT_DIR/update.sh"
cp "$TEMPLATE_DIR/.claude/lib/frontmatter.sh" "$SCRIPT_DIR/.claude/lib/frontmatter.sh"
cp "$TEMPLATE_DIR/scripts/lib/common.sh" "$SCRIPT_DIR/scripts/lib/common.sh"
chmod +x "$SCRIPT_DIR/update.sh"
# Template clone already at the upstream version (Scenario A).
cp "$UPSTREAM/CLAUDE.md" "$SCRIPT_DIR/CLAUDE.md"
cp "$UPSTREAM/CLAUDE.md" "$SCRIPT_DIR/.claude.md.base"
cp -p "$UPSTREAM/$HOOK" "$SCRIPT_DIR/$HOOK"
cp "$UPSTREAM/update-manifest.json" "$SCRIPT_DIR/update-manifest.json"

cat > "$WORKSPACE_DIR/.exocortex.env" <<'EOF'
GOVERNANCE_REPO="pilot-governance"
EOF
cp "$UPSTREAM/CLAUDE.md" "$WORKSPACE_DIR/CLAUDE.md"
cp "$UPSTREAM/CLAUDE.md" "$WORKSPACE_DIR/.claude.md.base"

git -C "$SCRIPT_DIR" init -q -b main 2>/dev/null || git -C "$SCRIPT_DIR" init -q
git -C "$SCRIPT_DIR" config user.email t@t
git -C "$SCRIPT_DIR" config user.name t
git -C "$SCRIPT_DIR" add -- update.sh update-manifest.json CLAUDE.md .claude.md.base "$HOOK" \
    .claude/lib/frontmatter.sh scripts/lib/common.sh
git -C "$SCRIPT_DIR" commit -q -m "at upstream version"

# The pilot's edit: a protective rule switched off, the file stays executable.
mkdir -p "$WORKSPACE_DIR/.claude/hooks"
user_edit() {
    { printf '#!/bin/bash\n# pilot: guard disabled locally\nexit 0\n'; cat "$UPSTREAM/$HOOK"; } \
        > "$WORKSPACE_DIR/$HOOK"
    chmod +x "$WORKSPACE_DIR/$HOOK"
    cp -p "$WORKSPACE_DIR/$HOOK" "$TEST_ROOT/user-hook.sh"
}

# Scheduler stubs: any call is recorded and refused, nothing reaches the real host.
for tool in launchctl systemctl crontab; do
    cat > "$STUB_DIR/$tool" <<EOF
#!/bin/bash
echo "$tool \$*" >> "$TEST_ROOT/scheduler-calls.log"
exit 1
EOF
    chmod +x "$STUB_DIR/$tool"
done

# curl shim: serves $UPSTREAM for single-file (-o) and batch (-K) downloads, answers the
# --parallel capability probe. Same contract as the shim in test-update-issue-226.sh.
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

hook_line() { grep -F "$HOOK" "$1" || true; }

# check_overwrite_without_backup SCENARIO LOG — the assertions shared by both scenarios.
check_overwrite_without_backup() {
    local s="$1" log="$2"
    if cmp -s "$UPSTREAM/$HOOK" "$WORKSPACE_DIR/$HOOK"; then
        pass "$s: hook bytes == upstream bytes (pilot's edit overwritten)"
    else
        fail "$s: hook bytes differ from upstream"
    fi
    if [ -x "$WORKSPACE_DIR/$HOOK" ]; then
        pass "$s: executable bit kept on the hook"
    else
        fail "$s: hook lost its executable bit"
    fi
    # Pinned: no backup anywhere in the install tree holds the pilot's version.
    local found=""
    while IFS= read -r f; do
        cmp -s "$f" "$TEST_ROOT/user-hook.sh" && found="$f"
    done < <(find "$WORKSPACE_DIR" -path "$SCRIPT_DIR/.git" -prune -o -type f -print)
    if [ -z "$found" ]; then
        pass "$s: no copy of the pilot's version kept (current behaviour: no backup for .claude/hooks/*)"
    else
        fail "$s: the pilot's version was kept at $found — update.sh now backs hooks up, update this test"
    fi
    if [ ! -d "$WORKSPACE_DIR/.backups" ]; then
        pass "$s: no .backups/ directory created"
    else
        fail "$s: .backups/ appeared: $(find "$WORKSPACE_DIR/.backups" -type f | head -3)"
    fi
    if hook_line "$log" | grep -q '⚠'; then
        fail "$s: a warning about the hook is printed now — update this test: $(hook_line "$log")"
    else
        pass "$s: no warning about the hook (current behaviour)"
    fi
}

# ------------------------------------------------------------------
# Scenario A: template clone at upstream, pilot edited the workspace hook
# ------------------------------------------------------------------
echo "--- Scenario A: modified hook, template already up to date ---"
cp -p "$UPSTREAM/$HOOK" "$WORKSPACE_DIR/$HOOK"
user_edit
run_update "$TEST_ROOT/out-a1.log"; RC_A1=$?

check_rc "$RC_A1" "A: first run exits 0" "A: first run exit $RC_A1"
if grep -q "Всё актуально" "$TEST_ROOT/out-a1.log"; then
    pass "A: update.sh takes the 'всё актуально' path"
else
    fail "A: expected the 'всё актуально' path"
fi
if grep -Fq "⟲ $HOOK → workspace (stale repair)" "$TEST_ROOT/out-a1.log"; then
    pass "A: the only hook line is the progress line '⟲ $HOOK → workspace (stale repair)'"
else
    fail "A: progress line missing; hook lines: $(hook_line "$TEST_ROOT/out-a1.log")"
fi
check_overwrite_without_backup A "$TEST_ROOT/out-a1.log"

tree_digest "$WORKSPACE_DIR" > "$TEST_ROOT/tree-a-before.txt"
run_update "$TEST_ROOT/out-a2.log"; RC_A2=$?
tree_digest "$WORKSPACE_DIR" > "$TEST_ROOT/tree-a-after.txt"
check_rc "$RC_A2" "A: second run exits 0" "A: second run exit $RC_A2"
if diff -q "$TEST_ROOT/tree-a-before.txt" "$TEST_ROOT/tree-a-after.txt" >/dev/null; then
    pass "A: second run changes no file (sha256 + mode of the whole install tree)"
else
    fail "A: second run changed files:"; diff "$TEST_ROOT/tree-a-before.txt" "$TEST_ROOT/tree-a-after.txt" >&2
fi
if [ -z "$(hook_line "$TEST_ROOT/out-a2.log")" ]; then
    pass "A: second run does not mention the hook"
else
    fail "A: second run touched the hook: $(hook_line "$TEST_ROOT/out-a2.log")"
fi

# ------------------------------------------------------------------
# Scenario B: upstream ships a new hook version, pilot edited the workspace hook
# ------------------------------------------------------------------
echo "--- Scenario B: modified hook, upstream ships a new version ---"
# The clone and the workspace hold the "old" platform version; upstream moves on.
{ cat "$TEMPLATE_DIR/$HOOK"; printf '# old platform version\n'; } > "$SCRIPT_DIR/$HOOK"
chmod +x "$SCRIPT_DIR/$HOOK"
python3 - "$SCRIPT_DIR" "$HOOK" <<'PY'
import hashlib, json, sys
from pathlib import Path
root, hook = Path(sys.argv[1]), sys.argv[2]
m = json.loads((root / "update-manifest.json").read_text(encoding="utf-8"))
for e in m["files"]:
    if e["path"] == hook:
        e["sha256"] = hashlib.sha256((root / hook).read_bytes()).hexdigest()
(root / "update-manifest.json").write_text(json.dumps(m), encoding="utf-8")
PY
git -C "$SCRIPT_DIR" add -- "$HOOK" update-manifest.json
git -C "$SCRIPT_DIR" commit -q -m "old hook version"
{ printf '#!/bin/bash\n# pilot: guard disabled locally\nexit 0\n'; cat "$SCRIPT_DIR/$HOOK"; } > "$WORKSPACE_DIR/$HOOK"
chmod +x "$WORKSPACE_DIR/$HOOK"
cp -p "$WORKSPACE_DIR/$HOOK" "$TEST_ROOT/user-hook.sh"
# upstream: the real hook plus a new line, so it differs from both the clone and the pilot's copy
{ cat "$TEMPLATE_DIR/$HOOK"; printf '# new platform version\n'; } > "$UPSTREAM/$HOOK"
write_upstream_manifest

run_update "$TEST_ROOT/out-b1.log"; RC_B1=$?
check_rc "$RC_B1" "B: first run exits 0" "B: first run exit $RC_B1"
if grep -Fq "✓ $HOOK → workspace" "$TEST_ROOT/out-b1.log"; then
    pass "B: the hook line is the progress line '✓ $HOOK → workspace'"
else
    fail "B: progress line missing; hook lines: $(hook_line "$TEST_ROOT/out-b1.log")"
fi
check_overwrite_without_backup B "$TEST_ROOT/out-b1.log"

tree_digest "$WORKSPACE_DIR" > "$TEST_ROOT/tree-b-before.txt"
run_update "$TEST_ROOT/out-b2.log"; RC_B2=$?
tree_digest "$WORKSPACE_DIR" > "$TEST_ROOT/tree-b-after.txt"
check_rc "$RC_B2" "B: second run exits 0" "B: second run exit $RC_B2"
if diff -q "$TEST_ROOT/tree-b-before.txt" "$TEST_ROOT/tree-b-after.txt" >/dev/null; then
    pass "B: second run changes no file (sha256 + mode of the whole install tree)"
else
    fail "B: second run changed files:"; diff "$TEST_ROOT/tree-b-before.txt" "$TEST_ROOT/tree-b-after.txt" >&2
fi

# Scheduler calls (if any) went to the refusing stubs, never to the host: reported, not asserted.
if [ -s "$TEST_ROOT/scheduler-calls.log" ]; then
    echo "  ℹ scheduler stubs were called: $(sort -u "$TEST_ROOT/scheduler-calls.log" | tr '\n' ';')"
fi

echo ""
echo "  Итог: $PASS_COUNT PASS, $FAIL_COUNT FAIL"
if [ "$FAIL_COUNT" -gt 0 ] && [ "${KEEP:-0}" != "1" ]; then
    echo "  (KEEP=1 оставит $TEST_ROOT для разбора)"
fi
exit "$FAIL_COUNT"
