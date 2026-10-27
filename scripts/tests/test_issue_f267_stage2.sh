#!/usr/bin/env bash
# test_issue_f267_stage2.sh - backup contract, regression alarm, delivery-confirmed notifier
# (WP-7 F267 stage 2, peer-session 2026-10-27-08-wp7-f267-stage2-backup-contract).
#
# What stage 2 promises, and what each section below pins:
#   1. "was" (last good status) and "alerted" survive every rewrite; a good status clears alerted;
#   2. a regression is "worked before, gone now": never-probed, "off" and programs the contract
#      does not need (tar under restic, restic under tar) are NOT regressions;
#   3. backup_engine: unset = tar and not explicit, restic only when written, junk = invalid;
#      an explicit restic is a decision on its own (no backup_dir needed);
#   4. the telegram fact records presence only, never the token;
#   5. notify.sh --require-delivery exits 0 only on a confirmed delivery (3/4/5 otherwise),
#      and the default behaviour is unchanged;
#   6. regress --notify marks "alerted" only after confirmed delivery and speaks once;
#   7. the entry point picks the engine from the contract and never switches silently;
#   8. the freshness check follows an EXPLICIT engine and keeps the old behaviour otherwise;
#   9. a restic key readable by others / owned by others / a symlink stops the run BEFORE
#      restic, and the script runs under the stock macOS bash 3.2 (no mapfile);
#  10. the scheduler tasks mark the day done only after success and never retry in a loop.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/scripts/lib/iwe-capabilities.sh"
CAP="$ROOT/scripts/iwe-capabilities.sh"
NOTIFY="$ROOT/roles/synchronizer/scripts/notify.sh"
SCHED="$ROOT/roles/synchronizer/scripts/scheduler.sh"

FAIL=0
pass() { echo "  ✅ PASS: $*"; }
fail() { echo "  ❌ FAIL: $*"; FAIL=$((FAIL + 1)); }

PYTHONUSERBASE="${PYTHONUSERBASE:-$(python3 -m site --user-base 2>/dev/null)}"
export PYTHONUSERBASE

TMP="$(mktemp -d)"
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
WS="$TMP/ws"
CAPDIR="$WS/.iwe-runtime/state/capabilities"
mkdir -p "$TMP/linux" "$TMP/darwin" "$TMP/home" "$WS" "$TMP/fakebin"

REAL_UNAME="$(command -v uname)"
printf '#!/bin/sh\n[ "${1:-}" = "-s" ] && { echo Linux; exit 0; }\nexec %s "$@"\n' "$REAL_UNAME" > "$TMP/linux/uname"
printf '#!/bin/sh\n[ "${1:-}" = "-s" ] && { echo Darwin; exit 0; }\nexec %s "$@"\n' "$REAL_UNAME" > "$TMP/darwin/uname"
chmod +x "$TMP/linux/uname" "$TMP/darwin/uname"

reset_ws() { rm -rf "$WS/.iwe-runtime" "$WS/params.yaml"; mkdir -p "$WS"; }
state() { sed -n "s/^$2: \{0,1\}//p" "$CAPDIR/$1" | head -1; }
put() {  # put NAME STATUS WAS ALERTED - a fact file as the library would have left it
    mkdir -p "$CAPDIR"
    printf 'status: %s\nvalue: \nchecked_at: x\nwas: %s\nalerted: %s\n' "$2" "$3" "$4" > "$CAPDIR/$1"
}
libcall() {  # libcall CODE - the library alone, clean environment, Linux
    env -i HOME="$TMP/home" PATH="$TMP/linux:/usr/bin:/bin" IWE_RUNTIME="$WS/.iwe-runtime" WORKSPACE_DIR="$WS" \
        CAP_NOTIFY_ENV="$TMP/notify.env" bash -c 'source "$1"; '"$1" _ "$LIB"
}

# --- 1. was / alerted survive rewrites ---------------------------------------------------
reset_ws
libcall 'cap_write gateway present ""; cap_write gateway absent ""'
if [ "$(state gateway status)" = absent ] && [ "$(state gateway was)" = present ] && [ "$(state gateway alerted)" = false ]; then
    pass "good → bad keeps the last good status in 'was'"
else
    fail "good→bad: status=$(state gateway status) was=$(state gateway was) alerted=$(state gateway alerted)"
fi
libcall 'cap_mark_alerted gateway; cap_write gateway absent ""'
[ "$(state gateway alerted)" = true ] && [ "$(state gateway was)" = present ] \
    && pass "bad → bad keeps both 'was' and 'alerted: true'" || fail "bad→bad lost the memory: alerted=$(state gateway alerted) was=$(state gateway was)"
