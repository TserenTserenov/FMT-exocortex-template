#!/bin/bash
# test-issue-226.sh — end-to-end smoke test for the 3 update.sh fixes (issue #226)
#
# Runs the REAL update.sh against a sandboxed SCRIPT_DIR/WORKSPACE_DIR, with a
# curl shim serving fixture "upstream" content instead of hitting GitHub.
#
# Scenario A (defect 1 + defect 3): workspace CLAUDE.md conflicts on merge.
#   Assert: hook + memory files still delivered, commit still happens,
#   update.sh exits non-zero (EXIT_CONFLICT=49), branch guard skips commit
#   on a non-default branch.
# Scenario B (defect 2): rerun with SCRIPT_DIR already at upstream version
#   (TOTAL_CHANGES=0) but workspace missing a hook file.
#   Assert: repair-pass fires even on the "всё актуально" early-exit path.
#
# Usage:
#   bash setup/test-update-issue-226.sh
#   KEEP=1 bash setup/test-update-issue-226.sh   # keep /tmp dir for inspection

set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
UPDATE_SH_REAL="$(dirname "$SELF_DIR")/update.sh"
TEST_ROOT="${ISSUE_226_WORKSPACE:-/tmp/iwe-issue-226-test-$$}"
FAKE_HOME="$TEST_ROOT/fake-home"

FAIL_COUNT=0
PASS_COUNT=0
fail() { echo "  ❌ FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
pass() { echo "  ✅ PASS: $*"; PASS_COUNT=$((PASS_COUNT + 1)); }

cleanup() { local rc=$?; [ "${KEEP:-0}" = "1" ] || rm -rf "$TEST_ROOT"; exit "$rc"; }
trap cleanup EXIT INT TERM

mkdir -p "$TEST_ROOT" "$FAKE_HOME"

# ------------------------------------------------------------------
# Fixture: fake "upstream" tree (what curl will serve)
# ------------------------------------------------------------------
UPSTREAM="$TEST_ROOT/upstream"
mkdir -p "$UPSTREAM/.claude/hooks"

cat > "$UPSTREAM/AGENTS.md" <<'EOF'
# Generated agent instructions

registry={{GOVERNANCE_REPO}}/docs/state-axes-registry.yaml
EOF

cat > "$UPSTREAM/CLAUDE.md" <<'EOF'
# Template CLAUDE.md

## 1. Platform section

Upstream v2 content.
EOF

cat > "$UPSTREAM/.claude/hooks/dummy-hook.sh" <<'EOF'
#!/bin/bash
echo "dummy hook v2"
EOF

mkdir -p "$UPSTREAM/memory"
cat > "$UPSTREAM/memory/dummy-memo.md" <<'EOF'
# Dummy memo v2
EOF

python3 -c "
import hashlib
import json
from pathlib import Path

root = Path('$UPSTREAM')
def entry(path):
    return {'path': path, 'sha256': hashlib.sha256((root / path).read_bytes()).hexdigest()}

manifest = {
    'schema_version': 2,
    'version': '0.99.0-test-226',
    'files': [
        entry('CLAUDE.md'),
        entry('AGENTS.md'),
        entry('.claude/hooks/dummy-hook.sh'),
        entry('memory/dummy-memo.md'),
    ],
    'deprecated_files': [],
}
with open('$UPSTREAM/update-manifest.json', 'w') as f:
    json.dump(manifest, f)
"

# ------------------------------------------------------------------
# Fixture: SCRIPT_DIR (local FMT-exocortex-template copy) — "old" state
# ------------------------------------------------------------------
SCRIPT_DIR="$TEST_ROOT/repo/FMT-exocortex-template"
mkdir -p "$SCRIPT_DIR/.claude/hooks" "$SCRIPT_DIR/.claude/lib" "$SCRIPT_DIR/scripts/lib" "$SCRIPT_DIR/memory"
cp "$UPDATE_SH_REAL" "$SCRIPT_DIR/update.sh"
cp "$SELF_DIR/../.claude/lib/frontmatter.sh" "$SCRIPT_DIR/.claude/lib/frontmatter.sh"
cp "$SELF_DIR/../scripts/lib/common.sh" "$SCRIPT_DIR/scripts/lib/common.sh"
chmod +x "$SCRIPT_DIR/update.sh"

cat > "$SCRIPT_DIR/CLAUDE.md" <<'EOF'
# Template CLAUDE.md

## 1. Platform section

Upstream v1 content (old).
EOF
cp "$SCRIPT_DIR/CLAUDE.md" "$SCRIPT_DIR/.claude.md.base"

WORKSPACE_DIR="$TEST_ROOT/repo"
cat > "$WORKSPACE_DIR/.exocortex.env" <<'EOF'
GOVERNANCE_REPO="pilot-governance"
EOF

# Workspace CLAUDE.md: user edited the SAME line the upstream also changed → real conflict
cat > "$WORKSPACE_DIR/CLAUDE.md" <<'EOF'
# Template CLAUDE.md

## 1. Platform section

Upstream v1 content (old).

## 9. My custom section

Pilot's own text, must survive.
EOF
sed_inplace() { sed -i '' "$@" 2>/dev/null || sed -i "$@"; }
sed_inplace 's/Upstream v1 content (old)\./User edited this exact line locally./' "$WORKSPACE_DIR/CLAUDE.md"
cp "$SCRIPT_DIR/CLAUDE.md" "$WORKSPACE_DIR/.claude.md.base"

git -C "$SCRIPT_DIR" init -q
git -C "$SCRIPT_DIR" config user.email t@t; git -C "$SCRIPT_DIR" config user.name t
git -C "$SCRIPT_DIR" add -A; git -C "$SCRIPT_DIR" commit -q -m init
# Simulate the reported scenario: HEAD sits on a contributor PR branch, not main.
git -C "$SCRIPT_DIR" checkout -q -b some-pr-branch

# ------------------------------------------------------------------
# curl shim: intercepts raw.githubusercontent.com/<REPO>/<BRANCH>/<path>
# ------------------------------------------------------------------
SHIM_DIR="$TEST_ROOT/shim"
mkdir -p "$SHIM_DIR"
# WP-546 Ф5 (peer-session 2026-08-21-12, Codex): --help all is written to a
# trace file (SHIM_TRACE), not just answered — Scenario F/G below assert on
# the trace, not just on update.sh's own printed message. A test that only
# checks the message can pass even if the capability-check call itself never
# happened (found live: this exact class of false-coverage is why Scenario
# F/G exist at all — see the долг 1 writeup in report.md of that session).
cat > "$SHIM_DIR/curl" <<SHIMEOF
#!/bin/bash
# WP-546 Ф2 (main 8112b1a) switched update.sh's batch download from one
# "curl -o dest url" per file to a single "curl --parallel -K configfile"
# call (url/output pairs live inside the config file, not argv) — this shim
# originally only understood the single-file shape, so every batch call
# fell through with url="" out="", hit the else branch below and exited 22
# for the WHOLE batch. Found live: 9/19 scenarios in this file failing on
# real CI after that merge (Scenario A/C/E), traced to exactly this gap.
#
# WP-546 Ф5 (peer-session 2026-08-21-12): update.sh:1170-1182's
# curl_supports_parallel_batch() probes "curl --help all" before its first
# download_batch() call — this shim didn't understand that call either,
# fell through the same way (empty url/out -> simulate_one_transfer("","")
# -> exit 22), so the probe always read "not supported" and every scenario
# in this file silently exercised only the sequential fallback path, never
# the parallel one, despite all 19 showing PASS. CURL_SHIM_PARALLEL_SUPPORTED
# (default 1, set by the caller) controls the answer explicitly instead of
# leaving it to shim-internal chance.
simulate_one_transfer() {
    local u="\$1" o="\$2"
    local rel="\${u#*/main/}"
    if [ "\$rel" = "update.sh" ]; then
        cp "$SCRIPT_DIR/update.sh" "\$o"
    elif [ "\$rel" = "update-manifest.json" ]; then
        cp "$UPSTREAM/update-manifest.json" "\$o"
    else
        local src="$UPSTREAM/\$rel"
        # Like real curl -sS -f: the cause goes to stderr (issue #980 reads its last line).
        [ -f "\$src" ] && cp "\$src" "\$o" || { echo "curl: (22) The requested URL returned error: 404" >&2; return 22; }
    fi
}

if [ "\$1" = "--help" ] && [ "\$2" = "all" ]; then
    echo "help-all" >> "${TEST_ROOT}/shim-trace.log"
    if [ "\${CURL_SHIM_PARALLEL_SUPPORTED:-1}" = "1" ]; then
        # Trailing space after each flag matters: real curl's --help all pads
        # with spaces before the description (e.g. " -Z, --parallel   Perform
        # transfers..."), so update.sh:1164's '--parallel[^-]' pattern needs a
        # non-'-' character right after the flag name to match. A bare
        # "--parallel\n" with nothing after it doesn't match — found live,
        # this exact gap made Scenario F below report "not supported" even
        # with CURL_SHIM_PARALLEL_SUPPORTED=1.
        printf -- '  --parallel \\n  --parallel-max <num>\\n  --remove-on-error \\n'
        exit 0
    fi
    printf -- '  -o, --output <file>\\n  -f, --fail\\n'
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
[ -n "\$cfgfile" ] && echo "batch-K" >> "${TEST_ROOT}/shim-trace.log"
[ -n "\$out" ] && [ -z "\$cfgfile" ] && echo "single-o" >> "${TEST_ROOT}/shim-trace.log"

if [ -n "\$cfgfile" ]; then
    # -K batch mode (download_batch()): url/output come in pairs, one per
    # line, no shell metacharacters expected — parsed as plain text, never
    # eval'd. Real curl --parallel --remove-on-error keeps going after one
    # transfer fails and lets the others still land, so a missing upstream
    # file here skips just that pair, not the whole batch (matches
    # simulate_one_transfer's per-file "no source -> no output" contract) —
    # but the shim still reports the batch as failed overall (had_error) if
    # anything in it didn't make it, same as real curl's own exit code.
    had_error=0
    pending_url=""
    # The '|| [ -n LINE ]' guard below: read returns non-zero on the
    # final line of a file with no trailing newline, which would otherwise
    # skip that line's pair entirely and silently under-report a failure —
    # today's config always ends in \n (download_batch's own printf appends
    # it, update.sh) so this doesn't currently fire, but the loop shouldn't
    # quietly depend on that (cold-context review).
    while IFS= read -r line || [ -n "\$line" ]; do
        case "\$line" in
            'url = '*)
                [ -n "\$pending_url" ] && had_error=1  # unpaired url before this one
                pending_url=\$(printf '%s' "\$line" | sed -e 's/^url = "//' -e 's/"\$//')
                ;;
            'output = '*)
                if [ -z "\$pending_url" ]; then
                    had_error=1  # output with no preceding url — malformed pair
                else
                    pending_out=\$(printf '%s' "\$line" | sed -e 's/^output = "//' -e 's/"\$//')
                    simulate_one_transfer "\$pending_url" "\$pending_out" || had_error=1
                    pending_url=""
                fi
                ;;
        esac
    done < "\$cfgfile"
    [ -n "\$pending_url" ] && had_error=1  # trailing url with no output line
    exit "\$had_error"
