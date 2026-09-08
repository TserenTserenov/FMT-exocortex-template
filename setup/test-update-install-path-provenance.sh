#!/bin/bash
# test-update-install-path-provenance.sh -- issue #524 (P0, WP-529 F16)
#
# The install-path guard (validate_no_install_values_in_applied_additions,
# update.sh) blocked a legitimate old->target upgrade when a NEW target-only
# file carried a canonical string that happens to match a real install value
# (live case: a test fixture with CLAUDE_PATH="/usr/bin/claude" -- the real
# standard binary path, not a leaked personal one). The file had no local git
# history to exempt it against, so any install-value substring in it looked
# like a leak. Fix: whole-file sha256 provenance against the target manifest
# -- a file byte-identical to what the manifest declares for its path cannot
# carry a locally-injected line (the hash would differ), so the ENTIRE file
# is exempt. Falls back to the pre-existing git-history line check otherwise.
#
# Four scenarios, python and no-python environments both exercised so the
# fix is not gated on `py_available` (peer-review, codex, 2026-08-24-07):
#   1. Positive: new target file, canonical CLAUDE_PATH line, hash matches
#      manifest -> exempt, update succeeds.
#   2. Negative control (unit-tested on the extracted guard function -- see
#      note at that scenario for why a full update.sh run can't reach it):
#      hash-mismatched file with a genuine, unhistoried install-value line
#      -> exempt correctly abstains, old check still blocks.
#   3. Merged file (CLAUDE.md 3-way merge changes bytes) -> hash mismatches
#      manifest by design -> falls to history check as before.
#   4. No-python environment: scenario 1 repeated with python3/python hidden
#      from PATH -> the awk fallback must exempt identically.
#
# Usage: bash setup/test-update-install-path-provenance.sh
# KEEP=1 bash setup/test-update-install-path-provenance.sh   # keep /tmp dir

set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
UPDATE_SH_REAL="$(dirname "$SELF_DIR")/update.sh"
TEST_ROOT="/tmp/iwe-install-path-provenance-test-$$"
FAKE_HOME="$TEST_ROOT/fake-home"

FAIL_COUNT=0
PASS_COUNT=0
fail() { echo "  FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
pass() { echo "  PASS: $*"; PASS_COUNT=$((PASS_COUNT + 1)); }
cleanup() { local rc=$?; [ "${KEEP:-0}" = "1" ] || rm -rf "$TEST_ROOT"; exit "$rc"; }
trap cleanup EXIT INT TERM
mkdir -p "$TEST_ROOT" "$FAKE_HOME"

FIXTURE_LINE='CLAUDE_PATH="/usr/bin/claude"'
FIXTURE_PATH="scripts/tests/test_launchd_identity_runtime.sh"

# CLAUDE.md content shared by scenarios that do NOT exercise the 3-way merge
# (S1/S4): identical on both local and upstream sides, so CLAUDE.md is
# UNCHANGED and never touches the guard at all -- only the new fixture file
# does. Multiple sections give scenario 3's edit real surrounding context.
CLAUDE_MD_UNCHANGED='# Template CLAUDE.md

## Section 1

New line.

## Section 2

Filler paragraph one.

## Section 3

Filler paragraph two.
'

# write_shim <shim-dir> <upstream-dir> <script-dir> -- self-contained curl
# stand-in serving a specific sandbox's upstream fixtures. Step 0 self-update
# gets served the CURRENT update.sh (identical hash -> no re-exec, keeps the
# test focused on the install-path guard, not the #505 self-overwrite class).
write_shim() {
    local shim_dir="$1" upstream_dir="$2" script_dir="$3"
    mkdir -p "$shim_dir"
    cat > "$shim_dir/curl" <<SHIMEOF
#!/bin/bash
serve() {
    local u="\$1" o="\$2" rel
    rel="\${u##*githubusercontent.com/}"; rel="\${rel#*/}"; rel="\${rel#*/}"; rel="\${rel#*/}"
    case "\$rel" in
        update.sh)
            case "\$o" in
                *.new) cp "$script_dir/update.sh" "\$o" ;;
                *) cp "$upstream_dir/update.sh" "\$o" ;;
            esac ;;
        update-manifest.json) cp "$upstream_dir/update-manifest.json" "\$o" ;;
        *) [ -f "$upstream_dir/\$rel" ] && cp "$upstream_dir/\$rel" "\$o" || return 22 ;;
    esac
}
if [ "\$1" = "--help" ] && [ "\$2" = "all" ]; then printf -- '  -o, --output <file>\n  -f, --fail\n'; exit 0; fi
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
    chmod +x "$shim_dir/curl"
}

