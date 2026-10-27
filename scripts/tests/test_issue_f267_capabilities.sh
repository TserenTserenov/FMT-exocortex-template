#!/usr/bin/env bash
# test_issue_f267_capabilities.sh - the installation capability record (WP-7 F267 stage 1).
#
# What the record promises, and what each check below pins:
#   1. it stores facts only: a gateway address with a secret in it never reaches a file;
#   2. the gateway fact follows the same order as day-open-pipeline.sh (#877);
#   3. a stored program path that stopped working is searched once more, and a second
#      miss is "absent"; a scheduler with a short PATH still gets the stored full path;
#   4. backup state is derived from existing sources, with NO new setting: the standard
#      params.yaml.example on Linux (backup_dir empty, backup_enabled true) is "undecided",
#      not "broken"; a pre-exported IWE_ICLOUD_BACKUP_DIR counts as a target;
#   5. "undecided" is announced once, and again only after it was resolved and came back;
#   6. never-probed reads and an unwritable runtime directory fail loudly, not silently;
#   7. parallel probes leave whole files and no temp leftovers;
#   8. the audit prints the record without checking anything itself.
# `uname -s` is faked through PATH; HOME is a throwaway directory.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CAP="$ROOT/scripts/iwe-capabilities.sh"
LIB="$ROOT/scripts/lib/iwe-capabilities.sh"
AUDIT="$ROOT/scripts/iwe-audit.sh"

FAIL=0
pass() { echo "  ✅ PASS: $*"; }
fail() { echo "  ❌ FAIL: $*"; FAIL=$((FAIL + 1)); }

PYTHONUSERBASE="${PYTHONUSERBASE:-$(python3 -m site --user-base 2>/dev/null)}"
export PYTHONUSERBASE

TMP="$(mktemp -d)"
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
WS="$TMP/ws"
mkdir -p "$TMP/linux" "$TMP/darwin" "$TMP/home" "$WS/DS-strategy" "$TMP/fakebin"

REAL_UNAME="$(command -v uname)"
for os in Linux Darwin; do
    dir="$TMP/$(echo "$os" | tr '[:upper:]' '[:lower:]')"
    printf '#!/bin/sh\n[ "${1:-}" = "-s" ] && { echo %s; exit 0; }\nexec %s "$@"\n' "$os" "$REAL_UNAME" > "$dir/uname"
    chmod +x "$dir/uname"
done

# run_cap OS ARGS... - the real command in a throwaway workspace. The environment of the
# machine running the test (gateway, backup target) is cleared first.
run_cap() {
    local os="$1"; shift
    env -u LLM_PROXY_URL -u PLATFORM_LLM_PROXY_URL -u IWE_ICLOUD_BACKUP_DIR -u CAP_EXTRA_DIRS \
        HOME="$TMP/home" PATH="$TMP/$os:$PATH" WORKSPACE_DIR="$WS" IWE_ROOT="$WS" \
        IWE_WORKSPACE="$WS" IWE_RUNTIME="$WS/.iwe-runtime" IWE_GOVERNANCE_REPO=DS-strategy \
        "$@" bash "$CAP" ${CAP_ARGS:-probe}
}
state() { sed -n "s/^$2: \{0,1\}//p" "$WS/.iwe-runtime/state/capabilities/$1" | head -1; }
reset_ws() { rm -rf "$WS/.iwe-runtime" "$WS/params.yaml" "$WS/.exocortex.env"; }

# --- 1. no secret in any file ---------------------------------------------------
reset_ws
SECRET="TOPSECRET-f267-$$"
run_cap linux LLM_PROXY_URL="https://gw.example/v1?token=$SECRET" >/dev/null 2>&1
if grep -rq "$SECRET" "$WS/.iwe-runtime" || grep -rq 'https\?://' "$WS/.iwe-runtime/state/capabilities"; then
    fail "an address or secret reached a capability file"
else
    pass "no address or secret value in the capability files"
fi
[ "$(state gateway status)" = present ] && pass "gateway fact: present" || fail "gateway should be present, got '$(state gateway status)'"
[ -z "$(state gateway value)" ] && pass "gateway value stays empty" || fail "gateway value not empty: $(state gateway value)"