fi

# Single-file mode (Step 0 self-update, manifest fetch — unchanged).
simulate_one_transfer "\$url" "\$out"
exit \$?
SHIMEOF
chmod +x "$SHIM_DIR/curl"

# ------------------------------------------------------------------
# Scenario A: run update.sh --yes on the non-default branch with a conflict
# ------------------------------------------------------------------
echo "--- Scenario A: CLAUDE.md conflict + non-default branch ---"
HEAD_A_BEFORE=$(git -C "$SCRIPT_DIR" rev-parse HEAD)
set +e
PATH="$SHIM_DIR:$PATH" HOME="$FAKE_HOME" IWE_UPDATE_CHANNEL=main bash "$SCRIPT_DIR/update.sh" --yes > "$TEST_ROOT/out-a.log" 2>&1
RC_A=$?
set -e

if [ "$RC_A" -eq 49 ]; then
    pass "A: update.sh exits with EXIT_CONFLICT(49), not a silent success"
else
    fail "A: expected exit 49, got $RC_A"
fi

if [ -f "$WORKSPACE_DIR/.claude/hooks/dummy-hook.sh" ] && grep -q "v2" "$WORKSPACE_DIR/.claude/hooks/dummy-hook.sh"; then
    pass "A: hook file still delivered to workspace despite CLAUDE.md conflict (defect 1)"
else
    fail "A: hook file was NOT delivered — defect 1 regression"
fi

CLAUDE_SLUG="$(echo "$WORKSPACE_DIR" | tr '/' '-')"
MEM_DST="$FAKE_HOME/.claude/projects/$CLAUDE_SLUG/memory/dummy-memo.md"
mkdir -p "$(dirname "$MEM_DST")"  # this dir must pre-exist for propagation per update.sh's own guard
# re-run only if propagation skipped it because dir didn't exist yet — check log for that path instead
if grep -q "dummy-memo" "$TEST_ROOT/out-a.log"; then
    pass "A: memory file propagation attempted (dummy-memo.md referenced in output)"
else
    fail "A: memory file propagation never attempted"
fi

if grep -q "конфликтов" "$TEST_ROOT/out-a.log"; then
    pass "A: conflict is reported to the user"
else
    fail "A: no conflict message found in output"
fi

if grep -qE "^\s*-\s*/.*CLAUDE\.md$" "$TEST_ROOT/out-a.log"; then
    pass "A: conflicted file path listed in final summary"
else
    fail "A: conflicted file path missing from final summary"
fi

if grep -q "Изменения оставлены незакоммиченными" "$TEST_ROOT/out-a.log"; then
    pass "A: updater explicitly leaves applied files uncommitted"
else
    fail "A: updater did not explain the no-autocommit contract"
fi

if [ "$HEAD_A_BEFORE" = "$(git -C "$SCRIPT_DIR" rev-parse HEAD)" ] && \
   [ -z "$(git -C "$SCRIPT_DIR" diff --cached --name-only)" ]; then
    pass "A: updater created no commit and changed no staged entries"
else
    fail "A: updater changed history or the user's index"
fi

if [ -f "$SCRIPT_DIR/.update-incomplete" ] && grep -q 'Обновление завершилось не полностью' "$TEST_ROOT/out-a.log"; then
    pass "A: conflict leaves an explicit incomplete-update marker"
else
    fail "A: conflict did not preserve/report incomplete update state"
fi