# write_upstream <upstream-dir> <claude-md-content> -- upstream tree + schema
# v2 manifest (path -> sha256, computed over what's actually on disk here).
write_upstream() {
    local upstream_dir="$1" claude_content="$2"
    mkdir -p "$upstream_dir/scripts/tests"
    printf '%s' "$claude_content" > "$upstream_dir/CLAUDE.md"
    cp "$UPDATE_SH_REAL" "$upstream_dir/update.sh"
    printf '#!/bin/bash\n%s\necho "fixture"\n' "$FIXTURE_LINE" > "$upstream_dir/$FIXTURE_PATH"
    python3 - "$upstream_dir" <<'PYEOF'
import hashlib, json, sys
from pathlib import Path
root = Path(sys.argv[1])
def entry(p):
    return {'path': p, 'sha256': hashlib.sha256((root / p).read_bytes()).hexdigest()}
manifest = {
    'schema_version': 2,
    'version': '0.99.0-test-524',
    'files': [entry('CLAUDE.md'), entry('scripts/tests/test_launchd_identity_runtime.sh')],
    'deprecated_files': [],
}
(root / 'update-manifest.json').write_text(json.dumps(manifest, indent=2))
PYEOF
}

# mk_script_dir <dir> <claude-md-content> <claude-md-base-content> -- old
# local checkout: no history at all for the new fixture file (upgrade across
# a version gap that introduced it), optional CLAUDE.md divergence for the
# 3-way-merge scenario. .exocortex.env carries the full field set update.sh's
# own regeneration template expects -- a minimal file reads as "incomplete"
# and gets migrated/regenerated, which could re-detect CLAUDE_PATH from the
# host instead of keeping the deterministic fixture value.
mk_script_dir() {
    local dir="$1" claude_content="$2" claude_base="$3"
    mkdir -p "$dir/.claude/hooks" "$dir/.claude/lib" "$dir/scripts/lib"
    cp "$UPDATE_SH_REAL" "$dir/update.sh"
    cp "$SELF_DIR/../.claude/lib/frontmatter.sh" "$dir/.claude/lib/frontmatter.sh"
    cp "$SELF_DIR/../scripts/lib/common.sh" "$dir/scripts/lib/common.sh"
    chmod +x "$dir/update.sh"
    printf '%s' "$claude_content" > "$dir/CLAUDE.md"
    printf '%s' "$claude_base" > "$dir/.claude.md.base"
    git -C "$dir" init -q
    git -C "$dir" config user.email t@t
    git -C "$dir" config user.name t
    git -C "$dir" add -A
    git -C "$dir" commit -q -m init
    git -C "$dir" branch -M main
    mkdir -p "$(dirname "$dir")"
    cat > "$(dirname "$dir")/.exocortex.env" <<ENVEOF
GITHUB_USER="test-user"
WORKSPACE_DIR="$(dirname "$dir")"
$FIXTURE_LINE
CLAUDE_PROJECT_SLUG="test-slug"
TIMEZONE_HOUR="4"
TIMEZONE_DESC="4:00 UTC"
HOME_DIR="$FAKE_HOME"
GOVERNANCE_REPO="DS-strategy"
L4_BACKEND=
L4_DATABASE_URL=
ENVEOF
}

run_update() {  # run_update <script-dir> <shim-dir> [extra-path-dir] -> writes out.log next to script-dir, echoes rc
    # extra_path, when given, REPLACES the inherited PATH entirely -- appending
    # the real PATH after it would leave python3 reachable there even with
    # NO_PY_DIR prepended, silently skipping the awk fallback it exists to
    # force (cold review, 2026-08-24-07, Critical 1: scenario 4 previously
    # exercised the python branch under a false "no-python" label).
    local script_dir="$1" shim_dir="$2" extra_path="${3:-}"
    local log="$(dirname "$script_dir")/out.log"
    local run_path="$shim_dir:$PATH"
    [ -n "$extra_path" ] && run_path="$extra_path:$shim_dir"
    ( PATH="$run_path" HOME="$FAKE_HOME" IWE_UPDATE_CHANNEL=main \
        bash "$script_dir/update.sh" --yes > "$log" 2>&1 )
    echo $?
}

