#!/bin/bash
# test-update-legacy-template-base.sh — upgrade from an install made by setup.sh 0.36 (WP-529 Ф270, 0.42 rc.9 row 3).
#
# setup.sh up to 0.36 wrote FMT/.claude.md.base from the SUBSTITUTED workspace CLAUDE.md, while the template copy
# keeps raw {{PLACEHOLDERS}}. update.sh restores only some keys before its 3-way merge, so a release that changed a
# {{GOVERNANCE_REPO}} line made an unedited template copy conflict; the retry then reported "Всё актуально".
#
# Scenario L: delivered template copy + legacy substituted base -> replaced, no conflict, exit 0.
# Scenario E: the pilot edited the template copy and update.sh 0.36 committed it -> HEAD alone does not prove
#             "unedited": the copy is not replaced, the edit stays.
# Scenario M: retry after an interrupted conflict (markers in the template copy, nothing new published) -> exit 49,
#             no "Всё актуально", the file named, the workspace CLAUDE.md and its base untouched.
# Scenario T: a refusal by a top-level exit (a download fails) keeps its code and prints no crash line (RT8-3).
#
# Runs the real update.sh in a sandbox; a curl shim serves the fixture upstream instead of GitHub.
# Usage: bash setup/test-update-legacy-template-base.sh   (KEEP=1 keeps the sandbox)

set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SELF_DIR")"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/iwe-legacy-base.XXXXXX")"
FAKE_HOME="$TEST_ROOT/fake-home"
GOV="pilot-governance"
EXIT_NETWORK=2
EXIT_CONFLICT=49
FAILS=0
pass() { echo "  ok: $*"; }
fail() { echo "  FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
cleanup() { local rc=$?; [ "${KEEP:-0}" = "1" ] || rm -rf "$TEST_ROOT"; exit "$rc"; }
trap cleanup EXIT INT TERM
mkdir -p "$FAKE_HOME"

OLD_CLAUDE='# Template CLAUDE.md

## State-Transition Gate

Name the target state transition; applies if {{GOVERNANCE_REPO}}/docs/state-axes-registry.yaml exists (old wording).'
NEW_CLAUDE='# Template CLAUDE.md

## State-Transition Gate

Read {{GOVERNANCE_REPO}}/docs/state-axes-registry.yaml before any non-trivial action (new wording).'

# write_manifest DIR VERSION FILE... — update-manifest.json listing FILE... of DIR with their sha256
write_manifest() {
    python3 - "$@" <<'PY'
import hashlib, json, sys
from pathlib import Path
root, version, files = Path(sys.argv[1]), sys.argv[2], sys.argv[3:]
entries = [{"path": p, "sha256": hashlib.sha256((root / p).read_bytes()).hexdigest()} for p in files]
(root / "update-manifest.json").write_text(json.dumps(
    {"schema_version": 2, "version": version, "files": entries, "deprecated_files": []}))
PY
}

# --- upstream: the release being installed ---
UPSTREAM="$TEST_ROOT/upstream"
mkdir -p "$UPSTREAM/setup/lib"
cp "$SELF_DIR/lib/apply-op.sh" "$UPSTREAM/setup/lib/apply-op.sh"
printf '%s\n' "$NEW_CLAUDE" > "$UPSTREAM/CLAUDE.md"
write_manifest "$UPSTREAM" 0.99.0-test-legacy-base CLAUDE.md setup/lib/apply-op.sh

# install_036 NAME [EDIT] — a workspace as setup.sh 0.36 left it, with the manifest of the installed release.
# EDIT, when given, is a line the pilot appended to the template copy before update.sh 0.36 committed the clone.
install_036() {
    local ws="$TEST_ROOT/$1" tpl="$TEST_ROOT/$1/FMT-exocortex-template"
    mkdir -p "$tpl/.claude/lib" "$tpl/scripts/lib" "$tpl/setup/lib"
    cp "$REPO_ROOT/update.sh" "$tpl/update.sh"
    cp "$REPO_ROOT/.claude/lib/frontmatter.sh" "$tpl/.claude/lib/frontmatter.sh"
    cp "$REPO_ROOT/scripts/lib/common.sh" "$tpl/scripts/lib/common.sh"
    cp "$SELF_DIR/lib/apply-op.sh" "$tpl/setup/lib/apply-op.sh"
    printf '%s\n' "$OLD_CLAUDE" > "$tpl/CLAUDE.md"
    write_manifest "$tpl" 0.36.3 CLAUDE.md setup/lib/apply-op.sh
    [ -z "${2:-}" ] || printf '%s\n' "$2" >> "$tpl/CLAUDE.md"
    printf 'GOVERNANCE_REPO="%s"\nWORKSPACE_DIR="%s"\n' "$GOV" "$ws" > "$ws/.exocortex.env"
    sed "s|{{GOVERNANCE_REPO}}|$GOV|g" "$tpl/CLAUDE.md" > "$ws/CLAUDE.md"
    cp "$ws/CLAUDE.md" "$ws/.claude.md.base"
    cp "$ws/CLAUDE.md" "$tpl/.claude.md.base"   # the legacy substituted template base
    git -C "$tpl" init -q
    git -C "$tpl" -c user.email=t@t -c user.name=t add -A
    git -C "$tpl" -c user.email=t@t -c user.name=t commit -q -m "chore: update from upstream template (0.36)"
}

# --- shims: curl serves raw.githubusercontent.com/<repo>/main/<path> from $UPSTREAM; gh is never logged in ---
SHIM_DIR="$TEST_ROOT/shim"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/curl" <<SHIMEOF
#!/bin/bash
serve() {
    local rel="\${1#*/main/}"
    if [ "\$rel" = "update.sh" ]; then cp "$REPO_ROOT/update.sh" "\$2"; return 0; fi
    [ -f "$UPSTREAM/\$rel" ] && cp "$UPSTREAM/\$rel" "\$2" \
        || { echo "curl: (22) The requested URL returned error: 404" >&2; return 22; }
}
if [ "\${1:-}" = "--help" ]; then printf -- '  -o, --output <file>\n  -f, --fail\n'; exit 0; fi
url="" out="" cfg=""
args=("\$@")
for ((i = 0; i < \${#args[@]}; i++)); do
    case "\${args[i]}" in
        http*) url="\${args[i]}" ;;
        -o) out="\${args[i+1]}" ;;
        -K) cfg="\${args[i+1]}" ;;
    esac
done
if [ -n "\$cfg" ]; then
    rc=0 u=""
    while IFS= read -r line || [ -n "\$line" ]; do
        case "\$line" in
            'url = '*) u=\$(printf '%s' "\$line" | sed -e 's/^url = "//' -e 's/"\$//') ;;
            'output = '*) serve "\$u" "\$(printf '%s' "\$line" | sed -e 's/^output = "//' -e 's/"\$//')" || rc=22 ;;
        esac
    done < "\$cfg"
    exit "\$rc"