# ------------------------------------------------------------------
# Scenario B: SCRIPT_DIR already at upstream version (TOTAL_CHANGES=0),
# workspace hook file missing (simulates a prior interrupted run).
# ------------------------------------------------------------------
echo "--- Scenario B: repair-pass on the 'всё актуально' path ---"
git -C "$SCRIPT_DIR" checkout -q main 2>/dev/null || git -C "$SCRIPT_DIR" checkout -q -b main
cp "$UPSTREAM/CLAUDE.md" "$SCRIPT_DIR/CLAUDE.md"
cp "$UPSTREAM/AGENTS.md" "$SCRIPT_DIR/AGENTS.md"
cp "$SCRIPT_DIR/CLAUDE.md" "$SCRIPT_DIR/.claude.md.base"
cp "$UPSTREAM/.claude/hooks/dummy-hook.sh" "$SCRIPT_DIR/.claude/hooks/dummy-hook.sh"
cp "$UPSTREAM/memory/dummy-memo.md" "$SCRIPT_DIR/memory/dummy-memo.md"
cp "$UPSTREAM/update-manifest.json" "$SCRIPT_DIR/update-manifest.json"
rm -f "$WORKSPACE_DIR/.claude/hooks/dummy-hook.sh"
rm -f "$WORKSPACE_DIR/AGENTS.md"
# Resolve the workspace CLAUDE.md conflict so it doesn't confuse this scenario
cp "$UPSTREAM/CLAUDE.md" "$WORKSPACE_DIR/CLAUDE.md"
cp "$UPSTREAM/CLAUDE.md" "$WORKSPACE_DIR/.claude.md.base"
git -C "$SCRIPT_DIR" add -A; git -C "$SCRIPT_DIR" commit -q -m "simulate: already at upstream version"

set +e
PATH="$SHIM_DIR:$PATH" HOME="$FAKE_HOME" IWE_UPDATE_CHANNEL=main bash "$SCRIPT_DIR/update.sh" --yes > "$TEST_ROOT/out-b.log" 2>&1
RC_B=$?
set -e

if grep -q "Всё актуально" "$TEST_ROOT/out-b.log"; then
    pass "B: update.sh correctly reports 'всё актуально' (TOTAL_CHANGES=0)"
else
    fail "B: expected 'всё актуально' branch, output was:"; cat "$TEST_ROOT/out-b.log" >&2
fi

if [ -f "$WORKSPACE_DIR/.claude/hooks/dummy-hook.sh" ]; then
    pass "B: missing hook file was repaired even on the early-exit path (defect 2)"
else
    fail "B: hook file was NOT repaired — defect 2 regression (repair-pass unreachable)"
fi

if grep -Fxq 'registry=pilot-governance/docs/state-axes-registry.yaml' "$WORKSPACE_DIR/AGENTS.md" && \
   ! grep -Fq '{{GOVERNANCE_REPO}}' "$WORKSPACE_DIR/AGENTS.md"; then
    pass "B: missing workspace AGENTS.md was repaired with install placeholders resolved"
else
    fail "B: workspace AGENTS.md was not repaired/substituted on TOTAL_CHANGES=0"
fi

if [ "$RC_B" -eq 0 ]; then
    pass "B: exit code 0 (no conflicts in this scenario)"
else
    fail "B: expected exit 0, got $RC_B"
fi

if [ ! -e "$SCRIPT_DIR/.update-incomplete" ]; then
    pass "B: successful recovery removes the incomplete-update marker"
else
    fail "B: incomplete-update marker survived a successful recovery"
fi

# Same repair guarantee on the sibling zero-change branch where one remote
# payload cannot be fetched. The failed path must not suppress local recovery.
echo "--- Scenario B2: repair-pass on incomplete zero-change verification ---"
python3 - "$UPSTREAM/update-manifest.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
manifest = json.loads(path.read_text(encoding="utf-8"))
manifest["files"].append({"path": "missing-payload.md", "sha256": "0" * 64})
path.write_text(json.dumps(manifest), encoding="utf-8")
PY
rm -f "$WORKSPACE_DIR/AGENTS.md"
set +e
PATH="$SHIM_DIR:$PATH" HOME="$FAKE_HOME" IWE_UPDATE_CHANNEL=main \
    bash "$SCRIPT_DIR/update.sh" --yes > "$TEST_ROOT/out-b2.log" 2>&1
RC_B2=$?
set -e
if [ "$RC_B2" -eq 0 ] && grep -q 'Проверка неполная' "$TEST_ROOT/out-b2.log" && \
   grep -Fxq 'registry=pilot-governance/docs/state-axes-registry.yaml' "$WORKSPACE_DIR/AGENTS.md"; then
    pass "B2: incomplete remote verification still repairs workspace AGENTS.md"
else
    fail "B2: skipped download suppressed AGENTS recovery (rc=$RC_B2)"
fi
python3 - "$UPSTREAM/update-manifest.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
manifest = json.loads(path.read_text(encoding="utf-8"))
manifest["files"] = [entry for entry in manifest["files"] if entry["path"] != "missing-payload.md"]
path.write_text(json.dumps(manifest), encoding="utf-8")
PY

# ------------------------------------------------------------------
# Scenario C: same version and paths, changed content hash.
# --check --fast must detect it; full check must reject a bad payload hash.
# ------------------------------------------------------------------
echo "--- Scenario C: manifest content hashes (#378) ---"
printf '#!/bin/bash\necho "dummy hook v3"\n' > "$UPSTREAM/.claude/hooks/dummy-hook.sh"
python3 - "$UPSTREAM/update-manifest.json" "$UPSTREAM/.claude/hooks/dummy-hook.sh" <<'PY'
import hashlib
import json
import sys

manifest_path, content_path = sys.argv[1:]
with open(manifest_path, encoding="utf-8") as handle:
    manifest = json.load(handle)
digest = hashlib.sha256(open(content_path, "rb").read()).hexdigest()
for entry in manifest["files"]:
    if entry["path"] == ".claude/hooks/dummy-hook.sh":
        entry["sha256"] = digest
with open(manifest_path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle)
PY

PATH="$SHIM_DIR:$PATH" HOME="$FAKE_HOME" IWE_UPDATE_CHANNEL=main bash "$SCRIPT_DIR/update.sh" --check --fast > "$TEST_ROOT/out-c-fast.log" 2>&1
if grep -q "Состав манифеста изменился" "$TEST_ROOT/out-c-fast.log"; then
    pass "C: --check --fast detects a content-only change at the same version/path"
else
    fail "C: --check --fast missed a content-only manifest change"
fi

python3 - "$UPSTREAM/update-manifest.json" <<'PY'
import json
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    manifest = json.load(handle)
for entry in manifest["files"]:
    if entry["path"] == ".claude/hooks/dummy-hook.sh":
        entry["sha256"] = "0" * 64
with open(path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle)
PY

PATH="$SHIM_DIR:$PATH" HOME="$FAKE_HOME" IWE_UPDATE_CHANNEL=main bash "$SCRIPT_DIR/update.sh" --check > "$TEST_ROOT/out-c-integrity.log" 2>&1 || true
if grep -q "sha256 не совпадает" "$TEST_ROOT/out-c-integrity.log" && \
   grep -q "Проверка неполная" "$TEST_ROOT/out-c-integrity.log"; then
    pass "C: full check rejects a downloaded file that does not match manifest sha256"
else
    fail "C: payload integrity mismatch was not surfaced as an incomplete check"
fi

