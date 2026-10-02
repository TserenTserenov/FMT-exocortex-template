#!/usr/bin/env bash
# Regression for issue #983 and the second half of #981 (decision D16, WP-7): when the canonical
# Day Open pipeline failed, the morning strategist run fell back to the free-form day-plan
# prompt, which ignores priorities.yaml and the scaffold and invents the content of the plan
# ("calendar unavailable", mandatory items that are not configured, half the commits).
#
# Now the morning run never starts that prompt. It logs the reason and alarms with one
# day-open-failed message a day; only a DELIVERED message counts, a failed send is retried by the
# next attempt. A structural failure (the pipeline is not delivered; no model gateway and the
# --scaffold-only retry failed too) ends the day: "GAVE UP scenario: day-plan (...)", exit 0, and
# already_ran_today() skips later launchd runs -- but only once the alarm is out: while a configured
# Telegram refuses it, the run exits 74 without GAVE UP and the scheduler sends it again (three
# sends a day at most; with no Telegram configured there is nothing to wait for). What the run gave
# up on is kept in the day's log, so the next run sends the alarm again WITHOUT starting the pipeline. A deferral (pipeline exit 7: yesterday is not
# closed yet) is no failure: no alarm, not an attempt, exit 7; the scheduler's retries that day keep the
# pipeline's own "started" and "deferred" notices back (DAY_OPEN_QUIET_RETRY, case 16). Any other pipeline code is passed
# out so the scheduler retries (2 as 73: the scheduler reads 2 as "lock held"); attempts are
# counted when they START (the scheduler's timeout kills the run before it can record an end), at
# most three a day. The explicit `strategist.sh day-plan` keeps running the prompt by hand.
#
# Runs the REAL roles/strategist/scripts/strategist.sh end to end under `env -i` with the REAL
# notify.sh and message template; stand-ins replace the pipeline, the model, curl (the Telegram
# Bot API, it can be switched off) and the desktop notifiers in front of PATH (no network). HOME,
# the workspace and the template are throwaway.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
STRATEGIST="$ROOT/roles/strategist/scripts/strategist.sh"
MESSAGE_TEMPLATE="$ROOT/roles/synchronizer/scripts/templates/strategist.sh"
# Explicit template: macOS mktemp without one ignores TMPDIR.
TMP=$(mktemp -d "${TMPDIR:-/tmp}/iwe-issue-983.XXXXXX")
TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
# The fixture git commands must not read the real home or pick up a caller's repository (a git
# hook exports GIT_DIR and friends); the strategist itself always runs under `env -i` below.
export HOME="$TMP/fixture-home"
export GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_PREFIX
mkdir -p "$HOME"

for tool in git python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "SKIP: $tool is not installed"; exit 0; }
done

fail=0
ok()  { echo "  PASS: $1"; }
bad() { echo "  FAIL: $1"; fail=$((fail + 1)); }
check() { # <label> <expected> <actual>
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (ожидалось «$2», получено «$3»)"; fi
}
check_has() { # <label> <text> <literal fragment>
    case "$2" in
        *"$3"*) ok "$1" ;;
        *) bad "$1 (нет «$3» в «$2»)" ;;
    esac
}

# The strategist keeps one log per calendar day and every case below reads it: do not start
# just before midnight.
seconds_to_midnight() {
    echo $((86400 - 10#$(date +%H) * 3600 - 10#$(date +%M) * 60 - 10#$(date +%S)))
}
if [ "$(seconds_to_midnight)" -lt 150 ]; then
    sleep $(($(seconds_to_midnight) + 2))
fi

weekday_name() { # <1-7, monday = 1> -> the lower-case English name day-rhythm-config.yaml uses
    case "$1" in
        1) echo monday ;; 2) echo tuesday ;; 3) echo wednesday ;; 4) echo thursday ;;
        5) echo friday ;; 6) echo saturday ;; *) echo sunday ;;
    esac
}
# Tomorrow is the strategy day, so today the morning run resolves to day-plan on any weekday.
STRATEGY_DAY=$(weekday_name $(( $(date +%u) % 7 + 1 )))

# --- stand-ins in front of PATH: no model, no network, no desktop notifications
STUBS="$TMP/stubs"
mkdir -p "$STUBS" "$TMP/tmp"
for stub in claude gh launchctl; do
    printf '#!/bin/sh\necho "stub %s: no network in this test" >&2\nexit 1\n' "$stub" > "$STUBS/$stub"
done
for stub in osascript notify-send caffeinate systemd-inhibit; do
    printf '#!/bin/sh\nexit 0\n' > "$STUBS/$stub"