fi
serve "\$url" "\$out"
SHIMEOF
chmod +x "$SHIM_DIR/curl"
printf '#!/bin/sh\nexit 1\n' > "$SHIM_DIR/gh"
chmod +x "$SHIM_DIR/gh"

run_update() {  # $1 = install name, $2 = log file; prints the exit code
    local rc=0
    (cd "$TEST_ROOT/$1/FMT-exocortex-template" && PATH="$SHIM_DIR:$PATH" HOME="$FAKE_HOME" \
        IWE_UPDATE_CHANNEL=main bash update.sh --yes) > "$2" 2>&1 || rc=$?
    echo "$rc"
}

echo "--- Scenario L: delivered template copy, legacy substituted base ---"
install_036 l
TPL="$TEST_ROOT/l/FMT-exocortex-template"
RC=$(run_update l "$TEST_ROOT/out-l.log")
[ "$RC" -eq 0 ] && pass "L: update.sh exit 0" || { tail -20 "$TEST_ROOT/out-l.log"; fail "L: exit $RC, expected 0"; }
grep -q '^<<<<<<<' "$TPL/CLAUDE.md" && fail "L: conflict markers in the template copy" \
    || pass "L: no conflict markers in the template copy"
cmp -s "$TPL/CLAUDE.md" "$UPSTREAM/CLAUDE.md" && pass "L: template copy equals the release" \
    || fail "L: template copy differs from the release"
grep -q "$GOV/docs/state-axes-registry.yaml before any non-trivial action (new wording)" "$TEST_ROOT/l/CLAUDE.md" \
    && pass "L: workspace CLAUDE.md carries the new wording with the install's governance repo" \
    || fail "L: workspace CLAUDE.md did not get the new wording"
[ ! -f "$TPL/.update-incomplete" ] && pass "L: no incomplete-update marker" \
    || fail "L: incomplete-update marker left behind"