# ------------------------------------------------------------------
# Scenario D: owner:user drift is reported even when no file is in the
# current NEW_FILES/UPDATED_FILES list (#375).
# ------------------------------------------------------------------
echo "--- Scenario D: owner:user memory drift (#375) ---"
# Restore a valid, unchanged remote manifest/payload first.
cp "$UPSTREAM/.claude/hooks/dummy-hook.sh" "$SCRIPT_DIR/.claude/hooks/dummy-hook.sh"
python3 - "$UPSTREAM/update-manifest.json" "$UPSTREAM" <<'PY'
import hashlib
import json
import pathlib
import sys
manifest_path, root = sys.argv[1:]
with open(manifest_path, encoding="utf-8") as handle:
    manifest = json.load(handle)
for entry in manifest["files"]:
    entry["sha256"] = hashlib.sha256((pathlib.Path(root) / entry["path"]).read_bytes()).hexdigest()
with open(manifest_path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle)
PY
cp "$UPSTREAM/update-manifest.json" "$SCRIPT_DIR/update-manifest.json"
mkdir -p "$(dirname "$MEM_DST")"
cat > "$MEM_DST" <<'EOF'
---
owner: user
---
Pilot-owned content that intentionally differs.
EOF

PATH="$SHIM_DIR:$PATH" HOME="$FAKE_HOME" IWE_UPDATE_CHANNEL=main bash "$SCRIPT_DIR/update.sh" --yes > "$TEST_ROOT/out-d.log" 2>&1 || true
if grep -q "owner: user, НЕ обновлён, но шаблонная версия отличается" "$TEST_ROOT/out-d.log" && \
   grep -q 'Сверьте: diff' "$TEST_ROOT/out-d.log"; then
    pass "D: owner:user drift is visible with a comparison command on an unchanged run"
else
    fail "D: owner:user drift remained silent outside the changed-files list"
fi
# The install above has no classifier script: the report must stay generic (verdict unknown)
# and must not claim to know where the copy came from.
if grep -qE "совпадает с версией из git-истории|не совпадает ни с одной закоммиченной" "$TEST_ROOT/out-d.log"; then
    fail "D: a verdict was claimed although the install has no classifier"
else
    pass "D: without the classifier the report claims no verdict (unknown)"
fi

# ------------------------------------------------------------------
# Scenario D2 (#965/#967): with the shipped classifier the drift report says WHY a copy
# differs — a copy equal to a committed version of the file, one equal to none, or an
# undecidable history — instead of one generic line for all three. The classifier compares
# the copy only with the versions COMMITTED in the template clone, so the report promises
# no more than that (the cases below, D3 and D4, pin the two ways the verdicts can mislead).
# ------------------------------------------------------------------
echo "--- Scenario D2: owner:user drift verdicts — committed version / no committed version / unknown (#965 #967) ---"
D2_COMMITTED_TEXT='совпадает с версией из git-истории клона шаблона; если вы коммитили свои правки в клон, это могут быть и они'
D2_UNCOMMITTED_TEXT='не совпадает ни с одной закоммиченной в клоне версией (ваши правки или уже применённый прошлый релиз)'
cp "$UPSTREAM/memory/dummy-memo.md" "$TEST_ROOT/memo-upstream.txt"
mkdir -p "$SCRIPT_DIR/.claude/scripts"
cp "$SELF_DIR/../.claude/scripts/classify-workspace-copy.sh" "$SCRIPT_DIR/.claude/scripts/classify-workspace-copy.sh"
# A second owner:user file that no commit of the template ever touched: verdict unknown.
printf '# Untracked memo\n' > "$UPSTREAM/memory/untracked-memo.md"
cp "$UPSTREAM/memory/untracked-memo.md" "$SCRIPT_DIR/memory/untracked-memo.md"
printf -- '---\nowner: user\n---\nPilot copy of the untracked memo\n' > "$(dirname "$MEM_DST")/untracked-memo.md"
d2_untracked_entry() {
    python3 - "$UPSTREAM/update-manifest.json" "$UPSTREAM" "$1" <<'PY'
import hashlib
import json
import pathlib
import sys
manifest_path, root, mode = sys.argv[1:]
with open(manifest_path, encoding="utf-8") as handle:
    manifest = json.load(handle)
name = "memory/untracked-memo.md"
manifest["files"] = [entry for entry in manifest["files"] if entry["path"] != name]
if mode == "add":
    manifest["files"].append({"path": name, "sha256": hashlib.sha256((pathlib.Path(root) / name).read_bytes()).hexdigest()})
with open(manifest_path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle)
PY
}
# d2_memo_sha — the manifest entry of memory/dummy-memo.md follows the upstream file again.
d2_memo_sha() {
    python3 - "$UPSTREAM/update-manifest.json" "$UPSTREAM" <<'PY'
import hashlib
import json
import pathlib
import sys
manifest_path, root = sys.argv[1:]
with open(manifest_path, encoding="utf-8") as handle:
    manifest = json.load(handle)
for entry in manifest["files"]:
    if entry["path"] == "memory/dummy-memo.md":
        entry["sha256"] = hashlib.sha256((pathlib.Path(root) / entry["path"]).read_bytes()).hexdigest()
with open(manifest_path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle)
PY
}
# d2_run_update LOG — the real update.sh --yes; its exit code is not the point here.
d2_run_update() {
    PATH="$SHIM_DIR:$PATH" HOME="$FAKE_HOME" IWE_UPDATE_CHANNEL=main bash "$SCRIPT_DIR/update.sh" --yes > "$TEST_ROOT/$1" 2>&1 || true
}
# d2_commit_memo SOURCE MESSAGE — the clone's memory/dummy-memo.md becomes SOURCE, committed.
d2_commit_memo() {
    cp "$1" "$SCRIPT_DIR/memory/dummy-memo.md"
    git -C "$SCRIPT_DIR" add memory/dummy-memo.md
    git -C "$SCRIPT_DIR" commit -q -m "$2"
}
# d2_hint_of LOG TEXT — the command printed on the line after the report line that carries TEXT.
d2_hint_of() {
    local line
    line=$(grep -A1 -F "$2" "$TEST_ROOT/$1" | tail -1)
    printf '%s\n' "${line#*: }"
}
# d2_check_save_hint LOG TEXT BEFORE LABEL — the offered command, run as printed, must keep the
# current copy (BEFORE) in MEM_DST.before-update and then make MEM_DST the template's file.
d2_check_save_hint() {
    local hint
    hint=$(d2_hint_of "$1" "$2")
    rm -f "$MEM_DST.before-update"
    bash -c "$hint" > /dev/null 2>&1 || true
    if [ -f "$MEM_DST.before-update" ] && [ "$(cat "$MEM_DST.before-update")" = "$3" ] \
        && cmp -s "$MEM_DST" "$SCRIPT_DIR/memory/dummy-memo.md"; then
        pass "$4: the offered command saves the current copy to .before-update, then refreshes it"
    else
        fail "$4: the offered command ('${hint:-<none>}') did not save the current copy before replacing it"
    fi
    rm -f "$MEM_DST.before-update"
}
d2_untracked_entry add

d2_run_update out-d-authored.log
if grep -qF "memory/dummy-memo.md — owner: user, НЕ обновлён: $D2_UNCOMMITTED_TEXT" "$TEST_ROOT/out-d-authored.log" && \
   grep -q 'Сверьте: diff' "$TEST_ROOT/out-d-authored.log"; then
    pass "D2: a copy that equals no committed version is reported with both possible causes, and a diff command"