libcall 'cap_write gateway present ""'
[ "$(state gateway alerted)" = false ] && pass "returning to good clears 'alerted'" || fail "alerted not cleared on recovery: $(state gateway alerted)"
reset_ws
libcall 'cap_write telegram absent ""'
[ -z "$(state telegram was)" ] && pass "never good → 'was' stays empty" || fail "was invented: '$(state telegram was)'"

# --- 2. what counts as a regression ----------------------------------------------------------
reset_ws
put gateway absent present false
[ "$(libcall 'cap_regressions')" = "gateway present absent" ] && pass "was present, now absent → regression" || fail "regression missed: '$(libcall 'cap_regressions')'"
reset_ws; put gateway absent "" false
[ -z "$(libcall 'cap_regressions')" ] && pass "never worked → no regression" || fail "never-worked counted: '$(libcall 'cap_regressions')'"
reset_ws; put backup off configured false
[ -z "$(libcall 'cap_regressions')" ] && pass "backup switched off by the pilot → not a regression" || fail "off counted as regression"
reset_ws; put backup undecided configured false
[ "$(libcall 'cap_regressions')" = "backup configured undecided" ] && pass "backup target disappeared (configured → undecided) → regression" || fail "lost target missed: '$(libcall 'cap_regressions')'"
reset_ws; printf 'backup_dir: "%s"\n' "$TMP/bk" > "$WS/params.yaml"
put backup configured configured false; put tar absent present false; put restic absent present false
[ "$(libcall 'cap_regressions')" = "tar present absent" ] && pass "engine tar: only tar counts, restic is not needed" || fail "tar engine: '$(libcall 'cap_regressions')'"
printf 'backup_dir: "%s"\nbackup_engine: restic\n' "$TMP/bk" > "$WS/params.yaml"
[ "$(libcall 'cap_regressions')" = "restic present absent" ] && pass "engine restic: only restic counts, tar is not needed" || fail "restic engine: '$(libcall 'cap_regressions')'"
reset_ws; put gateway absent present true
if [ -z "$(libcall 'cap_regressions --pending')" ] && [ -n "$(libcall 'cap_regressions')" ]; then
    pass "delivered regression: hidden from --pending, still listed for the audit"
else
    fail "pending/all split wrong"
fi

# --- 3. backup_engine -------------------------------------------------------------------------
engine_of() { reset_ws; [ -z "${1:-}" ] || printf '%s\n' "$1" > "$WS/params.yaml"; libcall 'echo "$(cap_backup_engine) $(cap_backup_engine_explicit && echo explicit || echo implicit)"'; }
[ "$(engine_of '')" = "tar implicit" ] && pass "key unset → tar, not explicit" || fail "unset: $(engine_of '')"
[ "$(engine_of 'backup_engine:')" = "tar implicit" ] && pass "empty key → tar, not explicit" || fail "empty: $(engine_of 'backup_engine:')"
[ "$(engine_of 'backup_engine: tar')" = "tar explicit" ] && pass "tar written → explicit tar" || fail "tar: $(engine_of 'backup_engine: tar')"
[ "$(engine_of 'backup_engine: "restic"  # my choice')" = "restic explicit" ] && pass "quotes and a trailing comment are stripped" || fail "restic: $(engine_of 'backup_engine: "restic"  # my choice')"
[ "$(engine_of 'backup_engine: zip')" = "invalid explicit" ] && pass "unknown value → invalid, never a silent tar" || fail "zip: $(engine_of 'backup_engine: zip')"
reset_ws; printf 'backup_engine: restic\n' > "$WS/params.yaml"
[ "$(libcall 'cap_probe_backup; cap_status backup')" = configured ] && pass "explicit restic without backup_dir → configured" || fail "restic decision ignored"
printf 'backup_engine: restic\nbackup_enabled: false\n' > "$WS/params.yaml"
[ "$(libcall 'cap_probe_backup; cap_status backup')" = off ] && pass "explicit restic + backup_enabled: false → off" || fail "off lost to restic"
printf 'backup_engine: tar\n' > "$WS/params.yaml"
[ "$(libcall 'cap_probe_backup; cap_status backup')" = undecided ] && pass "explicit tar without a target → still undecided" || fail "tar without target: $(libcall 'cap_probe_backup; cap_status backup')"

# a probe that ran between the read and the move must win over cap_mark_alerted:
# the status seen first is "absent", the one seen just before the move is "present"
reset_ws; put gateway absent present false
libcall 'cap_status() { local n; n=$(cat "$WORKSPACE_DIR/n" 2>/dev/null || echo 0); echo $((n + 1)) > "$WORKSPACE_DIR/n"; if [ "$n" = 0 ]; then echo absent; else echo present; fi; }; cap_mark_alerted gateway; echo "rc=$?" > "$WORKSPACE_DIR/mark.rc"' >/dev/null 2>&1
if [ "$(state gateway alerted)" = false ] && grep -q 'rc=1' "$WS/mark.rc"; then
    pass "a status that changed meanwhile → 'mark alerted' gives up and writes nothing"
