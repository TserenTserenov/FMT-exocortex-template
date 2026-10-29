#!/bin/bash
# test-update-check-verdict.sh — `update.sh --check` ends with one readiness verdict
# (WP-529 Ф244, peer-session 2026-10-29-18-wp529-f244-preupdate-check).
#
# Runs the REAL update.sh --check against fresh sandboxes: own SCRIPT_DIR/WORKSPACE_DIR under a
# temp dir, a fake HOME passed only to the child, a curl shim serving fixture "upstream" content
# (same contract as setup/test-update-modified-hook.sh), refusing scheduler stubs.
#
# Contract under test:
#   - the update is allowed only on exit 0 together with the exact line "ВЕРДИКТ: можно ставить";
#   - an install the real run would refuse (.exocortex.env, .backups/) gives
#     "ВЕРДИКТ: нельзя ставить" and exit 3 — the same predicates the apply gates use;
#   - incomplete download → "нельзя подтвердить", exit 2; no Python (tainted) → "нельзя
#     подтвердить", exit 4; failed registry canary → "нельзя ставить", exit 5;
#   - rollback / unverifiable release history: without --yes → positive verdict plus its own
#     caveat line (a --yes run would be stopped), exit 0; with --yes → "нельзя ставить", exit 1
#     and no positive line (the apply step refuses exactly this combination);
#   - a newer update.sh upstream: positive verdict plus its own caveat line, exit 0;
#   - --fast gives no verdict line at all;
#   - every --check leaves the installation unchanged: file contents, types, modes and symlink
#     targets (atime is not compared), and creates no env draft and no write probe.
#
# Usage:
#   bash setup/test-update-check-verdict.sh
#   KEEP=1 bash setup/test-update-check-verdict.sh   # keep the temp dir for inspection

set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_DIR="$(dirname "$SELF_DIR")"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/iwe-check-verdict-test.XXXXXX")"