else
    fail "D2: no verdict for the copy that equals no committed version: $(grep -n 'dummy-memo' "$TEST_ROOT/out-d-authored.log" | head -3 | tr '\n' ' ')"
fi
if grep -q "вероятно, ваши правки" "$TEST_ROOT/out-d-authored.log"; then
    fail "D2: the report still blames the pilot's edits without naming the other cause"
else
    pass "D2: the report no longer says 'probably your edits' on its own"
fi
if grep -q "memory/untracked-memo.md — owner: user, НЕ обновлён, но шаблонная версия отличается" "$TEST_ROOT/out-d-authored.log"; then
    pass "D2: an undecidable history (verdict unknown) keeps the generic text"
else
    fail "D2: the unknown verdict did not keep the generic text: $(grep -n 'untracked-memo' "$TEST_ROOT/out-d-authored.log" | head -3 | tr '\n' ' ')"
fi
if grep -q "owner:user memory drift: 2 файл" "$TEST_ROOT/out-d-authored.log"; then
    pass "D2: the drift summary still counts every differing file"
else
    fail "D2: the drift summary lost its count"
fi

# The deployed copy equals an OLDER version from the template history.
printf -- '---\nowner: user\n---\nOlder template text of the memo\n' > "$TEST_ROOT/memo-older.txt"
d2_commit_memo "$TEST_ROOT/memo-older.txt" "history: an older memo"
d2_commit_memo "$TEST_ROOT/memo-upstream.txt" "history: memo back to the upstream text"
cp "$TEST_ROOT/memo-older.txt" "$MEM_DST"

d2_run_update out-d-stale.log
if grep -qF "memory/dummy-memo.md — owner: user, НЕ обновлён: $D2_COMMITTED_TEXT" "$TEST_ROOT/out-d-stale.log"; then
    pass "D2: a copy that equals a committed version is reported as such, with the pilot's-own-commit caveat"
else
    fail "D2: no verdict for the copy that equals an older committed version: $(grep -n 'dummy-memo' "$TEST_ROOT/out-d-stale.log" | head -3 | tr '\n' ' ')"
fi
d2_check_save_hint out-d-stale.log "memory/dummy-memo.md — owner: user, НЕ обновлён: $D2_COMMITTED_TEXT" "$(cat "$TEST_ROOT/memo-older.txt")" "D2"
if grep -q "не совпадает ни с одной закоммиченной" "$TEST_ROOT/out-d-stale.log"; then
    fail "D2: a copy that equals a committed version was reported as equal to none"
else
    pass "D2: a copy that equals a committed version is not reported as equal to none"
fi

# ------------------------------------------------------------------
# Scenario D3: the same verdict, but the committed version IS the pilot's own edit — a fork
# with local commits (#963) keeps it in the clone's history. "Equals a committed version"
# proves nothing about who wrote it, so the report must not promise "no edits found", and the
# command it offers must save the copy before it replaces it.
# ------------------------------------------------------------------
echo "--- Scenario D3: a committed version can be the pilot's own edit (cold review of #965/#967) ---"
printf -- '---\nowner: user\n---\nPilot notes committed into the clone\n' > "$TEST_ROOT/memo-pilot.txt"
d2_commit_memo "$TEST_ROOT/memo-pilot.txt" "pilot: my notes in the memo"
d2_commit_memo "$TEST_ROOT/memo-upstream.txt" "history: memo back to the upstream text"
cp "$TEST_ROOT/memo-pilot.txt" "$MEM_DST"

d2_run_update out-d-committed.log
if grep -q "ваших правок не найдено" "$TEST_ROOT/out-d-committed.log"; then
    fail "D3: the report promises 'no edits found' for a copy that is the pilot's own committed edit"
else
    pass "D3: the report does not promise 'no edits found'"
fi
if grep -qF "memory/dummy-memo.md — owner: user, НЕ обновлён: $D2_COMMITTED_TEXT" "$TEST_ROOT/out-d-committed.log"; then
    pass "D3: the report says the match may be the pilot's own committed edit"
else
    fail "D3: the pilot's-own-commit caveat is missing: $(grep -n 'dummy-memo' "$TEST_ROOT/out-d-committed.log" | head -3 | tr '\n' ' ')"
fi
d2_check_save_hint out-d-committed.log "memory/dummy-memo.md — owner: user, НЕ обновлён: $D2_COMMITTED_TEXT" "$(cat "$TEST_ROOT/memo-pilot.txt")" "D3"

# ------------------------------------------------------------------
# Scenario D4: the copy equals no committed version, yet the pilot edited nothing. update.sh
# applies a release to the clone WITHOUT committing it, so after the pilot copied release one
# into the memory directory (the cp the report suggests) and release two arrived, the copy
# is release one — which exists in no commit of the clone.
# ------------------------------------------------------------------
echo "--- Scenario D4: an applied earlier release is not blamed on the pilot (cold review of #965/#967) ---"
printf -- '---\nowner: user\n---\nRelease one text of the memo\n' > "$MEM_DST"
printf -- '---\nowner: user\n---\nRelease two text of the memo\n' > "$UPSTREAM/memory/dummy-memo.md"
cp "$UPSTREAM/memory/dummy-memo.md" "$SCRIPT_DIR/memory/dummy-memo.md"
d2_memo_sha

d2_run_update out-d-release.log
if grep -qF "memory/dummy-memo.md — owner: user, НЕ обновлён: $D2_UNCOMMITTED_TEXT" "$TEST_ROOT/out-d-release.log"; then
    pass "D4: the report names an already applied earlier release as a possible cause"
else
    fail "D4: the earlier-release cause is missing: $(grep -n 'dummy-memo' "$TEST_ROOT/out-d-release.log" | head -3 | tr '\n' ' ')"
fi
if grep -q "вероятно, ваши правки" "$TEST_ROOT/out-d-release.log"; then
    fail "D4: the report says 'probably your edits' for an unedited copy of an earlier release"
else
    pass "D4: the report does not say 'probably your edits'"
fi
# Back to the state the next scenarios expect: the clone and the upstream carry the committed text.
cp "$TEST_ROOT/memo-upstream.txt" "$UPSTREAM/memory/dummy-memo.md"
cp "$TEST_ROOT/memo-upstream.txt" "$SCRIPT_DIR/memory/dummy-memo.md"
d2_memo_sha

d2_untracked_entry remove
rm -f "$UPSTREAM/memory/untracked-memo.md" "$SCRIPT_DIR/memory/untracked-memo.md" "$(dirname "$MEM_DST")/untracked-memo.md"

# ------------------------------------------------------------------
# Scenario E: a genuine change (memo v2 → v3) lands alongside a manifest
# entry whose fetch fails (WP-529 Ф2). Before this fix, TOTAL_CHANGES>0
# meant the run applied the fetched files and stamped the local manifest as
# fully updated, leaving the failed file silently on the old version.
# ------------------------------------------------------------------
echo "--- Scenario E: partial fetch failure must abort, not partially apply (WP-529) ---"
printf '# Dummy memo v3\n' > "$UPSTREAM/memory/dummy-memo.md"
python3 - "$UPSTREAM/update-manifest.json" "$UPSTREAM" <<'PY'
import hashlib
import json
import pathlib
import sys
manifest_path, root = sys.argv[1:]
with open(manifest_path, encoding="utf-8") as handle:
    manifest = json.load(handle)
