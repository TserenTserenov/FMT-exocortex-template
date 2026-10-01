#!/usr/bin/env bash
# Regression coverage for the #541 refusal on installs made by setup.sh since
# v0.38.10 (WP-7 F193, upgrade run v0.40.2 -> candidate, finding B1).
#
# setup.sh keeps the CLAUDE.md merge base only in the workspace root
# ($WORKSPACE_DIR/.claude.md.base, "the template repo must never receive this
# copy"), while update.sh Step 5 merged the template repo's own CLAUDE.md
# against $SCRIPT_DIR/.claude.md.base. Finding none, it kept the #541 refusal on
# every run: CLAUDE.md never updated, exit 49, a permanent .update-incomplete
# (the strategist skips every launch while that marker exists).
#
# Runs the REAL update.sh --yes (channel main) against disposable installs and a
# stubbed GitHub: curl serves a local upstream tree, gh is never authenticated,
# launchctl/osascript/claude and friends only log their calls. No network, no
# writes outside $TMPDIR. The workspace copy of CLAUDE.md and its merge base are
# written by setup.sh's own install functions, so the setup.sh -> update.sh
# contract (both substitute placeholders the same way) is what gets exercised.
#
# Cases:
#   1 modern layout (base only in the workspace root), the template copy has no
#     local edits, upstream changed CLAUDE.md, the pilot has a line in section 9
#   2 an install already stuck by the refusal (manifest replaced, marker left)
#     heals on the next run without any manual step; the run after that is a no-op
#   3 template copy edited and no base in the template repo: refusal as before
#   4 no merge base anywhere: refusal as before
#   5 old layout (base in the template repo): 3-way merge as before
#   6 the pilot edited a line upstream also changed: conflict markers, exit 49
#   7 author_mode with an unpromoted edit of the template copy: the author guard
#     still runs first, the file stays untouched
#
# Usage: bash scripts/tests/test_issue_541_workspace_base.sh
#        KEEP=1 ... keeps the temporary tree for inspection.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UPDATE_SH="$ROOT/update.sh"
SETUP_SH="$ROOT/setup.sh"
FIXTURE_SHA="3333333333333333333333333333333333333333"
B1_LINE="обновлён (копия в каталоге шаблона не правилась)"
REFUSAL_LINE="CLAUDE.md НЕ тронут — базовый файл для слияния отсутствовал"
PILOT_LINE="- Pilot rule: this line must survive every update."

# Explicit template: a bare mktemp on macOS ignores $TMPDIR, this test must stay inside it.
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/iwe-claude-md-workspace-base.XXXXXX")
cleanup() {
    local rc=$?
    if [ "${KEEP:-0}" = "1" ]; then
        echo "Kept: $TEST_ROOT"
    else
        rm -rf "$TEST_ROOT"
    fi
    exit "$rc"
}
trap cleanup EXIT INT TERM

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "  ✅ PASS: $*"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "  ❌ FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# check LABEL CMD... — PASS when CMD succeeds; FAIL shows the tail of the last run's log.
check() {
    local label="$1"
    shift
    if "$@"; then
        pass "$label"
    else
        fail "$label (log tail: $(tail -3 "$RUN_LOG" 2>/dev/null | tr '\n' ' '))"
    fi
}
absent() { [ ! -e "$1" ]; }
same() { cmp -s "$1" "$2"; }
has_line() { grep -qxF -- "$2" "$1"; }
lacks_text() { ! grep -qF -- "$2" "$1"; }
log_has() { grep -qF -- "$1" "$RUN_LOG"; }
log_lacks() { ! grep -qF -- "$1" "$RUN_LOG"; }
rc_is() { [ "$RUN_RC" -eq "$1" ]; }

# --- setup.sh's own install helpers (the workspace copy and its merge base) ---
SETUP_FUNCS="$TEST_ROOT/setup-funcs.sh"
for fn in sed_escape_replacement install_workspace_instruction install_workspace_merge_base; do
    awk -v signature="$fn() {" '
        $0 == signature { found=1 }
        found { print }
        found && /^}$/ { exit }
    ' "$SETUP_SH"