FAIL_COUNT=0
PASS_COUNT=0
fail() { echo "  ❌ FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
pass() { echo "  ✅ PASS: $*"; PASS_COUNT=$((PASS_COUNT + 1)); }

# shellcheck disable=SC2329  # invoked by the trap below
cleanup() {
    local rc=$?
    # Restore permissions a scenario took away, or rm cannot clean up.
    chmod -R u+rwx "$TEST_ROOT" 2>/dev/null
    [ "${KEEP:-0}" = "1" ] || rm -rf "$TEST_ROOT"
    exit "$rc"
}
trap cleanup EXIT INT TERM

IS_ROOT=false
[ "$(id -u)" -eq 0 ] && IS_ROOT=true

# ------------------------------------------------------------------
# Upstream fixtures (shared by all scenarios)
# ------------------------------------------------------------------
STUB_DIR="$TEST_ROOT/stubs"
NOPY_DIR="$TEST_ROOT/stubs-nopy"
UPSTREAM="$TEST_ROOT/upstream"
UPSTREAM_INCOMPLETE="$TEST_ROOT/upstream-incomplete"
mkdir -p "$STUB_DIR" "$NOPY_DIR" "$UPSTREAM" "$UPSTREAM_INCOMPLETE"

cat > "$UPSTREAM/CLAUDE.md" <<'EOF'
# Template CLAUDE.md

## 1. Platform section

Upstream content, new release.
EOF
cp "$UPSTREAM/CLAUDE.md" "$UPSTREAM_INCOMPLETE/CLAUDE.md"

# write_manifest DIR VERSION [MISSING_PATH] — MISSING_PATH is listed but never served.
write_manifest() {
    python3 - "$1" "$2" "${3:-}" <<'PY'
import hashlib, json, sys
from pathlib import Path
root, version, missing = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
files = [{"path": "CLAUDE.md",
          "sha256": hashlib.sha256((root / "CLAUDE.md").read_bytes()).hexdigest()}]
if missing:
    files.append({"path": missing, "sha256": "0" * 64})
manifest = {"schema_version": 2, "version": version, "files": files, "deprecated_files": []}
(root / "update-manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
PY
}
write_manifest "$UPSTREAM" "0.99.0-test-check-verdict"
write_manifest "$UPSTREAM_INCOMPLETE" "0.99.0-test-check-verdict" "missing-payload.md"

for tool in launchctl systemctl crontab; do
    cat > "$STUB_DIR/$tool" <<EOF
#!/bin/bash
echo "$tool \$*" >> "$TEST_ROOT/scheduler-calls.log"
exit 1
EOF
    chmod +x "$STUB_DIR/$tool"
done

# No-Python stubs: update.sh probes `python3 -c pass` / `python -c pass` and falls back to the
# grep parser (INTEGRITY_TAINTED) when both fail.
for py in python3 python; do
    printf '#!/bin/bash\nexit 1\n' > "$NOPY_DIR/$py"
    chmod +x "$NOPY_DIR/$py"
done

# curl shim: serves $SHIM_UPSTREAM (set per run) for single-file (-o) and batch (-K)
# downloads; update.sh itself is served from $SHIM_UPDATER so Step 0 sees no new version.
cat > "$STUB_DIR/curl" <<'SHIMEOF'
#!/bin/bash
serve() {
    # raw URL is .../OWNER/REPO/<ref>/<path>; <ref> is main, a tag or a commit SHA
    local rel
    rel=$(printf '%s' "$1" | sed -E 's#^https://raw\.githubusercontent\.com/[^/]+/[^/]+/[^/]+/##')
    case "$rel" in
        update.sh) cp "$SHIM_UPDATER" "$2" ;;
        *) [ -f "$SHIM_UPSTREAM/$rel" ] && cp "$SHIM_UPSTREAM/$rel" "$2" \
               || { echo "curl: (22) The requested URL returned error: 404" >&2; return 22; } ;;
    esac
}
if [ "${1:-}" = "--help" ] && [ "${2:-}" = "all" ]; then
    printf -- '  --parallel \n  --parallel-max <num>\n  --remove-on-error \n'
    exit 0
fi
url="" out="" cfg=""
args=("$@")
# GitHub API (release channel): the latest release is v9.9.9, resolved to $SHIM_RELEASE_SHA
for a in "${args[@]}"; do
    case "$a" in
        https://api.github.com/*/releases/latest) printf '{"tag_name":"v9.9.9"}\n'; exit 0 ;;
        https://api.github.com/*/commits/v9.9.9) printf '{"sha":"%s"}\n' "$SHIM_RELEASE_SHA"; exit 0 ;;
        https://api.github.com/*) echo "curl: (22) The requested URL returned error: 404" >&2; exit 22 ;;
    esac
done
for ((i=0; i<${#args[@]}; i++)); do
    case "${args[i]}" in
        http*) url="${args[i]}" ;;
        -o) out="${args[i+1]}" ;;
        -K) cfg="${args[i+1]}" ;;
    esac
done
if [ -n "$cfg" ]; then
    rc=0 pending=""
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            'url = '*) pending=$(printf '%s' "$line" | sed -e 's/^url = "//' -e 's/"$//') ;;
            'output = '*) o=$(printf '%s' "$line" | sed -e 's/^output = "//' -e 's/"$//')
                          serve "$pending" "$o" || rc=22; pending="" ;;
        esac
    done < "$cfg"
    exit "$rc"
fi
serve "$url" "$out"
SHIMEOF
chmod +x "$STUB_DIR/curl"

# No authenticated gh: github_api_get must take the anonymous curl path served by the shim.
printf '#!/bin/bash\nexit 1\n' > "$STUB_DIR/gh"
chmod +x "$STUB_DIR/gh"

