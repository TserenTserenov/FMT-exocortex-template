#!/usr/bin/env bash
# Issue #943: fetch_update_manifest() in update.sh. A stubbed curl (PATH) plays a
# scripted sequence of outcomes; the real function is extracted from update.sh.
# Temp-only, no network. Bash 3.2 compatible.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SELF_DIR")"
UPDATE_SH="$REPO_ROOT/update.sh"

FAILS=0
ok()   { echo "  ✅ PASS: $1"; }
fail() { echo "  ❌ FAIL: $1" >&2; FAILS=$((FAILS + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

FUNC="$TMP/func.sh"
awk '/^fetch_update_manifest\(\) \{/ {found=1} found {print} found && /^}$/ {exit}' "$UPDATE_SH" > "$FUNC"
grep -q '^fetch_update_manifest() {' "$FUNC" || { echo "FATAL: cannot extract fetch_update_manifest" >&2; exit 2; }

# --- stub curl: outcome N of the run is the N-th word of $FAKE_SEQ.
#   ok          200, valid JSON          rcN[:HTTP]  curl exit N (default HTTP 000)
#   html        200, an HTML page        empty       exit 0, no body
# In "-o FILE" mode the HTTP code goes to stdout (curl -w), the body to FILE;
# without -o the body goes to stdout.  Every call is appended to $FAKE_LOG.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
out=""; want_code=false
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift ;;
    -w) want_code=true; shift ;;
  esac
  shift
done
n=$(( $(cat "$FAKE_COUNT" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE_COUNT"
echo "call $n mode=$([ -n "$out" ] && echo file || echo stdout)" >> "$FAKE_LOG"
outcome=$(echo $FAKE_SEQ | awk -v n="$n" '{print $n}'); outcome="${outcome:-ok}"
body=""; code="200"; rc=0
case "$outcome" in
  ok)    body='{"schema_version":2,"files":{}}' ;;
  html)  body='<html>Please log in</html>' ;;
  empty) body="" ;;
  rc*)   rc="${outcome#rc}"; code="000"
         case "$rc" in *:*) code="${rc#*:}"; rc="${rc%%:*}" ;; esac
         echo "curl: ($rc) fake failure $n" >&2 ;;
esac
if [ "$rc" -eq 0 ]; then
  if [ -n "$out" ]; then printf '%s' "$body" > "$out"; else printf '%s' "$body"; fi
fi
$want_code && printf '%s' "$code"
exit "$rc"
STUB
chmod +x "$TMP/bin/curl"

# run_case SEQ [DEST_DIR] — runs the function with the scripted sequence.
# Sets: RC (function status), CALLS, OUT (its stdout), DEST, DIAG.
run_case() {
  local seq="$1" dir="${2:-$TMP/case}"
  mkdir -p "$dir"
  DEST="$dir/manifest.json"
  : > "$TMP/count"; : > "$TMP/log"
  OUT=$(
    PATH="$TMP/bin:$PATH" FAKE_SEQ="$seq" FAKE_COUNT="$TMP/count" FAKE_LOG="$TMP/log" \
    CURL_BASE_OPTS="" _CURL_SSL_OPT="" IWE_FETCH_RETRY_SLEEP=0 \
    bash -c '. "$1"; fetch_update_manifest "https://example.invalid/m.json" "$2"; rc=$?; echo "@@DIAG:$FETCH_MANIFEST_DIAG"; exit $rc' _ "$FUNC" "$DEST"
  )
  RC=$?
  CALLS=$(wc -l < "$TMP/log" | tr -d ' ')
  DIAG=$(printf '%s\n' "$OUT" | sed -n 's/^@@DIAG://p')
  OUT=$(printf '%s\n' "$OUT" | grep -v '^@@DIAG:')
}

valid_json_in() { grep -q '"schema_version":2' "$1" 2>/dev/null; }

echo "== success at once"
rm -f "$TMP/case/manifest.json"
run_case "ok"
[ "$RC" -eq 0 ] && [ "$CALLS" -eq 1 ] && valid_json_in "$DEST" && ok "one attempt, valid manifest in place" || fail "success at once (rc=$RC calls=$CALLS)"
[ ! -e "$DEST.part" ] && [ ! -e "$DEST.err" ] && ok "no temp files left" || fail "temp files left behind"

echo "== transient errors are retried"
rm -f "$TMP/case/manifest.json"
run_case "rc28 rc28 ok"
[ "$RC" -eq 0 ] && [ "$CALLS" -eq 3 ] && valid_json_in "$DEST" && ok "timeout twice, then success on attempt 3" || fail "transient then success (rc=$RC calls=$CALLS)"

