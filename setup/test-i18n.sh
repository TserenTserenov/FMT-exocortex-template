#!/bin/bash
# test-i18n.sh — language catalogs (.claude/lib/i18n.sh) and their first users
# (WP-610 F9 step 2).
#
# The expected outputs of close-gate-reminder.sh in setup/i18n-fixtures/ were
# captured by running the hook from origin/main 557e8bfe BEFORE it moved to the
# catalogs; they are an independent reference, not derived from the catalogs.
# Fixture 08 ("не закрывай пока" -> session close) records known behaviour,
# not a desired one: negation is a separate change.
#
# Usage: bash setup/test-i18n.sh
# Exit:  0 all checks passed, 1 a check failed.

set -u

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
LIB="$REPO_ROOT/.claude/lib/i18n.sh"
LOCALE="$REPO_ROOT/.claude/lib/locale"
HOOK="$REPO_ROOT/.claude/hooks/close-gate-reminder.sh"
FIXTURES="$REPO_ROOT/setup/i18n-fixtures/close-gate-reminder"
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
# Inner shells use the interpreter running this file, so `/bin/bash setup/test-i18n.sh`
# really exercises bash 3.2 rather than whatever bash comes first on PATH.
echo "bash: $BASH ($BASH_VERSION)"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAILS=0
ok()   { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; FAILS=$((FAILS + 1)); }

# check <name> <expected> <actual>
check() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1: expected [$2], got [$3]"; fi; }

# run_lib <locale dir> <IWE_LANG> <shell snippet> — prints stdout, then "rc=N".
run_lib() {
  local out rc
  out=$(IWE_LOCALE_DIR="$1" IWE_LANG="$2" "$BASH" -c ". '$LIB'; $3" 2>"$TMP/stderr"; printf 'rc=%s' "$?")
  printf '%s' "$out"
}

# locale_with <name> <catalog>... — a locale dir holding copies of the named catalogs.
locale_with() {
  local dir="$TMP/$1" c
  shift
  mkdir -p "$dir"
  for c in "$@"; do cp "$LOCALE/$c.json" "$dir/"; done
  printf '%s' "$dir"
}

echo "== language selection =="
BOTH=$(locale_with both ru en)
check "both catalogs, IWE_LANG unset -> ru" "ru
rc=0" "$(run_lib "$BOTH" "" i18n_lang)"
check "IWE_LANG=en" "en
rc=0" "$(run_lib "$BOTH" en i18n_lang)"
check "unknown IWE_LANG is an error" "rc=3" "$(run_lib "$BOTH" xx i18n_lang)"
check "IWE_LANG cannot leave the locale dir" "rc=3" "$(run_lib "$BOTH" ../locale/en i18n_lang)"
ONLY_EN=$(locale_with only-en en)
check "the only shipped catalog wins" "en
rc=0" "$(run_lib "$ONLY_EN" "" i18n_lang)"
NO_RU=$(locale_with no-ru en)
cp "$LOCALE/en.json" "$NO_RU/de.json"
check "several catalogs without ru is an error" "rc=3" "$(run_lib "$NO_RU" "" i18n_lang)"
mkdir -p "$TMP/empty"
check "no catalogs is an error" "rc=3" "$(run_lib "$TMP/empty" "" i18n_lang)"
BROKEN=$(locale_with broken en)
printf '{"agent.close_gate.day": ' > "$BROKEN/ru.json"
check "a corrupt catalog is an error, not a missing one" "rc=3" \
  "$(run_lib "$BROKEN" ru 'i18n_msg agent.close_gate.day')"

echo "== formatting =="
FMT=$(locale_with fmt)
cat > "$FMT/ru.json" <<'EOF'
{
  "msg.two": "a %s b %s",
  "msg.percent": "100%% done, %%s stays",
  "msg.bad": "count %d",
  "msg.newline": "line\n\n",
  "msg.number": 5,
  "recognition.bad": "(unclosed"
}
EOF
check "positional %s" "a x b y
rc=0" "$(run_lib "$FMT" "" 'i18n_msg msg.two x y; echo')"
check "%% and %%s are literal" "100% done, %s stays
rc=0" "$(run_lib "$FMT" "" 'i18n_msg msg.percent; echo')"
check "an argument is not formatted again" "a %s b \\\$x
rc=0" "$(run_lib "$FMT" "" "i18n_msg msg.two '%s' '\\\$x'; echo")"
check "fewer arguments than %s is an error" "rc=3" "$(run_lib "$FMT" "" 'i18n_msg msg.two x')"
check "more arguments than %s is an error" "rc=3" "$(run_lib "$FMT" "" 'i18n_msg msg.two x y z')"
check "a specifier other than %s is an error" "rc=3" "$(run_lib "$FMT" "" 'i18n_msg msg.bad 1')"
check "a missing key is an error" "rc=3" "$(run_lib "$FMT" "" 'i18n_msg msg.absent')"
check "a non-string value is an error" "rc=3" "$(run_lib "$FMT" "" 'i18n_msg msg.number')"
check "trailing newlines are kept" "6" \
  "$(IWE_LOCALE_DIR="$FMT" "$BASH" -c ". '$LIB'; i18n_msg msg.newline" | wc -c | tr -d ' ')"