# ------------------------------------------------------------------
# Per-scenario installation
# ------------------------------------------------------------------
# new_install NAME [current] — a fresh install under $TEST_ROOT/NAME. By default the template
# clone is one release behind (CLAUDE.md differs → the full check block runs); "current" puts
# it at the upstream version (the "всё актуально" branch). Sets WS and SD.
new_install() {
    # per-scenario knobs never leak into the next installation
    unset CHANNEL SHIM_RELEASE_SHA SHIM_UPDATER_OVERRIDE
    WS="$TEST_ROOT/$1/repo"
    SD="$WS/FMT-exocortex-template"
    mkdir -p "$SD/.claude/lib" "$SD/scripts/lib" "$TEST_ROOT/$1/home"
    cp "$TEMPLATE_DIR/update.sh" "$SD/update.sh"
    cp "$TEMPLATE_DIR/.claude/lib/frontmatter.sh" "$SD/.claude/lib/frontmatter.sh"
    cp "$TEMPLATE_DIR/scripts/lib/common.sh" "$SD/scripts/lib/common.sh"
    chmod +x "$SD/update.sh"
    if [ "${2:-}" = "current" ]; then
        cp "$UPSTREAM/CLAUDE.md" "$SD/CLAUDE.md"
    else
        printf '# Template CLAUDE.md\n\n## 1. Platform section\n\nUpstream content, old release.\n' \
            > "$SD/CLAUDE.md"
    fi
    cp "$SD/CLAUDE.md" "$SD/.claude.md.base"
    cp "$UPSTREAM/update-manifest.json" "$SD/update-manifest.json"
    if [ "${2:-}" != "current" ]; then
        python3 - "$SD/update-manifest.json" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1]); m = json.loads(p.read_text()); m["version"] = "0.98.0-test-old"
p.write_text(json.dumps(m, indent=2))
PY
    fi
    git -C "$SD" init -q -b main 2>/dev/null || git -C "$SD" init -q
    git -C "$SD" config user.email t@t
    git -C "$SD" config user.name t
    git -C "$SD" add -- update.sh update-manifest.json CLAUDE.md .claude.md.base \
        .claude/lib/frontmatter.sh scripts/lib/common.sh
    git -C "$SD" commit -q -m "installed release"
    printf 'GOVERNANCE_REPO="pilot-governance"\n' > "$WS/.exocortex.env"
    cp "$SD/CLAUDE.md" "$WS/CLAUDE.md"
    cp "$SD/.claude.md.base" "$WS/.claude.md.base"
}

# snapshot DIR — type, mode, link target and content hash of every entry, .git excluded
# (git may rewrite its own index on a read). atime is deliberately not part of it.
snapshot() {
    python3 - "$1" <<'PY'
import hashlib, os, stat, sys
root = sys.argv[1]
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = sorted(d for d in dirnames if d != ".git")
    for name in sorted(dirnames + filenames):
        p = os.path.join(dirpath, name)
        st = os.lstat(p)
        rel = os.path.relpath(p, root)
        if stat.S_ISLNK(st.st_mode):
            print("L", oct(st.st_mode & 0o7777), rel, os.readlink(p))
        elif stat.S_ISDIR(st.st_mode):
            print("D", oct(st.st_mode & 0o7777), rel)
        else:
            with open(p, "rb") as fh:
                print("F", oct(st.st_mode & 0o7777), rel, hashlib.sha256(fh.read()).hexdigest())
PY
}

# run_check NAME LOG [extra update.sh args...] — sets RC. SHIM_UPSTREAM and EXTRA_PATH may be
# set by the caller for one scenario.
run_check() {
    local name="$1" log="$2"
    shift 2
    run_update "$name" "$log" --check "$@"
}