echo "=== 1. Positive: new target file, canonical line, hash matches manifest ==="
S1="$TEST_ROOT/s1"; mkdir -p "$S1"
write_upstream "$S1/upstream" "$CLAUDE_MD_UNCHANGED"
write_shim "$S1/shim" "$S1/upstream" "$S1/repo"
mk_script_dir "$S1/repo" "$CLAUDE_MD_UNCHANGED" "$CLAUDE_MD_UNCHANGED"
RC1=$(run_update "$S1/repo" "$S1/shim")
[ "$RC1" -eq 0 ] && pass "S1: update.sh exits 0" || fail "S1: rc=$RC1; tail: $(tail -6 "$S1/out.log" | tr '\n' ' ')"
grep -q "exempt (byte-identical" "$S1/out.log" && pass "S1: exempt path logged" || fail "S1: exempt message missing; log: $(tail -6 "$S1/out.log" | tr '\n' ' ')"
[ -f "$S1/repo/.update-incomplete" ] && fail "S1: stale marker left" || pass "S1: no incomplete marker"

echo "=== 2. Negative control: exempt correctly abstains when hash mismatches AND a genuine leak is present ==="
# A full update.sh run defends against a "leaked line survives to the guard"
# scenario TWICE before ever reaching this code: substitute_claude_placeholders()
# rewrites literal CLAUDE_PATH values in CLAUDE.md back to {{CLAUDE_PATH}}
# tokens (confirmed live: the fixture line landed as
# 'Example: CLAUDE_PATH="{{CLAUDE_PATH}}"', not the literal value), and the
# download-integrity check (schema v2 sha256) rejects a tampered raw fetch
# outright. Both are correct, pre-existing protections -- they just make it
# impossible to construct an end-to-end scenario that reaches THIS guard's
# fallback with a real leak still inside it. Unit-test the guard function in
# isolation instead (same extraction technique as
# scripts/tests/lib/extract-update-download-batch.sh): a hash-mismatched
# file with a genuinely new, unhistoried install-value line must still fail.
S2="$TEST_ROOT/s2"; mkdir -p "$S2/repo"
GUARD_FUNCS=$(mktemp)
{
    # hash_file/py_available are tiny, stable one-off helpers -- redeclared
    # here rather than auto-extracted (py_available is a single-line
    # function; the multi-line-aware awk state machine below only handles
    # functions that end in a bare "}" on their own line).
    echo 'hash_file() { shasum -a 256 "$1" 2>/dev/null | cut -d" " -f1 || sha256sum "$1" 2>/dev/null | cut -d" " -f1; }'
    echo 'py_available() { [ -n "$PY_BIN" ]; }'
    awk '
        /^validate_no_install_values_in_applied_additions\(\) \{$/ { f=1 }
        f { print }
        f && /^\}$/ { f=0 }
    ' "$UPDATE_SH_REAL"
} > "$GUARD_FUNCS"
if ! grep -q 'manifest_sha256_for_path()' "$GUARD_FUNCS"; then
    fail "S2: extraction found no manifest_sha256_for_path -- markers no longer match update.sh"
fi
printf '%s\n' "$FIXTURE_LINE" > "$S2/repo/leaked.txt"
python3 - "$S2/repo" <<'PYEOF'
import hashlib, json, sys
from pathlib import Path
root = Path(sys.argv[1])
manifest = {
    'schema_version': 2, 'version': '0.99.0-test-524',
    # Manifest declares a DIFFERENT hash than what's on disk now -- exactly
    # the "hash mismatch" precondition for the fallback path.
    'files': [{'path': 'leaked.txt', 'sha256': 'f' * 64}],
    'deprecated_files': [],
}
(root / 'update-manifest.json').write_text(json.dumps(manifest, indent=2))
PYEOF
(
    set -uo pipefail
    # shellcheck disable=SC1090
    . "$GUARD_FUNCS"
    SCRIPT_DIR="$S2/repo"
    WORKSPACE_DIR="$S2"
    MANIFEST="$S2/repo/update-manifest.json"
    APPLIED_PATHS=("leaked.txt")
    PY_BIN="python3"
    printf '%s\n' "$FIXTURE_LINE" > "$S2/.exocortex.env"
    validate_no_install_values_in_applied_additions
) > "$S2/out.log" 2>&1
RC2=$?
[ "$RC2" -ne 0 ] && pass "S2: guard function returns non-zero on hash-mismatched leak" || fail "S2: expected non-zero, got 0"
grep -q "install-value" "$S2/out.log" && pass "S2: guard fired with its message" || fail "S2: no guard message; log: $(tail -6 "$S2/out.log" | tr '\n' ' ')"
rm -f "$GUARD_FUNCS"

