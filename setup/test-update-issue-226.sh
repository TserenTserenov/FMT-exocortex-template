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

mkdir -p "$UPSTREAM/extensions"
cat > "$UPSTREAM/extensions/day-open.checks.md" <<'EOF'
# Template Day Open checks
```bash
test -f "$FILE"
```
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
        entry('extensions/day-open.checks.md'),
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

# Existing installations can have their own Day Open hooks and checks. The
# updater must deliver its default into the template without touching these.
mkdir -p "$WORKSPACE_DIR/extensions" "$TEST_ROOT/user-extensions-before"
for hook in before checks after; do
    printf '# Pilot-owned Day Open %s\n```bash\nprintf "user-%s\\n"\n```\n' \
        "$hook" "$hook" > "$WORKSPACE_DIR/extensions/day-open.$hook.md"
    cp "$WORKSPACE_DIR/extensions/day-open.$hook.md" \
        "$TEST_ROOT/user-extensions-before/day-open.$hook.md"
done

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

if cmp -s "$UPSTREAM/extensions/day-open.checks.md" "$SCRIPT_DIR/extensions/day-open.checks.md"; then
    pass "A: default Day Open checks delivered into template"
else
    fail "A: default Day Open checks missing from updated template"
fi
for hook in before checks after; do
    if cmp -s "$TEST_ROOT/user-extensions-before/day-open.$hook.md" \
        "$WORKSPACE_DIR/extensions/day-open.$hook.md"; then
        pass "A: existing user day-open.$hook.md preserved byte-for-byte"
    else
        fail "A: existing user day-open.$hook.md changed during update"
    fi
done

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
# Scenario D: a memory copy that differs from the template is reported even when no file is in
# the current NEW_FILES/UPDATED_FILES list (#375). Since #965/#967 the memory policy decides,
# not the owner: marker: a copy nothing proves untouched is kept, with a ready command.
# ------------------------------------------------------------------
echo "--- Scenario D: differing memory copy on an unchanged run (#375 #965) ---"
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
if grep -qF "memory/dummy-memo.md — НЕ обновлён: не удалось проверить, менялся ли файл (нет классификатора истории). Сам он не обновится. Сверьте: diff " "$TEST_ROOT/out-d.log" && \
   grep -q 'Pilot-owned content that intentionally differs' "$MEM_DST"; then
    pass "D: a differing copy nothing proves untouched is kept, with the reason and a ready command, on an unchanged run"
else
    fail "D: the differing copy was replaced or not reported: $(grep -n 'dummy-memo' "$TEST_ROOT/out-d.log" | head -3 | tr '\n' ' ')"
fi
# The install above has no classifier script: the report must stay generic (verdict unknown)
# and must not claim to know where the copy came from.
if grep -qE "совпадает с версией в истории текущей ветки|не совпадает ни с одной версией в истории текущей ветки" "$TEST_ROOT/out-d.log"; then
    fail "D: a verdict was claimed although the install has no classifier"
else
    pass "D: without the classifier the report claims no verdict (unknown)"
fi