for entry in manifest["files"]:
    if entry["path"] == "memory/dummy-memo.md":
        entry["sha256"] = hashlib.sha256(
            (pathlib.Path(root) / entry["path"]).read_bytes()
        ).hexdigest()
# A manifest entry with no matching file under $UPSTREAM — the curl shim
# exits 22 for it, landing it in SKIPPED_DOWNLOAD.
manifest["files"].append({"path": "memory/never-fetched.md", "sha256": "0" * 64})
with open(manifest_path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle)
PY
MEMO_BEFORE=$(cat "$SCRIPT_DIR/memory/dummy-memo.md")
MANIFEST_HASH_BEFORE=$(sha256sum "$SCRIPT_DIR/update-manifest.json" | cut -d' ' -f1)

set +e
PATH="$SHIM_DIR:$PATH" HOME="$FAKE_HOME" IWE_UPDATE_CHANNEL=main bash "$SCRIPT_DIR/update.sh" --yes > "$TEST_ROOT/out-e.log" 2>&1
RC_E=$?
set -e

if [ "$RC_E" -eq 2 ]; then
    pass "E: update.sh exits with EXIT_NETWORK(2) on a partial fetch failure"
else
    fail "E: expected exit 2, got $RC_E"
fi

if grep -q "Обновление остановлено" "$TEST_ROOT/out-e.log"; then
    pass "E: abort is reported to the user with a clear reason"
else
    fail "E: no abort message found in output"
fi

if [ "$(cat "$SCRIPT_DIR/memory/dummy-memo.md")" = "$MEMO_BEFORE" ]; then
    pass "E: the file that WOULD have changed was left untouched (no partial apply)"
else
    fail "E: dummy-memo.md was updated despite the aborted run — partial apply regression"
fi

if [ "$(sha256sum "$SCRIPT_DIR/update-manifest.json" | cut -d' ' -f1)" = "$MANIFEST_HASH_BEFORE" ]; then
    pass "E: local update-manifest.json was not stamped as updated"
else
    fail "E: local manifest changed despite the aborted run"
fi

# issue #980: the failed transfer used to be silent (curl's stderr went to /dev/null).
# Now the batch call's exit code and the last line of its stderr are shown.
if grep -q "curl код [0-9][0-9]*; curl: (22) The requested URL returned error: 404" "$TEST_ROOT/out-e.log"; then
    pass "E: a failed batch download shows curl's exit code and its last stderr line"
else
    fail "E: the failed batch download left no curl diagnostic in the output"
fi

echo "--- Scenario E2: the sequential fallback names the file and curl's cause (#980) ---"
set +e
CURL_SHIM_PARALLEL_SUPPORTED=0 PATH="$SHIM_DIR:$PATH" HOME="$FAKE_HOME" IWE_UPDATE_CHANNEL=main bash "$SCRIPT_DIR/update.sh" --yes > "$TEST_ROOT/out-e2.log" 2>&1
RC_E2=$?
set -e
if [ "$RC_E2" -eq 2 ]; then
    pass "E2: the sequential path also aborts with EXIT_NETWORK(2) on a failed fetch"
else
    fail "E2: expected exit 2, got $RC_E2"
fi
if grep -q "memory/never-fetched.md: curl код 22; curl: (22) The requested URL returned error: 404" "$TEST_ROOT/out-e2.log"; then
    pass "E2: the failed file is named together with curl's exit code and stderr line"
else
    fail "E2: the sequential failure left no per-file curl diagnostic"
fi

# A dead network must not print one line per manifest entry: the first 5 failures of a
# call are shown, the rest are counted. Seven failing files, two passes (first + retry).
echo "--- Scenario E3: sequential diagnostics are capped at 5 per call (#980) ---"
# e3_extra_entries add|remove — six more manifest entries that the shim cannot serve.
e3_extra_entries() {
    python3 - "$UPSTREAM/update-manifest.json" "$1" <<'PY'
import json
import sys
path, mode = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    manifest = json.load(handle)
extra = [f"memory/never-fetched-{number}.md" for number in range(1, 7)]
manifest["files"] = [entry for entry in manifest["files"] if entry["path"] not in extra]
if mode == "add":
    manifest["files"] += [{"path": name, "sha256": "0" * 64} for name in extra]
with open(path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle)
PY
}
e3_extra_entries add
set +e
CURL_SHIM_PARALLEL_SUPPORTED=0 PATH="$SHIM_DIR:$PATH" HOME="$FAKE_HOME" IWE_UPDATE_CHANNEL=main bash "$SCRIPT_DIR/update.sh" --yes > "$TEST_ROOT/out-e3.log" 2>&1
set -e
E3_SHOWN=$(grep -c "curl код 22" "$TEST_ROOT/out-e3.log" || true)
E3_COUNTED=$(grep -c "ещё 2 сбоев загрузки не показано" "$TEST_ROOT/out-e3.log" || true)
if [ "$E3_SHOWN" -eq 10 ] && [ "$E3_COUNTED" -eq 2 ]; then
    pass "E3: 5 diagnostics per call are shown and the other 2 are counted (first pass and retry)"
else
    fail "E3: expected 10 shown diagnostics and 2 counter lines, got $E3_SHOWN and $E3_COUNTED"
fi
e3_extra_entries remove

# ------------------------------------------------------------------
# Scenario F/G (WP-546 Ф5, peer-session 2026-08-21-12): assert that
# curl_supports_parallel_batch()'s capability-check actually drives which
# transport update.sh uses — not just that the printed message matches,
# which a shim answering "not supported" for every run would satisfy
# trivially (found live: this exact gap made all 19 scenarios in this file
# silently exercise only the sequential fallback for weeks). Assertions
# read $TEST_ROOT/shim-trace.log, written by the shim itself on every call,
# not update.sh's own stdout — a stronger signal than a message string.
# ------------------------------------------------------------------
echo "--- Scenario F: capability-check reports supported -> parallel batch path used ---"
printf '# Dummy memo v4\n' > "$UPSTREAM/memory/dummy-memo.md"
python3 -c "
import hashlib, json
from pathlib import Path
manifest_path = '$UPSTREAM/update-manifest.json'
with open(manifest_path) as f:
    manifest = json.load(f)
for entry in manifest['files']:
    if entry['path'] == 'memory/dummy-memo.md':
        entry['sha256'] = hashlib.sha256((Path('$UPSTREAM') / entry['path']).read_bytes()).hexdigest()
manifest['files'] = [e for e in manifest['files'] if e['path'] != 'memory/never-fetched.md']
with open(manifest_path, 'w') as f:
    json.dump(manifest, f)
"
rm -f "$TEST_ROOT/shim-trace.log"
CURL_SHIM_PARALLEL_SUPPORTED=1 PATH="$SHIM_DIR:$PATH" HOME="$FAKE_HOME" IWE_UPDATE_CHANNEL=main bash "$SCRIPT_DIR/update.sh" --yes > "$TEST_ROOT/out-f.log" 2>&1
RC_F=$?

if [ "$RC_F" -eq 0 ]; then
    pass "F: update.sh exits 0 when curl supports the parallel batch options"
else
    fail "F: expected exit 0, got $RC_F"; cat "$TEST_ROOT/out-f.log" >&2
fi

if grep -q "^help-all$" "$TEST_ROOT/shim-trace.log" 2>/dev/null; then
    pass "F: the capability-check call (curl --help all) actually happened"