# run_update NAME LOG update.sh args... — one update.sh run in the sandbox; sets RC.
run_update() {
    local name="$1" log="$2"
    shift 2
    env -u GH_TOKEN -u GITHUB_TOKEN HOME="$TEST_ROOT/$name/home" \
        PATH="${EXTRA_PATH:+$EXTRA_PATH:}$STUB_DIR:$PATH" \
        IWE_UPDATE_CHANNEL="${CHANNEL:-main}" SHIM_UPSTREAM="${SHIM_UPSTREAM:-$UPSTREAM}" \
        SHIM_RELEASE_SHA="${SHIM_RELEASE_SHA:-}" \
        SHIM_UPDATER="${SHIM_UPDATER_OVERRIDE:-$TEMPLATE_DIR/update.sh}" \
        bash "$SD/update.sh" "$@" > "$log" 2>&1
    RC=$?
}

POSITIVE_LINE="ВЕРДИКТ: можно ставить"

# expect NAME LOG RC VERDICT_LINE — exit code and exact verdict line; a refusal must not also
# carry the positive line.
expect() {
    local name="$1" log="$2" want_rc="$3" want_line="$4"
    if [ "$RC" -eq "$want_rc" ]; then
        pass "$name: exit $RC"
    else
        fail "$name: exit $RC, expected $want_rc (log: $(tail -3 "$log" | tr '\n' '|'))"
    fi
    if grep -Fxq "$want_line" "$log"; then
        pass "$name: line «${want_line}»"
    else
        fail "$name: line «${want_line}» missing"
    fi
    if [ "$want_line" != "$POSITIVE_LINE" ] && grep -Fxq "$POSITIVE_LINE" "$log"; then
        fail "$name: refusal also printed the positive verdict"
    fi
}

# expect_unchanged NAME BEFORE — the installation is byte- and mode-identical to BEFORE, and no
# env draft or backups write probe was left behind.
expect_unchanged() {
    local name="$1" before="$2" after leftovers
    after=$(snapshot "$WS")
    if [ "$before" = "$after" ]; then
        pass "$name: installation unchanged (contents, types, modes, symlink targets)"
    else
        fail "$name: installation changed: $(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -5 | tr '\n' '|')"
    fi
    leftovers=$(find "$WS" -name '.exocortex.env.tmp.*' -o -name '.write-probe.*' 2>/dev/null)
    if [ -z "$leftovers" ]; then
        pass "$name: no env draft and no write probe left"
    else
        fail "$name: leftovers: $leftovers"
    fi
}

# scenario NAME RC LINE SETUP_FN [update.sh args...] — fresh install, SETUP_FN mutates it,
# then one --check with the shared assertions.
scenario() {
    local name="$1" want_rc="$2" want_line="$3" setup_fn="$4" before log
    shift 4
    echo "--- $name ---"
    new_install "$name"
    "$setup_fn"
    before=$(snapshot "$WS")
    log="$TEST_ROOT/$name.log"
    run_check "$name" "$log" "$@"
    expect "$name" "$log" "$want_rc" "$want_line"
    expect_unchanged "$name" "$before"
}

# ------------------------------------------------------------------
# Refusals of the install itself: exit 3, same predicates as the apply gates
# ------------------------------------------------------------------
no_setup() { :; }
backups_live_symlink() { mkdir -p "$WS/elsewhere"; ln -s "$WS/elsewhere" "$WS/.backups"; }
backups_broken_symlink() { ln -s "$WS/nonexistent" "$WS/.backups"; }
backups_regular_file() { printf 'not a dir\n' > "$WS/.backups"; }
backups_no_write() { mkdir -p "$WS/.backups"; chmod 500 "$WS/.backups"; }
backups_no_search() { mkdir -p "$WS/.backups"; chmod 600 "$WS/.backups"; }
env_symlink() { mv "$WS/.exocortex.env" "$WS/env.real"; ln -s "$WS/env.real" "$WS/.exocortex.env"; }
env_directory() { rm -f "$WS/.exocortex.env"; mkdir "$WS/.exocortex.env"; }
legacy_symlink() { rm -f "$WS/.exocortex.env"; ln -s "$WS/nowhere" "$SD/.exocortex.env"; }
env_missing() { rm -f "$WS/.exocortex.env"; }