# ------------------------------------------------------------------
# Scenario D2 (#965/#967): with the shipped classifier the memory policy decides by the clone's
# history — a copy equal to a committed version of the file is refreshed (after a backup), one
# equal to none is kept, an undecidable history keeps it too — and each line says why. The
# classifier compares the copy only with the versions COMMITTED in the template clone, so the
# lines promise no more than that (the cases below, D3 and D4, pin the two ways the verdicts
# can mislead).
# ------------------------------------------------------------------
echo "--- Scenario D2: memory policy by the clone's history — committed version / no committed version / unknown (#965 #967) ---"
D2_COMMITTED_TEXT='обновлён (не менялся: равен версии из истории клона шаблона; если в клоне шаблона была ваша правка, она в прежней версии)'
D2_UNCOMMITTED_TEXT='не совпадает ни с одной версией в истории текущей ветки клона (ваши правки или уже применённый прошлый релиз)'
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
# d2_hint_of LOG TEXT — the command at the end of the line that carries TEXT: the reason, the diff
# and the command to accept the template version are one line ("… копия останется рядом): <command>").
d2_hint_of() {
    local line
    line=$(grep -F "$2" "$TEST_ROOT/$1" | head -1)
    printf '%s\n' "${line#*прежняя копия останется рядом): }"
}
# A `date` that always prints the same value: the name of the saved copy must not depend on the
# clock or on a shell's random numbers (the two runs below get the same date and the same seed).
D2_FIXED_DATE_DIR="$TEST_ROOT/fixed-date"
mkdir -p "$D2_FIXED_DATE_DIR"
printf '#!/bin/bash\necho 20260101000000\n' > "$D2_FIXED_DATE_DIR/date"
chmod +x "$D2_FIXED_DATE_DIR/date"
# d2_check_save_hint LOG TEXT BEFORE LABEL — the offered command, run as printed, must keep the
# current copy (BEFORE) next to MEM_DST and then make MEM_DST the template's file. Run a second
# time (the pilot repeats it, e.g. after the next release, or twice in a row) it must not
# overwrite that copy: the first copy — the only one that holds the pilot's edits — survives next
# to the second one, even when both runs happen under identical conditions (the same second, the
# same RANDOM seed).
d2_check_save_hint() {
    local hint backup count=0 original_kept=0
    hint=$(d2_hint_of "$1" "$2")
    rm -f "$MEM_DST".before-update*
    PATH="$D2_FIXED_DATE_DIR:$PATH" bash -c "RANDOM=11; $hint" > /dev/null 2>&1 || true
    PATH="$D2_FIXED_DATE_DIR:$PATH" bash -c "RANDOM=11; $hint" > /dev/null 2>&1 || true
    for backup in "$MEM_DST".before-update-*; do
        [ -f "$backup" ] || continue
        count=$((count + 1))
        if [ "$(cat "$backup")" = "$3" ]; then
            original_kept=1
        fi
    done
    if [ "$count" -eq 2 ] && [ "$original_kept" -eq 1 ] && cmp -s "$MEM_DST" "$SCRIPT_DIR/memory/dummy-memo.md"; then
        pass "$4: the offered command saves the copy under a unique name and a second run keeps both copies"
    else
        fail "$4: the offered command ('${hint:-<none>}') left $count saved copies (original kept: $original_kept); two were expected, one with the original"
    fi
    rm -f "$MEM_DST".before-update*
}
d2_untracked_entry add

d2_run_update out-d-authored.log
if grep -qF "memory/dummy-memo.md — НЕ обновлён: $D2_UNCOMMITTED_TEXT. Сам он не обновится. Сверьте: diff " "$TEST_ROOT/out-d-authored.log" && \
   grep -q 'Pilot-owned content that intentionally differs' "$MEM_DST"; then
    pass "D2: a copy that equals no committed version is kept, named with both possible causes and a ready command"
else
    fail "D2: no verdict for the copy that equals no committed version: $(grep -n 'dummy-memo' "$TEST_ROOT/out-d-authored.log" | head -3 | tr '\n' ' ')"
fi
if grep -q "вероятно, ваши правки" "$TEST_ROOT/out-d-authored.log"; then
    fail "D2: the report still blames the pilot's edits without naming the other cause"
else
    pass "D2: the report no longer says 'probably your edits' on its own"
fi
if grep -qF "memory/untracked-memo.md — НЕ обновлён: не удалось проверить, менялся ли файл (в истории клона шаблона нет этого файла). Сам он не обновится. Сверьте: diff " "$TEST_ROOT/out-d-authored.log"; then
    pass "D2: an undecidable history (verdict unknown) keeps the copy and says it cannot be checked"
else
    fail "D2: the unknown verdict did not keep the copy with its reason: $(grep -n 'untracked-memo' "$TEST_ROOT/out-d-authored.log" | head -3 | tr '\n' ' ')"