done > "$SETUP_FUNCS"
for fn in sed_escape_replacement install_workspace_instruction install_workspace_merge_base; do
    grep -q "^$fn() {" "$SETUP_FUNCS" || {
        echo "FATAL: $fn() not found in setup.sh" >&2
        exit 2
    }
done
# Same cross-platform definition setup.sh uses at its top level.
if sed --version >/dev/null 2>&1; then
    sed_inplace() { sed -i "$@"; }
else
    sed_inplace() { sed -i '' "$@"; }
fi
# shellcheck disable=SC1090
. "$SETUP_FUNCS"

# --- stubs: GitHub, schedulers, notifications, the agent CLI ---
SHIM_DIR="$TEST_ROOT/shim"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/curl" <<'SHIM'
#!/bin/bash
# Offline GitHub: API answers and raw file bodies come from $UPSTREAM_FIXTURE.
if [ "${1:-}" = "--help" ]; then
    printf -- '  --parallel \n  --parallel-max <num>\n  --remove-on-error \n'
    exit 0
fi
url="" out="" cfg=""
while [ $# -gt 0 ]; do
    case "$1" in
        http*) url="$1" ;;
        -o) out="$2"; shift ;;
        -K) cfg="$2"; shift ;;
    esac
    shift
done
serve() {
    local u="$1" o="$2" rel
    case "$u" in
        https://api.github.com/*/commits/*) printf '{"sha":"%s"}\n' "$FIXTURE_SHA"; return 0 ;;
        https://api.github.com/*) echo "curl: (22) The requested URL returned error: 404" >&2; return 22 ;;
    esac
    rel="${u#https://raw.githubusercontent.com/}"; rel="${rel#*/}"; rel="${rel#*/}"; rel="${rel#*/}"
    if [ ! -f "$UPSTREAM_FIXTURE/$rel" ]; then
        echo "curl: (22) The requested URL returned error: 404" >&2
        return 22
    fi
    if [ -n "$o" ]; then cp "$UPSTREAM_FIXTURE/$rel" "$o"; else cat "$UPSTREAM_FIXTURE/$rel"; fi
}
if [ -n "$cfg" ]; then
    rc=0; pending=""
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            'url = '*) pending=$(printf '%s' "$line" | sed -e 's/^url = "//' -e 's/"$//') ;;
            'output = '*) target=$(printf '%s' "$line" | sed -e 's/^output = "//' -e 's/"$//'); serve "$pending" "$target" || rc=1 ;;
        esac
    done < "$cfg"
    exit "$rc"
fi
serve "$url" "$out"
SHIM
printf '#!/bin/bash\nexit 1\n' > "$SHIM_DIR/gh"
for stub in launchctl osascript claude crontab systemctl open caffeinate; do
    # shellcheck disable=SC2016  # $* and $STUB_LOG belong to the stub, expanded when it runs
    printf '#!/bin/bash\necho "%s $*" >> "$STUB_LOG"\nexit 0\n' "$stub" > "$SHIM_DIR/$stub"