# --- 2. gateway order (same as day-open-pipeline.sh) -----------------------------
reset_ws; run_cap linux >/dev/null 2>&1
[ "$(state gateway status)" = absent ] && pass "no gateway variables → absent" || fail "expected absent, got $(state gateway status)"
reset_ws; run_cap linux PLATFORM_LLM_PROXY_URL="https://platform.example/v1" >/dev/null 2>&1
[ "$(state gateway status)" = present ] && pass "PLATFORM_LLM_PROXY_URL → present" || fail "PLATFORM_LLM_PROXY_URL not honoured"
reset_ws; printf 'PLATFORM_LLM_PROXY_URL=https://llm.aisystant.com\n' > "$WS/.exocortex.env"; run_cap linux >/dev/null 2>&1
[ "$(state gateway status)" = absent ] && pass "legacy placeholder in .exocortex.env is ignored" || fail "legacy placeholder counted as a gateway"
for degenerate in "/" "/v1" "/v1/"; do
    reset_ws; run_cap linux LLM_PROXY_URL="$degenerate" >/dev/null 2>&1
    [ "$(state gateway status)" = absent ] && pass "explicit LLM_PROXY_URL='$degenerate' trims to empty → absent (as the pipeline does)" \
        || fail "explicit LLM_PROXY_URL='$degenerate' counted as a gateway: $(state gateway status)"
done
reset_ws; printf 'PLATFORM_LLM_PROXY_URL=https://real.example/v1\n' > "$WS/.exocortex.env"; run_cap linux >/dev/null 2>&1
[ "$(state gateway status)" = present ] && pass ".exocortex.env gateway → present" || fail ".exocortex.env gateway not read"

# --- 3. program paths: stale, double miss, short scheduler PATH --------------------
printf '#!/bin/sh\nexit 0\n' > "$TMP/fakebin/fakeprog"; chmod +x "$TMP/fakebin/fakeprog"
lib_call() {  # lib_call CODE - the library alone, one fake program, a clean runtime
    env -i HOME="$TMP/home" PATH="${LIB_PATH:-/usr/bin:/bin}" IWE_RUNTIME="$WS/.iwe-runtime" CAP_EXTRA_DIRS="${EXTRA:-}" \
        bash -c 'source "$1"; cap_program_for() { echo "${FAKE_PROG:-fakeprog}"; }; '"$2" _ "$LIB"
}
reset_ws
mkdir -p "$WS/.iwe-runtime/state/capabilities"
printf 'status: present\nvalue: /nonexistent/gone/fakeprog\nchecked_at: x\n' > "$WS/.iwe-runtime/state/capabilities/restic"
out=$(EXTRA="$TMP/fakebin" lib_call x 'cap_resolve restic')
if [ "$out" = "$TMP/fakebin/fakeprog" ] && [ "$(state restic value)" = "$TMP/fakebin/fakeprog" ]; then
    pass "stale stored path → one fresh search, file refreshed"
else
    fail "stale path not re-searched: out='$out' file='$(state restic value)'"
fi
reset_ws
mkdir -p "$WS/.iwe-runtime/state/capabilities"
printf 'status: present\nvalue: /nonexistent/gone/x\nchecked_at: x\n' > "$WS/.iwe-runtime/state/capabilities/restic"
FAKE_PROG=iwe-no-such-program-f267 lib_call x 'cap_resolve restic' >/dev/null
rc=$?
if [ "$rc" -ne 0 ] && [ "$(state restic status)" = absent ]; then
    pass "second miss → absent (resolve fails, file says absent)"
else
    fail "double miss: rc=$rc status=$(state restic status)"
fi
reset_ws
mkdir -p "$WS/.iwe-runtime/state/capabilities"
printf 'status: present\nvalue: %s\nchecked_at: x\n' "$TMP/fakebin/fakeprog" > "$WS/.iwe-runtime/state/capabilities/restic"
out=$(LIB_PATH=/usr/bin:/bin lib_call x 'cap_resolve restic')
[ "$out" = "$TMP/fakebin/fakeprog" ] && pass "scheduler-short PATH: the stored full path is used" || fail "short PATH lost the stored path: '$out'"