fi
if grep -F 'Не обновлено файлов памяти' "$TEST_ROOT/out-d-authored.log" | grep -qF ': 2 ('; then
    pass "D2: the closing summary counts every kept file"
else
    fail "D2: the closing summary lost its count of kept files"
fi
d2_check_save_hint out-d-authored.log "memory/dummy-memo.md — НЕ обновлён: $D2_UNCOMMITTED_TEXT" "$(cat "$MEM_DST")" "D2"

# The deployed copy equals an OLDER version from the template history.
printf -- '---\nowner: user\n---\nOlder template text of the memo\n' > "$TEST_ROOT/memo-older.txt"
d2_commit_memo "$TEST_ROOT/memo-older.txt" "history: an older memo"
d2_commit_memo "$TEST_ROOT/memo-upstream.txt" "history: memo back to the upstream text"
cp "$TEST_ROOT/memo-older.txt" "$MEM_DST"

d2_run_update out-d-stale.log
if grep -qF "memory/dummy-memo.md → memory/ — $D2_COMMITTED_TEXT" "$TEST_ROOT/out-d-stale.log" && \
   cmp -s "$MEM_DST" "$SCRIPT_DIR/memory/dummy-memo.md"; then
    pass "D2: a copy that equals an older committed version is refreshed, the line naming the proof and its caveat"
else
    fail "D2: the copy that equals an older committed version was not refreshed: $(grep -n 'dummy-memo' "$TEST_ROOT/out-d-stale.log" | head -3 | tr '\n' ' ')"
fi
if grep -rqF 'Older template text of the memo' "$WORKSPACE_DIR/.backups/memory-pre-update" 2>/dev/null && \
   grep -qF 'Заменено файлов памяти: 1 (memory/dummy-memo.md)' "$TEST_ROOT/out-d-stale.log"; then
    pass "D2: the refreshed copy is backed up first and the closing summary names it"
else
    fail "D2: no backup of the refreshed copy, or the summary does not name it"
fi
if grep -q "не совпадает ни с одной версией в истории текущей ветки" "$TEST_ROOT/out-d-stale.log"; then
    fail "D2: a copy that equals a committed version was reported as equal to none"
else
    pass "D2: a copy that equals a committed version is not reported as equal to none"
fi

# ------------------------------------------------------------------
# Scenario D3: the same verdict, but the committed version IS the pilot's own edit — a fork
# with local commits (#963) keeps it in the clone's history. "Equals a committed version"
# proves nothing about who wrote it; the policy refreshes such a copy all the same (the residual
# risk accepted for #965/#967), so the line must not promise "no edits found", must name the
# caveat, and the copy must be saved before it is replaced.
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
if grep -qF "memory/dummy-memo.md → memory/ — $D2_COMMITTED_TEXT" "$TEST_ROOT/out-d-committed.log"; then
    pass "D3: the line says the match may be the pilot's own committed edit, kept in the previous version"
else
    fail "D3: the pilot's-own-commit caveat is missing: $(grep -n 'dummy-memo' "$TEST_ROOT/out-d-committed.log" | head -3 | tr '\n' ' ')"
fi
if grep -rqF 'Pilot notes committed into the clone' "$WORKSPACE_DIR/.backups/memory-pre-update" 2>/dev/null; then
    pass "D3: the pilot's committed edit survives in the backup taken before the replacement"
else
    fail "D3: the pilot's committed edit was replaced without a backup"
fi