scenario "R1-backups-live-symlink"   3 "ВЕРДИКТ: нельзя ставить" backups_live_symlink
scenario "R2-backups-broken-symlink" 3 "ВЕРДИКТ: нельзя ставить" backups_broken_symlink
scenario "R3-backups-regular-file"   3 "ВЕРДИКТ: нельзя ставить" backups_regular_file
scenario "R4-env-symlink"            3 "ВЕРДИКТ: нельзя ставить" env_symlink
scenario "R5-env-directory"          3 "ВЕРДИКТ: нельзя ставить" env_directory
scenario "R6-legacy-env-symlink"     3 "ВЕРДИКТ: нельзя ставить" legacy_symlink
scenario "R7-both-env-missing"       3 "ВЕРДИКТ: нельзя ставить" env_missing
if [ ! -e "$WS/.exocortex.env" ]; then
    pass "R7-both-env-missing: --check created no .exocortex.env"
else
    fail "R7-both-env-missing: --check created .exocortex.env"
fi

# Permission bits do not bind root: these two only mean something for an ordinary user.
if $IS_ROOT; then
    echo "  ℹ R8/R9/R10 skipped: running as root, permission bits do not refuse writes"
else
    scenario "R8-backups-no-write"  3 "ВЕРДИКТ: нельзя ставить" backups_no_write
    scenario "R9-backups-no-search" 3 "ВЕРДИКТ: нельзя ставить" backups_no_search
    # R10: no .backups/ and a workspace root the user cannot write into.
    echo "--- R10-backups-parent-readonly ---"
    new_install "R10-backups-parent-readonly"
    chmod 555 "$WS"
    before=$(snapshot "$WS")
    run_check "R10-backups-parent-readonly" "$TEST_ROOT/R10.log"
    expect "R10-backups-parent-readonly" "$TEST_ROOT/R10.log" 3 "ВЕРДИКТ: нельзя ставить"
    expect_unchanged "R10-backups-parent-readonly" "$before"
    chmod 755 "$WS"
fi

# Both independent predicates report together.
both_broken() { env_symlink; backups_regular_file; }
scenario "R11-env-and-backups" 3 "ВЕРДИКТ: нельзя ставить" both_broken
if grep -q 'является символической ссылкой' "$TEST_ROOT/R11-env-and-backups.log" \
   && grep -q 'не является каталогом' "$TEST_ROOT/R11-env-and-backups.log"; then
    pass "R11-env-and-backups: both reasons are listed"
else
    fail "R11-env-and-backups: expected both the env and the .backups reason"
fi

# ------------------------------------------------------------------
# Allowed: exit 0 + the exact positive line
# ------------------------------------------------------------------
legacy_env_only() { mv "$WS/.exocortex.env" "$SD/.exocortex.env"; }
incomplete_marker() { : > "$SD/.update-incomplete"; }

scenario "A1-healthy-update-available" 0 "$POSITIVE_LINE" no_setup
scenario "A2-legacy-env-only"          0 "$POSITIVE_LINE" legacy_env_only
scenario "A3-incomplete-marker"        0 "$POSITIVE_LINE" incomplete_marker
if grep -q '^Оговорка: найден маркер незавершённого обновления' "$TEST_ROOT/A3-incomplete-marker.log"; then
    pass "A3-incomplete-marker: caveat on its own line"
else
    fail "A3-incomplete-marker: caveat line missing"
fi

# ------------------------------------------------------------------
# Caveats: the verdict is positive, the caveat sits on its own line (WP-529 Ф244 tail)
# ------------------------------------------------------------------
ROLLBACK_CAVEAT='^Оговорка: вердикт относится к ручному запуску; запуск с --yes будет остановлен'
UPDATER_CAVEAT='^Оговорка: вердикт вынесен текущей версией update.sh'
FAKE_SHA=$(printf 'a%.0s' $(seq 1 40))   # a commit the install does not have and cannot fetch

