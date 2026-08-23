#!/bin/bash
# test-update-self-overwrite.sh — issue #505 regression, full-run E2E.
#
# The live failure (external user, twice on clean disposable installs): the
# delivery snapshot carried an update.sh different from the RUNNING one, and
# Step 5's generic `cp` truncated the very inode bash was still reading —
# execution continued into garbage ("line 1875: command not found", rc=127,
# stale .update-incomplete, runtime never built).
#
# This test runs the REAL update.sh in a sandbox (issue-226 harness pattern)
# where the manifest binds an update.sh that differs from the running copy:
# Step 0's self-update fetch is served the CURRENT content (no re-exec), the
# batch download is served the MARKED content — the residual divergence class
# Step 5 must SKIP (self-update is update.sh's only delivery channel; applying
# it here clobbered the running inode AND let the placeholder-substitution
# pass bake install paths into the updater's own sed templates). Also pins:
# the delivery channel must be resolved BEFORE the self-update bootstrap.
#
# Usage: bash setup/test-update-self-overwrite.sh

set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
UPDATE_SH_REAL="$(dirname "$SELF_DIR")/update.sh"
TEST_ROOT="/tmp/iwe-self-overwrite-test-$$"
FAKE_HOME="$TEST_ROOT/fake-home"

FAIL_COUNT=0
PASS_COUNT=0
fail() { echo "  ❌ FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
pass() { echo "  ✅ PASS: $*"; PASS_COUNT=$((PASS_COUNT + 1)); }
cleanup() { local rc=$?; [ "${KEEP:-0}" = "1" ] || rm -rf "$TEST_ROOT"; exit "$rc"; }
trap cleanup EXIT INT TERM
mkdir -p "$TEST_ROOT" "$FAKE_HOME"

# --- Static ordering guard (fix part 1): channel resolution precedes Step 0 --
RESOLVE_LINE=$(grep -n '^resolve_delivery_ref$' "$UPDATE_SH_REAL" | head -1 | cut -d: -f1)
STEP0_LINE=$(grep -n 'Проверка update.sh' "$UPDATE_SH_REAL" | head -1 | cut -d: -f1)
if [ -n "$RESOLVE_LINE" ] && [ -n "$STEP0_LINE" ] && [ "$RESOLVE_LINE" -lt "$STEP0_LINE" ]; then
  pass "resolve_delivery_ref runs before the Step 0 self-update (no main/release ping-pong)"
else
  fail "channel resolution does not precede Step 0 (resolve at '${RESOLVE_LINE:-none}', Step 0 at '${STEP0_LINE:-none}')"
fi

# --- Fixture: upstream tree ---------------------------------------------------
UPSTREAM="$TEST_ROOT/upstream"
mkdir -p "$UPSTREAM/.claude/hooks"
printf '# Template CLAUDE.md\n\nSame content both sides.\n' > "$UPSTREAM/CLAUDE.md"
printf '#!/bin/bash\necho "hook v2"\n' > "$UPSTREAM/.claude/hooks/dummy-hook.sh"

# The marked update.sh the manifest will bind — differs from the running copy.
cp "$UPDATE_SH_REAL" "$UPSTREAM/update.sh"
printf '\n# self-overwrite-regression-marker issue-505\n' >> "$UPSTREAM/update.sh"

python3 - "$UPSTREAM" <<'PYEOF'
import hashlib, json, sys
from pathlib import Path
root = Path(sys.argv[1])
def entry(p):
    return {'path': p, 'sha256': hashlib.sha256((root / p).read_bytes()).hexdigest()}
manifest = {
    'schema_version': 2,
    'version': '0.99.0-test-505',
    'files': [entry('CLAUDE.md'), entry('.claude/hooks/dummy-hook.sh'), entry('update.sh')],
    'deprecated_files': [],
}
(root / 'update-manifest.json').write_text(json.dumps(manifest))
PYEOF

# --- Fixture: sandboxed SCRIPT_DIR (old local state) --------------------------
SCRIPT_DIR="$TEST_ROOT/repo/FMT-exocortex-template"
mkdir -p "$SCRIPT_DIR/.claude/hooks" "$SCRIPT_DIR/.claude/lib" "$SCRIPT_DIR/scripts/lib"
cp "$UPDATE_SH_REAL" "$SCRIPT_DIR/update.sh"
cp "$SELF_DIR/../.claude/lib/frontmatter.sh" "$SCRIPT_DIR/.claude/lib/frontmatter.sh"
cp "$SELF_DIR/../scripts/lib/common.sh" "$SCRIPT_DIR/scripts/lib/common.sh"
chmod +x "$SCRIPT_DIR/update.sh"
cp "$UPSTREAM/CLAUDE.md" "$SCRIPT_DIR/CLAUDE.md"
cp "$UPSTREAM/CLAUDE.md" "$SCRIPT_DIR/.claude.md.base"
WORKSPACE_DIR="$TEST_ROOT/repo"
cp "$UPSTREAM/CLAUDE.md" "$WORKSPACE_DIR/CLAUDE.md"
cp "$UPSTREAM/CLAUDE.md" "$WORKSPACE_DIR/.claude.md.base"
git -C "$SCRIPT_DIR" init -q
git -C "$SCRIPT_DIR" config user.email t@t; git -C "$SCRIPT_DIR" config user.name t
git -C "$SCRIPT_DIR" add -A; git -C "$SCRIPT_DIR" commit -q -m init
git -C "$SCRIPT_DIR" branch -M main

# Provenance for the install-path guard (same mechanics as the F5 guard
# tests): the marked update.sh must exist in @{upstream} history, otherwise
# the guard treats every line of the freshly applied file as a new addition
# and false-blocks on the sandbox's own install values.
REMOTE_GIT="$TEST_ROOT/remote.git"
git init -q --bare "$REMOTE_GIT"
git -C "$SCRIPT_DIR" remote add origin "$REMOTE_GIT"
git -C "$SCRIPT_DIR" push -q -u origin main
PROV_CLONE="$TEST_ROOT/prov-clone"
git clone -q "$REMOTE_GIT" "$PROV_CLONE"
git -C "$PROV_CLONE" config user.email t@t; git -C "$PROV_CLONE" config user.name t
cp "$UPSTREAM/update.sh" "$PROV_CLONE/update.sh"
git -C "$PROV_CLONE" add update.sh; git -C "$PROV_CLONE" commit -q -m "upstream v2"
git -C "$PROV_CLONE" push -q origin main
git -C "$SCRIPT_DIR" fetch -q origin

# --- curl shim ----------------------------------------------------------------
# Step 0's self-update fetch writes to *.new — serve the CURRENT update.sh
# there (hashes equal, no re-exec). Everything else that asks for update.sh
# (the batch download staging into files/) gets the MARKED version: the exact
# "manifest binds a different update.sh than the one running" divergence.
SHIM_DIR="$TEST_ROOT/shim"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/curl" <<SHIMEOF
#!/bin/bash
serve() {
    local u="\$1" o="\$2" rel
    rel="\${u##*githubusercontent.com/}"; rel="\${rel#*/}"; rel="\${rel#*/}"; rel="\${rel#*/}"
    case "\$rel" in
        update.sh)
            case "\$o" in
                *.new) cp "$SCRIPT_DIR/update.sh" "\$o" ;;
                *)     cp "$UPSTREAM/update.sh" "\$o" ;;
            esac ;;
        update-manifest.json) cp "$UPSTREAM/update-manifest.json" "\$o" ;;
        *) [ -f "$UPSTREAM/\$rel" ] && cp "$UPSTREAM/\$rel" "\$o" || return 22 ;;
    esac
}
if [ "\$1" = "--help" ] && [ "\$2" = "all" ]; then
    printf -- '  -o, --output <file>\n  -f, --fail\n'
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
    had_error=0; pending_url=""
    while IFS= read -r line; do
        case "\$line" in
            url*) pending_url="\${line#*\\"}"; pending_url="\${pending_url%\\"}" ;;
            output*) o="\${line#*\\"}"; o="\${o%\\"}"; serve "\$pending_url" "\$o" || had_error=1; pending_url="" ;;
        esac
    done < "\$cfgfile"
    exit "\$had_error"
fi
[ -z "\$url" ] && exit 22
[ -z "\$out" ] && exit 0
serve "\$url" "\$out"
SHIMEOF
chmod +x "$SHIM_DIR/curl"

# --- Run the REAL update.sh ---------------------------------------------------
echo "--- full run: manifest binds a different update.sh than the running one ---"
set +e
PATH="$SHIM_DIR:$PATH" HOME="$FAKE_HOME" IWE_UPDATE_CHANNEL=main \
    bash "$SCRIPT_DIR/update.sh" --yes > "$TEST_ROOT/out.log" 2>&1
RC=$?
set -e

if [ "$RC" -eq 0 ]; then
  pass "update.sh finished cleanly (rc=0) while replacing itself"
else
  fail "update.sh exited rc=$RC (issue #505 class); tail: $(tail -3 "$TEST_ROOT/out.log" | tr '\n' ' ')"
fi
if grep -q "command not found" "$TEST_ROOT/out.log"; then
  fail "output contains 'command not found' — the running script read garbage mid-flight"
else
  pass "no mid-flight corruption in the output"
fi
if [ -f "$SCRIPT_DIR/.update-incomplete" ]; then
  fail ".update-incomplete marker left behind"
else
  pass "no stale .update-incomplete marker"
fi
if grep -q "self-overwrite-regression-marker issue-505" "$SCRIPT_DIR/update.sh"; then
  fail "Step 5 applied update.sh — its ONLY delivery channel is Step 0 self-update"
else
  pass "running update.sh untouched by Step 5 (self-update owns delivery)"
fi
if grep -q "доставляется только самообновлением" "$TEST_ROOT/out.log"; then
  pass "skip is explicit in the output, not silent"
else
  fail "no explicit skip message for update.sh in Step 5"
fi
if grep -q "install-value" "$TEST_ROOT/out.log"; then
  fail "install-path guard fired — placeholder substitution touched update.sh again"
else
  pass "no install-path leak into update.sh (substitution pass skips it)"
fi
BAKED=$(grep -c "$TEST_ROOT" "$SCRIPT_DIR/update.sh" || true)
if [ "${BAKED:-0}" -eq 0 ]; then
  pass "no sandbox paths baked into update.sh's own sed templates"
else
  fail "$BAKED sandbox path(s) baked into update.sh — {{KEY}} templates substituted"
fi

# --- Scenario 2: Step 0 self-update — inode + behavioural negative control ---
# The v0.38.7 matrix (external user) proved scenario 1 blind to Step 0: it
# serves the CURRENT update.sh at the *.new fetch, so self-update never runs.
# Here the shim serves the MARKED update.sh EVERYWHERE: Step 0 must replace
# the running script via staged rename (inode CHANGES — a cp keeps the inode
# and is exactly the #505 class), re-exec the marked copy, and that copy must
# carry the whole update to a clean finish (behavioural control, codex В2).
echo "--- Scenario 2: Step 0 self-update (inode + re-exec survival) ---"
SCRIPT_DIR2="$TEST_ROOT/repo2/FMT-exocortex-template"
mkdir -p "$SCRIPT_DIR2/.claude/hooks" "$SCRIPT_DIR2/.claude/lib" "$SCRIPT_DIR2/scripts/lib"
cp "$UPDATE_SH_REAL" "$SCRIPT_DIR2/update.sh"
cp "$SELF_DIR/../.claude/lib/frontmatter.sh" "$SCRIPT_DIR2/.claude/lib/frontmatter.sh"
cp "$SELF_DIR/../scripts/lib/common.sh" "$SCRIPT_DIR2/scripts/lib/common.sh"
chmod +x "$SCRIPT_DIR2/update.sh"
cp "$UPSTREAM/CLAUDE.md" "$SCRIPT_DIR2/CLAUDE.md"
cp "$UPSTREAM/CLAUDE.md" "$SCRIPT_DIR2/.claude.md.base"
WORKSPACE_DIR2="$TEST_ROOT/repo2"
cp "$UPSTREAM/CLAUDE.md" "$WORKSPACE_DIR2/CLAUDE.md"
cp "$UPSTREAM/CLAUDE.md" "$WORKSPACE_DIR2/.claude.md.base"
git -C "$SCRIPT_DIR2" init -q
git -C "$SCRIPT_DIR2" config user.email t@t; git -C "$SCRIPT_DIR2" config user.name t
git -C "$SCRIPT_DIR2" add -A; git -C "$SCRIPT_DIR2" commit -q -m init
git -C "$SCRIPT_DIR2" branch -M main
git -C "$SCRIPT_DIR2" remote add origin "$REMOTE_GIT"
git -C "$SCRIPT_DIR2" fetch -q origin
git -C "$SCRIPT_DIR2" branch -q -u origin/main main

SHIM2_DIR="$TEST_ROOT/shim2"
mkdir -p "$SHIM2_DIR"
# The shim was written through an UNQUOTED heredoc: sandbox paths inside it
# are already literal. The only line serving the CURRENT update.sh is the
# *.new branch — repoint it at the marked copy.
sed "s|$SCRIPT_DIR/update.sh|$UPSTREAM/update.sh|" "$SHIM_DIR/curl" > "$SHIM2_DIR/curl"
if diff -q "$SHIM_DIR/curl" "$SHIM2_DIR/curl" >/dev/null 2>&1; then
  echo "FATAL: shim2 rewrite changed nothing — serve anchor moved" >&2; exit 2
fi
chmod +x "$SHIM2_DIR/curl"

inode_of() { stat -c %i "$1" 2>/dev/null || stat -f %i "$1"; }
INODE_BEFORE=$(inode_of "$SCRIPT_DIR2/update.sh")
set +e
PATH="$SHIM2_DIR:$PATH" HOME="$FAKE_HOME" IWE_UPDATE_CHANNEL=main \
    bash "$SCRIPT_DIR2/update.sh" --yes > "$TEST_ROOT/out2.log" 2>&1
RC2=$?
set -e
INODE_AFTER=$(inode_of "$SCRIPT_DIR2/update.sh")

if [ "$RC2" -eq 0 ]; then
  pass "S2: self-updated run finishes cleanly (rc=0)"
else
  fail "S2: rc=$RC2; tail: $(tail -3 "$TEST_ROOT/out2.log" | tr '\n' ' ')"
fi
if grep -q "Перезапуск" "$TEST_ROOT/out2.log"; then
  pass "S2: Step 0 actually replaced and re-exec'ed the updater"
else
  fail "S2: self-update path never ran — scenario is blind again"
fi
if [ "$INODE_BEFORE" != "$INODE_AFTER" ]; then
  pass "S2: inode changed — staged rename semantics (a cp would keep it: #505 class)"
else
  fail "S2: inode unchanged — Step 0 overwrote the running inode (cp semantics)"
fi
if grep -q "self-overwrite-regression-marker issue-505" "$SCRIPT_DIR2/update.sh"; then
  pass "S2: final update.sh is the manifest-bound (marked) version"
else
  fail "S2: final update.sh is not the fetched version"
fi
if grep -q "command not found" "$TEST_ROOT/out2.log"; then
  fail "S2: mid-flight corruption in output"
else
  pass "S2: no mid-flight corruption"
fi
[ -f "$SCRIPT_DIR2/.update-incomplete" ] && fail "S2: stale .update-incomplete left" || pass "S2: no stale incomplete marker"

echo
echo "Result: $PASS_COUNT PASS, $FAIL_COUNT FAIL"
[ "$FAIL_COUNT" -eq 0 ] && exit 0 || exit 1