# ------------------------------------------------------------------
# Scenario D4 (review С2, #965): the copy is an earlier release that update.sh itself put in place.
# update.sh never commits what it applies, so no commit of the clone knows that release, and the
# history check alone would keep such a copy forever (this scenario used to pin exactly that). The
# record of installed versions, written by the run that found the copy equal to the template,
# proves it untouched, so the next release reaches it.
# ------------------------------------------------------------------
echo "--- Scenario D4: an earlier release update.sh installed is refreshed by the record (#965, review С2) ---"
printf -- '---\nowner: user\n---\nRelease one text of the memo\n' > "$UPSTREAM/memory/dummy-memo.md"
cp "$UPSTREAM/memory/dummy-memo.md" "$SCRIPT_DIR/memory/dummy-memo.md"
cp "$UPSTREAM/memory/dummy-memo.md" "$MEM_DST"
d2_memo_sha
d2_run_update out-d-release-one.log
# Release two lands in the clone; the memory copy stays on release one.
printf -- '---\nowner: user\n---\nRelease two text of the memo\n' > "$UPSTREAM/memory/dummy-memo.md"
cp "$UPSTREAM/memory/dummy-memo.md" "$SCRIPT_DIR/memory/dummy-memo.md"
d2_memo_sha

d2_run_update out-d-release.log
if grep -qF "memory/dummy-memo.md → memory/ — обновлён (не менялся: равен версии, установленной в прошлый раз" "$TEST_ROOT/out-d-release.log" && \
   cmp -s "$MEM_DST" "$SCRIPT_DIR/memory/dummy-memo.md"; then
    pass "D4: an earlier release update.sh installed, unknown to the clone's history, is refreshed by the record"
else
    fail "D4: the copy of an earlier installed release stays old: $(grep -n 'dummy-memo' "$TEST_ROOT/out-d-release.log" | head -3 | tr '\n' ' ')"
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
# Scenario I (#967): Step 6 used to replace a changed platform memory file — first with a bare
# cp, then after a backup; a pilot's edit to e.g. memory/navigation.md was lost with every
# release that touched the file. Now Step 6 keeps a copy that differs from the version it
# installed last time (and that the clone's history cannot explain), with a ready command.
# ------------------------------------------------------------------
echo "--- Scenario I: Step 6 keeps an edited owner: platform memory file (#967) ---"
printf '# Dummy memo v6\n' > "$UPSTREAM/memory/dummy-memo.md"
d2_memo_sha
printf -- '---\nowner: platform\n---\n# Dummy memo v5\nPilot edit: notes about this installation\n' > "$MEM_DST"
I_BEFORE=$(cat "$MEM_DST")
set +e
PATH="$SHIM_DIR:$PATH" HOME="$FAKE_HOME" IWE_UPDATE_CHANNEL=main bash "$SCRIPT_DIR/update.sh" --yes > "$TEST_ROOT/out-i.log" 2>&1
RC_I=$?
set -e
if [ "$RC_I" -eq 0 ]; then
    pass "I: update.sh exits 0 when it keeps an edited memory file"
else
    fail "I: expected exit 0, got $RC_I; tail: $(tail -3 "$TEST_ROOT/out-i.log" | tr '\n' ' ')"
fi
if [ "$(cat "$MEM_DST")" = "$I_BEFORE" ] && \
   ! grep -rqF 'Pilot edit: notes about this installation' "$WORKSPACE_DIR/.backups/memory-pre-update" 2>/dev/null; then
    pass "I: the pilot's edited owner: platform copy is left exactly as it was, nothing replaced or backed up"
else
    fail "I: the edited memory file was replaced or backed up for a replacement"
fi
I_LINE=$(grep -F 'memory/dummy-memo.md — НЕ обновлён: ' "$TEST_ROOT/out-i.log" | head -1 || true)
if grep -qF '. Сам он не обновится. Сверьте: diff ' <<<"$I_LINE" && grep -qF 'Если ваших правок там нет, примите версию шаблона (прежняя копия останется рядом): ' <<<"$I_LINE" && \
   ! grep -qF 'Заменено файлов памяти' "$TEST_ROOT/out-i.log" && \
   grep -F 'Не обновлено файлов памяти' "$TEST_ROOT/out-i.log" | grep -qF ': 1 (memory/dummy-memo.md)'; then
    pass "I: one line gives the reason, a diff and then the command; the summary counts the kept file and replaces none"
else
    fail "I: no kept-file line with a command, or a wrong summary: '${I_LINE:-<none>}'"
