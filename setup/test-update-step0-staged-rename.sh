#!/bin/bash
# test-update-step0-staged-rename.sh — issue #505 residual, full-run E2E.
#
# Codex peer-review of the v0.38.7 post-mortem (2026-08-22): the #516
# regression test deliberately makes Step 0 a no-op (it serves the CURRENT
# update.sh to the self-update fetch), so the dangerous replacement itself —
# Step 0 overwriting the RUNNING script — had no E2E coverage. #517 switched
# that replacement from `cp` (truncates the inode bash is still executing) to
# sibling-tmp + mv (atomic rename, the process keeps its old inode). This test
# exercises exactly that path: the self-update fetch is served a DIFFERENT
# update.sh, Step 0 must stage+rename it, re-exec, and the run must complete
# cleanly.
#
# Two --check scenarios run first, on the same fixture (issue #955 / #980):
#   - the fetch is served a different update.sh: Step 0 must say a new version
#     exists and must NOT also claim "update.sh актуален", and --check must leave
#     the local file byte-identical;
#   - the fetch fails (curl exit 23, a write error): Step 0 must say it could not
#     check, show curl's cause, and must NOT claim "актуален".
#
# Usage: bash setup/test-update-step0-staged-rename.sh

set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
UPDATE_SH_REAL="$(dirname "$SELF_DIR")/update.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/iwe-step0-rename-test.XXXXXX")"
FAKE_HOME="$TEST_ROOT/fake-home"

