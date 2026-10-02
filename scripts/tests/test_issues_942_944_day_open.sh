#!/usr/bin/env bash
# Issues #942 (calendar_source switch) and #944 (stale priorities.yaml must not
# reach the DayPlan). Runs the real functions extracted from the shipped scripts.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

FAILS=0
ok()   { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS + 1)); }

# assert_contains NAME TEXT NEEDLE / assert_lacks NAME TEXT NEEDLE
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) fail "$1 (want «$3», got «$2»)" ;; esac; }
assert_lacks()    { case "$2" in *"$3"*) fail "$1 (unexpected «$3» in «$2»)" ;; *) ok "$1" ;; esac; }

# date_offset N → YYYY-MM-DD, N days from today (negative = past); BSD then GNU date.
date_offset() {
  local n="$1" sign="+"
  [ "$n" -lt 0 ] && { sign="-"; n=$((-n)); }
  date -v"${sign}${n}"d +%Y-%m-%d 2>/dev/null || date -d "${sign}${n} days" +%Y-%m-%d
}

# ---------------------------------------------------------------- #944
echo "== #944 read_morning_priorities"
FUNCS="$TMP/funcs.sh"
awk '/^_prio_epoch\(\) \{/,/^}/ {print} /^read_morning_priorities\(\) \{/,/^}/ {print}' \
  "$ROOT/scripts/day-open-scaffold.sh" > "$FUNCS"
grep -q 'read_morning_priorities' "$FUNCS" || { echo "FAIL: cannot extract the reader"; exit 1; }

GOV=DS-test
mkdir -p "$TMP/ws/$GOV/current"
PRIO="$TMP/ws/$GOV/current/priorities.yaml"

run_reader() {  # extra env passed via env(1) by the caller
  IWE="$TMP/ws" IWE_GOVERNANCE_REPO="$GOV" bash -c '. "$1"; read_morning_priorities' _ "$FUNCS"
}
write_prio() {  # DATE_LINE_VALUE (empty = no last_updated line)
  {
    [ -n "$1" ] && echo "last_updated: \"$1\""
    printf 'today:\n  - WP-101\n  - WP-102\n'
  } > "$PRIO"
}

out=$(run_reader); [ -z "$out" ] && ok "no file → silent" || fail "no file → silent (got «${out}»)"

write_prio "$(date_offset 0)";  out=$(run_reader)
assert_contains "today's date → list shown" "$out" "- WP-101"
assert_lacks    "today's date → no warning" "$out" "⚠️"

write_prio "$(date_offset 1)";  out=$(run_reader)
assert_contains "tomorrow's date (Day Close convention) → list shown" "$out" "- WP-101"

write_prio "$(date_offset -3)"; out=$(run_reader)
assert_contains "3 days old (weekend) → still shown" "$out" "- WP-102"

write_prio "$(date_offset -4)"; out=$(run_reader)
assert_contains "4 days old → warning" "$out" "приоритеты устарели"
assert_lacks    "4 days old → list NOT carried into the DayPlan" "$out" "WP-101"

write_prio "$(date_offset -9)"; out=$(run_reader)
assert_lacks    "9 days old (the reported case) → no stale tasks" "$out" "WP-1"

write_prio "$(date_offset -2)"
out=$(PRIORITIES_STALE_DAYS=1 IWE="$TMP/ws" IWE_GOVERNANCE_REPO="$GOV" bash -c '. "$1"; read_morning_priorities' _ "$FUNCS")
assert_contains "PRIORITIES_STALE_DAYS=1 makes 2 days stale" "$out" "приоритеты устарели"

write_prio "";                  out=$(run_reader)
assert_contains "no last_updated → its own message" "$out" "нет даты last_updated"
assert_lacks    "no last_updated → no list" "$out" "WP-101"

write_prio "not-a-date";        out=$(run_reader)
assert_contains "unreadable date → its own message" "$out" "не читается"
assert_lacks    "unreadable date → no list" "$out" "WP-101"

write_prio "$(date_offset 5)";  out=$(run_reader)
assert_contains "date in the future → its own message" "$out" "в будущем"
assert_lacks    "date in the future → no list" "$out" "WP-101"

printf 'last_updated: "%s"\ntoday: []\n' "$(date_offset 0)" > "$PRIO"; out=$(run_reader)
[ -z "$out" ] && ok "fresh empty list → silent (fallback to yesterday's carry-over)" || fail "fresh empty list (got «${out}»)"

# Day arithmetic must not lose a day across a DST change: 4 calendar days that
# start BEFORE the clock change are 95 h of local time, still 4 days here.
# (Europe/Berlin springs forward 2026-03-29, America/New_York 2026-03-08.)
dst_case() {  # TZ FROM TO
  local diff
  diff=$(TZ="$1" bash -c '. "$1"; a=$(_prio_epoch "$2"); b=$(_prio_epoch "$3"); echo $(( (b - a) / 86400 ))' _ "$FUNCS" "$2" "$3")
  [ "$diff" = 4 ] && ok "DST: $2 → $3 is 4 days in $1" || fail "DST in $1 gives ${diff} days for $2 → $3"
}
dst_case Europe/Berlin 2026-03-28 2026-04-01
dst_case America/New_York 2026-03-07 2026-03-11