else
    fail "mark_alerted ignored a concurrent change: alerted=$(state gateway alerted) $(cat "$WS/mark.rc" 2>/dev/null)"
fi
libcall 'cap_mark_alerted gateway'
[ "$(state gateway alerted)" = true ] && pass "'mark alerted' with a stable status → alerted: true" || fail "mark_alerted does nothing in the calm case"

# --- 4. telegram: presence only -----------------------------------------------------------------
reset_ws
printf 'TELEGRAM_BOT_TOKEN=SECRET-f267-token\nTELEGRAM_CHAT_ID=424242\n' > "$TMP/notify.env"
libcall 'cap_probe_telegram'
if [ "$(state telegram status)" = present ] && ! grep -rq 'SECRET-f267-token\|424242' "$WS/.iwe-runtime"; then
    pass "token and chat id set → present, no value in any file"
else
    fail "telegram probe: status=$(state telegram status)"
fi
printf 'TELEGRAM_BOT_TOKEN="SECRET-f267-token"\n' > "$TMP/notify.env"
libcall 'cap_probe_telegram'
[ "$(state telegram status)" = absent ] && [ "$(state telegram was)" = present ] && pass "chat id missing → absent, and 'was' remembers it worked" || fail "half config: $(state telegram status)/$(state telegram was)"
printf 'export TELEGRAM_BOT_TOKEN=SECRET-f267-token\nexport TELEGRAM_CHAT_ID=424242\n' > "$TMP/notify.env"
libcall 'cap_probe_telegram'
[ "$(state telegram status)" = present ] && pass "'export NAME=value' lines count (notify.sh sources the file)" || fail "export prefix not recognised: $(state telegram status)"
rm -f "$TMP/notify.env"; libcall 'cap_probe_telegram'
[ "$(state telegram status)" = absent ] && pass "no env file → absent" || fail "no env file: $(state telegram status)"

# --- 5. notify.sh --require-delivery ---------------------------------------------------------------
mkdir -p "$TMP/nbin" "$TMP/tpl" "$TMP/nhome/.config/aist"
cp "$ROOT/roles/synchronizer/scripts/templates/capabilities.sh" "$TMP/tpl/capabilities.sh"
printf '#!/bin/sh\nprintf "%%s" "$FAKE_CURL_BODY"\n' > "$TMP/nbin/curl"; chmod +x "$TMP/nbin/curl"
notify_rc() {  # notify_rc BODY TEXT FLAG... -> exit code; stdout kept in $TMP/notify.out
    local body="$1" text="$2"; shift 2
    env -i HOME="$TMP/nhome" PATH="$TMP/nbin:/usr/bin:/bin" TEMPLATES_DIR="$TMP/tpl" FAKE_CURL_BODY="$body" \
        IWE_CAP_ALERT_TEXT="$text" bash "$NOTIFY" "$@" capabilities regress > "$TMP/notify.out" 2>&1
    echo $?
}
rm -f "$TMP/nhome/.config/aist/env"
[ "$(notify_rc '' 'text' --require-delivery)" = 3 ] && pass "flag, no token → exit 3" || fail "no token with the flag"
[ "$(notify_rc '' 'text')" = 0 ] && pass "no flag, no token → exit 0 (behaviour unchanged)" || fail "default behaviour changed for a missing token"
printf 'TELEGRAM_BOT_TOKEN=t\nTELEGRAM_CHAT_ID=1\n' > "$TMP/nhome/.config/aist/env"
[ "$(notify_rc '{"ok":false}' 'text' --require-delivery)" = 4 ] && pass "flag, Telegram says ok=false → exit 4" || fail "send failure not reported"
[ "$(notify_rc '{"ok":false}' 'text')" = 0 ] && pass "no flag, Telegram says ok=false → exit 0 (behaviour unchanged)" || fail "default behaviour changed for a failed send"
rc=$(notify_rc '{"ok":true}' 'text' --require-delivery)
if [ "$rc" = 0 ] && grep -q 'notification sent' "$TMP/notify.out"; then pass "flag, ok=true → exit 0 and a sent line"; else fail "confirmed delivery: rc=$rc out=$(cat "$TMP/notify.out")"; fi
printf '#!/bin/sh\nexit 28\n' > "$TMP/nbin/curl"
[ "$(notify_rc '' 'text')" = 28 ] && pass "no flag, curl itself fails → curl's exit code, exactly as before the change" || fail "default exit code for a curl failure changed: $(notify_rc '' 'text')"
[ "$(notify_rc '' 'text' --require-delivery)" = 4 ] && pass "flag, curl itself fails → exit 4" || fail "curl failure with the flag: $(notify_rc '' 'text' --require-delivery)"
printf '#!/bin/sh\nprintf "%%s" "$FAKE_CURL_BODY"\n' > "$TMP/nbin/curl"
[ "$(notify_rc '{"ok":true}' '' --require-delivery)" = 5 ] && pass "flag, empty message → exit 5" || fail "empty message with the flag"
[ "$(notify_rc '{"ok":true}' '')" = 0 ] && pass "no flag, empty message → exit 0 (behaviour unchanged)" || fail "default behaviour changed for an empty message"

