#!/usr/bin/env bash
# shellcheck disable=SC2034  # stub globals are read by the sourced step0_release_is_older
# WP-529 Ф270, RT-1 of the v0.42.0-rc.1 red team: on an install of the candidate, a plain
# `bash update.sh` (release channel, older 0.41.11) replaced update.sh with the older copy in
# Step 0 and re-executed it; the older updater predates the rollback guard, so 81 files were
# rolled back without ROLLBACK. Step 0 must keep the running updater when the release it
# delivers is older than the installed manifest. Drives the real step0_release_is_older()
# extracted from update.sh with curl stubbed to a local manifest (no network), and checks
# that Step 0 consults it before it replaces and re-executes itself.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
UPDATE_SH="$ROOT/update.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/iwe-f270-step0.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

FAILS=0
ok()   { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS + 1)); }

FUNCS="$TMP/funcs.sh"
extract_function() {
  awk -v signature="$1() {" '
    $0 == signature { found=1 }
    found { print }
    found && /^}$/ { exit }
  ' "$UPDATE_SH"
}
for fn in step0_release_is_older manifest_version version_compare; do
  extract_function "$fn" >> "$FUNCS"
  grep -q "^$fn() {" "$FUNCS" || { echo "FATAL: $fn not found in update.sh" >&2; exit 2; }
done

set_manifest() { printf '{"version": "%s", "files": []}\n' "$2" > "$1"; }

# older_rc INSTALLED_VERSION|- RELEASE_VERSION|- -> step0_release_is_older's exit code
# ("-" = no installed manifest / the release manifest cannot be fetched).
older_rc() {
  (
    # shellcheck disable=SC1090
    . "$FUNCS"
    SCRIPT_DIR="$TMP/install"; TMPDIR_UPDATE="$TMP/run"; RAW_BASE="https://example.invalid"
    CURL_BASE_OPTS=""; _CURL_SSL_OPT=""
    rm -rf "$SCRIPT_DIR" "$TMPDIR_UPDATE"; mkdir -p "$SCRIPT_DIR" "$TMPDIR_UPDATE"
    [ "$1" = "-" ] || set_manifest "$SCRIPT_DIR/update-manifest.json" "$1"
    [ "$2" = "-" ] || set_manifest "$TMP/release-manifest.json" "$2"
    RELEASE_VERSION="$2"
    curl() {
      local out=""
      while [ $# -gt 0 ]; do [ "$1" = "-o" ] && { out="$2"; shift; }; shift; done
      [ "$RELEASE_VERSION" = "-" ] && return 22
      cp "$TMP/release-manifest.json" "$out"
    }
    rc=0
    step0_release_is_older || rc=$?
    echo "$rc"
  ) 2>/dev/null
}

echo "== decision =="
rc=$(older_rc 0.42.0 0.41.11)
[ "$rc" = "0" ] && ok "installed 0.42.0, release 0.41.11 -> keep the running updater (0)" \
  || fail "rollback case: expected 0, got $rc"
rc=$(older_rc 0.41.11 0.42.0)
[ "$rc" = "1" ] && ok "installed 0.41.11, release 0.42.0 -> self-update as before (1)" \
  || fail "normal update: expected 1, got $rc"
rc=$(older_rc 0.42.0 0.42.0)
[ "$rc" = "1" ] && ok "equal versions -> self-update as before (1)" \
  || fail "equal versions: expected 1, got $rc"
rc=$(older_rc - 0.41.11)
[ "$rc" = "1" ] && ok "no installed manifest (old install) -> self-update as before (1)" \
  || fail "no installed manifest: expected 1, got $rc"
rc=$(older_rc 0.42.0 -)
[ "$rc" = "1" ] && ok "release manifest not fetched -> self-update as before (1)" \
  || fail "fetch failure: expected 1, got $rc"
rc=$(older_rc 0.42.0 dev)
[ "$rc" = "1" ] && ok "unreadable release version -> self-update as before (1)" \
  || fail "unreadable version: expected 1, got $rc"

echo "== wiring: Step 0 asks before it replaces and re-executes itself =="
STEP0=$(awk '/^# === Step 0: Self-update/{f=1} /^# === Step 1:/{f=0} f' "$UPDATE_SH")
guard_line=$(printf '%s\n' "$STEP0" | grep -n '^    elif step0_release_is_older; then' | cut -d: -f1)
replace_line=$(printf '%s\n' "$STEP0" | grep -n 'Найдена новая версия update.sh' | cut -d: -f1)
exec_line=$(printf '%s\n' "$STEP0" | grep -n 'exec bash "\$SCRIPT_DIR/update.sh"' | cut -d: -f1)
if [ -n "$guard_line" ] && [ -n "$replace_line" ] && [ -n "$exec_line" ] \
   && [ "$guard_line" -lt "$replace_line" ] && [ "$replace_line" -lt "$exec_line" ]; then
  ok "guard (line $guard_line) precedes replace ($replace_line) and exec ($exec_line) in Step 0"
else
  fail "Step 0 wiring: guard=$guard_line replace=$replace_line exec=$exec_line"
fi
printf '%s\n' "$STEP0" | grep -q '^    elif \$CHECK_ONLY && step0_release_is_older; then' \
  && ok "--check reports the kept updater instead of 'a newer update.sh is available'" \
  || fail "--check branch for an older release update.sh is missing"

echo
if [ "$FAILS" -gt 0 ]; then
  echo "FAILED: $FAILS check(s)"
  exit 1
fi
echo "PASS"