done
chmod +x "$SHIM_DIR"/*

# --- fixture content ---
write_claude_v1() {
    cat > "$1" <<'EOF'
# Instructions

## 1. Platform

Working directory: {{WORKSPACE_DIR}}/
Governance repository: {{GOVERNANCE_REPO}}
Budget check: {{IWE_TEMPLATE}}/scripts/verify-context-budget.sh
Home: {{HOME_DIR}}
Platform rule A: version one.

## 8. Staging

Staging notes from the platform.

## 9. Authored

Authored section placeholder.
EOF
}
write_claude_v2() {
    cat > "$1" <<'EOF'
# Instructions

## 1. Platform

Working directory: {{WORKSPACE_DIR}}/
Governance repository: {{GOVERNANCE_REPO}}
Budget check: {{IWE_TEMPLATE}}/scripts/verify-context-budget.sh
Home: {{HOME_DIR}}
Platform rule A: version two.

## FPF Usage

A section the new release adds.

## 8. Staging

Staging notes from the platform.

## 9. Authored

Authored section placeholder.
EOF
}

# write_manifest DIR VERSION — schema v2 update-manifest.json for DIR's CLAUDE.md and update.sh
write_manifest() {
    python3 - "$1" "$2" <<'PY'
import hashlib
import json
import pathlib
import sys

root, version = pathlib.Path(sys.argv[1]), sys.argv[2]
files = [
    {"path": path, "sha256": hashlib.sha256((root / path).read_bytes()).hexdigest()}
    for path in ("CLAUDE.md", "update.sh")
]
manifest = {"schema_version": 2, "version": version, "files": files, "deprecated_files": []}
(root / "update-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
PY
}

# with_setup_values TEMPLATE CMD... — runs a setup.sh function with the values
# setup.sh holds while installing (the same ones write_env records); TEMPLATE is
# where CLAUDE.md is read from. setup.sh writes into $WORKSPACE_DIR and also
# substitutes {{WORKSPACE_DIR}} with it, so it is always the real $WS here.
with_setup_values() {
    local template="$1"
    shift
    # shellcheck disable=SC2034  # every value below is read by the sourced setup.sh functions
    (
        TEMPLATE_DIR="$template"
        WORKSPACE_DIR="$WS"
        GITHUB_USER="test-user"
        CLAUDE_PATH="/usr/local/bin/claude"
        CLAUDE_PROJECT_SLUG="-test-workspace"
        TIMEZONE_HOUR="4"
        TIMEZONE_DESC="4:00 UTC"
        HOME_DIR="$CASE_DIR/home"
        GOVERNANCE_REPO="DS-strategy"
        IWE_TEMPLATE_PATH="$SD"
        IWE_RUNTIME_PATH="$WS/.iwe-runtime"
        "$@"
    )
}

# install_workspace_copy — the workspace CLAUDE.md and its merge base, exactly as setup.sh installs them.
install_workspace_copy() {
    with_setup_values "$SD" install_workspace_instruction "CLAUDE.md" &&
        with_setup_values "$SD" install_workspace_merge_base
}

# write_env — .exocortex.env in the shape setup.sh writes it (quoted values).
write_env() {
    cat > "$WS/.exocortex.env" <<EOF
GITHUB_USER="test-user"
WORKSPACE_DIR="$WS"
CLAUDE_PATH="/usr/local/bin/claude"
CLAUDE_PROJECT_SLUG="-test-workspace"
TIMEZONE_HOUR="4"
TIMEZONE_DESC="4:00 UTC"
HOME_DIR="$CASE_DIR/home"
USER_NAME="test-user"
GOVERNANCE_REPO="DS-strategy"
IWE_TEMPLATE="$SD"
IWE_RUNTIME="$WS/.iwe-runtime"
IWE_SCRIPTS="$SD/scripts"
EOF
    chmod 600 "$WS/.exocortex.env"
}

# add_pilot_line FILE — the pilot's own rule at the end of section 9.
add_pilot_line() {
    printf '%s\n' "$PILOT_LINE" >> "$1"
}

# expected_workspace_copy OUT PILOT — what a clean merge must produce: upstream's
# CLAUDE.md substituted by setup.sh's own function, plus the pilot line when
# PILOT=yes. The workspace copy is set aside meanwhile and put back unchanged.
expected_workspace_copy() {
    local out="$1" pilot="$2" saved="$CASE_DIR/ws-claude-saved.md"
    mv "$WS/CLAUDE.md" "$saved"
    if ! with_setup_values "$UP" install_workspace_instruction "CLAUDE.md"; then
        mv "$saved" "$WS/CLAUDE.md"
        return 1
    fi
    mv "$WS/CLAUDE.md" "$out"
    mv "$saved" "$WS/CLAUDE.md"
    if [ "$pilot" = "yes" ]; then
        add_pilot_line "$out"
    fi
}

# build_case NAME LAYOUT — a disposable install and its upstream.
#   LAYOUT modern: merge base only in the workspace root (setup.sh since v0.38.10)
#   LAYOUT legacy: a raw base in the template repo as well (older installs)
# Sets CASE_DIR, UP (served upstream), WS (workspace root), SD (template repo).
build_case() {
    local name="$1" layout="$2"
    CASE_DIR="$TEST_ROOT/$name"
    UP="$CASE_DIR/upstream"
    WS="$CASE_DIR/ws"
    SD="$WS/FMT-exocortex-template"
    RUN_N=0
    RUN_LOG="$CASE_DIR/no-run-yet.log"
    mkdir -p "$UP" "$CASE_DIR/home" "$CASE_DIR/tmp" "$SD/.claude/lib" "$SD/scripts/lib"

    # Upstream: CLAUDE.md v2 next to the very update.sh under test (Step 0 then
    # finds nothing to replace, so the script under test is the one that runs).
    cp "$UPDATE_SH" "$UP/update.sh"
    write_claude_v2 "$UP/CLAUDE.md"
    write_manifest "$UP" "0.40.2"

    # The install: CLAUDE.md v1 with its manifest, plus the two libraries update.sh sources.
    cp "$UPDATE_SH" "$SD/update.sh"
    chmod +x "$SD/update.sh"
    cp "$ROOT/.claude/lib/frontmatter.sh" "$SD/.claude/lib/frontmatter.sh"
    cp "$ROOT/scripts/lib/common.sh" "$SD/scripts/lib/common.sh"
    write_claude_v1 "$SD/CLAUDE.md"
    write_manifest "$SD" "0.40.1"
    if [ "$layout" = "legacy" ]; then
        cp "$SD/CLAUDE.md" "$SD/.claude.md.base"
    fi
    git -C "$SD" init -q
    git -C "$SD" add update.sh update-manifest.json CLAUDE.md .claude/lib/frontmatter.sh scripts/lib/common.sh
    git -C "$SD" -c user.name=test -c user.email=test@example.com commit -q -m "install"

    write_env
    install_workspace_copy || {
        echo "FATAL: setup.sh install functions failed for $name" >&2
        exit 2
    }
    add_pilot_line "$WS/CLAUDE.md"
}

# run_update — the real update.sh --yes on channel main, under the same bash that
# runs this test (so /bin/bash on macOS checks bash 3.2); sets RUN_RC and RUN_LOG.
run_update() {
    RUN_N=$((RUN_N + 1))
    RUN_LOG="$CASE_DIR/run-$RUN_N.log"
    env -i PATH="$SHIM_DIR:$PATH" HOME="$CASE_DIR/home" TMPDIR="$CASE_DIR/tmp" \
        LANG="${LANG:-C}" USER="${USER:-tester}" TERM=dumb \
        GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com \
        GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com \
        IWE_UPDATE_CHANNEL=main UPSTREAM_FIXTURE="$UP" FIXTURE_SHA="$FIXTURE_SHA" \
        STUB_LOG="$TEST_ROOT/stub-calls.log" \
        "$BASH" "$SD/update.sh" --yes > "$RUN_LOG" 2>&1
    RUN_RC=$?
}

# tree_digest DIR — checksum per regular file, git internals excluded.
tree_digest() {
    (cd "$1" && find . -type f ! -path '*/.git/*' | LC_ALL=C sort | while IFS= read -r p; do
        printf '%s %s\n' "$(cksum < "$p")" "$p"
    done)
}

echo "=== case 1: modern layout, template copy without local edits ==="
build_case modern modern
expected_workspace_copy "$CASE_DIR/expected-ws.md" yes
expected_workspace_copy "$CASE_DIR/expected-base.md" no
run_update
check "1 update.sh --yes exits 0" rc_is 0
check "1 no .update-incomplete is left" absent "$SD/.update-incomplete"
check "1 the template copy is upstream's CLAUDE.md byte for byte" same "$SD/CLAUDE.md" "$UP/CLAUDE.md"
check "1 no merge base is written into the template repo" absent "$SD/.claude.md.base"
check "1 the run names the reason it took upstream as is" log_has "$B1_LINE"
check "1 the workspace copy is merged: upstream change plus the pilot line, nothing else" \
    same "$WS/CLAUDE.md" "$CASE_DIR/expected-ws.md"
check "1 the pilot line in section 9 survives" has_line "$WS/CLAUDE.md" "$PILOT_LINE"
check "1 the workspace base advances to the substituted upstream copy" \
    same "$WS/.claude.md.base" "$CASE_DIR/expected-base.md"

echo "=== case 2: an install stuck by the refusal heals on the next run ==="
build_case stuck modern
cp "$WS/CLAUDE.md" "$CASE_DIR/ws-before.md"
# Run 1 reproduces the stuck state with the real updater: with no merge base
# reachable it takes the same #541 refusal the updater before this fix took on
# every setup.sh install (exit 49, marker kept, update-manifest.json already
# replaced by Step 6e). Putting the workspace base back afterwards leaves
# exactly what that updater left behind.
mv "$WS/.claude.md.base" "$CASE_DIR/hidden-base.md"
run_update
check "2 stuck run: exit 49" rc_is 49
check "2 stuck run: marker left behind" test -f "$SD/.update-incomplete"
check "2 stuck run: the installed manifest is already the new one" same "$SD/update-manifest.json" "$UP/update-manifest.json"
check "2 stuck run: the template copy is still the old one" lacks_text "$SD/CLAUDE.md" "version two"
mv "$CASE_DIR/hidden-base.md" "$WS/.claude.md.base"
check "2 stuck state: the workspace copy was not touched" same "$WS/CLAUDE.md" "$CASE_DIR/ws-before.md"
expected_workspace_copy "$CASE_DIR/expected-ws.md" yes
run_update
check "2 next run: exit 0" rc_is 0
check "2 next run: the marker is removed" absent "$SD/.update-incomplete"
check "2 next run: the run reports the removed marker" log_has "Маркер незавершённого обновления снят"
check "2 next run: the template copy is upstream's CLAUDE.md" same "$SD/CLAUDE.md" "$UP/CLAUDE.md"
check "2 next run: no merge base in the template repo" absent "$SD/.claude.md.base"
check "2 next run: the workspace copy is merged with the pilot line kept" same "$WS/CLAUDE.md" "$CASE_DIR/expected-ws.md"
tree_digest "$WS" > "$CASE_DIR/digest-before.txt"
run_update
tree_digest "$WS" > "$CASE_DIR/digest-after.txt"
check "2 rerun: exit 0" rc_is 0
check "2 rerun: reports that nothing is left to update" log_has "Всё актуально"
check "2 rerun: no file in the workspace changes" same "$CASE_DIR/digest-before.txt" "$CASE_DIR/digest-after.txt"
check "2 rerun: no marker" absent "$SD/.update-incomplete"

echo "=== case 3: edited template copy without a base in the template repo ==="
build_case edited modern
printf 'Local edit made in the template copy.\n' >> "$SD/CLAUDE.md"
cp "$SD/CLAUDE.md" "$CASE_DIR/template-before.md"
run_update
check "3 exit 49" rc_is 49
check "3 the edited template copy is untouched" same "$SD/CLAUDE.md" "$CASE_DIR/template-before.md"
check "3 no base is invented in the template repo" absent "$SD/.claude.md.base"
check "3 the marker stays" test -f "$SD/.update-incomplete"
check "3 the refusal is reported" log_has "$REFUSAL_LINE"
check "3 upstream is not taken as is" log_lacks "$B1_LINE"

echo "=== case 4: no merge base anywhere ==="
build_case nobase modern
rm "$WS/.claude.md.base"
cp "$WS/CLAUDE.md" "$CASE_DIR/ws-before.md"
run_update
check "4 exit 49" rc_is 49
check "4 the template copy is untouched" lacks_text "$SD/CLAUDE.md" "version two"
check "4 no base is invented in the template repo" absent "$SD/.claude.md.base"
check "4 no base is invented in the workspace" absent "$WS/.claude.md.base"
check "4 the workspace copy is untouched" same "$WS/CLAUDE.md" "$CASE_DIR/ws-before.md"
check "4 the marker stays" test -f "$SD/.update-incomplete"
check "4 the refusal is reported" log_has "$REFUSAL_LINE"
check "4 upstream is not taken as is" log_lacks "$B1_LINE"

echo "=== case 5: old layout, base in the template repo ==="
build_case legacy legacy
expected_workspace_copy "$CASE_DIR/expected-ws.md" yes
run_update
check "5 exit 0" rc_is 0
check "5 the template copy goes through the 3-way merge" log_has "(3-way merge, чисто)"
check "5 the new shortcut is not used when a template base exists" log_lacks "$B1_LINE"
check "5 the template copy is upstream's CLAUDE.md" same "$SD/CLAUDE.md" "$UP/CLAUDE.md"
check "5 the template base advances to upstream" same "$SD/.claude.md.base" "$UP/CLAUDE.md"
check "5 the workspace copy is merged with the pilot line kept" same "$WS/CLAUDE.md" "$CASE_DIR/expected-ws.md"
check "5 no marker" absent "$SD/.update-incomplete"

echo "=== case 6: the pilot edited a line upstream also changed ==="
build_case conflict modern
sed_inplace 's/^Platform rule A: version one\.$/Platform rule A: pilot version./' "$WS/CLAUDE.md"
cp "$WS/.claude.md.base" "$CASE_DIR/ws-base-before.md"
run_update
check "6 exit 49" rc_is 49
check "6 conflict markers in the workspace copy" grep -q '^<<<<<<<' "$WS/CLAUDE.md"
check "6 the pilot's version of the line is kept inside the conflict" has_line "$WS/CLAUDE.md" "Platform rule A: pilot version."
check "6 upstream's version of the line is offered inside the conflict" has_line "$WS/CLAUDE.md" "Platform rule A: version two."
check "6 the workspace base does not advance past an unresolved conflict" same "$WS/.claude.md.base" "$CASE_DIR/ws-base-before.md"
check "6 the marker stays" test -f "$SD/.update-incomplete"
check "6 no merge base in the template repo" absent "$SD/.claude.md.base"

echo "=== case 7: author_mode, unpromoted edit of the template copy ==="
build_case author modern
printf 'author_mode: true\n' > "$WS/params.yaml"
printf 'Author edit not promoted yet.\n' >> "$SD/CLAUDE.md"
# The workspace already synced from the edited copy, so the copy matches the
# workspace base: only the author guard can keep the shortcut away from it.
install_workspace_copy
add_pilot_line "$WS/CLAUDE.md"
cp "$SD/CLAUDE.md" "$CASE_DIR/template-before.md"
run_update
check "7 exit 0" rc_is 0
check "7 the author guard reports the skip" log_has "CLAUDE.md — author_mode: несмёрженные правки, файл не тронут."
check "7 the shortcut does not run" log_lacks "$B1_LINE"
check "7 the template copy with the author's edit is untouched" same "$SD/CLAUDE.md" "$CASE_DIR/template-before.md"
check "7 no merge base in the template repo" absent "$SD/.claude.md.base"

echo
echo "Result: $PASS_COUNT PASS, $FAIL_COUNT FAIL"
[ "$FAIL_COUNT" -eq 0 ]