# --- 6. regress --notify end to end ------------------------------------------------------------------
cat > "$TMP/notify-ok.sh" <<EOF
#!/bin/bash
echo "\$*" >> "$TMP/sent.args"
printf '%s' "\$IWE_CAP_ALERT_TEXT" >> "$TMP/sent.text"
exit 0
EOF
printf '#!/bin/bash\nexit 4\n' > "$TMP/notify-fail.sh"
run_regress() {  # run_regress STUB [ARGS] - the real command; stdout+stderr in $TMP/regress.out
    local stub="$1"; shift
    env -i HOME="$TMP/home" PATH="$TMP/linux:/usr/bin:/bin" WORKSPACE_DIR="$WS" IWE_ROOT="$WS" IWE_WORKSPACE="$WS" \
        IWE_RUNTIME="$WS/.iwe-runtime" CAP_NOTIFY_SH="$stub" bash "$CAP" regress "$@" > "$TMP/regress.out" 2>&1
    echo $?
}
rm -f "$TMP/sent.args" "$TMP/sent.text"
reset_ws; put gateway absent present false; put telegram present present false
rc=$(run_regress "$TMP/notify-ok.sh" --notify)
if [ "$rc" = 0 ] && [ "$(state gateway alerted)" = true ] && grep -q -- '--require-delivery' "$TMP/sent.args" && grep -q 'gateway' "$TMP/sent.text"; then
    pass "confirmed delivery → one message with the capability name, 'alerted' set"
else
    fail "regress --notify: rc=$rc alerted=$(state gateway alerted) args=$(cat "$TMP/sent.args" 2>/dev/null) out=$(cat "$TMP/regress.out")"
fi
rc=$(run_regress "$TMP/notify-ok.sh" --notify)
[ "$rc" = 0 ] && [ "$(wc -l < "$TMP/sent.args" | tr -d ' ')" = 1 ] && pass "second run: nothing pending, no second message" || fail "repeated alarm: rc=$rc sent=$(wc -l < "$TMP/sent.args")"
libcall 'cap_write gateway present ""; cap_write gateway absent ""'
rc=$(run_regress "$TMP/notify-ok.sh" --notify)
[ "$rc" = 0 ] && [ "$(wc -l < "$TMP/sent.args" | tr -d ' ')" = 2 ] && pass "came back and went away again → speaks again" || fail "no repeat after recovery: sent=$(wc -l < "$TMP/sent.args")"
reset_ws; put gateway absent present false; put telegram present present false
rc=$(run_regress "$TMP/notify-fail.sh" --notify)
if [ "$rc" = 1 ] && [ "$(state gateway alerted)" = false ] && grep -q 'delivery not confirmed' "$TMP/regress.out"; then
    pass "delivery not confirmed → exit 1, regression stays pending"
else
    fail "failed delivery: rc=$rc alerted=$(state gateway alerted)"
fi
reset_ws; put gateway absent present false; put telegram absent present false
rc=$(run_regress "$TMP/notify-ok.sh" --notify)
if [ "$rc" = 0 ] && [ "$(state gateway alerted)" = false ] && grep -q 'Telegram не настроен' "$TMP/regress.out"; then
    pass "no telegram → told once, nothing marked delivered"
else
    fail "no-telegram path: rc=$rc alerted=$(state gateway alerted) out=$(cat "$TMP/regress.out")"
