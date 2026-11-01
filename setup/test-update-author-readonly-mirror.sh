#!/bin/bash
# test-update-author-readonly-mirror.sh — update.sh on an author host whose workspace
# .claude/ subdirectories are a read-only mirror delivered by the author's own config
# repository (WP-568 F11; e.g. hooks/, skills/, scripts/ are r-x).
#
# Before the fix a NEW template hook made repair_pass() run `cp` into the read-only
# hooks/ directory: `Permission denied`, the run aborted and .update-incomplete stayed,
# which then blocked the morning Strategist for ten days.
#
# Runs the REAL update.sh against a sandbox (same shape as test-update-modified-hook.sh:
# own SCRIPT_DIR/WORKSPACE_DIR, fake HOME, curl shim serving fixture upstream, scheduler stubs).
#
# The upstream ships two new files: a hook (its directory exists, read-only) and a
# skill whose own directory does not exist yet (the nearest existing ancestor,
# .claude/skills/, is read-only).
#
# A: author_mode, read-only mirror, clone already at upstream (repair_pass path) ->
#    run succeeds, marker cleared, neither file created, one warning per file,
#    the summary counts 2.
# B: author_mode, writable dirs -> both files created as before.
# C: no author_mode, read-only mirror -> the run still fails and keeps the marker
#    (a read-only workspace is a real error for an ordinary user).
# D: author_mode, read-only mirror, clone BEHIND upstream (Step 6 propagation, then
#    repair_pass meets the same files) -> run succeeds, each warning printed once,
#    the summary counts 2, not 4.
#
# Usage: bash setup/test-update-author-readonly-mirror.sh   (KEEP=1 keeps the temp dir)

set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_DIR="$(dirname "$SELF_DIR")"
NEW_HOOK=".claude/hooks/new-template-hook.sh"
NEW_SKILL=".claude/skills/new-template-skill/SKILL.md"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/iwe-author-ro-test.XXXXXX")"