fi
if [ "$(grep -cF 'memory/dummy-memo.md — НЕ обновлён: ' "$TEST_ROOT/out-i.log")" = "1" ]; then
    pass "I: Step 6 and the repair pass after it report the kept file once"
else
    fail "I: the kept file is reported $(grep -cF 'memory/dummy-memo.md — НЕ обновлён: ' "$TEST_ROOT/out-i.log") times in one run"
fi

# ------------------------------------------------------------------
# Scenario J (#965): the pilot's owner: user copy equals the version the previous update
# installed, and the clone's history cannot show it (update.sh never commits what it applies).
# Only the hash Step 2 records before replacing the template file proves the copy untouched:
# the release must reach it, after a backup, and the closing summary must name it. A second
# run of the same release then changes nothing.
# ------------------------------------------------------------------
echo "--- Scenario J: an untouched owner: user copy follows the release (#965) ---"
printf -- '---\nowner: user\n---\nRelease six text of the memo\n' > "$SCRIPT_DIR/memory/dummy-memo.md"
cp "$SCRIPT_DIR/memory/dummy-memo.md" "$MEM_DST"
printf -- '---\nowner: user\n---\nRelease seven text of the memo\n' > "$UPSTREAM/memory/dummy-memo.md"
d2_memo_sha
set +e
PATH="$SHIM_DIR:$PATH" HOME="$FAKE_HOME" IWE_UPDATE_CHANNEL=main bash "$SCRIPT_DIR/update.sh" --yes > "$TEST_ROOT/out-j.log" 2>&1
RC_J=$?
set -e
J_BACKUP=$(grep -rlF 'Release six text of the memo' "$WORKSPACE_DIR/.backups/memory-pre-update" 2>/dev/null | head -1 || true)
if [ "$RC_J" -eq 0 ] && cmp -s "$MEM_DST" "$UPSTREAM/memory/dummy-memo.md" && [ -n "$J_BACKUP" ]; then
    pass "J: the untouched owner: user copy carries the release now, the previous version is backed up"
else
    fail "J: the untouched owner: user copy did not follow the release (rc=$RC_J, backup: ${J_BACKUP:-none}): $(grep -n 'dummy-memo' "$TEST_ROOT/out-j.log" | head -3 | tr '\n' ' ')"
fi
if grep -qF 'memory/dummy-memo.md → memory/ — обновлён (не менялся: равен прошлой версии шаблона; если в клоне шаблона была ваша правка, она в прежней версии)' "$TEST_ROOT/out-j.log" && \
   grep -F 'Заменено файлов памяти: 1 (memory/dummy-memo.md)' "$TEST_ROOT/out-j.log" | grep -qF "$WORKSPACE_DIR/.backups/memory-pre-update"; then
    pass "J: the line names the proof, the closing summary names the file and the backup directory"
else
    fail "J: the replacement line or the summary is missing: $(grep -nE 'dummy-memo|Заменено' "$TEST_ROOT/out-j.log" | head -3 | tr '\n' ' ')"
fi
J_BACKUP_COUNT=$(find "$WORKSPACE_DIR/.backups/memory-pre-update" -type f 2>/dev/null | wc -l | tr -d ' ')
J_MEMORY_STATE=$(cksum < "$MEM_DST")
set +e
PATH="$SHIM_DIR:$PATH" HOME="$FAKE_HOME" IWE_UPDATE_CHANNEL=main bash "$SCRIPT_DIR/update.sh" --yes > "$TEST_ROOT/out-j2.log" 2>&1
RC_J2=$?
set -e
if [ "$RC_J2" -eq 0 ] && [ "$J_MEMORY_STATE" = "$(cksum < "$MEM_DST")" ] && \
   [ "$J_BACKUP_COUNT" = "$(find "$WORKSPACE_DIR/.backups/memory-pre-update" -type f 2>/dev/null | wc -l | tr -d ' ')" ] && \
   ! grep -qE 'Заменено файлов памяти|dummy-memo.md — НЕ обновлён' "$TEST_ROOT/out-j2.log"; then
    pass "J: a second run of the same release changes nothing and backs up nothing"