fi
reset_ws; mkdir -p "$CAPDIR"
printf 'status: present\nvalue: /nonexistent/gone/tar\nchecked_at: x\nwas: present\nalerted: false\n' > "$CAPDIR/tar"
run_regress "$TMP/notify-ok.sh" >/dev/null
case "$(state tar value)" in /*/tar) [ -x "$(state tar value)" ] && pass "regress re-resolves a stale stored program path" || fail "stale tar path kept: $(state tar value)" ;; *) fail "tar value after re-resolve: $(state tar value)" ;; esac

# --- 7. the entry point ------------------------------------------------------------------------------
TREE="$TMP/tree"; MARK="$TMP/marks"
mkdir -p "$TREE/scripts" "$TREE/.claude/lib" "$TMP/fakebin2"
cp "$ROOT/scripts/iwe-backup.sh" "$TREE/scripts/"; cp -R "$ROOT/scripts/lib" "$TREE/scripts/lib"
cp "$ROOT/.claude/lib/iwe-env-bootstrap.sh" "$TREE/.claude/lib/"
printf '#!/bin/bash\necho "TAR-RAN $* PROG=$(command -v tar)" >> "%s"\n' "$MARK" > "$TREE/scripts/backup-icloud.sh"
printf '#!/bin/bash\necho "RESTIC-RAN $* PROG=$(command -v restic)" >> "%s"\n' "$MARK" > "$TREE/scripts/iwe-backup-run.sh"
printf '#!/bin/sh\nexit 0\n' > "$TMP/fakebin2/restic"; chmod +x "$TMP/fakebin2/restic"
run_entry() {  # run_entry [ARGS] - stdout+stderr in $TMP/entry.out; EXTRA_DIRS selects the fake restic
    env -i HOME="$TMP/home" PATH="${UNAME_DIR:-$TMP/linux}:/usr/bin:/bin" WORKSPACE_DIR="$WS" IWE_ROOT="$WS" IWE_WORKSPACE="$WS" \
        IWE_RUNTIME="$WS/.iwe-runtime" CAP_EXTRA_DIRS="${EXTRA_DIRS:-}" bash "$TREE/scripts/iwe-backup.sh" "$@" > "$TMP/entry.out" 2>&1
    echo $?
}
rm -f "$MARK"; reset_ws; printf 'backup_enabled: false\nbackup_dir: "%s"\n' "$TMP/bk" > "$WS/params.yaml"
rc=$(run_entry)
[ "$rc" = 0 ] && [ ! -e "$MARK" ] && grep -q 'выключен явно' "$TMP/entry.out" && pass "backup_enabled: false → nothing runs, one line why, exit 0" || fail "off: rc=$rc"
reset_ws; rc=$(run_entry)
[ "$rc" = 0 ] && [ ! -e "$MARK" ] && grep -q 'не настроен' "$TMP/entry.out" && pass "no target on Linux → nothing runs, exit 0, no alarm" || fail "undecided: rc=$rc out=$(cat "$TMP/entry.out")"
printf 'backup_dir: "%s"\n' "$TMP/bk" > "$WS/params.yaml"
rc=$(run_entry)
[ "$rc" = 0 ] && grep -q '^TAR-RAN' "$MARK" && ! grep -q RESTIC-RAN "$MARK" && pass "default engine → the tar script, exit 0" || fail "default engine: rc=$rc marks=$(cat "$MARK" 2>/dev/null)"
# a Mac without iCloud Drive: the default target points into iCloud, which is not there. The scheduler
# runs this daily, so it must be a quiet "not configured", never a daily failure (acceptance finding)
rm -f "$MARK"; reset_ws; rm -rf "$TMP/home/Library"
rc=$(UNAME_DIR="$TMP/darwin" run_entry)
if [ "$rc" = 0 ] && [ ! -e "$MARK" ] && grep -q 'iCloud Drive' "$TMP/entry.out" && ! grep -q '❌' "$TMP/entry.out"; then
    pass "macOS without iCloud Drive and without backup_dir → quiet exit 0, nothing runs, no error line"
else
    fail "Mac without iCloud: rc=$rc out=$(cat "$TMP/entry.out")"
fi
[ "$(libcall 'IWE_ICLOUD_ROOT="$HOME/Library/CloudDocs"; IWE_ICLOUD_BACKUP_DIR="$IWE_ICLOUD_ROOT/IWE-backups"; iwe_path_inside() { case "$1" in "$2"/*) return 0 ;; *) return 1 ;; esac; }; cap_probe_backup; cap_status backup')" = undecided ] \
    && pass "backup target inside a missing iCloud Drive → undecided, not configured" || fail "missing iCloud counted as configured"
mkdir -p "$TMP/home/Library/Mobile Documents/com~apple~CloudDocs"
rc=$(UNAME_DIR="$TMP/darwin" run_entry)
[ "$rc" = 0 ] && grep -q '^TAR-RAN' "$MARK" && pass "macOS with iCloud Drive present → the tar script runs" || fail "Mac with iCloud: rc=$rc marks=$(cat "$MARK" 2>/dev/null)"
rm -rf "$TMP/home/Library"; rm -f "$MARK"; reset_ws; printf 'backup_dir: "%s"\n' "$TMP/bk" > "$WS/params.yaml"
rc=$(run_entry --with-optional)
[ "$rc" = 2 ] && [ ! -e "$MARK" ] && pass "tar with an argument → exit 2, nothing runs" || fail "tar + argument: rc=$rc"
printf 'backup_dir: "%s"\nbackup_engine: zip\n' "$TMP/bk" > "$WS/params.yaml"
rc=$(run_entry)
[ "$rc" = 2 ] && [ ! -e "$MARK" ] && grep -q 'Недопустимое' "$TMP/entry.out" && pass "unknown engine → exit 2, no silent fallback to tar" || fail "invalid engine: rc=$rc"
printf 'backup_engine: restic\n' > "$WS/params.yaml"
rc=$(EXTRA_DIRS="$TMP/fakebin2" run_entry --with-optional)
if [ "$rc" = 0 ] && grep -q "^RESTIC-RAN --with-optional PROG=$TMP/fakebin2/restic" "$MARK" && ! grep -q 'backup_dir относится' "$TMP/entry.out"; then
    pass "explicit restic → restic script with its arguments, program dir on PATH, no backup_dir note"
else
    fail "restic engine: rc=$rc marks=$(cat "$MARK" 2>/dev/null) out=$(cat "$TMP/entry.out")"
fi
rm -f "$MARK"; printf 'backup_engine: restic\nbackup_dir: "%s"\n' "$TMP/bk" > "$WS/params.yaml"
rc=$(EXTRA_DIRS="$TMP/fakebin2" run_entry)
[ "$rc" = 0 ] && grep -q '^RESTIC-RAN' "$MARK" && grep -q 'backup_dir относится к архивам tar' "$TMP/entry.out" \
    && pass "restic + backup_dir → allowed, with a visible note (not an error, not silent)" || fail "restic+backup_dir: rc=$rc out=$(cat "$TMP/entry.out")"
have_restic=0
# the same fixed directories cap_find_program searches in this environment (env -i, a throwaway HOME,
# no HOMEBREW_PREFIX): a restic elsewhere is invisible to the entry point, so it does not count here
for d in /usr/local/bin /usr/bin /bin /snap/bin; do [ -x "$d/restic" ] && have_restic=1; done
if [ "$have_restic" -eq 0 ]; then
    rm -f "$MARK"; reset_ws; printf 'backup_engine: restic\n' > "$WS/params.yaml"
    rc=$(EXTRA_DIRS="" run_entry)
    [ "$rc" = 1 ] && [ ! -e "$MARK" ] && pass "restic chosen but not installed → exit 1 with a reason, nothing runs" || fail "missing restic: rc=$rc"
else
    echo "  ⏭  SKIP: restic is installed on this machine; the 'not installed' case needs a machine without it"
fi

# --- 8. the freshness check follows an explicit engine ----------------------------------------------------
check_out() {  # check_out PARAMS_LINES... - the real check against a throwaway root
    reset_ws; mkdir -p "$WS/.iwe-runtime"
    : > "$WS/params.yaml"; for l in "$@"; do printf '%s\n' "$l" >> "$WS/params.yaml"; done
    env -i HOME="$TMP/home" PATH="$TMP/linux:/usr/bin:/bin" WORKSPACE_DIR="$WS" IWE_ROOT="$WS" IWE_WORKSPACE="$WS" \
        IWE_RUNTIME="$WS/.iwe-runtime" PYTHONUSERBASE="$PYTHONUSERBASE" bash "$ROOT/scripts/iwe-backup-check.sh" --root "$WS" 2>&1
}
out=$(check_out "backup_dir: \"$TMP/bk\"" 'backup_engine: restic')
printf '%s' "$out" | grep -q 'Архивы tar не проверяются: движок бэкапа restic' && pass "explicit restic → tar archives are not judged" || fail "restic engine, section 1: $(printf '%s' "$out" | sed -n '/## 1\./,/## 2\./p' | head -6 | tr '\n' ' ')"
printf '%s' "$out" | grep -q 'backup_dir относится к архивам tar' && pass "restic + backup_dir → the note is in the check output too" || fail "no backup_dir note in the check"
out=$(check_out "backup_dir: \"$TMP/bk\"" 'backup_engine: tar')
printf '%s' "$out" | grep -q 'свежесть снимков restic не проверяется' && pass "explicit tar → restic freshness is not judged" || fail "tar engine, section 5: $(printf '%s' "$out" | sed -n '/## 5\./,/^---/p' | head -6 | tr '\n' ' ')"
out=$(check_out "backup_dir: \"$TMP/bk\"" 'backup_engine: zip')
printf '%s' "$out" | grep -q 'Недопустимое значение backup_engine' && pass "junk engine → a warning in the check" || fail "no warning for an invalid engine"
out=$(check_out "backup_dir: \"$TMP/bk\"")
if ! printf '%s' "$out" | grep -q 'Архивы tar не проверяются: движок\|свежесть снимков restic не проверяется'; then
    pass "engine unset → old behaviour: neither check is switched off"
else
    fail "an unset engine switched a check off"
fi

# the audit shows an invalid engine even before the first probe (the facts are not recorded yet)
reset_ws; printf 'backup_engine: zip\n' > "$WS/params.yaml"
aud=$(env -u LLM_PROXY_URL -u PLATFORM_LLM_PROXY_URL -u IWE_ICLOUD_BACKUP_DIR HOME="$TMP/home" PATH="$TMP/linux:$PATH" \
    WORKSPACE_DIR="$WS" IWE_ROOT="$WS" IWE_WORKSPACE="$WS" IWE_RUNTIME="$WS/.iwe-runtime" IWE_GOVERNANCE_REPO=DS-strategy \
    bash "$ROOT/scripts/iwe-audit.sh" 2>&1 | sed -n '/^## 8\./,$p')
printf '%s' "$aud" | grep -q 'Недопустимое значение `backup_engine`' && pass "audit section 8 warns about an invalid engine before any probe" || fail "no engine warning in the unprobed audit: $(printf '%s' "$aud" | head -4 | tr '\n' ' ')"

# --- 9. restic key safety + bash 3.2 ----------------------------------------------------------------------------
RH="$TMP/rhome"; RB="$TMP/rbin"; RMARK="$TMP/rmark"
mkdir -p "$RH/.iwe-backup" "$RH/srcdir" "$RB"
printf 'tier0_unique:\n  - path: "${HOME}/srcdir"\n' > "$RH/.iwe-backup-sources.local.yaml"
cat > "$RB/restic" <<EOF
#!/bin/sh
echo "RESTIC \$*" >> "$RMARK"
case "\$*" in *"backup --json"*) echo '{"message_type":"summary","snapshot_id":"abc123"}' ;; esac
exit 0
EOF
chmod +x "$RB/restic"
run_restic_run() {  # stock /bin/bash on purpose: macOS has bash 3.2 there, which has no mapfile
    env -i HOME="$RH" PATH="$RB:/usr/bin:/bin" WORKSPACE_DIR="$WS" IWE_ROOT="$WS" IWE_WORKSPACE="$WS" \
        IWE_RUNTIME="$WS/.iwe-runtime" PYTHONUSERBASE="$PYTHONUSERBASE" /bin/bash "$ROOT/scripts/iwe-backup-run.sh" > "$TMP/run.out" 2>&1
    echo $?
}
KEY="$RH/.iwe-backup/protect-repo.key"
rm -f "$RMARK" "$KEY"; printf 'secret-key\n' > "$KEY"; chmod 644 "$KEY"
rc=$(run_restic_run)
if [ "$rc" = 1 ] && [ ! -e "$RMARK" ] && grep -q 'небезопасный файл ключа' "$TMP/run.out" && ! grep -q 'secret-key' "$TMP/run.out"; then
    pass "key readable by others → exit 1 before restic, key content not printed"
else
    fail "644 key: rc=$rc restic-called=$([ -e "$RMARK" ] && echo yes || echo no) out=$(cat "$TMP/run.out")"
fi
rm -f "$RMARK" "$KEY"; printf 'secret-key\n' > "$TMP/realkey"; chmod 600 "$TMP/realkey"; ln -s "$TMP/realkey" "$KEY"
rc=$(run_restic_run)
[ "$rc" = 1 ] && [ ! -e "$RMARK" ] && grep -q 'символьная ссылка' "$TMP/run.out" && pass "key is a symlink → exit 1 before restic" || fail "symlink key: rc=$rc out=$(cat "$TMP/run.out")"
rm -f "$RMARK" "$KEY"; printf 'secret-key\n' > "$KEY"; chmod 600 "$KEY"
rc=$(run_restic_run)
[ "$rc" = 0 ] && grep -q 'RESTIC .*backup' "$RMARK" && pass "key 600, owned by me → the run goes through under /bin/bash" || fail "safe key: rc=$rc out=$(cat "$TMP/run.out")"
rm -f "$RMARK" "$KEY"
rc=$(run_restic_run)
[ "$rc" = 0 ] && [ "$(stat -c %a "$KEY" 2>/dev/null || stat -f %Lp "$KEY")" = 600 ] && pass "no key yet → created with mode 600 and used" || fail "new key: rc=$rc mode=$(stat -c %a "$KEY" 2>/dev/null || stat -f %Lp "$KEY")"

# --- 10. scheduler tasks --------------------------------------------------------------------------------------------
T10="$TMP/sched"; mkdir -p "$T10/ps"
{
    echo 'set -u'
    echo "STATE_DIR='$T10/state'; mkdir -p \"\$STATE_DIR\"; DATE=2026-10-27; NOW=1000; LOG_FILE='$T10/log'"
    echo 'TASK_TIMEOUT_LONG=30; TASK_TIMEOUT_SHORT=30'
    echo 'log() { echo "$1" >> "$LOG_FILE"; }'
    echo 'timeout() { shift; "$@"; }'
    sed -n '/^mark_done() {/,/^}/p;/^mark_interval() {/,/^}/p' "$SCHED"
    sed -n '/^# === Бэкап и возможности установки/,/^# === Очистка старых маркеров/p' "$SCHED" | sed '$d'
    echo 'case "$1" in backup) run_backup_task ;; regress) run_capability_regress_task ;; esac'
} > "$T10/harness.sh"
for s in iwe-backup.sh iwe-capabilities.sh; do printf '#!/bin/bash\nexit "${STUB_RC:-0}"\n' > "$T10/ps/$s"; done
task() {  # task NAME RC - fresh state, run one scheduler task with the stub exiting RC
    rm -rf "$T10/state" "$T10/log"
    STUB_RC="$2" IWE_SCRIPTS="$T10/ps" bash "$T10/harness.sh" "$1" >/dev/null 2>&1
}
has() { [ -e "$T10/state/$1" ]; }
task backup 0
has synchronizer-backup-2026-10-27 && has synchronizer-backup-last && pass "backup success → day marked done, attempt stamped" || fail "backup rc 0 markers"
task backup 1
! has synchronizer-backup-2026-10-27 && has synchronizer-backup-last && grep -q 'backup failed (rc=1' "$T10/log" && pass "backup failure → day NOT done, attempt stamped (no 10-minute retry loop)" || fail "backup rc 1 markers"
task backup 124
has synchronizer-backup-2026-10-27 && grep -q 'timed out' "$T10/log" && pass "backup timeout → no retry today (it would hold the shared lock again), logged" || fail "backup rc 124 markers"
task backup 2
has synchronizer-backup-2026-10-27 && grep -q 'backup contract is invalid' "$T10/log" && pass "invalid contract → marked done (no retry all day), warning logged" || fail "backup rc 2 markers"
# a missing entry point (update not finished) is a plain line: the DayPlan scheduler row reads this
# log, and WARN:/ALARM:/ERROR: lines turn it red while SKIP: lines mark it "deferred"
rm -rf "$T10/state" "$T10/log"; mkdir -p "$T10/empty"
IWE_SCRIPTS="$T10/empty" bash "$T10/harness.sh" backup >/dev/null 2>&1
IWE_SCRIPTS="$T10/empty" bash "$T10/harness.sh" regress >/dev/null 2>&1
if grep -q 'backup: iwe-backup.sh is not in' "$T10/log" && grep -q 'iwe-capabilities.sh is not in' "$T10/log" \
    && ! grep -Eq '(^|[[:space:]])((WARN|ALARM|ERROR|FATAL|SKIP):|(FAILED|GAVE UP) scenario:)' "$T10/log" \
    && ! has synchronizer-backup-2026-10-27 && has synchronizer-backup-last; then
    pass "missing entry points → plain lines (no WARN/SKIP, the DayPlan row stays green), day not done, attempt stamped"
else
    fail "missing scripts: $(cat "$T10/log" 2>/dev/null | tr '\n' ' ')"
fi
task regress 0
has synchronizer-cap-regress-2026-10-27 && pass "regress check finished → day marked done" || fail "regress rc 0"
task regress 1
! has synchronizer-cap-regress-2026-10-27 && has synchronizer-cap-regress-last && grep -q 'did not finish' "$T10/log" \
    && pass "regress check failed (delivery) → day NOT done, attempt stamped (retry after the interval, not every dispatch)" || fail "regress rc 1"
if sed -n '/^dispatch() {/,/^}/p' "$SCHED" | grep -q 'ran_today "synchronizer-backup"' \
    && sed -n '/^dispatch() {/,/^}/p' "$SCHED" | grep -q 'run_backup_task' \
    && sed -n '/^dispatch() {/,/^}/p' "$SCHED" | grep -q 'run_capability_regress_task'; then
    pass "dispatch calls both tasks behind a once-a-day marker"
else
    fail "the tasks are not wired into dispatch"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then echo "ALL PASS"; else echo "FAILED: $FAIL"; exit 1; fi