else
    fail "F: no help-all trace entry — capability-check was never invoked"
fi

if grep -q "^batch-K$" "$TEST_ROOT/shim-trace.log" 2>/dev/null; then
    pass "F: the parallel batch transport (-K config mode) was actually used"
else
    fail "F: no batch-K trace entry — download did not use the parallel path"
fi

if grep -q "до 8 параллельно" "$TEST_ROOT/out-f.log"; then
    pass "F: the printed message matches the parallel path"
else
    fail "F: expected the parallel-mode message, output was:"; cat "$TEST_ROOT/out-f.log" >&2
fi

echo "--- Scenario G: capability-check reports unsupported -> sequential fallback used ---"
printf '# Dummy memo v5\n' > "$UPSTREAM/memory/dummy-memo.md"
python3 -c "
import hashlib, json
from pathlib import Path
manifest_path = '$UPSTREAM/update-manifest.json'
with open(manifest_path) as f:
    manifest = json.load(f)
for entry in manifest['files']:
    if entry['path'] == 'memory/dummy-memo.md':
        entry['sha256'] = hashlib.sha256((Path('$UPSTREAM') / entry['path']).read_bytes()).hexdigest()
with open(manifest_path, 'w') as f:
    json.dump(manifest, f)
"
rm -f "$TEST_ROOT/shim-trace.log"
CURL_SHIM_PARALLEL_SUPPORTED=0 PATH="$SHIM_DIR:$PATH" HOME="$FAKE_HOME" IWE_UPDATE_CHANNEL=main bash "$SCRIPT_DIR/update.sh" --yes > "$TEST_ROOT/out-g.log" 2>&1
RC_G=$?

if [ "$RC_G" -eq 0 ]; then
    pass "G: update.sh exits 0 on the sequential fallback path too"
else
    fail "G: expected exit 0, got $RC_G"; cat "$TEST_ROOT/out-g.log" >&2
fi

if grep -q "^help-all$" "$TEST_ROOT/shim-trace.log" 2>/dev/null; then
    pass "G: the capability-check call happened here too"
else
    fail "G: no help-all trace entry"
fi

if ! grep -q "^batch-K$" "$TEST_ROOT/shim-trace.log" 2>/dev/null; then
    pass "G: the parallel batch transport was NOT used"
else
    fail "G: batch-K trace entry present — fallback did not actually engage"
fi

if grep -q "^single-o$" "$TEST_ROOT/shim-trace.log" 2>/dev/null; then
    pass "G: individual sequential transfers were actually made"
else
    fail "G: no single-o trace entries — sequential fallback made no transfers at all"
fi

if grep -q "последовательно" "$TEST_ROOT/out-g.log" && ! grep -q "до 8 параллельно" "$TEST_ROOT/out-g.log"; then
    pass "G: the printed message matches the sequential path"
else
    fail "G: expected the sequential-mode message, output was:"; cat "$TEST_ROOT/out-g.log" >&2
fi

# ------------------------------------------------------------------
# Scenario I (#967): Step 6 used to replace a changed platform memory file with a bare
# cp — a pilot's edit to e.g. memory/navigation.md vanished with no backup and no word.
# Now the previous version is saved first and the replaced files are named.
# ------------------------------------------------------------------
echo "--- Scenario I: Step 6 backs up a modified platform memory file (#967) ---"
printf '# Dummy memo v6\n' > "$UPSTREAM/memory/dummy-memo.md"
python3 - "$UPSTREAM/update-manifest.json" "$UPSTREAM" <<'PY'
import hashlib
import json
import pathlib
import sys
manifest_path, root = sys.argv[1:]
with open(manifest_path, encoding="utf-8") as handle:
    manifest = json.load(handle)
for entry in manifest["files"]:
    if entry["path"] == "memory/dummy-memo.md":
        entry["sha256"] = hashlib.sha256((pathlib.Path(root) / entry["path"]).read_bytes()).hexdigest()
with open(manifest_path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle)
PY
printf -- '---\nowner: platform\n---\n# Dummy memo v5\nPilot edit: notes about this installation\n' > "$MEM_DST"
set +e
PATH="$SHIM_DIR:$PATH" HOME="$FAKE_HOME" IWE_UPDATE_CHANNEL=main bash "$SCRIPT_DIR/update.sh" --yes > "$TEST_ROOT/out-i.log" 2>&1
RC_I=$?
set -e
if [ "$RC_I" -eq 0 ]; then
    pass "I: update.sh exits 0 when it replaces a platform memory file"
else
    fail "I: expected exit 0, got $RC_I; tail: $(tail -3 "$TEST_ROOT/out-i.log" | tr '\n' ' ')"
fi
I_BACKUP=$(grep -rl 'Pilot edit: notes about this installation' "$WORKSPACE_DIR/.backups/memory-pre-update" 2>/dev/null | head -1 || true)
if [ -n "$I_BACKUP" ] && [ "$(basename "$I_BACKUP")" = "dummy-memo.md" ]; then
    pass "I: the pilot's version is saved under .backups/memory-pre-update/ before Step 6 replaces it"
else
    fail "I: no backup of the pilot's memory edit (found: ${I_BACKUP:-none})"
fi
if cmp -s "$MEM_DST" "$UPSTREAM/memory/dummy-memo.md"; then
    pass "I: the memory file now carries the release version"
else
    fail "I: the memory file was not replaced with the release version"
fi
I_SUMMARY=$(grep -F 'Заменено файлов памяти платформы' "$TEST_ROOT/out-i.log" || true)
if grep -qF -- 'Заменено файлов памяти платформы: 1' <<<"$I_SUMMARY" && \
   grep -qF -- 'memory/dummy-memo.md' <<<"$I_SUMMARY" && \
   grep -qF -- "$WORKSPACE_DIR/.backups/memory-pre-update" <<<"$I_SUMMARY"; then
    pass "I: the run names the replaced file and where the previous version went"
else
    fail "I: no replaced-files summary with the backup directory: '${I_SUMMARY:-<none>}'"
fi

# ------------------------------------------------------------------
# Scenario H (WP-546 Ф5, peer-session 2026-08-21-12, Codex): the grep-only
# fallback parser (no Python) fails closed on a compact manifest — two or
# more "path" keys sharing one physical line — instead of the old behavior
# of silently extracting only the FIRST match on that line and losing every
# other entry with no signal at all. NO_PY_DIR shadows python3/python ahead
# of SHIM_DIR so py_available() genuinely returns false (a bare "not in
# SHIM_DIR" isn't enough — the real python3 elsewhere on the test runner's
# PATH would still be found).
# ------------------------------------------------------------------
echo "--- Scenario H: fallback parser fails closed on a compact/minified manifest (High 2) ---"
NO_PY_DIR="$TEST_ROOT/no-python"
mkdir -p "$NO_PY_DIR"
for stub in python3 python py; do
    cat > "$NO_PY_DIR/$stub" <<'STUBEOF'
#!/bin/bash
exit 127
STUBEOF
    chmod +x "$NO_PY_DIR/$stub"
done

# A manifest with two "path" keys on one physical line — the exact shape
# the old single-match-per-line sed would have silently mishandled.
cat > "$UPSTREAM/update-manifest.json" <<'EOF'
{"schema_version": 2, "version": "0.99.0-test-226", "files": [{"path": "CLAUDE.md", "sha256": "0"}, {"path": "memory/dummy-memo.md", "sha256": "0"}], "deprecated_files": []}
EOF