check "a pattern key is refused by i18n_msg" "rc=3" "$(run_lib "$FMT" "" 'i18n_msg recognition.bad')"

echo "== recognition =="
check "union over all catalogs, in catalog file order" "(close the day|closing the day|day close)|(итоги дня|закрываю день|закрывай день)
rc=0" "$(run_lib "$BOTH" "" 'i18n_pattern recognition.close_day; echo')"
check "match" "rc=0" "$(run_lib "$BOTH" "" 'i18n_match recognition.close_day "итоги дня"')"
check "no match" "rc=1" "$(run_lib "$BOTH" "" 'i18n_match recognition.close_day "привет"')"
check "an early match in long multi-line text under pipefail" "rc=0" \
  "$(run_lib "$BOTH" "" 'set -o pipefail; t="итоги дня"; for i in $(seq 4000); do t="$t
filler line number $i of a long prompt"; done; i18n_match recognition.close_day "$t"')"
check "an invalid expression is an error, not a no-match" "rc=3" \
  "$(run_lib "$FMT" "" 'i18n_match recognition.bad "x"')"

echo "== close-gate-reminder.sh against the pre-catalog reference =="
for prompt in "$FIXTURES"/*.prompt; do
  name=$(basename "$prompt" .prompt)
  jq -n --rawfile p "$prompt" '{prompt:$p}' | "$BASH" "$HOOK" > "$TMP/out" 2>"$TMP/stderr"
  if cmp -s "$TMP/out" "$FIXTURES/$name.expected"; then
    ok "fixture $name: $(head -n 1 "$prompt")"
  else
    fail "fixture $name differs from the reference"
  fi
done

hook_context() { # <prompt> — additionalContext or {} when the hook stays silent
  jq -n --arg p "$1" '{prompt:$p}' | "$BASH" "$HOOK" | jq -r '.hookSpecificOutput.additionalContext // "{}"'
}
DAY_RU=$(IWE_LOCALE_DIR="$LOCALE" "$BASH" -c ". '$LIB'; i18n_msg agent.close_gate.day")
SESSION_RU=$(IWE_LOCALE_DIR="$LOCALE" "$BASH" -c ". '$LIB'; i18n_msg agent.close_gate.session")
check "English day phrase -> day instruction" "$DAY_RU" "$(hook_context 'Close the day, please')"
check "English session phrase -> session instruction" "$SESSION_RU" "$(hook_context "let's close the session")"
check "day wins over session in one prompt" "$DAY_RU" "$(hook_context 'close the day and push and close')"
check "unrelated English stays silent" "{}" "$(hook_context 'the issue is closed')"

EN_ONLY_HOOK="$TMP/en-install/.claude"
mkdir -p "$EN_ONLY_HOOK/hooks" "$EN_ONLY_HOOK/lib/locale"
cp "$HOOK" "$EN_ONLY_HOOK/hooks/"
cp "$LIB" "$EN_ONLY_HOOK/lib/"
cp "$LOCALE/en.json" "$EN_ONLY_HOOK/lib/locale/"
EN_DAY=$(jq -n --arg p 'close the day' '{prompt:$p}' | "$BASH" "$EN_ONLY_HOOK/hooks/close-gate-reminder.sh" \
  | jq -r '.hookSpecificOutput.additionalContext')
case "$EN_DAY" in
  "⛔ BLOCKING: Day Close"*) ok "English-only install answers in English" ;;
  *) fail "English-only install: got [$EN_DAY]" ;;
esac

printf '{"agent.close_gate.day": ' > "$EN_ONLY_HOOK/lib/locale/en.json"
jq -n --arg p 'close the day' '{prompt:$p}' | "$BASH" "$EN_ONLY_HOOK/hooks/close-gate-reminder.sh" \
  > "$TMP/out" 2>"$TMP/stderr"
rc=$?
if [ "$rc" -ne 0 ] && [ ! -s "$TMP/out" ] && [ -s "$TMP/stderr" ]; then
  ok "broken catalog: non-zero exit, diagnostic, no JSON"
else
  fail "broken catalog: rc=$rc stdout=$(wc -c < "$TMP/out") stderr=$(wc -c < "$TMP/stderr")"
fi

echo "== DayPlan validators accept the yesterday heading in both languages =="
for lang in ru en; do
  heading=$(IWE_LOCALE_DIR="$LOCALE" IWE_LANG=$lang "$BASH" -c ". '$LIB'; i18n_msg format.dayplan.yesterday 2 \"\$(i18n_msg format.month_genitive.11)\"")
  pattern=$(IWE_LOCALE_DIR="$LOCALE" "$BASH" -c ". '$LIB'; i18n_pattern recognition.dayplan.section.yesterday")
  if printf '<summary><b>%s</b></summary>\n' "$heading" | grep -qE "$pattern"; then
    ok "$lang heading [$heading] is recognised"
  else
    fail "$lang heading [$heading] is not recognised by [$pattern]"
  fi
done
check "Russian heading text" "Итоги вчера (2 ноября)" \
  "$(IWE_LOCALE_DIR="$LOCALE" "$BASH" -c ". '$LIB'; i18n_msg format.dayplan.yesterday 2 \"\$(i18n_msg format.month_genitive.11)\"")"

echo "== validate-staged-artifacts.sh promoted into the governance repo =="
# <workspace>/.claude/lib is installed by setup.sh; the promoted validator sits in
# <workspace>/<governance repo>/scripts and runs from a git hook without IWE_* set.
PROMOTED="$TMP/promoted-ws"
mkdir -p "$PROMOTED/.claude" "$PROMOTED/DS-strategy/scripts"
cp -R "$REPO_ROOT/.claude/lib" "$PROMOTED/.claude/"
cp "$REPO_ROOT/scripts/validate-staged-artifacts.sh" "$PROMOTED/DS-strategy/scripts/"
# Run the validator's own library lookup, with BASH_SOURCE[0] pinned to the copy's path.
sed -n '/^VALIDATOR_DIR=/,/^done$/p' "$PROMOTED/DS-strategy/scripts/validate-staged-artifacts.sh" \
  | sed "s#\"\${BASH_SOURCE\[0\]}\"#\"$PROMOTED/DS-strategy/scripts/validate-staged-artifacts.sh\"#" > "$TMP/lookup.sh"
pattern=$(env -u IWE_WORKSPACE -u IWE_ROOT "$BASH" -c ". '$TMP/lookup.sh'; printf '%s' \"\$I18N_LIB\"")
check "promoted copy finds the workspace library" "$PROMOTED/DS-strategy/scripts/../../.claude/lib/i18n.sh" "$pattern"

echo "== scripts/check-locale-catalogs.py =="
CHECKER="$REPO_ROOT/scripts/check-locale-catalogs.py"
python3 "$CHECKER" "$REPO_ROOT" > "$TMP/check.out"
check "the shipped catalogs are clean" "0" "$?"
# check_offence <name> <expected line> — run the checker on a copy of the catalogs
# after the caller damaged $DAMAGED/.claude/lib/locale.
check_offence() {
  python3 "$CHECKER" "$DAMAGED" > "$TMP/check.out"
  local rc=$?
  if [ "$rc" -eq 1 ] && grep -qF -- "$2" "$TMP/check.out"; then ok "$1"; else fail "$1: rc=$rc, output: $(head -3 "$TMP/check.out")"; fi
}
reset_damaged() {
  rm -rf "$DAMAGED"
  mkdir -p "$DAMAGED/.claude/lib"
  cp -R "$LOCALE" "$DAMAGED/.claude/lib/"
  printf '{"files": []}\n' > "$DAMAGED/update-manifest.json"
}
DAMAGED="$TMP/damaged"
reset_damaged
jq 'del(.["format.month_genitive.3"])' "$LOCALE/en.json" > "$DAMAGED/.claude/lib/locale/en.json"
check_offence "a key missing in one catalog" "en.json: missing format.month_genitive.3"
reset_damaged
jq '.["format.dayplan.yesterday"] = "Yesterday (%s)"' "$LOCALE/en.json" > "$DAMAGED/.claude/lib/locale/en.json"
check_offence "a different %s count" "format.dayplan.yesterday: different number of %s"
reset_damaged
jq '.["recognition.close_day"] = ""' "$LOCALE/en.json" > "$DAMAGED/.claude/lib/locale/en.json"
check_offence "an empty pattern" "en.json: recognition.close_day is empty"
reset_damaged
jq '.["recognition.dayplan.section.calendar"] = "Calendar|x*"' "$LOCALE/en.json" > "$DAMAGED/.claude/lib/locale/en.json"
check_offence "a pattern matching anything" "recognition.dayplan.section.calendar matches an empty line"
reset_damaged
printf '#!/bin/bash\ni18n_msg agent.not_there\n' > "$DAMAGED/uses.sh"
printf '{"files": [{"path": "uses.sh"}]}\n' > "$DAMAGED/update-manifest.json"
check_offence "shipped code using an absent key" "uses.sh: uses agent.not_there"

echo
if [ "$FAILS" -eq 0 ]; then echo "OK: all checks passed."; exit 0; fi
echo "FAIL: $FAILS check(s) failed."
exit 1