else
    fail "J: the repeated run changed the memory copy or its backups (rc=$RC_J2): $(grep -nE 'dummy-memo|Заменено' "$TEST_ROOT/out-j2.log" | head -3 | tr '\n' ' ')"
fi

# ------------------------------------------------------------------
# Scenario K (review С1): a run stops with code 49 between Step 5 and Step 6 (conflict markers left
# in the workspace CLAUDE.md): the clone carries the new release, the memory copy does not, and the
# hashes this run took in Step 2 are gone with its temporary directory. The next run must still
# refresh the untouched copy - the record of installed versions proves it - and must keep an edited
# one, its record line unchanged.
# ------------------------------------------------------------------
echo "--- Scenario K: a broken-off run (code 49 before Step 6), then the next run (review С1) ---"
# k_break TEXT LOG — release TEXT reaches the clone, and the run stops with code 49 before Step 6
# (markers left over in the workspace CLAUDE.md); the markers are resolved afterwards.
k_break() {
    printf -- '---\nowner: user\n---\n%s\n' "$1" > "$UPSTREAM/memory/dummy-memo.md"
    d2_memo_sha
    printf '<<<<<<< left over from an earlier run\n' >> "$WORKSPACE_DIR/CLAUDE.md"
    set +e
    PATH="$SHIM_DIR:$PATH" HOME="$FAKE_HOME" IWE_UPDATE_CHANNEL=main bash "$SCRIPT_DIR/update.sh" --yes > "$TEST_ROOT/$2" 2>&1
    K_RC=$?
    set -e
    sed_inplace '/^<<<<<<< left over from an earlier run$/d' "$WORKSPACE_DIR/CLAUDE.md"
}
# k_record_line — the record's line for the memo, if any.
k_record_line() { grep -F 'memory/dummy-memo.md' "$WORKSPACE_DIR/.memory-deployed.tsv" 2>/dev/null || true; }
K_BEFORE=$(cat "$MEM_DST")
k_break "Release eight text of the memo" out-k-broken.log
if [ "$K_RC" -eq 49 ] && [ "$(cat "$MEM_DST")" = "$K_BEFORE" ] && grep -q 'Release eight' "$SCRIPT_DIR/memory/dummy-memo.md"; then
    pass "K: the run stops with code 49 after the clone took the release and before the memory copy did"
else
    fail "K: the broken-off run did not stop between Step 5 and Step 6 (rc=$K_RC)"
fi
d2_run_update out-k.log
if grep -qF 'memory/dummy-memo.md → memory/ — обновлён (не менялся: равен версии, установленной в прошлый раз' "$TEST_ROOT/out-k.log" && \
   cmp -s "$MEM_DST" "$UPSTREAM/memory/dummy-memo.md"; then
    pass "K: the next run refreshes the untouched copy the broken-off run left behind"
else
    fail "K: the copy left behind by the broken-off run stays old: $(grep -n 'dummy-memo' "$TEST_ROOT/out-k.log" | head -3 | tr '\n' ' ')"
fi
printf 'Pilot line written after the update\n' >> "$MEM_DST"
K_EDITED=$(cat "$MEM_DST")
K_RECORD_LINE=$(k_record_line)
k_break "Release nine text of the memo" out-k2-broken.log
d2_run_update out-k2.log
if [ "$(cat "$MEM_DST")" = "$K_EDITED" ] && grep -qF 'memory/dummy-memo.md — НЕ обновлён: ' "$TEST_ROOT/out-k2.log" && \
   [ -n "$K_RECORD_LINE" ] && [ "$(k_record_line)" = "$K_RECORD_LINE" ]; then
    pass "K: an edited copy stays through a broken-off run, its record line still naming the version installed before"
else
    fail "K: the edited copy or its record line changed after a broken-off run: $(grep -n 'dummy-memo' "$TEST_ROOT/out-k2.log" | head -3 | tr '\n' ' ')"