done
# The model: one line per start in MODEL_LOG, the prompt it got next to it.
cat > "$STUBS/model" <<'EOF'
#!/bin/sh
echo started >> "$MODEL_LOG"
printf '%s\n' "$*" >> "$MODEL_LOG.prompt"
exit 0
EOF
# The Telegram Bot API: unreachable while $NET_DOWN_FILE exists (curl's own exit 6); otherwise
# records the JSON body of every accepted message, one per line, and answers ok.
cat > "$STUBS/curl" <<'EOF'
#!/bin/sh
if [ -f "$NET_DOWN_FILE" ]; then
    echo "curl: (6) Could not resolve host" >&2
    exit 6
fi
body=""
while [ $# -gt 0 ]; do
    case "$1" in
        -d) body="$2"; shift 2 ;;
        *) shift ;;
    esac
done
printf '%s\n' "$body" >> "$CURL_LOG"
printf '{"ok":true}'
EOF
chmod +x "$STUBS"/*
# The stand-in must shadow the real notifier, or the run would pop a desktop notification.
[ "$(PATH="$STUBS:$PATH" command -v osascript)" = "$STUBS/osascript" ] \
    || { echo "the stand-in osascript does not shadow the real one" >&2; exit 2; }

# --- the pipeline stand-in. PIPE_RC: exit code of a plain run; PIPE_SCAFFOLD_RC: of a
# --scaffold-only run; PIPE_MODE=killparent: the run dies from outside, as when the
# scheduler's timeout kills it (the stand-in kills the strategist that started it).
SCRIPTS="$TMP/scripts"
mkdir -p "$SCRIPTS" "$TMP/no-scripts"
cat > "$SCRIPTS/day-open-pipeline.sh" <<'EOF'
#!/bin/bash
echo "pipeline ${1:-plain}" >> "$PIPE_LOG"
# what strategist.sh told this run about retries after a deferral (case 16): "none" when it did not
echo "${DAY_OPEN_QUIET_RETRY:-none}" >> "$PIPE_LOG.quiet"
# what the real tg_notify logs about a deferral notice: PIPE_NOTICE=delivered / failed (case 16)
case "${PIPE_NOTICE:-}" in
    delivered) echo "  [tg delivered] ⏸ Day Open 2026-10-02 отложен: stub" ;;
    failed) echo "  [tg delivery FAILED] ⏸ Day Open 2026-10-02 отложен: stub" ;;
esac
if [ "${PIPE_MODE:-}" = killparent ]; then
    kill -KILL "$PPID"
    exit 0
fi
if [ "${1:-}" = "--scaffold-only" ]; then
    exit "${PIPE_SCAFFOLD_RC:-0}"
fi
exit "${PIPE_RC:-0}"
EOF
chmod +x "$SCRIPTS/day-open-pipeline.sh"

# --- template: the real prompts, the real notify.sh and message templates
TPL="$TMP/template"
mkdir -p "$TPL/roles/strategist" "$TPL/roles/synchronizer/scripts"
ln -s "$ROOT/roles/strategist/prompts" "$TPL/roles/strategist/prompts"
cp "$ROOT/roles/synchronizer/scripts/notify.sh" "$TPL/roles/synchronizer/scripts/notify.sh"
ln -s "$ROOT/roles/synchronizer/scripts/templates" "$TPL/roles/synchronizer/scripts/templates"

# --- a fresh case: workspace with a governance repo (a clone of a local bare origin), a home
# with Telegram configured, empty records
CASE_N=0
new_case() {
    CASE_N=$((CASE_N + 1))
    C="$TMP/case$CASE_N"
    WS="$C/ws"
    TEST_HOME="$C/home"
    mkdir -p "$WS" "$TEST_HOME/.config/aist"
    printf 'TELEGRAM_BOT_TOKEN=fake-token-983\nTELEGRAM_CHAT_ID=983\n' > "$TEST_HOME/.config/aist/env"
    git init -q --bare "$C/origin.git" 2>/dev/null
    git init -q "$WS/DS-strategy" 2>/dev/null
    mkdir -p "$WS/DS-strategy/exocortex"
    printf 'strategy_day: %s\n' "$STRATEGY_DAY" > "$WS/DS-strategy/exocortex/day-rhythm-config.yaml"
    git -C "$WS/DS-strategy" symbolic-ref HEAD refs/heads/main
    git -C "$WS/DS-strategy" remote add origin "$C/origin.git"
    git -C "$WS/DS-strategy" -c user.name=fixture -c user.email=fixture@example.invalid \
        -c core.hooksPath=/dev/null add exocortex/day-rhythm-config.yaml
    git -C "$WS/DS-strategy" -c user.name=fixture -c user.email=fixture@example.invalid \
        -c core.hooksPath=/dev/null commit -q -m "fixture: governance repo" 2>/dev/null
    git -C "$WS/DS-strategy" push -q -u origin main 2>/dev/null
    MODEL_LOG="$C/model.log"
    PIPE_LOG="$C/pipeline.log"
    CURL_LOG="$C/telegram.log"
    NET_DOWN_FILE="$C/net-down"
    OUT="$C/out.txt"
}

# run_strategist <scenario> [VAR=value ...] -> exit code of the real strategist.sh on stdout
run_strategist() {
    local scenario="$1"
    shift
    env -i HOME="$TEST_HOME" PATH="$STUBS:$PATH" TMPDIR="$TMP/tmp" \
        IWE_WORKSPACE="$WS" IWE_GOVERNANCE_REPO=DS-strategy IWE_TEMPLATE="$TPL" \
        IWE_SCRIPTS="$SCRIPTS" AI_CLI="$STUBS/model" \
        MODEL_LOG="$MODEL_LOG" PIPE_LOG="$PIPE_LOG" CURL_LOG="$CURL_LOG" NET_DOWN_FILE="$NET_DOWN_FILE" \
        "$@" "$BASH" "$STRATEGIST" "$scenario" >> "$OUT" 2>&1
    echo $?
}

day_log() { cat "$TEST_HOME"/logs/strategist/2*.log 2>/dev/null; }
count_lines() { # <file> -> number of lines, 0 for a missing file
    if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi
}
log_count() { day_log | grep -cF -- "$1" || true; }   # <literal text>
model_runs() { count_lines "$MODEL_LOG"; }
messages() { count_lines "$CURL_LOG"; }   # messages the Bot API accepted
message_texts() { # the decoded text of every accepted message, one per line
    [ -f "$CURL_LOG" ] || return 0
    python3 -c 'import json, sys
for line in open(sys.argv[1], encoding="utf-8"):
    if line.strip():
        print(json.loads(line)["text"].replace("\n", " / "))' "$CURL_LOG"
}
HEADER="🔴 План дня не собран"

# ---------------------------------------------------------------- 1
echo "== 1: конвейер не доставлен — тревога, отказ на сегодня, выход 0, без свободного промпта"
new_case
rc=$(run_strategist morning IWE_SCRIPTS="$TMP/no-scripts")
check "1: код выхода" "0" "$rc"
check "1: модель (свободный промпт) не запускалась" "0" "$(model_runs)"
check "1: в журнале отказ на сегодня GAVE UP" "1" "$(log_count 'GAVE UP scenario: day-plan (')"
check "1: ложного SUCCESS нет" "0" "$(log_count 'SUCCESS scenario')"
check "1: доставлено одно сообщение" "1" "$(messages)"
check_has "1: сообщение с заголовком" "$(message_texts)" "$HEADER"
check_has "1: сообщение советует update.sh" "$(message_texts)" "update.sh"
rc=$(run_strategist morning IWE_SCRIPTS="$TMP/no-scripts")
check "1: повторный запуск в тот же день: выход 0" "0" "$rc"
check "1: повторный запуск пропущен как завершённый" "1" "$(log_count 'SKIP: day-plan already completed today')"
check "1: повторный запуск не шлёт второе сообщение" "1" "$(messages)"
check "1: модель так и не запускалась" "0" "$(model_runs)"

# ---------------------------------------------------------------- 2
echo "== 2: шлюза нет (код 9), повтор --scaffold-only тоже упал (код 4) — отказ на сегодня с сохранённым кодом"
new_case
rc=$(run_strategist morning PIPE_RC=9 PIPE_SCAFFOLD_RC=4)
check "2: код выхода" "0" "$rc"
check "2: модель не запускалась" "0" "$(model_runs)"
check "2: конвейер вызван дважды: как есть и с --scaffold-only" \
    "pipeline plain|pipeline --scaffold-only" "$(tr '\n' '|' < "$PIPE_LOG" | sed 's/|$//')"
check "2: GAVE UP называет код повтора 4" "1" "$(day_log | grep -F 'GAVE UP scenario: day-plan (' | grep -c 'код 4')"
check "2: одно сообщение" "1" "$(messages)"
check_has "2: сообщение о шлюзе с кодом повтора" "$(message_texts)" "Шлюз модели не настроен"
check_has "2: в сообщении код 4" "$(message_texts)" "(код 4)"
check "2: ложного SUCCESS нет" "0" "$(log_count 'SUCCESS scenario')"
rc=$(run_strategist morning PIPE_RC=9 PIPE_SCAFFOLD_RC=4)
check "2: повторный запуск: выход 0 и конвейер больше не вызывается" "0/2" "$rc/$(count_lines "$PIPE_LOG")"

# ---------------------------------------------------------------- 3
echo "== 3: шлюза нет (код 9), повтор --scaffold-only прошёл — план есть, тревоги нет"
new_case
rc=$(run_strategist morning PIPE_RC=9 PIPE_SCAFFOLD_RC=0)
check "3: код выхода" "0" "$rc"
check "3: каркас без модели собран" "1" "$(log_count 'Morning: Day Open pipeline OK (scaffold only, no gateway)')"
check "3: модель не запускалась, сообщений нет" "0/0" "$(model_runs)/$(messages)"

# ---------------------------------------------------------------- 4
echo "== 4: переходный отказ (код 5): код наружу, повтор планировщиком, одна тревога, отказ после 3-й попытки"
new_case
rc1=$(run_strategist morning PIPE_RC=5)
check "4: первая попытка: код конвейера проходит наружу" "5" "$rc1"
check "4: без повтора --scaffold-only (код не 9)" "pipeline plain" "$(cat "$PIPE_LOG" 2>/dev/null)"
check "4: начало попытки записано" "1" "$(log_count 'RECORDED: day-open attempt')"
check "4: доставлено одно сообщение" "1" "$(messages)"
check_has "4: сообщение называет код 5" "$(message_texts)" "(код 5)"
check_has "4: повтор обещан только при планировщике Синхронизатора" "$(message_texts)" "Если включён планировщик Синхронизатора"
check "4: первая попытка ещё не сдаётся" "0" "$(log_count 'GAVE UP')"
rc2=$(run_strategist morning PIPE_RC=5)
check "4: вторая попытка: код 5, второе сообщение не уходит" "5/1" "$rc2/$(messages)"
rc3=$(run_strategist morning PIPE_RC=5)
check "4: третья попытка: выход 0 (планировщик отметит день)" "0" "$rc3"
check "4: третья попытка: GAVE UP, сообщение по-прежнему одно" "1/1" "$(log_count 'GAVE UP scenario: day-plan (')/$(messages)"
rc4=$(run_strategist morning PIPE_RC=5)
check "4: четвёртый запуск пропущен, конвейер не вызывается" "0/3" "$rc4/$(count_lines "$PIPE_LOG")"
check "4: модель ни разу не запускалась" "0" "$(model_runs)"

# ---------------------------------------------------------------- 5
echo "== 5: попытки считаются по началу: три запуска убиты снаружи, четвёртый сдаётся без конвейера"
new_case
for n in 1 2 3; do
    rc=$(run_strategist morning PIPE_MODE=killparent)
    [ "$rc" -ne 0 ] || bad "5: запуск $n должен был умереть от сигнала, а вышел с 0"
done
check "5: три начала попыток записаны, хотя ни одна не дошла до конца" "3" "$(log_count 'RECORDED: day-open attempt')"
check "5: убитые попытки не слали сообщений" "0" "$(messages)"
rc=$(run_strategist morning PIPE_RC=0)
check "5: четвёртый запуск: выход 0" "0" "$rc"
check "5: четвёртый запуск не запускал конвейер" "3" "$(count_lines "$PIPE_LOG")"
check "5: GAVE UP и одно сообщение" "1/1" "$(log_count 'GAVE UP scenario: day-plan (')/$(messages)"
check_has "5: сообщение «попытки исчерпаны»" "$(message_texts)" "Попытки собрать план за сегодня исчерпаны"
check "5: модель не запускалась" "0" "$(model_runs)"

# ---------------------------------------------------------------- 6
echo "== 6: конвейер прошёл — без тревоги; повторные запуски после успеха не сдаются ложно"
new_case
for n in 1 2 3 4; do
    rc=$(run_strategist morning PIPE_RC=0)
    check "6: запуск $n: выход 0" "0" "$rc"
done
check "6: конвейер вызывался каждый раз (его собственная дедупликация решает)" "4" "$(count_lines "$PIPE_LOG")"
check "6: сообщений нет, GAVE UP нет, модель не запускалась" "0/0/0" "$(messages)/$(log_count 'GAVE UP')/$(model_runs)"

# ---------------------------------------------------------------- 7
echo "== 7: ручной strategist.sh day-plan по-прежнему запускает промпт"
new_case
rc=$(run_strategist day-plan)
check "7: код выхода" "0" "$rc"
check "7: модель запущена один раз" "1" "$(model_runs)"
check "7: модель получила промпт day-plan" "1" "$(grep -c 'Day Open для роли Стратег' "$MODEL_LOG.prompt" 2>/dev/null || true)"
check "7: конвейер не вызывался" "0" "$(count_lines "$PIPE_LOG")"

# ---------------------------------------------------------------- 8
echo "== 8: отсрочка (код 7, вчерашний день не закрыт) — не сбой: без тревоги, без счёта попыток, код 7"
new_case
rcs=""
for n in 1 2 3 4 5; do
    rcs="$rcs$(run_strategist morning PIPE_RC=7) "
done
# Compound checks on purpose: "no message" alone would also hold where nothing alarms at all.
check "8: пять отсрочек подряд: каждая выходит с 7, сообщений нет, день не сожжён (GAVE UP нет)" \
    "7 7 7 7 7 |0|0" "$rcs|$(messages)|$(log_count 'GAVE UP')"
check "8: каждая отсрочка записана, с причиной по-русски" \
    "5/5" "$(log_count 'RECORDED: day-open deferred')/$(log_count 'вчерашний день ещё не закрыт')"
rc=$(run_strategist morning PIPE_RC=0)
check "8: шестой запуск после закрытия дня строит план" "0/1" "$rc/$(log_count 'Morning: Day Open pipeline OK (scaffold + llm-fill)')"
check "8: конвейер вызывался все шесть раз" "6" "$(count_lines "$PIPE_LOG")"
new_case
rc=$(run_strategist morning PIPE_RC=9 PIPE_SCAFFOLD_RC=7)
check "8: отсрочка при повторе --scaffold-only — тоже код 7, без тревоги и без GAVE UP" \
    "7/0/0" "$rc/$(messages)/$(log_count 'GAVE UP')"

# ---------------------------------------------------------------- 9
echo "== 9: код 2 конвейера не выдаёт себя за «замок занят»"
new_case
rc=$(run_strategist morning PIPE_RC=2)
check "9: наружу уходит 73, а не 2; одно сообщение с исходным кодом 2" \
    "73|1|1" "$rc|$(messages)|$(message_texts | grep -cF '(код 2)')"
check "9: исходный код и замена в журнале" "1" "$(day_log | grep -F 'FAILED scenario: day-plan (rc=2)' | grep -c 'передаю как 73')"

# ---------------------------------------------------------------- 10
echo "== 10: первая отправка тревоги не дошла (сети нет) — следующая попытка шлёт снова, потом не шлёт"
new_case
touch "$NET_DOWN_FILE"
rc1=$(run_strategist morning PIPE_RC=5)
rm -f "$NET_DOWN_FILE"
first="$rc1|$(messages)|$(log_count 'Telegram notification sent: strategist/day-open-failed')"
rc2=$(run_strategist morning PIPE_RC=5)
check "10: первая отправка не дошла и не засчитана, вторая попытка доставила тревогу" \
    "5|0|0 -> 5|1" "$first -> $rc2|$(messages)"
check_has "10: доставлено именно сообщение «План дня не собран»" "$(message_texts)" "$HEADER"
rc3=$(run_strategist morning PIPE_RC=5)
check "10: третья попытка сдаётся и больше не шлёт" "0/1" "$rc3/$(messages)"
check "10: в журнале ровно одна доставка" "1" "$(log_count 'Telegram notification sent: strategist/day-open-failed')"
check "10: третья попытка знает о доставке" "1" "$(log_count 'тревога сегодня уже доставлена')"

# ---------------------------------------------------------------- 11
echo "== 11: текст сообщения day-open-failed в шаблоне уведомлений"
message() { # <reason> <code> -> the message the real template builds
    ( HOME="$TMP/msg-home" IWE_WORKSPACE="$TMP/msg-ws" DAY_OPEN_FAILED_REASON="$1" DAY_OPEN_FAILED_RC="$2" \
        bash -c '. "$1" && build_message day-open-failed' _ "$MESSAGE_TEMPLATE" ) 2>/dev/null
}
for reason in not-delivered scaffold-only-failed pipeline-failed attempts-exhausted unknown-reason; do
    text=$(message "$reason" 4)
    case "$text" in
        *"$HEADER"*"«открывай»"*) ok "11: $reason — заголовок и что делать (сессия, «открывай»)" ;;
        *) bad "11: $reason — нет заголовка или совета «открывай»: «${text}»" ;;
    esac
done
check_has "11: «не доставлен» советует запустить update.sh" "$(message not-delivered '')" "update.sh"
check_has "11: код отказа виден в сообщении" "$(message scaffold-only-failed 4)" "(код 4)"
text=$(message pipeline-failed 'x;<i>')
case "$text" in
    *'x;<i>'*) bad "11: нецифровой код попал в HTML-сообщение" ;;
    *"$HEADER"*) ok "11: сообщение собрано, в него попадает только числовой код" ;;
    *) bad "11: сообщения с нецифровым кодом нет: «${text}»" ;;
esac

# ---------------------------------------------------------------- 12
echo "== 12: структурный отказ, Telegram отказал: день не закрывается, тревога уходит со следующим запуском"
new_case
touch "$NET_DOWN_FILE"
rc1=$(run_strategist morning IWE_SCRIPTS="$TMP/no-scripts")
check "12: первый запуск: код 74, день не закрыт (GAVE UP нет), сообщений нет" \
    "74|0|0" "$rc1|$(log_count 'GAVE UP')|$(messages)"
check "12: в журнале тревога и просьба повторить доставку" "1/1" \
    "$(log_count 'ALARM: day-open-failed')/$(log_count 'повтор доставки при следующем запуске планировщика')"
rm -f "$NET_DOWN_FILE"
rc2=$(run_strategist morning IWE_SCRIPTS="$TMP/no-scripts")
check "12: второй запуск (сеть есть): тревога доставлена, день закрыт: выход 0" "0|1|1" \
    "$rc2|$(messages)|$(log_count 'GAVE UP scenario: day-plan (')"
check_has "12: доставлено именно сообщение «План дня не собран»" "$(message_texts)" "$HEADER"
rc3=$(run_strategist morning IWE_SCRIPTS="$TMP/no-scripts")
check "12: третий запуск пропущен, второго сообщения нет" "0/1" "$rc3/$(messages)"
check "12: модель так и не запускалась" "0" "$(model_runs)"

# ---------------------------------------------------------------- 12b
echo "== 12б: шлюза нет, повтор --scaffold-only упал, Telegram отказал: доставка повторяется без нового запуска конвейера"
new_case
touch "$NET_DOWN_FILE"
rc1=$(run_strategist morning PIPE_RC=9 PIPE_SCAFFOLD_RC=4)
check "12б: первый запуск: код 74, день не закрыт, конвейер вызван дважды (как есть и с --scaffold-only)" \
    "74|0|2" "$rc1|$(log_count 'GAVE UP')|$(count_lines "$PIPE_LOG")"
check "12б: в журнале запись об отложенном отказе с причиной и кодом 4" "1" \
    "$(log_count 'RECORDED: day-open give-up pending|scaffold-only-failed|4|')"
rm -f "$NET_DOWN_FILE"
rc2=$(run_strategist morning PIPE_RC=9 PIPE_SCAFFOLD_RC=4)
check "12б: второй запуск: выход 0, тревога доставлена, день закрыт, конвейер НЕ вызывался снова" "0|1|1|2" \
    "$rc2|$(messages)|$(log_count 'GAVE UP scenario: day-plan (')|$(count_lines "$PIPE_LOG")"
check_has "12б: в сообщении код 4 из записи" "$(message_texts)" "(код 4)"
check "12б: начата одна попытка, повторная доставка её не тратила" "1" "$(log_count 'RECORDED: day-open attempt')"

# ---------------------------------------------------------------- 13
echo "== 13: Telegram отказывает всё время: три отправки, потом отказ на день без бесконечных повторов"
new_case
touch "$NET_DOWN_FILE"
rcs=""
for n in 1 2 3; do
    rcs="$rcs$(run_strategist morning IWE_SCRIPTS="$TMP/no-scripts") "
done
check "13: две попытки с кодом 74, третья сдаётся с кодом 0" "74 74 0 " "$rcs"
check "13: три попытки отправки, GAVE UP ровно один, сообщений нет" "3/1/0" \
    "$(log_count 'ALARM: day-open-failed')/$(log_count 'GAVE UP scenario: day-plan (')/$(messages)"
rc4=$(run_strategist morning IWE_SCRIPTS="$TMP/no-scripts")
check "13: четвёртый запуск пропущен без новой попытки" "0/3" "$rc4/$(log_count 'ALARM: day-open-failed')"

# ---------------------------------------------------------------- 14
echo "== 14: Telegram не настроен: ждать нечего, отказ на день сразу, код 0"
new_case
rm -f "$TEST_HOME/.config/aist/env"
rc=$(run_strategist morning IWE_SCRIPTS="$TMP/no-scripts")
check "14: выход 0 и GAVE UP сразу" "0/1" "$rc/$(log_count 'GAVE UP scenario: day-plan (')"
check "14: тревога в журнале есть, отправки нет" "1/0" "$(log_count 'ALARM: day-open-failed')/$(messages)"
check "14: без повтора доставки" "0" "$(log_count 'повтор доставки при следующем запуске планировщика')"

# ---------------------------------------------------------------- 15
echo "== 15: тревога убита снаружи на третьей отправке: следующий запуск не начинает четвёртую"
# A run killed inside the send (the scheduler's timeout while the Bot API hangs) leaves its ALARM line and the
# pending give-up behind. The count of STARTED sends must stop the next run before it contacts Telegram: red team
# of the 0.41.1 candidate found the limit checked only after the send.
new_case
touch "$NET_DOWN_FILE"
for n in 1 2; do
    run_strategist morning IWE_SCRIPTS="$TMP/no-scripts" > /dev/null
done
LOGF=$(ls "$TEST_HOME"/logs/strategist/2*.log | head -1)
# what the killed third run left: its ALARM line and nothing else
printf '[%s] ALARM: day-open-failed (конвейер Открытия дня не доставлен, запуск убит внутри отправки)\n' "$(date '+%Y-%m-%d %H:%M:%S')" >> "$LOGF"
rm -f "$NET_DOWN_FILE"   # the Bot API answers now: a fourth send would be delivered
rc=$(run_strategist morning IWE_SCRIPTS="$TMP/no-scripts")
check "15: выход 0 (отказ на день)" "0" "$rc"
check "15: начатых тревог по-прежнему три" "3" "$(log_count 'ALARM: day-open-failed')"
check "15: Telegram не получил сообщений" "0" "$(messages)"
check "15: GAVE UP ровно один" "1" "$(log_count 'GAVE UP scenario: day-plan (')"
check "15: в журнале сказано, что больше не шлём" "1" "$(log_count 'больше не шлю')"

# ---------------------------------------------------------------- 16
echo "== 16: повторы после доставленной отсрочки идут тихо: «запущен» и «отложен» уходят один раз"
# The pipeline defers while yesterday is not closed, and the scheduler comes back at every tick (up to seven a
# day). Red team of the 0.41.1 candidate: each tick started the pipeline and sent its "started" and "deferred"
# notices again, 13-15 messages a day where v0.41.0 sent two. Once a deferral notice has been DELIVERED (the pipeline's
# tg_notify logs "[tg delivered] ⏸ ..."), strategist.sh tells the pipeline to keep those two notices back
# (DAY_OPEN_QUIET_RETRY=1); until then the retries try again (red team, round 38: a lost first send must not
# silence the rest of the day).
quiet_flags() { tr '\n' ' ' < "$PIPE_LOG.quiet" 2>/dev/null | sed 's/ $//'; }
new_case
for n in 1 2 3; do
    run_strategist morning PIPE_RC=7 PIPE_NOTICE=delivered > /dev/null
done
run_strategist morning PIPE_RC=0 > /dev/null
check "16: первый запуск без флага, повторы после доставленной отсрочки с флагом (и тот, что построил план)" "none 1 1 1" "$(quiet_flags)"
new_case
run_strategist morning PIPE_RC=7 PIPE_NOTICE=failed > /dev/null
run_strategist morning PIPE_RC=7 PIPE_NOTICE=delivered > /dev/null
run_strategist morning PIPE_RC=7 PIPE_NOTICE=delivered > /dev/null
check "16: первое сообщение об отсрочке не дошло: следующий запуск говорит снова, молчат только после доставки" "none none 1" "$(quiet_flags)"
new_case
for n in 1 2; do
    run_strategist morning PIPE_RC=7 > /dev/null
done
check "16: сообщений об отсрочке не было (Telegram не настроен): флага нет" "none none" "$(quiet_flags)"
new_case
for n in 1 2; do
    run_strategist morning PIPE_RC=5 > /dev/null
done
check "16: переходный сбой не отсрочка: повторы громкие, флага нет" "none none" "$(quiet_flags)"
new_case
for n in 1 2; do
    run_strategist morning PIPE_RC=9 PIPE_SCAFFOLD_RC=7 PIPE_NOTICE=delivered > /dev/null
done
check "16: шлюза нет, отсрочка при --scaffold-only: повтор тихий в обоих вызовах конвейера" "none none 1 1" "$(quiet_flags)"

# The pipeline's own tg_notify, extracted from the real script: with the flag only the "started" notice and the
# four "deferred" notices are kept back; the digest and every abort or warning still go out.
PIPELINE="$ROOT/scripts/day-open-pipeline.sh"
awk '/^tg_notify\(\) \{/ { on = 1 } on { print } on && /^\}/ { exit }' "$PIPELINE" > "$TMP/tg_notify.sh"
# every `tg_notify "<text>"` call with a literal text; a variable in it becomes a date. The one call that passes only
# the variable ($MSG, the digest built at run time) turns into the bare date and is dropped.
grep -o 'tg_notify "[^"]*"' "$PIPELINE" | sed -e 's/^tg_notify "//' -e 's/"$//' \
    | sed -E 's/\$\{?[A-Za-z_][A-Za-z_0-9]*\}?/2026-10-02/g' | grep -vx '2026-10-02' > "$TMP/notices.txt"
notice_raw() { # <quiet flag: 1 or empty> <message> [fail] -> what tg_notify prints, then its exit code
    env -i PATH="$PATH" QUIET="$1" MSG="$2" SENDFAIL="${3:-}" "$BASH" -c '
        PROBE=false; TG_TOKEN=t; TG_CHAT=c
        if [ -n "$QUIET" ]; then export DAY_OPEN_QUIET_RETRY="$QUIET"; fi
        if [ -n "$SENDFAIL" ]; then telegram_send() { return 1; }; else telegram_send() { echo SENT; }; fi
        . "$1"
        tg_notify "$MSG"
        echo "rc=$?"' _ "$TMP/tg_notify.sh" 2>&1
}
notice() { # <quiet flag: 1 or empty> <message> -> sent | kept back | other: <output>
    local out
    out=$(notice_raw "$1" "$2")
    case "$out" in
        *SENT*) echo "sent" ;;
        *"TG suppressed"*) echo "kept back" ;;
        *) echo "other: $out" ;;
    esac
}
if [ ! -s "$TMP/tg_notify.sh" ] || [ ! -s "$TMP/notices.txt" ]; then
    bad "16: tg_notify или его вызовы не найдены в day-open-pipeline.sh (разметка изменилась?)"
else
    started=0; deferred=0; other=0; quiet_wrong=""; loud_wrong=""
    while IFS= read -r msg; do
        case "$msg" in
            "🌅 "*) started=$((started + 1)); want_quiet="kept back" ;;
            "⏸ "*) deferred=$((deferred + 1)); want_quiet="kept back" ;;
            *) other=$((other + 1)); want_quiet="sent" ;;
        esac
        [ "$(notice 1 "$msg")" = "$want_quiet" ] || quiet_wrong="$quiet_wrong [$msg]"
        [ "$(notice "" "$msg")" = "sent" ] || loud_wrong="$loud_wrong [$msg]"
    done < "$TMP/notices.txt"
    check "16: в конвейере одно сообщение «запущен» и четыре «отложен»" "1/4" "$started/$deferred"
    check "16: с флагом молчат ровно «запущен» и «отложен», остальные уходят (сводка дня, тревоги, предупреждения)" "" "$quiet_wrong"
    check "16: без флага уходят все сообщения конвейера" "" "$loud_wrong"
    [ "$other" -gt 5 ] && ok "16: проверено $other прочих сообщений конвейера" || bad "16: прочих сообщений слишком мало ($other): разбор вызовов сломан?"
fi
# the digest is built at run time ($MSG): it is no "started" or "deferred" notice
check "16: сводка дня (текст собирается при запуске) с флагом уходит" "sent" "$(notice 1 '📅 День открыт 2026-10-02: план собран')"
# The two phrases inside a digest or an alarm reason do not make them a "started" or "deferred" notice (round 37):
# the filter looks at the start of the message, not at a phrase somewhere in it.
check "16: сводка с фразой «Day Open pipeline started for» внутри с флагом уходит" "sent" \
    "$(notice 1 '📅 День открыт 2026-10-02: в плане строка Day Open pipeline started for 2026-10-02')"
check "16: тревога с текстом отсрочки в причине с флагом уходит" "sent" \
    "$(notice 1 '🚨 Day Open pipeline aborted: в журнале Day Open 2026-10-02 отложен: неделя 2026-W40 ещё закрывается')"
# The line strategist.sh waits for before it goes quiet (round 38) comes from the real tg_notify, and only on a delivery.
out=$(notice_raw "" '⏸ Day Open 2026-10-02 отложен: тест')
case "$out" in
    *"[tg delivered] ⏸ Day Open 2026-10-02 отложен"*"rc=0"*) ok "16: доставленное сообщение об отсрочке оставляет в журнале строку «[tg delivered] ⏸»" ;;
    *) bad "16: нет строки «[tg delivered] ⏸» после доставленного сообщения: «$out»" ;;
esac
out=$(notice_raw "" '⏸ Day Open 2026-10-02 отложен: тест' fail)
case "$out" in
    *"[tg delivered]"*) bad "16: недоставленное сообщение отмечено доставленным: «$out»" ;;
    *"[tg delivery FAILED]"*"rc=1"*) ok "16: недоставленное сообщение строки о доставке не оставляет, код 1" ;;
    *) bad "16: у недоставленного сообщения нет строки об отказе: «$out»" ;;
esac
check "16: метку доставки strategist.sh и конвейер называют одинаково" "1" \
    "$(grep -c 'DAY_OPEN_DEFERRAL_DELIVERED_MARK="\[tg delivered\] ⏸ "' "$STRATEGIST")"

echo
if [ "$fail" -eq 0 ]; then
    echo "PASS: issue #983 — утреннее Открытие дня без свободного промпта, с тревогой и пределом попыток"
else
    echo "FAIL: issue #983 — провалено проверок: $fail"
    exit 1
fi
