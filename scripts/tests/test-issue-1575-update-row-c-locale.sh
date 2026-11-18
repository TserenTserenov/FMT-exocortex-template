#!/usr/bin/env bash
# issue #1575: the Day Open "Update IWE" row picks the update.sh --check --fast
# verdict with grep. Under cron/launchd there is no LANG/LC_ALL (C locale), and a
# bracket expression like [✓⚠] is then a set of BYTES, so the new informational
# line "ℹ …" (same leading byte E2) was picked instead of the verdict -> a false
# yellow row every morning. This runs the real selection block from both shipped
# copies of day-open-scaffold.sh in an empty environment (C locale).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

INFO_LINE='ℹ Сводка «Главное в этом обновлении» в режиме --fast недоступна: файлы релиза не скачиваются.'
OK_LINE='✓ Версия и состав манифеста совпадают (0.42.0)'
WARN_LINE='⚠ Доступна новая версия: 0.42.1'

# run_block <scaffold> <update output> -> prints "<emoji>|<status>" computed by the
# script's own block, executed with no locale variables at all.
run_block() {
  local scaffold="$1" output="$2" block="$SANDBOX/block.sh"
  {
    echo 'upd_output=$(cat "$1")'
    awk '/upd_status=\$\(printf .%s\\n. "\$upd_output"/ {on=1} on {print} on && /^[[:space:]]*esac[[:space:]]*$/ {exit}' "$scaffold"
    echo 'printf "%s|%s\n" "$upd_emoji" "$upd_status"'
  } > "$block"
  grep -q 'case "\$upd_status"' "$block" || fail "selection block not found in $scaffold"
  printf '%s\n' "$output" > "$SANDBOX/out.txt"
  env -i PATH=/usr/bin:/bin bash "$block" "$SANDBOX/out.txt"
}

for rel in scripts/day-open-scaffold.sh seed/strategy/scripts/day-open-scaffold.sh; do
  scaffold="$ROOT/$rel"
  [ -f "$scaffold" ] || fail "missing $rel"

  got=$(run_block "$scaffold" "$INFO_LINE"$'\n\n'"$OK_LINE")
  [ "$got" = "🟢|$OK_LINE" ] || fail "$rel: no update, C locale -> expected green verdict, got: $got"

  got=$(run_block "$scaffold" "$INFO_LINE"$'\n\n'"$WARN_LINE")
  [ "$got" = "🟡|$WARN_LINE" ] || fail "$rel: update available, C locale -> expected yellow ⚠ verdict, got: $got"

  got=$(run_block "$scaffold" "$INFO_LINE")
  case "$got" in
    "🟡|не удалось определить статус"*) ;;
    *) fail "$rel: no verdict line -> expected the 'cannot determine' fallback, got: $got" ;;
  esac
  pass "$rel: Update IWE row picks the ✓/⚠ verdict, not the ℹ line, in the C locale"
done