# release channel, release commit is an ancestor of the installed HEAD → rollback detected
rollback_detected() {
    CHANNEL=release
    SHIM_RELEASE_SHA=$(git -C "$SD" rev-parse HEAD)
    printf 'local commit after the release\n' > "$SD/ahead.txt"
    git -C "$SD" add -- ahead.txt && git -C "$SD" commit -q -m "ahead of release"
}
# release commit unknown and unfetchable → history cannot be verified
rollback_uncertain() { CHANNEL=release; SHIM_RELEASE_SHA="$FAKE_SHA"; }
# upstream update.sh differs from the installed one (a comment line, still a valid script)
updater_outdated() {
    SHIM_UPDATER_OVERRIDE="$TEST_ROOT/update-newer.sh"
    { head -n 1 "$TEMPLATE_DIR/update.sh"; echo '# a newer updater'; tail -n +2 "$TEMPLATE_DIR/update.sh"; } \
        > "$SHIM_UPDATER_OVERRIDE"
}

# expect_line_count NAME LOG REGEX WANT — exactly WANT lines match; a caveat must not repeat
# and a clean positive verdict must not carry a foreign one
expect_line_count() {
    local name="$1" log="$2" re="$3" want="$4" got
    got=$(grep -c -- "$re" "$log")
    if [ "$got" -eq "$want" ]; then
        pass "$name: «${re:0:48}…» on $want line(s)"
    else
        fail "$name: «${re:0:48}…» on $got line(s), expected $want"
    fi
}
expect_one_verdict() {
    local name="$1" log="$2" got
    got=$(grep -c '^ВЕРДИКТ:' "$log")
    if [ "$got" -eq 1 ]; then pass "$name: exactly one verdict line"; else fail "$name: $got verdict lines"; fi
}

# the reason that put the run into each rollback state — "detected" must not pass as "uncertain"
ROLLBACK_DETECTED_MSG='^🔴 ВНИМАНИЕ: локальная установка новее последнего релиза'
ROLLBACK_UNCERTAIN_MSG='^⚠️ ВНИМАНИЕ: не удалось проверить историю релиза'
# rollback_msg KIND — the warning line of that rollback state
rollback_msg() { if [ "$1" = detected ]; then echo "$ROLLBACK_DETECTED_MSG"; else echo "$ROLLBACK_UNCERTAIN_MSG"; fi; }
other_kind() { if [ "$1" = detected ]; then echo uncertain; else echo detected; fi; }

for kind in detected uncertain; do
    # without --yes: positive, with the caveat that a --yes run is stopped
    scenario "B-rollback-$kind" 0 "$POSITIVE_LINE" "rollback_$kind"
    expect_line_count "B-rollback-$kind" "$TEST_ROOT/B-rollback-$kind.log" "$ROLLBACK_CAVEAT" 1
    expect_line_count "B-rollback-$kind" "$TEST_ROOT/B-rollback-$kind.log" "$UPDATER_CAVEAT" 0
    expect_one_verdict "B-rollback-$kind" "$TEST_ROOT/B-rollback-$kind.log"
    # with --yes: the apply step would refuse, so the preview refuses too
    scenario "B-rollback-$kind-yes" 1 "ВЕРДИКТ: нельзя ставить" "rollback_$kind" --yes
    expect_line_count "B-rollback-$kind-yes" "$TEST_ROOT/B-rollback-$kind-yes.log" "$ROLLBACK_CAVEAT" 0
    expect_one_verdict "B-rollback-$kind-yes" "$TEST_ROOT/B-rollback-$kind-yes.log"
    # the state itself, in both runs: its own warning once, the other state's warning never
    for log in "$TEST_ROOT/B-rollback-$kind.log" "$TEST_ROOT/B-rollback-$kind-yes.log"; do
        expect_line_count "B-rollback-$kind ($(basename "$log"))" "$log" "$(rollback_msg "$kind")" 1
        expect_line_count "B-rollback-$kind ($(basename "$log"))" "$log" "$(rollback_msg "$(other_kind "$kind")")" 0
    done