echo "--- Scenario E: pilot's edit to the template copy, committed by update.sh 0.36 ---"
EDIT_LINE="Pilot's own rule kept in the template copy."
install_036 e "$EDIT_LINE"
RC=$(run_update e "$TEST_ROOT/out-e.log")
cmp -s "$TEST_ROOT/e/FMT-exocortex-template/CLAUDE.md" "$UPSTREAM/CLAUDE.md" \
    && fail "E: the edited copy was replaced by the release" || pass "E: the edited copy was not replaced"
grep -qF "$EDIT_LINE" "$TEST_ROOT/e/FMT-exocortex-template/CLAUDE.md" && pass "E: the pilot's line is still there" \
    || fail "E: the pilot's line is gone (exit $RC)"
grep -q 'не правилась' "$TEST_ROOT/out-e.log" && fail "E: the edited copy was reported as unedited" \
    || pass "E: no «не правилась» claim for an edited copy"

echo "--- Scenario M: template copy left with conflict markers, nothing new published ---"
TPL="$TEST_ROOT/l/FMT-exocortex-template"
printf '<<<<<<< mine\nleft\n=======\nright\n>>>>>>> theirs\n' >> "$TPL/CLAUDE.md"
cp "$TEST_ROOT/l/CLAUDE.md" "$TEST_ROOT/ws-claude-before"
cp "$TEST_ROOT/l/.claude.md.base" "$TEST_ROOT/ws-base-before"
RC=$(run_update l "$TEST_ROOT/out-m.log")
[ "$RC" -eq "$EXIT_CONFLICT" ] && pass "M: update.sh exits $EXIT_CONFLICT (conflict)" \
    || { tail -20 "$TEST_ROOT/out-m.log"; fail "M: exit $RC, expected $EXIT_CONFLICT"; }
grep -q 'Всё актуально' "$TEST_ROOT/out-m.log" && fail "M: reported «Всё актуально» over a conflicted CLAUDE.md" \
    || pass "M: no false «Всё актуально»"
grep -q "$TPL/CLAUDE.md" "$TEST_ROOT/out-m.log" && pass "M: the conflicted file is named" \
    || fail "M: the conflicted file is not named"
cmp -s "$TEST_ROOT/l/CLAUDE.md" "$TEST_ROOT/ws-claude-before" && cmp -s "$TEST_ROOT/l/.claude.md.base" "$TEST_ROOT/ws-base-before" \
    && pass "M: workspace CLAUDE.md and its base untouched" || fail "M: markers carried into the workspace copy or base"
[ -f "$TPL/.update-incomplete" ] && pass "M: incomplete-update marker kept" || fail "M: incomplete-update marker removed"
grep -q 'Обновление завершилось не полностью' "$TEST_ROOT/out-m.log" && pass "M: the incomplete update is reported" \
    || fail "M: the exit trap lost the status and did not report the incomplete update"

echo "--- Scenario T: top-level refusal, a download fails ---"
install_036 t
mv "$UPSTREAM/setup/lib/apply-op.sh" "$TEST_ROOT/apply-op.sh.away"   # listed in the manifest, now a 404
printf '\n' >> "$UPSTREAM/CLAUDE.md"
write_manifest "$UPSTREAM" 0.99.1-test-legacy-base CLAUDE.md
python3 - "$UPSTREAM/update-manifest.json" <<'PY'
import hashlib, json, sys
p = sys.argv[1]
m = json.load(open(p))
m["files"].append({"path": "setup/lib/apply-op.sh", "sha256": hashlib.sha256(b"changed upstream").hexdigest()})
json.dump(m, open(p, "w"))
PY
RC=$(run_update t "$TEST_ROOT/out-t.log")
[ "$RC" -eq "$EXIT_NETWORK" ] && pass "T: refusal keeps its code ($EXIT_NETWORK)" \
    || { tail -20 "$TEST_ROOT/out-t.log"; fail "T: exit $RC, expected $EXIT_NETWORK"; }
grep -q 'прервался на строке' "$TEST_ROOT/out-t.log" && fail "T: a deliberate refusal printed the crash line" \
    || pass "T: no crash line after the deliberate refusal (RT8-3)"

echo
if [ "$FAILS" -gt 0 ]; then
    echo "FAILED: $FAILS check(s)"
    exit 1
fi
echo "PASS: legacy template base, edited copy, conflicted retry, top-level refusal"