echo "== three failures keep the old manifest and say why"
mkdir -p "$TMP/keep"; echo '{"old":true}' > "$TMP/keep/manifest.json"
run_case "rc28 rc28 rc28" "$TMP/keep"
[ "$RC" -ne 0 ] && [ "$CALLS" -eq 3 ] && ok "gives up after 3 attempts" || fail "three failures (rc=$RC calls=$CALLS)"
grep -q '"old":true' "$DEST" && ok "previous manifest untouched" || fail "previous manifest was replaced"
case "$DIAG" in *"curl код 28"*) ok "diagnostic names curl exit code 28" ;; *) fail "diagnostic lacks the code: $DIAG" ;; esac
case "$OUT" in *"fake failure 3"*) ok "stderr line of the failing attempt is shown" ;; *) fail "stderr line not shown: $OUT" ;; esac

echo "== HTTP 404 is not retried"
run_case "rc22:404 ok"
[ "$RC" -ne 0 ] && [ "$CALLS" -eq 1 ] && ok "one attempt only" || fail "404 retried or accepted (rc=$RC calls=$CALLS)"
case "$DIAG" in *"HTTP 404"*) ok "diagnostic carries HTTP 404" ;; *) fail "no HTTP status in: $DIAG" ;; esac

echo "== HTTP 503 and 429 are retried"
run_case "rc22:503 ok"
[ "$RC" -eq 0 ] && [ "$CALLS" -eq 2 ] && ok "503 then success" || fail "503 (rc=$RC calls=$CALLS)"
run_case "rc22:429 ok"
[ "$RC" -eq 0 ] && [ "$CALLS" -eq 2 ] && ok "429 then success" || fail "429 (rc=$RC calls=$CALLS)"

echo "== a 200 that is not JSON never replaces the manifest"
mkdir -p "$TMP/html"; echo '{"old":true}' > "$TMP/html/manifest.json"
run_case "html" "$TMP/html"
[ "$RC" -ne 0 ] && grep -q '"old":true' "$DEST" && ok "HTML page rejected, old manifest kept" || fail "HTML accepted (rc=$RC)"
case "$DIAG" in *"не похож на JSON"*) ok "diagnostic explains it" ;; *) fail "diagnostic: $DIAG" ;; esac

echo "== write failure (curl 23) switches to the redirect experiment"
rm -f "$TMP/case/manifest.json"
run_case "rc23 ok"
[ "$RC" -eq 0 ] && [ "$CALLS" -eq 2 ] && valid_json_in "$DEST" && ok "second attempt succeeded" || fail "rc23 (rc=$RC calls=$CALLS)"
[ "$(sed -n 2p "$TMP/log")" = "call 2 mode=stdout" ] && ok "second attempt wrote through the redirect" || fail "second call mode: $(sed -n 2p "$TMP/log")"
case "$OUT" in *"диагностика"*) ok "the experiment is labelled in the output" ;; *) fail "experiment not labelled: $OUT" ;; esac

echo "== an empty file after a clean exit counts as a write failure"
rm -f "$TMP/case/manifest.json"
run_case "empty ok"
[ "$RC" -eq 0 ] && [ "$(sed -n 2p "$TMP/log")" = "call 2 mode=stdout" ] && ok "empty file → redirect attempt" || fail "empty file (rc=$RC, $(sed -n 2p "$TMP/log"))"

echo "== the redirect experiment cannot see the HTTP status: a 22 there is retried, not given up"
rm -f "$TMP/case/manifest.json"
run_case "rc23 rc22 ok"
[ "$RC" -eq 0 ] && [ "$CALLS" -eq 3 ] && valid_json_in "$DEST" && ok "23, then a 22 in redirect mode, then success" || fail "rc23 rc22 ok (rc=$RC calls=$CALLS)"

echo "== a failed move into place is reported, not hidden"
mkdir -p "$TMP/mvfail"
cat > "$TMP/bin/mv" <<'MVSTUB'
#!/bin/sh
echo "mv: cannot move: Permission denied" >&2
exit 1
MVSTUB
chmod +x "$TMP/bin/mv"
run_case "ok" "$TMP/mvfail"
rm -f "$TMP/bin/mv"
[ "$RC" -ne 0 ] && ok "returns a failure" || fail "a failed mv counted as success"
case "$DIAG" in *"не записан"*) ok "the diagnostic says the manifest was not written" ;; *) fail "diag: $DIAG" ;; esac
[ ! -e "$TMP/mvfail/manifest.json" ] && ok "no half-written manifest" || fail "manifest exists after a failed move"

echo "== a path with spaces"
rm -f "$TMP/with space/manifest.json"
run_case "ok" "$TMP/with space"
[ "$RC" -eq 0 ] && valid_json_in "$DEST" && ok "works" || fail "spaces (rc=$RC)"

echo "== a certificate error (60) stops at once"
run_case "rc60 ok"
[ "$RC" -ne 0 ] && [ "$CALLS" -eq 1 ] && ok "no retry on a non-transient error" || fail "rc60 (rc=$RC calls=$CALLS)"

echo
if [ "$FAILS" -eq 0 ]; then echo "PASS: update manifest fetch (#943)"; else echo "FAILED: $FAILS check(s)"; exit 1; fi
