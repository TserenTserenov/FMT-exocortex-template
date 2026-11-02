#!/usr/bin/env bash
# Issue #1398: week-draft-append.sh takes the closed day from --date (not the
# clock), parses `wakatime-cli --today` text by unit words, and writes "—"
# instead of a fabricated 0min when WakaTime has no value.
# Runs the real script against a throwaway workspace; no network: the API
# helper finds no key (HOME is the fixture) and exits 3.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT/scripts/week-draft-append.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

FAILS=0
ok()   { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS + 1)); }

WS="$TMP/ws"
mkdir -p "$WS/KI" "$TMP/home"
printf 'knowledge_repo: KI\n' > "$WS/params.yaml"

# Fake CLI prints whatever $FAKE_WAKA holds.
FAKE_CLI="$TMP/wakatime-cli"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$FAKE_WAKA"\n' > "$FAKE_CLI"
chmod +x "$FAKE_CLI"

draft() {  # draft <year> <NN-month> <week> <row labels...>
  local dir="$WS/KI/docs/$1/$2" week=$3; shift 3
  mkdir -p "$dir"
  { echo "| День | WakaTime | Коммиты | РП | Бюджет | Прогресс |"
    echo "|---|---|---|---|---|---|"
    for l in "$@"; do echo "| $l | | | | | |"; done; } > "$dir/week-draft-w$week.md"
}

run() {
  HOME="$TMP/home" WAKATIME_API_KEY="" WORKSPACE_DIR="$WS" WAKATIME_CLI="$FAKE_CLI" \
    bash "$SCRIPT" "$@" 2>"$TMP/err"
}

echo "== --date picks the closed day, not the clock =="
draft 2026 03-октябрь 44 "Пн 26" "Вт 27" "Ср 28" "Чт 29" "Пт 30" "Сб 31" "Вс 1"
OUT=$(FAKE_WAKA="4 hrs 22 mins" run --date 2026-10-28 --dry-run)
echo "$OUT" | grep -q '^| Ср 28 | — |' \
  && ok "past day: row Ср 28, CLI not used for a past day -> —" \
  || fail "past day row (got: $(echo "$OUT" | grep '^|'))"

echo "== Monday's folder for a week across a month boundary =="
OUT=$(FAKE_WAKA="" run --date 2026-11-01 --dry-run)
echo "$OUT" | grep -q 'docs/2026/03-октябрь/week-draft-w44.md' \
  && ok "Sunday 01.11 uses the October draft of W44" \
  || fail "month boundary (got: $(echo "$OUT" | head -1))"
echo "$OUT" | grep -q '^| Вс 1 |' && ok "row label Вс 1" || fail "row label Вс 1"

echo "== wakatime-cli --today parsing (today only) =="
TODAY=$(date +%Y-%m-%d)
read -r Y M W L <<< "$(python3 -c '
from datetime import date, timedelta
d = date.today(); m = d - timedelta(days=d.isoweekday() - 1)
names = ["январь","февраль","март","апрель","май","июнь","июль","август","сентябрь","октябрь","ноябрь","декабрь"]
dow = ["Пн","Вт","Ср","Чт","Пт","Сб","Вс"][d.isoweekday() - 1]
print(m.year, "%02d-%s" % (13 - m.month, names[m.month - 1]), "%02d" % d.isocalendar()[1], dow + "_" + str(d.day))')"
draft "$Y" "$M" "$W" "${L/_/ }"
for case in "21 mins|21min" "4 hrs 22 mins|4h 22min" "1 hr 5 mins|1h 05min" "2 hrs|2h 00min" \
            "Today: 4 hrs 22 mins|4h 22min" "|—" "0 secs|—"; do
  in=${case%%|*}; want=${case##*|}
  got=$(FAKE_WAKA="$in" run --date "$TODAY" --dry-run | grep '^|' | awk -F' [|] ' '{print $2}')
  [ "$got" = "$want" ] && ok "«$in» -> $want" || fail "«$in» -> want $want, got $got"
done
FAKE_WAKA="" run --date "$TODAY" --dry-run >/dev/null
grep -q "нет значения" "$TMP/err" && ok "empty value is logged on stderr" || fail "empty value not logged"

echo "== bad --date is rejected =="
run --date 28.10.2026 --dry-run >/dev/null; rc=$?
[ "$rc" = 2 ] && ok "28.10.2026 -> exit 2" || fail "bad date exit code $rc"

echo
if [ "$FAILS" -eq 0 ]; then
  echo "test_issue_1398_week_draft_append: all checks passed"
else
  echo "test_issue_1398_week_draft_append: $FAILS check(s) failed"
  exit 1
fi