# --- 4. backup state matrix ----------------------------------------------------------
cp "$ROOT/params.yaml.example" "$WS/params.yaml"
reset_ws_keep_params() { rm -rf "$WS/.iwe-runtime"; }
reset_ws_keep_params; run_cap linux >/dev/null 2>&1
[ "$(state backup status)" = undecided ] && pass "Linux + standard params.yaml.example → undecided (not broken)" || fail "standard example on Linux: $(state backup status)"
printf 'backup_dir: "%s"\n' "$TMP/bk" > "$WS/params.yaml"
reset_ws_keep_params; run_cap linux >/dev/null 2>&1
if [ "$(state backup status)" = configured ] && [ -z "$(state backup value)" ]; then
    pass "Linux + backup_dir → configured, the target path stays out of the record"
else
    fail "backup_dir case: $(state backup status) / $(state backup value)"
fi
if grep -rqF "$TMP/bk" "$WS/.iwe-runtime"; then
    fail "the backup target path reached a capability file"
else
    pass "no backup target path in any capability file"
fi
printf 'backup_dir: "%s"\nbackup_enabled: false\n' "$TMP/bk" > "$WS/params.yaml"
reset_ws_keep_params; run_cap linux >/dev/null 2>&1
[ "$(state backup status)" = off ] && pass "backup_enabled: false → off, even with a target" || fail "backup_enabled false: $(state backup status)"
rm -f "$WS/params.yaml"
reset_ws_keep_params; run_cap linux IWE_ICLOUD_BACKUP_DIR="$TMP/pre" >/dev/null 2>&1
[ "$(state backup status)" = configured ] && pass "pre-exported IWE_ICLOUD_BACKUP_DIR counts as a target" || fail "pre-exported target ignored: $(state backup status)"
reset_ws_keep_params; run_cap darwin >/dev/null 2>&1
[ "$(state backup status)" = configured ] && pass "macOS without params → configured (iCloud default kept)" || fail "macOS default: $(state backup status)"

# --- types ---------------------------------------------------------------------------
reset_ws; run_cap linux >/dev/null 2>&1
case "$(state os value)" in macos|linux|unknown) pass "os value is a known OS word" ;; *) fail "os value: $(state os value)" ;; esac
tar_path="$(state tar value)"
if [ "$(state tar status)" = present ] && [ "${tar_path#/}" != "$tar_path" ]; then
    pass "program capability records a full path"
else
    fail "tar: $(state tar status) '$tar_path'"
fi
bad=0
for n in os tar restic claude_cli gateway telegram backup; do
    f="$WS/.iwe-runtime/state/capabilities/$n"
    [ "$(wc -l < "$f" | tr -d ' ')" = 5 ] && grep -q '^status: ' "$f" && grep -q '^value: ' "$f" && grep -q '^checked_at: ' "$f" \
        && grep -q '^was: ' "$f" && grep -q '^alerted: ' "$f" || bad=1
done
[ "$bad" -eq 0 ] && pass "every file is exactly status/value/checked_at/was/alerted" || fail "a capability file has the wrong shape"

# --- 5. the one message --------------------------------------------------------------
reset_ws; rm -f "$WS/params.yaml"
first=$(CAP_ARGS="probe --announce" run_cap linux 2>&1)
second=$(CAP_ARGS="probe --announce" run_cap linux 2>&1)
if printf '%s' "$first" | grep -q 'Бэкап IWE не настроен' && [ -z "$second" ]; then
    pass "undecided: the message comes once, the second run is silent"
else
    fail "message once: first='$first' second='$second'"
fi
printf 'backup_dir: "%s"\n' "$TMP/bk" > "$WS/params.yaml"
CAP_ARGS="probe --announce" run_cap linux >/dev/null 2>&1
rm -f "$WS/params.yaml"
third=$(CAP_ARGS="probe --announce" run_cap linux 2>&1)
printf '%s' "$third" | grep -q 'Бэкап IWE не настроен' && pass "undecided again after it was resolved → speaks again" || fail "no message after the state returned to undecided"