done

# Control: the release is NEWER than the installed commit (or equal to it) — not a rollback.
# Guards the direction of the ancestor test: a flipped check would flag this install.
release_newer() {
    CHANNEL=release
    printf 'release commit\n' > "$SD/newer.txt"
    git -C "$SD" add -- newer.txt && git -C "$SD" commit -q -m "release is newer"
    SHIM_RELEASE_SHA=$(git -C "$SD" rev-parse HEAD)
    git -C "$SD" reset -q --hard HEAD~1   # the install sits one commit behind the release
}
release_equal() { CHANNEL=release; SHIM_RELEASE_SHA=$(git -C "$SD" rev-parse HEAD); }
for control in newer equal; do
    scenario "B-no-rollback-release-$control" 0 "$POSITIVE_LINE" "release_$control"
    log="$TEST_ROOT/B-no-rollback-release-$control.log"
    expect_line_count "B-no-rollback-release-$control" "$log" '^Оговорка:' 0
    expect_line_count "B-no-rollback-release-$control" "$log" "$ROLLBACK_DETECTED_MSG" 0
    expect_line_count "B-no-rollback-release-$control" "$log" "$ROLLBACK_UNCERTAIN_MSG" 0
done

# The real run (no --check) must stop on the same combination the preview refuses.
for kind in detected uncertain; do
    echo "--- B-apply-rollback-$kind-yes ---"
    new_install "B-apply-rollback-$kind-yes"
    "rollback_$kind"
    before=$(snapshot "$WS")
    run_update "B-apply-rollback-$kind-yes" "$TEST_ROOT/B-apply-$kind.log" --yes
    if [ "$RC" -eq 1 ]; then pass "B-apply-rollback-$kind-yes: exit 1"; else fail "B-apply-rollback-$kind-yes: exit $RC, expected 1"; fi
    expect_line_count "B-apply-rollback-$kind-yes" "$TEST_ROOT/B-apply-$kind.log" "$(rollback_msg "$kind")" 1
    expect_unchanged "B-apply-rollback-$kind-yes" "$before"
done

scenario "B-updater-outdated" 0 "$POSITIVE_LINE" updater_outdated
expect_line_count "B-updater-outdated" "$TEST_ROOT/B-updater-outdated.log" "$UPDATER_CAVEAT" 1
expect_line_count "B-updater-outdated" "$TEST_ROOT/B-updater-outdated.log" "$ROLLBACK_CAVEAT" 0
expect_one_verdict "B-updater-outdated" "$TEST_ROOT/B-updater-outdated.log"

# a clean install carries no caveat at all
expect_line_count "A1-healthy-update-available" "$TEST_ROOT/A1-healthy-update-available.log" '^Оговорка:' 0

echo "--- A4-up-to-date ---"
new_install "A4-up-to-date" current
before=$(snapshot "$WS")
run_check "A4-up-to-date" "$TEST_ROOT/A4.log"
expect "A4-up-to-date" "$TEST_ROOT/A4.log" 0 "$POSITIVE_LINE"
expect_unchanged "A4-up-to-date" "$before"

# ------------------------------------------------------------------
# Cannot confirm / refused by later checks
# ------------------------------------------------------------------
echo "--- U1-incomplete-download ---"
new_install "U1-incomplete-download" current
before=$(snapshot "$WS")
SHIM_UPSTREAM="$UPSTREAM_INCOMPLETE" run_check "U1-incomplete-download" "$TEST_ROOT/U1.log"
expect "U1-incomplete-download" "$TEST_ROOT/U1.log" 2 "ВЕРДИКТ: нельзя подтвердить"
expect_unchanged "U1-incomplete-download" "$before"