echo "=== 3. Merged file (CLAUDE.md, 3-way merge): hash mismatch by design, history check active ==="
S3="$TEST_ROOT/s3"; mkdir -p "$S3"
# base = what the OLD local checkout was tracking as upstream's prior version;
# local = base + a custom section, separated from the edited line by two
# unchanged filler sections (real diff3 context on both sides -- adjacent
# insert+edit without separating context makes git merge-file conflict);
# target (served by upstream) changes "Old line." -> "New line." in Section 1
# only. Clean, non-conflicting 3-way merge; the merged result still carries
# the custom section raw upstream never had, so its hash cannot match the
# manifest -- exactly the mismatch scenario codex asked for.
CLAUDE_MD_BASE='# Template CLAUDE.md

## Section 1

Old line.

## Section 2

Filler paragraph one.

## Section 3

Filler paragraph two.
'
CLAUDE_MD_LOCAL="${CLAUDE_MD_BASE}
## 9. Custom

User text.
"
write_upstream "$S3/upstream" "$CLAUDE_MD_UNCHANGED"
write_shim "$S3/shim" "$S3/upstream" "$S3/repo"
mk_script_dir "$S3/repo" "$CLAUDE_MD_LOCAL" "$CLAUDE_MD_BASE"
RC3=$(run_update "$S3/repo" "$S3/shim")
grep -q "no manifest hash match, falling back" "$S3/out.log" && pass "S3: CLAUDE.md fell back to history check (hash mismatch, as expected for a merge)" || fail "S3: expected fallback message; log: $(tail -10 "$S3/out.log" | tr '\n' ' ')"
[ "$RC3" -eq 0 ] && pass "S3: update.sh still exits 0 (merged CLAUDE.md has no leaked install-value line)" || fail "S3: rc=$RC3; tail: $(tail -6 "$S3/out.log" | tr '\n' ' ')"
grep -qF "## 9. Custom" "$S3/repo/CLAUDE.md" && pass "S3: 3-way merge preserved the local custom section" || fail "S3: custom section lost in merge"

echo "=== 4. No-python environment: positive scenario must exempt identically via shell fallback ==="
NO_PY_DIR="$TEST_ROOT/no-py-path"
mkdir -p "$NO_PY_DIR"
# curl deliberately excluded: it must keep resolving to this scenario's shim,
# not the real system curl -- only python3/python are hidden from PATH here.
for tool in bash sh grep sed awk cp mv rm mkdir cat chmod git date wc head tail cut tr diff mktemp dirname basename find sort uniq shasum sha256sum; do
    real=$(command -v "$tool" 2>/dev/null) && ln -sf "$real" "$NO_PY_DIR/$tool"
done
S4="$TEST_ROOT/s4"; mkdir -p "$S4"
write_upstream "$S4/upstream" "$CLAUDE_MD_UNCHANGED"
write_shim "$S4/shim" "$S4/upstream" "$S4/repo"
mk_script_dir "$S4/repo" "$CLAUDE_MD_UNCHANGED" "$CLAUDE_MD_UNCHANGED"
# Discriminating control: prove python3/python are genuinely unreachable on
# the exact PATH run_update constructs, not just "hopefully hidden".
if PATH="$NO_PY_DIR:$S4/shim" command -v python3 python >/dev/null 2>&1; then
    fail "S4 control: python3/python still resolvable on the no-python PATH -- test is not isolating what it claims to"
else
    pass "S4 control: python3/python genuinely unreachable on the constructed PATH"
fi
RC4=$(run_update "$S4/repo" "$S4/shim" "$NO_PY_DIR")
# EXIT_TAINTED=4 (update.sh, peer-session 2026-08-21-09): a no-python run is
# pre-existing, intentional behavior -- update completes but integrity was
# only file-list-compared, not content-verified, so it exits tainted rather
# than clean. The install-path guard's shell fallback firing correctly is
# the thing this scenario actually tests, not a clean exit.
[ "$RC4" -eq 4 ] && pass "S4: update.sh exits 4 (EXIT_TAINTED, expected without python)" || fail "S4: rc=$RC4; tail: $(tail -8 "$S4/out.log" | tr '\n' ' ')"
grep -q "exempt (byte-identical" "$S4/out.log" && pass "S4: shell-fallback exempt fired (no python)" || fail "S4: shell-fallback exempt did not fire; log: $(tail -8 "$S4/out.log" | tr '\n' ' ')"

echo
echo "Result: $PASS_COUNT PASS, $FAIL_COUNT FAIL"
[ "$FAIL_COUNT" -eq 0 ] && exit 0 || exit 1