fi

# ------------------------------------------------------------------
# Scenario L (review С2): an installation from before the record. The copy equals the clone's file,
# which update.sh brought (no commit knows it); the first run finds them equal and starts the
# record. Later the copy falls two releases behind - a broken-off run, then one more release - and
# neither the clone's history nor this run's replaced version can prove it untouched; the record can.
# ------------------------------------------------------------------
echo "--- Scenario L: an installed copy two releases behind, its record started by a later run (review С2) ---"
rm -f "$WORKSPACE_DIR/.memory-deployed.tsv"
printf -- '---\nowner: user\n---\nRelease ten text of the memo\n' > "$UPSTREAM/memory/dummy-memo.md"
cp "$UPSTREAM/memory/dummy-memo.md" "$SCRIPT_DIR/memory/dummy-memo.md"
cp "$UPSTREAM/memory/dummy-memo.md" "$MEM_DST"
d2_memo_sha
d2_run_update out-l1.log
L_TEN_LINE=$(printf 'memory/dummy-memo.md\t%s' "$(python3 -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$MEM_DST")")
if [ "$(k_record_line)" = "$L_TEN_LINE" ]; then
    pass "L: a run that finds the copy equal to the template starts its record line"
else
    fail "L: no record line after a run that found the copy equal to the template: '$(k_record_line)'"
fi
k_break "Release eleven text of the memo" out-l2-broken.log
printf -- '---\nowner: user\n---\nRelease twelve text of the memo\n' > "$UPSTREAM/memory/dummy-memo.md"
d2_memo_sha
d2_run_update out-l3.log
if grep -qF 'memory/dummy-memo.md → memory/ — обновлён (не менялся: равен версии, установленной в прошлый раз' "$TEST_ROOT/out-l3.log" && \
   cmp -s "$MEM_DST" "$UPSTREAM/memory/dummy-memo.md"; then
    pass "L: a copy two releases behind, unknown to the clone's history, is refreshed by the record"
else
    fail "L: the copy two releases behind stays old: $(grep -n 'dummy-memo' "$TEST_ROOT/out-l3.log" | head -3 | tr '\n' ' ')"
fi

# ------------------------------------------------------------------
# Scenario M (review-12 С1): an installation from before the record. The old updater applied release
# two by curl - the clone's working tree and the memory copies, no commit - and the FIRST run of this
# version (it brings release three) breaks off with code 49 between Step 5 and Step 6. The next run
# must refresh the untouched copies, owner: user and owner: platform alike, and keep the edited one
# with no record line for it; release four after that must work the same way.
# ------------------------------------------------------------------
echo "--- Scenario M: the first run of this version breaks off before Step 6, no record yet (review-12 С1) ---"
MEM_DIR=$(dirname "$MEM_DST")
# m_release TEXT — every memo of this scenario in the upstream gets TEXT; the manifest follows.
m_release() {
    printf -- '---\nowner: user\n---\nUser memo %s\n' "$1" > "$UPSTREAM/memory/dummy-memo.md"
    printf -- '---\nowner: platform\n---\nPlatform memo %s\n' "$1" > "$UPSTREAM/memory/m-platform.md"
    printf -- '---\nowner: platform\n---\nEdited memo %s\n' "$1" > "$UPSTREAM/memory/m-edited.md"
    python3 - "$UPSTREAM/update-manifest.json" "$UPSTREAM" memory/m-platform.md memory/m-edited.md <<'PY'
import hashlib
import json
import pathlib
import sys
manifest_path, root, *added = sys.argv[1:]
with open(manifest_path, encoding="utf-8") as handle:
    manifest = json.load(handle)
known = {entry["path"] for entry in manifest["files"]}
manifest["files"].extend({"path": path} for path in added if path not in known)
for entry in manifest["files"]:
    source = pathlib.Path(root) / entry["path"]
    if source.is_file():
        entry["sha256"] = hashlib.sha256(source.read_bytes()).hexdigest()
with open(manifest_path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle)
PY
}
# m_copy NAME — the deployed copy of memory/NAME, last line.
m_copy() { tail -1 "$MEM_DIR/$1"; }
rm -f "$WORKSPACE_DIR/.memory-deployed.tsv"
m_release "release two"
for m_name in dummy-memo.md m-platform.md m-edited.md; do
    cp "$UPSTREAM/memory/$m_name" "$SCRIPT_DIR/memory/$m_name"
    cp "$UPSTREAM/memory/$m_name" "$MEM_DIR/$m_name"