echo "--- U2-no-python-tainted ---"
new_install "U2-no-python-tainted"
before=$(snapshot "$WS")
EXTRA_PATH="$NOPY_DIR" run_check "U2-no-python-tainted" "$TEST_ROOT/U2.log"
expect "U2-no-python-tainted" "$TEST_ROOT/U2.log" 4 "ВЕРДИКТ: нельзя подтвердить"
expect_unchanged "U2-no-python-tainted" "$before"

# A governance repo whose registry self-test fails: the canary refuses the update.
failing_canary() {
    mkdir -p "$WS/pilot-governance/docs" "$WS/pilot-governance/.claude/scripts"
    printf '# WP-REGISTRY\n' > "$WS/pilot-governance/docs/WP-REGISTRY.md"
    printf '#!/bin/bash\necho "registry unreadable" >&2\nexit 1\n' \
        > "$WS/pilot-governance/.claude/scripts/wp-sync-bundle.sh"
    chmod +x "$WS/pilot-governance/.claude/scripts/wp-sync-bundle.sh"
}
scenario "U3-canary-failed" 5 "ВЕРДИКТ: нельзя ставить" failing_canary

# The same two refusals on the other branch (cold review of this phase): changes pending
# with a skipped download, and an up-to-date install with a failing canary.
echo "--- U4-incomplete-download-with-changes ---"
new_install "U4-incomplete-download-with-changes"
before=$(snapshot "$WS")
SHIM_UPSTREAM="$UPSTREAM_INCOMPLETE" run_check "U4-incomplete-download-with-changes" "$TEST_ROOT/U4.log"
expect "U4-incomplete-download-with-changes" "$TEST_ROOT/U4.log" 2 "ВЕРДИКТ: нельзя подтвердить"
expect_unchanged "U4-incomplete-download-with-changes" "$before"

echo "--- U5-canary-failed-up-to-date ---"
new_install "U5-canary-failed-up-to-date" current
failing_canary
before=$(snapshot "$WS")
run_check "U5-canary-failed-up-to-date" "$TEST_ROOT/U5.log"
expect "U5-canary-failed-up-to-date" "$TEST_ROOT/U5.log" 5 "ВЕРДИКТ: нельзя ставить"
expect_unchanged "U5-canary-failed-up-to-date" "$before"

# ------------------------------------------------------------------
# --fast: version only, no verdict
# ------------------------------------------------------------------
echo "--- F1-fast-no-verdict ---"
new_install "F1-fast-no-verdict"
env_missing   # a refusal --fast must not report: it checks the version only
before=$(snapshot "$WS")
run_check "F1-fast-no-verdict" "$TEST_ROOT/F1.log" --fast
if [ "$RC" -eq 0 ]; then pass "F1-fast-no-verdict: exit 0"; else fail "F1-fast-no-verdict: exit $RC"; fi
if grep -q '^ВЕРДИКТ:' "$TEST_ROOT/F1.log"; then
    fail "F1-fast-no-verdict: --fast printed a verdict line"
else
    pass "F1-fast-no-verdict: no verdict line"
fi
if grep -q '^Вердикт о готовности не выдаётся' "$TEST_ROOT/F1.log"; then
    pass "F1-fast-no-verdict: says why there is no verdict"
else
    fail "F1-fast-no-verdict: explanation line missing"
fi
expect_unchanged "F1-fast-no-verdict" "$before"

if [ -s "$TEST_ROOT/scheduler-calls.log" ]; then
    echo "  ℹ scheduler stubs were called: $(sort -u "$TEST_ROOT/scheduler-calls.log" | tr '\n' ';')"
fi

echo ""
echo "  Итог: $PASS_COUNT PASS, $FAIL_COUNT FAIL"
if [ "$FAIL_COUNT" -gt 0 ] && [ "${KEEP:-0}" != "1" ]; then
    echo "  (KEEP=1 оставит $TEST_ROOT для разбора)"
fi
exit "$FAIL_COUNT"