# ---------------------------------------------------------------- #942
echo "== #942 calendar_source"
COMMON="$ROOT/scripts/lib/common.sh"
src() { bash -c '. "$1"; iwe_calendar_source "$2"' _ "$COMMON" "$1" 2>"$TMP/err"; }

[ "$(src "$TMP/absent.yaml")" = connector ] && ok "no params file → connector" || fail "no params file → connector"
printf 'video_check: true\n' > "$TMP/p.yaml"
[ "$(src "$TMP/p.yaml")" = connector ] && ok "key missing → connector (existing installs keep working)" || fail "key missing → connector"
for v in connector script none; do
  printf 'calendar_source: %s\n' "$v" > "$TMP/p.yaml"
  [ "$(src "$TMP/p.yaml")" = "$v" ] && ok "calendar_source: $v" || fail "calendar_source: $v"
done
printf 'calendar_source: "none"   # no Google here\n' > "$TMP/p.yaml"
[ "$(src "$TMP/p.yaml")" = none ] && ok "quoted value with a comment → none" || fail "quoted value with a comment"
printf 'calendar_source: "none"   \n' > "$TMP/p.yaml"
[ "$(src "$TMP/p.yaml")" = none ] && ok "quoted none with trailing spaces, no comment → none" || fail "quoted none with trailing spaces"
printf "calendar_source: 'script'  \n" > "$TMP/p.yaml"
[ "$(src "$TMP/p.yaml")" = script ] && ok "single-quoted script with trailing spaces → script" || fail "single-quoted script"
printf 'calendar_source: gcal\n' > "$TMP/p.yaml"
got=$(src "$TMP/p.yaml")
[ "$got" = connector ] && ok "unknown value → connector" || fail "unknown value → connector (got $got)"
assert_contains "unknown value → warning on stderr" "$(cat "$TMP/err")" "неизвестно"

# preflight: none → "disabled" and server-calendar.sh is never started
PF="$TMP/pf"
mkdir -p "$PF/scripts/lib" "$PF/$GOV/exocortex"
cp "$ROOT/scripts/day-open-preflight.sh" "$PF/scripts/"
cp "$ROOT"/scripts/lib/*.sh "$PF/scripts/lib/"
cat > "$PF/scripts/server-calendar.sh" <<EOF
#!/usr/bin/env bash
touch "$PF/calendar-script-was-called"
echo "| 10:00 | meeting |"
EOF
run_preflight() {
  IWE_WORKSPACE="$PF" IWE_GOVERNANCE_REPO="$GOV" HOME="$TMP/home" bash "$PF/scripts/day-open-preflight.sh" 2>/dev/null
}
mkdir -p "$TMP/home"
if command -v jq >/dev/null 2>&1; then
  printf 'calendar_source: none\n' > "$PF/params.yaml"
  out=$(run_preflight); cal=$(printf '%s' "$out" | jq -r .calendar 2>/dev/null)
  [ "$cal" = disabled ] && ok "preflight: none → calendar disabled" || fail "preflight: none → disabled (got «${cal}», out «${out}»)"
  [ ! -e "$PF/calendar-script-was-called" ] && ok "preflight: none → server-calendar.sh not called" || fail "preflight: none → script was called"

  printf 'calendar_source: connector\n' > "$PF/params.yaml"
  out=$(run_preflight); cal=$(printf '%s' "$out" | jq -r .calendar 2>/dev/null)
  [ "$cal" = ok ] && [ -e "$PF/calendar-script-was-called" ] && ok "preflight: connector → script runs, status ok" || fail "preflight: connector (got «${cal}»)"
else
  echo "  skip: jq not installed, preflight cases not run"
fi

# DayPlan calendar section is omitted when the calendar is off
SECTION="$TMP/section.sh"
awk '/^render_calendar_section\(\) \{/,/^}/ {print}' "$ROOT/scripts/day-open-scaffold.sh" > "$SECTION"
off=$(CALENDAR_PF=disabled DAY_NUM=30 MONTH_RU=сентября DATE=2026-09-30 bash -c '. "$1"; render_calendar_section' _ "$SECTION")
on=$(CALENDAR_PF=ok DAY_NUM=30 MONTH_RU=сентября DATE=2026-09-30 bash -c '. "$1"; render_calendar_section' _ "$SECTION")
[ -z "$off" ] && ok "scaffold: disabled → no Календарь section" || fail "scaffold: disabled → section printed"
script_mode=$(CALENDAR_PF=ok CALENDAR_SOURCE=script DAY_NUM=30 MONTH_RU=сентября DATE=2026-09-30 bash -c '. "$1"; render_calendar_section' _ "$SECTION")
assert_contains "scaffold: script mode names server-calendar.sh" "$script_mode" "server-calendar.sh"
assert_lacks    "scaffold: script mode does not send the agent to the connector" "$script_mode" "календарный коннектор (MCP"
assert_contains "scaffold: connector mode still names the connector" "$(CALENDAR_PF=ok CALENDAR_SOURCE=connector DAY_NUM=30 MONTH_RU=сентября DATE=2026-09-30 bash -c '. "$1"; render_calendar_section' _ "$SECTION")" "календарный коннектор (MCP"

assert_contains "scaffold: ok → Календарь section present" "$on" "Календарь (30 сентября)"

echo
if [ "$FAILS" -eq 0 ]; then echo "PASS: issues #942/#944"; else echo "FAILED: $FAILS check(s)"; exit 1; fi