done
printf 'Pilot line in the edited memo\n' >> "$MEM_DIR/m-edited.md"
M_EDITED=$(cat "$MEM_DIR/m-edited.md")
m_release "release three"
printf '<<<<<<< left over from an earlier run\n' >> "$WORKSPACE_DIR/CLAUDE.md"
set +e
PATH="$SHIM_DIR:$PATH" HOME="$FAKE_HOME" IWE_UPDATE_CHANNEL=main bash "$SCRIPT_DIR/update.sh" --yes > "$TEST_ROOT/out-m1.log" 2>&1
M_RC=$?
set -e
sed_inplace '/^<<<<<<< left over from an earlier run$/d' "$WORKSPACE_DIR/CLAUDE.md"
if [ "$M_RC" -eq 49 ] && [ "$(m_copy dummy-memo.md)" = "User memo release two" ] && [ "$(m_copy m-platform.md)" = "Platform memo release two" ] \
   && grep -q 'User memo release three' "$SCRIPT_DIR/memory/dummy-memo.md"; then
    pass "M: the first run stops with code 49 after the clone took release three, before the memory copies did"
else
    fail "M: the first run did not stop between Step 5 and Step 6 (rc=$M_RC, copies: $(m_copy dummy-memo.md) / $(m_copy m-platform.md))"
fi
d2_run_update out-m2.log
if [ "$(m_copy dummy-memo.md)" = "User memo release three" ] && [ "$(m_copy m-platform.md)" = "Platform memo release three" ] \
   && grep -qF 'memory/dummy-memo.md → memory/ — обновлён (не менялся: ' "$TEST_ROOT/out-m2.log" \
   && grep -qF 'memory/m-platform.md → memory/ — обновлён (не менялся: ' "$TEST_ROOT/out-m2.log"; then
    pass "M: the next run refreshes the untouched copies, owner: user and owner: platform"
else
    fail "M: untouched copies stay old after the broken-off first run: $(grep -nE 'dummy-memo|m-platform' "$TEST_ROOT/out-m2.log" | head -3 | tr '\n' ' ')"
fi
if [ "$(cat "$MEM_DIR/m-edited.md")" = "$M_EDITED" ] && grep -qF 'memory/m-edited.md — НЕ обновлён: ' "$TEST_ROOT/out-m2.log" \
   && ! grep -qF 'memory/m-edited.md' "$WORKSPACE_DIR/.memory-deployed.tsv"; then
    pass "M: the edited copy stays, with its line, and gets no record line"
else
    fail "M: the edited copy changed or entered the record: $(grep -n 'm-edited' "$TEST_ROOT/out-m2.log" "$WORKSPACE_DIR/.memory-deployed.tsv" | head -3 | tr '\n' ' ')"
fi
m_release "release four"
d2_run_update out-m3.log
if [ "$(m_copy dummy-memo.md)" = "User memo release four" ] && [ "$(m_copy m-platform.md)" = "Platform memo release four" ] \
   && [ "$(cat "$MEM_DIR/m-edited.md")" = "$M_EDITED" ] && ! grep -qF 'memory/m-edited.md' "$WORKSPACE_DIR/.memory-deployed.tsv"; then
    pass "M: release four reaches the untouched copies as well; the edited one stays out of it"
else
    fail "M: release four did not behave: $(grep -nE 'dummy-memo|m-platform|m-edited' "$TEST_ROOT/out-m3.log" | head -3 | tr '\n' ' ')"
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