rm -f "$TEST_ROOT/shim-trace.log"
set +e
PATH="$NO_PY_DIR:$SHIM_DIR:$PATH" HOME="$FAKE_HOME" IWE_UPDATE_CHANNEL=main bash "$SCRIPT_DIR/update.sh" --check > "$TEST_ROOT/out-h.log" 2>&1
RC_H=$?
set -e

if [ "$RC_H" -eq 3 ]; then
    pass "H: update.sh exits with EXIT_RUNTIME(3) on a compact manifest without Python"
else
    fail "H: expected exit 3, got $RC_H"; cat "$TEST_ROOT/out-h.log" >&2
fi

if grep -q "компактном/минифицированном формате" "$TEST_ROOT/out-h.log"; then
    pass "H: the compact-format guard message is shown"
else
    fail "H: no compact-format guard message, output was:"; cat "$TEST_ROOT/out-h.log" >&2
fi

# WP-529 F26: the no-Python degradation used to announce itself with a single
# line lost among dozens of others — a user learned that integrity was never
# checked only from exit code 4, if they looked at it at all. The run above
# already goes through that exact branch, so assert the framed warning and its
# consequences here rather than building a second fixture for it.
if grep -q "ОБНОВЛЕНИЕ БЕЗ ПРОВЕРКИ ЦЕЛОСТНОСТИ" "$TEST_ROOT/out-h.log"; then
    pass "H: the no-Python degradation is announced with a visible framed banner"
else
    fail "H: framed integrity warning missing, output was:"; cat "$TEST_ROOT/out-h.log" >&2
fi

if grep -q "установите python3" "$TEST_ROOT/out-h.log"; then
    pass "H: the warning tells the user how to restore full verification"
else
    fail "H: the warning does not say how to restore full verification"
fi

if grep -q "кодом 4" "$TEST_ROOT/out-h.log"; then
    pass "H: the warning explains that exit code 4 marks an unverified run"
else
    fail "H: the warning does not explain the meaning of exit code 4"
fi

if grep -q "Не удалось разобрать манифест" "$TEST_ROOT/out-h.log"; then
    fail "H: wrong error path — hit the Python-parser failure message, not the fallback guard"
else
    pass "H: the fallback-specific guard fired, not the Python-parser error path"
fi

# Regression guard: a normally-formatted (one "path" per line, matching
# this repo's own manifest-generator layout — see update.sh:1116's
# PATH_LINE_RE for the exact grammar) manifest must still parse under the
# same no-Python PATH — the compact-format check must not become a blanket
# "no Python -> fail" rule. The fixture below deliberately mirrors the real
# generator's one-field-per-line shape, not a hand-written {"path": ...}
# single-line object — that latter shape is itself unsupported (see
# Scenario H's single-file negative case further down) and would make this
# "regression guard" silently test the wrong thing.
cat > "$UPSTREAM/update-manifest.json" <<'EOF'
{
  "schema_version": 2,
  "version": "0.99.0-test-226",
  "files": [
    {
      "path": "CLAUDE.md",
      "sha256": "0"
    },
    {
      "path": "memory/dummy-memo.md",
      "sha256": "0"
    }
  ],
  "deprecated_files": []
}
EOF
set +e
PATH="$NO_PY_DIR:$SHIM_DIR:$PATH" HOME="$FAKE_HOME" IWE_UPDATE_CHANNEL=main bash "$SCRIPT_DIR/update.sh" --check > "$TEST_ROOT/out-h-normal.log" 2>&1
RC_H_NORMAL=$?
set -e

if [ "$RC_H_NORMAL" -eq 4 ]; then
    pass "H: a normally-formatted manifest still parses without Python (exit EXIT_TAINTED=4, not blocked)"
else
    fail "H: expected exit 4 on a normal one-path-per-line manifest, got $RC_H_NORMAL"; cat "$TEST_ROOT/out-h-normal.log" >&2
fi

# Negative case (peer-session 2026-08-21-12, second cold-context round):
# a compact single-file manifest is valid JSON and was briefly believed to
# be supported by this fallback (a "path" surrounded by other content on
# the same line still contains the key) — Codex rejected loosening the
# grammar to allow that, since an unconstrained prefix before "path" could
# just as easily hide corruption or a "path" match inside an unrelated
# string value. This asserts the deliberate scope limit explicitly, not
# just implicitly via Scenario H's two-path-per-line case above.
cat > "$UPSTREAM/update-manifest.json" <<'EOF'
{"schema_version": 2, "version": "0.99.0-test-226", "files": [{"path": "single.md", "sha256": "0"}], "deprecated_files": []}
EOF
set +e
PATH="$NO_PY_DIR:$SHIM_DIR:$PATH" HOME="$FAKE_HOME" IWE_UPDATE_CHANNEL=main bash "$SCRIPT_DIR/update.sh" --check > "$TEST_ROOT/out-h-singlefile.log" 2>&1
RC_H_SINGLEFILE=$?
set -e

if [ "$RC_H_SINGLEFILE" -eq 3 ]; then
    pass "H: a compact single-file manifest is deliberately unsupported (exit EXIT_RUNTIME=3, not a silent pass)"
else
    fail "H: expected exit 3 on a compact single-file manifest, got $RC_H_SINGLEFILE"; cat "$TEST_ROOT/out-h-singlefile.log" >&2
fi

# Negative case (third cold-context round, same peer-session): a manifest
# with zero "path" keys was the concrete counterexample that caught a real
# `set -e` bug — `grep ... > file; grep_rc=$?` (no `||`) aborts the script
# on the FIRST non-zero exit (grep's own "no matches" status 1 counts),
# so `grep_rc=$?` never runs and the script dies with a raw exit 1 instead
# of this guard's own EXIT_RUNTIME=3. `files: []` is a legitimate manifest
# shape the real generator can produce (an update with only deprecated
# files, no new/changed ones) — it must fail closed with the guard's own
# diagnostic, not a bare shell death with no message at all.
cat > "$UPSTREAM/update-manifest.json" <<'EOF'
{"schema_version": 2, "version": "0.99.0-test-226", "files": [], "deprecated_files": []}
EOF
set +e
PATH="$NO_PY_DIR:$SHIM_DIR:$PATH" HOME="$FAKE_HOME" IWE_UPDATE_CHANNEL=main bash "$SCRIPT_DIR/update.sh" --check > "$TEST_ROOT/out-h-nopath.log" 2>&1
RC_H_NOPATH=$?
set -e

if [ "$RC_H_NOPATH" -eq 3 ]; then
    pass "H: a manifest with zero \"path\" keys fails closed with EXIT_RUNTIME(3), not a raw shell death"
else
    fail "H: expected exit 3 on a manifest with no path keys, got $RC_H_NOPATH"; cat "$TEST_ROOT/out-h-nopath.log" >&2
fi

if grep -q "Не удалось прочитать манифест" "$TEST_ROOT/out-h-nopath.log"; then
    pass "H: the read-error guard message is shown, not a silent bare exit"
else
    fail "H: no read-error guard message, output was:"; cat "$TEST_ROOT/out-h-nopath.log" >&2
fi

echo ""
echo "============================================"
echo "  Results: $PASS_COUNT PASS, $FAIL_COUNT FAIL"
echo "============================================"
[ "$FAIL_COUNT" -eq 0 ]