FAIL_COUNT=0
PASS_COUNT=0
fail() { echo "  ❌ FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
pass() { echo "  ✅ PASS: $*"; PASS_COUNT=$((PASS_COUNT + 1)); }

# shellcheck disable=SC2329  # invoked by the trap below
cleanup() {
    local rc=$?
    chmod -R u+w "$TEST_ROOT" 2>/dev/null
    [ "${KEEP:-0}" = "1" ] || rm -rf "$TEST_ROOT"
    exit "$rc"
}
trap cleanup EXIT INT TERM

if [ "$(id -u)" -eq 0 ]; then
    echo "  ⏭ SKIP: root ignores directory write permissions, the scenario cannot be reproduced"
    exit 0
fi

# write_manifest ROOT VERSION PATH... — manifest of ROOT listing the given paths.
write_manifest() {
    python3 - "$@" <<'PY'
import hashlib, json, sys
from pathlib import Path
root, version, paths = Path(sys.argv[1]), sys.argv[2], sys.argv[3:]
entry = lambda p: {"path": p, "sha256": hashlib.sha256((root / p).read_bytes()).hexdigest()}
manifest = {"schema_version": 2, "version": version, "files": [entry(p) for p in paths], "deprecated_files": []}
(root / "update-manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
PY
}

UPSTREAM="$TEST_ROOT/upstream"
STUB_DIR="$TEST_ROOT/stubs"
mkdir -p "$UPSTREAM/.claude/hooks" "$UPSTREAM/$(dirname "$NEW_SKILL")" "$UPSTREAM/setup/lib" "$STUB_DIR"
printf '#!/bin/bash\n# new hook shipped by the template\nexit 0\n' > "$UPSTREAM/$NEW_HOOK"
chmod +x "$UPSTREAM/$NEW_HOOK"
printf -- '---\nname: new-template-skill\ndescription: test fixture\n---\n\n# New skill\n' > "$UPSTREAM/$NEW_SKILL"
printf '# Template CLAUDE.md\n\n## 1. Platform section\n\nUpstream content.\n' > "$UPSTREAM/CLAUDE.md"
cp "$TEMPLATE_DIR/setup/lib/apply-op.sh" "$UPSTREAM/setup/lib/apply-op.sh"
write_manifest "$UPSTREAM" 0.99.0-test-author-ro CLAUDE.md "$NEW_HOOK" "$NEW_SKILL" setup/lib/apply-op.sh

# Scheduler stubs: refuse every call, nothing reaches the real host.
for tool in launchctl systemctl crontab; do
    printf '#!/bin/bash\nexit 1\n' > "$STUB_DIR/$tool"
    chmod +x "$STUB_DIR/$tool"
done

# curl shim: same contract as in test-update-modified-hook.sh; update.sh itself is
# served from the template under test.
cat > "$STUB_DIR/curl" <<SHIMEOF
#!/bin/bash
serve() {
    local rel="\${1#*/main/}"
    case "\$rel" in
        update.sh) cp "$TEMPLATE_DIR/update.sh" "\$2" ;;
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

# make_sandbox NAME AUTHOR(true|false) MIRROR_RO(true|false) CLONE(at|behind)
# — prints the workspace dir.
make_sandbox() {
    local ws="$TEST_ROOT/$1"
    local sd="$ws/FMT-exocortex-template"
    local new_files=()
    mkdir -p "$ws/.claude/hooks" "$ws/.claude/skills" "$ws/fake-home" "$sd/.claude/hooks" \
        "$sd/.claude/lib" "$sd/scripts/lib" "$sd/setup/lib"
    cp "$TEMPLATE_DIR/update.sh" "$sd/update.sh"
    cp "$TEMPLATE_DIR/.claude/lib/frontmatter.sh" "$sd/.claude/lib/frontmatter.sh"
    cp "$TEMPLATE_DIR/scripts/lib/common.sh" "$sd/scripts/lib/common.sh"
    cp "$UPSTREAM/CLAUDE.md" "$sd/CLAUDE.md"
    cp "$UPSTREAM/CLAUDE.md" "$sd/.claude.md.base"
    cp "$UPSTREAM/setup/lib/apply-op.sh" "$sd/setup/lib/apply-op.sh"
    if [ "$4" = at ]; then
        mkdir -p "$sd/$(dirname "$NEW_SKILL")"
        cp -p "$UPSTREAM/$NEW_HOOK" "$sd/$NEW_HOOK"
        cp "$UPSTREAM/$NEW_SKILL" "$sd/$NEW_SKILL"
        cp "$UPSTREAM/update-manifest.json" "$sd/update-manifest.json"
        new_files=("$NEW_HOOK" "$NEW_SKILL")
    else
        write_manifest "$sd" 0.98.0-test-author-ro CLAUDE.md setup/lib/apply-op.sh
    fi
    (
        cd "$sd" || exit 1
        { git init -q -b main 2>/dev/null || git init -q; } &&
            git config user.email t@t && git config user.name t &&
            git add -- update.sh update-manifest.json CLAUDE.md .claude.md.base \
                ${new_files[@]+"${new_files[@]}"} \
                .claude/lib/frontmatter.sh scripts/lib/common.sh setup/lib/apply-op.sh &&
            git commit -q -m "template clone fixture"
    ) || { echo "sandbox $1: git fixture failed" >&2; exit 1; }
    printf 'GOVERNANCE_REPO="pilot-governance"\n' > "$ws/.exocortex.env"
    cp "$UPSTREAM/CLAUDE.md" "$ws/CLAUDE.md"
    cp "$UPSTREAM/CLAUDE.md" "$ws/.claude.md.base"
    if [ "$2" = true ]; then printf 'author_mode: true\n' > "$ws/params.yaml"; fi
    if [ "$3" = true ]; then chmod 555 "$ws/.claude/hooks" "$ws/.claude/skills"; fi
    # The run under test starts from a marker left by an aborted earlier run.
    printf 'started_at=2026-10-22T19:25:07Z\nstate=applying\n' > "$sd/.update-incomplete"
    printf '%s' "$ws"
}

run_update() {  # WORKSPACE LOG -> exit code of update.sh
    env HOME="$1/fake-home" PATH="$STUB_DIR:$PATH" IWE_UPDATE_CHANNEL=main \
        bash "$1/FMT-exocortex-template/update.sh" --yes > "$2" 2>&1
}

exists() { if [ -e "$1" ]; then echo yes; else echo no; fi; }

# warnings LOG FILE — how many read-only warning lines name FILE.
warnings() { grep -cF -- "$2 — author_mode: каталог рабочей копии только для чтения" "$1"; }

# check_skipped SCENARIO LOG WORKSPACE RC — the assertions shared by A and D.
check_skipped() {
    local s="$1" log="$2" ws="$3" rc="$4" f n
    if [ "$rc" -eq 0 ]; then pass "$s: update.sh finished"; else fail "$s: update.sh exit $rc; tail: $(tail -5 "$log")"; fi
    if [ ! -e "$ws/FMT-exocortex-template/.update-incomplete" ]; then pass "$s: marker cleared"; else fail "$s: marker still present"; fi
    for f in "$NEW_HOOK" "$NEW_SKILL"; do
        if [ ! -e "$ws/$f" ]; then pass "$s: $f not created in the read-only mirror"; else fail "$s: $f appeared in a read-only directory"; fi
        n=$(warnings "$log" "$f")
        if [ "$n" -eq 1 ]; then pass "$s: exactly one warning names $f"; else fail "$s: $n warnings for $f, expected 1"; fi
    done
    if grep -q 'в каталогах только для чтения 2$' "$log"; then
        pass "$s: summary counts 2 skipped files"
    else
        fail "$s: summary line: $(grep 'в каталогах только для чтения' "$log" || echo none)"
    fi
    if ! grep -q 'Permission denied' "$log"; then pass "$s: no Permission denied in the log"; else fail "$s: Permission denied still reached the log"; fi
}

echo "== A: author_mode, read-only mirror, clone at upstream"
WS=$(make_sandbox a true true at)
run_update "$WS" "$TEST_ROOT/a.log"; rc=$?
check_skipped A "$TEST_ROOT/a.log" "$WS" "$rc"

echo "== B: author_mode, writable dirs"
WS=$(make_sandbox b true false at)
run_update "$WS" "$TEST_ROOT/b.log"; rc=$?
if [ "$rc" -eq 0 ] && cmp -s "$UPSTREAM/$NEW_HOOK" "$WS/$NEW_HOOK" && [ -f "$WS/$NEW_SKILL" ]; then
    pass "B: new hook and skill created as before"
else
    fail "B: exit $rc, hook: $(exists "$WS/$NEW_HOOK"), skill: $(exists "$WS/$NEW_SKILL")"
fi

echo "== C: ordinary user, read-only mirror"
WS=$(make_sandbox c false true at)
run_update "$WS" "$TEST_ROOT/c.log"; rc=$?
if [ "$rc" -ne 0 ] && [ -e "$WS/FMT-exocortex-template/.update-incomplete" ] && grep -q 'Permission denied' "$TEST_ROOT/c.log"; then
    pass "C: run fails on the read-only directory and keeps the marker"
else
    fail "C: exit $rc, marker present: $(exists "$WS/FMT-exocortex-template/.update-incomplete")"
fi

echo "== D: author_mode, read-only mirror, clone behind upstream"
WS=$(make_sandbox d true true behind)
run_update "$WS" "$TEST_ROOT/d.log"; rc=$?
check_skipped D "$TEST_ROOT/d.log" "$WS" "$rc"
if [ -f "$WS/FMT-exocortex-template/$NEW_HOOK" ]; then
    pass "D: the template clone itself received the new hook (Step 6 path ran)"
else
    fail "D: the new hook did not reach the template clone (Step 6 path not exercised)"
fi

echo
echo "Итого: $PASS_COUNT прошло, $FAIL_COUNT провалено"
[ "$FAIL_COUNT" -eq 0 ]
