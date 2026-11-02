#!/usr/bin/env bash
# Issue #1410: the install time zone is a params.yaml key (`timezone:`), not
# the author's Asia/Nicosia hardcoded in the platform files.
# Drives the real iwe_timezone from lib/common.sh, not a reimplementation.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

FAILS=0
ok()   { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS + 1)); }

# shellcheck source=../lib/common.sh
source "$ROOT/scripts/lib/common.sh"

echo "== iwe_timezone: resolution from params.yaml =="
[ -z "$(iwe_timezone "$TMP/missing.yaml")" ] \
  && ok "missing file -> empty (system zone)" || fail "missing file -> empty"

printf 'other_key: 1\n' > "$TMP/p1.yaml"
[ -z "$(iwe_timezone "$TMP/p1.yaml")" ] \
  && ok "key absent -> empty" || fail "key absent -> empty"

printf 'timezone:\n' > "$TMP/p2.yaml"
[ -z "$(iwe_timezone "$TMP/p2.yaml")" ] \
  && ok "empty value -> empty" || fail "empty value -> empty"

printf 'timezone: "Asia/Vladivostok"   # UTC+10\n' > "$TMP/p3.yaml"
[ "$(iwe_timezone "$TMP/p3.yaml")" = "Asia/Vladivostok" ] \
  && ok "quoted value with comment -> Asia/Vladivostok" || fail "quoted value with comment"

# The unknown-zone check needs a zoneinfo database; Git Bash has none and
# trusts the value as given, so the check is skipped there.
if [ -d "${TZDIR:-/nonexistent}" ] || [ -d /usr/share/zoneinfo ] || [ -d /etc/zoneinfo ]; then
  printf 'timezone: Mars/Base\n' > "$TMP/p4.yaml"
  [ -z "$(iwe_timezone "$TMP/p4.yaml" 2>/dev/null)" ] \
    && ok "unknown zone -> empty" || fail "unknown zone -> empty"
  iwe_timezone "$TMP/p4.yaml" 2>&1 >/dev/null | grep -q "не найден" \
    && ok "unknown zone warns on stderr" || fail "unknown zone warns on stderr"
else
  echo "  skip: no zoneinfo database on this host"
fi

echo "== no author time zone left in shipped platform files =="
HITS=$(grep -rln "TZ=Asia/Nicosia\|default=\"Europe/Nicosia\"\|\`Asia/Nicosia\` (UTC+3)" \
  "$ROOT/scripts" "$ROOT/seed" "$ROOT/memory" 2>/dev/null | grep -v '/tests/' || true)
[ -z "$HITS" ] && ok "no hardcoded Nicosia" || fail "hardcoded Nicosia in: $HITS"

grep -q '^timezone:' "$ROOT/params.yaml.example" \
  && ok "params.yaml.example documents timezone" || fail "params.yaml.example lacks timezone"

echo
if [ "$FAILS" -eq 0 ]; then
  echo "test_issue_1410_timezone_param: all checks passed"
else
  echo "test_issue_1410_timezone_param: $FAILS check(s) failed"
  exit 1
fi