# --- 6. loud failures ---------------------------------------------------------------
reset_ws
CAP_ARGS="get backup" run_cap linux >/dev/null 2>&1
rc=$?
[ "$rc" -eq 1 ] && pass "never probed → get exits 1 (set -u safe)" || fail "get on a never-probed name: rc=$rc"
CAP_ARGS="get ../../etc/passwd" run_cap linux >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] && pass "get refuses a name outside the capability list (no path escape)" || fail "get with a path-like name: rc=$rc"
reset_ws; : > "$TMP/afile"
err=$(env -u LLM_PROXY_URL HOME="$TMP/home" PATH="$TMP/linux:$PATH" WORKSPACE_DIR="$WS" IWE_ROOT="$WS" IWE_WORKSPACE="$WS" \
    IWE_RUNTIME="$TMP/afile" bash "$CAP" probe 2>&1 >/dev/null)
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$err" | grep -q 'cannot create'; then
    pass "unwritable runtime → exit 1 with a clear message"
else
    fail "unwritable runtime: rc=$rc err='$err'"
fi

# --- 7. parallel probes -----------------------------------------------------------------
reset_ws
for _ in 1 2 3 4 5 6 7 8; do run_cap linux >/dev/null 2>&1 & done
wait
leftovers=$(find "$WS/.iwe-runtime/state/capabilities" -name '.*.??????' 2>/dev/null | wc -l | tr -d ' ')
bad=0
for n in os tar restic claude_cli gateway telegram backup; do
    [ "$(wc -l < "$WS/.iwe-runtime/state/capabilities/$n" | tr -d ' ')" = 5 ] || bad=1
done
[ "$leftovers" = 0 ] && [ "$bad" -eq 0 ] && pass "8 parallel probes: whole files, no temp leftovers" || fail "parallel probes: leftovers=$leftovers bad=$bad"

# --- 8. the audit prints the record -------------------------------------------------------
reset_ws; rm -f "$WS/params.yaml"
run_cap linux >/dev/null 2>&1
aud=$(env -u LLM_PROXY_URL -u PLATFORM_LLM_PROXY_URL -u IWE_ICLOUD_BACKUP_DIR HOME="$TMP/home" PATH="$TMP/linux:$PATH" \
    WORKSPACE_DIR="$WS" IWE_ROOT="$WS" IWE_WORKSPACE="$WS" IWE_RUNTIME="$WS/.iwe-runtime" IWE_GOVERNANCE_REPO=DS-strategy \
    bash "$AUDIT" 2>&1)
sec8=$(printf '%s\n' "$aud" | sed -n '/^## 8\./,$p')
if printf '%s' "$sec8" | grep -q '| backup | undecided' && printf '%s' "$sec8" | grep -q 'Бэкап не решён'; then
    pass "audit section 8 shows the recorded state and the yellow backup line"
else
    fail "audit section 8: $(printf '%s' "$sec8" | head -12 | tr '\n' ' ')"
fi
# "undecided" is information, not an alarm: the audit's own exit code comes from its
# warning counter, and the whole audit exits 2 in a bare test workspace whatever section 8
# does - so run the REAL section 8 code alone and read the counter it leaves behind.
section8_counter() {
    {
        echo 'set -eu'
        echo "SCRIPT_DIR='$ROOT/scripts'"
        echo "source '$ROOT/.claude/lib/iwe-env-bootstrap.sh'"
        echo 'OPTIONAL_MISSING=0'
        sed -n '/^echo "## 8\. /,/^# ---------- Exit code/p' "$AUDIT" | sed '$d'
        echo 'echo "COUNTER=$OPTIONAL_MISSING"'
    } > "$TMP/section8.sh"
    env -u LLM_PROXY_URL -u PLATFORM_LLM_PROXY_URL -u IWE_ICLOUD_BACKUP_DIR HOME="$TMP/home" PATH="$TMP/linux:$PATH" \
        WORKSPACE_DIR="$WS" IWE_ROOT="$WS" IWE_WORKSPACE="$WS" IWE_RUNTIME="$WS/.iwe-runtime" \
        bash "$TMP/section8.sh" 2>&1 | sed -n 's/^COUNTER=//p'
}
reset_ws; rm -f "$WS/params.yaml"; run_cap linux >/dev/null 2>&1
if [ "$(state backup status)" = undecided ] && [ "$(section8_counter)" = 0 ]; then
    pass "undecided backup adds nothing to the audit's warning counter"
else
    fail "section 8 with an undecided backup: status=$(state backup status) counter='$(section8_counter)'"
fi


echo ""
if [ "$FAIL" -eq 0 ]; then echo "ALL PASS"; else echo "FAILED: $FAIL"; exit 1; fi