FAIL_COUNT=0
PASS_COUNT=0
fail() { echo "  ❌ FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
pass() { echo "  ✅ PASS: $*"; PASS_COUNT=$((PASS_COUNT + 1)); }
cleanup() { local rc=$?; [ "${KEEP:-0}" = "1" ] || rm -rf "$TEST_ROOT"; exit "$rc"; }
trap cleanup EXIT INT TERM
mkdir -p "$TEST_ROOT" "$FAKE_HOME"

# --- Fixture: upstream tree ---------------------------------------------------
UPSTREAM="$TEST_ROOT/upstream"
mkdir -p "$UPSTREAM/.claude/hooks"
printf '# Template CLAUDE.md\n\nSame content both sides.\n' > "$UPSTREAM/CLAUDE.md"
printf '#!/bin/bash\necho "hook v2"\n' > "$UPSTREAM/.claude/hooks/dummy-hook.sh"

# The marked update.sh — what upstream "published" (differs from the running
# copy by a trailing comment, same behaviour otherwise).
cp "$UPDATE_SH_REAL" "$UPSTREAM/update.sh"
printf '\n# step0-staged-rename-marker issue-505-residual\n' >> "$UPSTREAM/update.sh"

python3 - "$UPSTREAM" <<'PYEOF'
import hashlib, json, sys
from pathlib import Path
root = Path(sys.argv[1])
def entry(p):
    return {'path': p, 'sha256': hashlib.sha256((root / p).read_bytes()).hexdigest()}
manifest = {
    'schema_version': 2,
    'version': '0.99.0-test-505-residual',
    'files': [entry('CLAUDE.md'), entry('.claude/hooks/dummy-hook.sh'), entry('update.sh')],
    'deprecated_files': [],
}
(root / 'update-manifest.json').write_text(json.dumps(manifest))
PYEOF

# --- Fixture: sandboxed SCRIPT_DIR (old local state: UNMARKED update.sh) ------
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

# Provenance for the install-path guard (same mechanics as the #505 test):
# the marked update.sh must exist in @{upstream} history.
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
# Unlike the #505 test, the self-update fetch (*.new) is served the MARKED
# update.sh too — Step 0 must actually replace the running script and re-exec.
# After the replacement the re-executed copy fetches the same marked content
# again: hashes match, no second replacement, no re-exec loop.
SHIM_DIR="$TEST_ROOT/shim"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/curl" <<SHIMEOF
#!/bin/bash
serve() {
    local u="\$1" o="\$2" rel
    rel="\${u##*githubusercontent.com/}"; rel="\${rel#*/}"; rel="\${rel#*/}"; rel="\${rel#*/}"
    case "\$rel" in
        update.sh) cp "$UPSTREAM/update.sh" "\$o" ;;
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
# SHIM_FAIL_UPDATE_SH_RC: the Step 0 fetch of update.sh fails like a native Windows
# curl that cannot write to a POSIX temp path (issue #980).
if [ -n "\${SHIM_FAIL_UPDATE_SH_RC:-}" ] && [ "\${url##*/}" = "update.sh" ]; then
    echo "curl: (\$SHIM_FAIL_UPDATE_SH_RC) client returned ERROR on write of 16384 bytes" >&2
    exit "\$SHIM_FAIL_UPDATE_SH_RC"
fi
[ -z "\$out" ] && exit 0
serve "\$url" "\$out"
SHIMEOF
chmod +x "$SHIM_DIR/curl"

# --- --check with a newer update.sh upstream (issue #955) -----------------------
# Before the fix Step 0 printed the warning and then, unconditionally,
# "update.sh актуален." right under it.
echo "--- --check: a newer update.sh is reported once, as a warning ---"
cp "$SCRIPT_DIR/update.sh" "$TEST_ROOT/update.sh.before"
set +e
PATH="$SHIM_DIR:$PATH" HOME="$FAKE_HOME" IWE_UPDATE_CHANNEL=main \
    bash "$SCRIPT_DIR/update.sh" --check > "$TEST_ROOT/check-new.log" 2>&1
set -e
if grep -q "Новая версия update.sh доступна" "$TEST_ROOT/check-new.log"; then
  pass "--check reports that a new update.sh is available"
else
  fail "--check did not report the new update.sh; tail: $(tail -3 "$TEST_ROOT/check-new.log" | tr '\n' ' ')"
fi
if grep -q "update.sh актуален" "$TEST_ROOT/check-new.log"; then
  fail "--check says 'update.sh актуален' although a newer update.sh exists (#955)"
else
  pass "--check does not claim update.sh is up to date"
fi
if cmp -s "$SCRIPT_DIR/update.sh" "$TEST_ROOT/update.sh.before"; then
  pass "--check left the local update.sh byte-identical"
else
  fail "--check changed the local update.sh"
fi

# --- --check when the Step 0 download fails (issues #955 / #980) -----------------
# Before the fix curl's stderr went to /dev/null and the failure fell through to
# the same "актуален" line: "could not check" was reported as "checked, current".
echo "--- --check: a failed update.sh download is not reported as up to date ---"
set +e
SHIM_FAIL_UPDATE_SH_RC=23 PATH="$SHIM_DIR:$PATH" HOME="$FAKE_HOME" IWE_UPDATE_CHANNEL=main \
    bash "$SCRIPT_DIR/update.sh" --check > "$TEST_ROOT/check-fail.log" 2>&1
set -e
if grep -q "не удалось проверить update.sh" "$TEST_ROOT/check-fail.log"; then
  pass "a failed Step 0 download is reported as a failed check"
else
  fail "a failed Step 0 download was not reported; tail: $(tail -3 "$TEST_ROOT/check-fail.log" | tr '\n' ' ')"
fi
if grep -q "не удалось проверить update.sh.*curl код 23" "$TEST_ROOT/check-fail.log" && \
   grep -q "client returned ERROR on write" "$TEST_ROOT/check-fail.log"; then
  pass "the report carries curl's exit code and its last stderr line"
else
  fail "curl's cause is missing from the report: $(grep -n 'update.sh' "$TEST_ROOT/check-fail.log" | head -3 | tr '\n' ' ')"
fi
if grep -q "update.sh актуален" "$TEST_ROOT/check-fail.log"; then
  fail "a failed download was reported as 'update.sh актуален' (#955/#980)"
else
  pass "a failed download is not reported as up to date"
fi
if cmp -s "$SCRIPT_DIR/update.sh" "$TEST_ROOT/update.sh.before"; then
  pass "a failed download left the local update.sh untouched"
else
  fail "a failed download changed the local update.sh"
fi

# --- Run the REAL update.sh: Step 0 must replace+re-exec itself ---------------
echo "--- full run: Step 0 self-update replaces the running script ---"
set +e
PATH="$SHIM_DIR:$PATH" HOME="$FAKE_HOME" IWE_UPDATE_CHANNEL=main \
    bash "$SCRIPT_DIR/update.sh" --yes > "$TEST_ROOT/out.log" 2>&1
RC=$?
set -e

if [ "$RC" -eq 0 ]; then
  pass "update.sh finished cleanly (rc=0) through the Step 0 replace+re-exec"
else
  fail "update.sh exited rc=$RC; tail: $(tail -3 "$TEST_ROOT/out.log" | tr '\n' ' ')"
fi
if grep -q "step0-staged-rename-marker issue-505-residual" "$SCRIPT_DIR/update.sh"; then
  pass "running update.sh was replaced by the upstream copy"
else
  fail "Step 0 did not replace update.sh (marker missing)"
fi
if grep -q "Перезапуск" "$TEST_ROOT/out.log"; then
  pass "re-exec happened after the replacement"
else
  fail "no re-exec after Step 0 replacement"
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
if compgen -G "$SCRIPT_DIR/.update.sh.staged.*" > /dev/null; then
  fail "staged tmp file(s) left behind: $(ls "$SCRIPT_DIR"/.update.sh.staged.* 2>/dev/null | tr '\n' ' ')"
else
  pass "no staged tmp files left behind"
fi

echo
echo "Result: $PASS_COUNT PASS, $FAIL_COUNT FAIL"
[ "$FAIL_COUNT" -eq 0 ] && exit 0 || exit 1
