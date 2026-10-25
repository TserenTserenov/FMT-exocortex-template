#!/usr/bin/env bash
# day-open-observer-smoke.sh -- хост-наблюдатель вместо второго писателя дня (WP-568, 25.10.2026).
# Живой инцидент: сервер опубликовал DayPlan в 03:04, утренний launchd-стратег на втором хосте
# в 04:00 вызвал пайплайн напрямую, гард WP-539 отказал (exit 1), стратег подписал это как
# «🔴 План дня не собран» — ложная тревога три дня подряд.
#
# Поведение после правки (ключ observer: true в секции day_open файла day-rhythm-config.yaml):
#   план на origin          -> молчаливый SKIP, exit 0, пайплайн не вызывается, тревоги нет;
#   окно владельца не прошло -> defer (exit 7), тревоги нет;
#   окно прошло, плана нет   -> один сигнал «сервер не опубликовал план» в день, GAVE UP, exit 0;
#   fetch невозможен (сеть)  -> defer, сигнал НЕ шлём (иначе сетевой сбой = ложное «нет плана»);
#   без ключа observer, пайплайн вернул 77 (отказ гарда) -> тихий skip, без тревоги «план не собран».
#
# Runs the REAL roles/strategist/scripts/strategist.sh end to end under `env -i` with the REAL
# notify.sh and message template; stand-ins replace the pipeline, the model and curl (no network).
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
STRATEGIST="$ROOT/roles/strategist/scripts/strategist.sh"
MESSAGE_TEMPLATE="$ROOT/roles/synchronizer/scripts/templates/strategist.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/iwe-observer.XXXXXX")
TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
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
TODAY=$(date +%Y-%m-%d)

# --- stand-ins in front of PATH: no model, no network, no desktop notifications
STUBS="$TMP/stubs"
mkdir -p "$STUBS" "$TMP/tmp"
for stub in claude gh launchctl; do
    printf '#!/bin/sh\necho "stub %s: no network in this test" >&2\nexit 1\n' "$stub" > "$STUBS/$stub"
done
for stub in osascript notify-send caffeinate systemd-inhibit; do
    printf '#!/bin/sh\nexit 0\n' > "$STUBS/$stub"
done
printf '#!/bin/sh\nexit 0\n' > "$STUBS/model"
# The Telegram Bot API: records the JSON body of every accepted message, one per line.
# CURL_FAIL=1 simulates an unreachable/failing Bot API: nothing is recorded, curl exits 1.
cat > "$STUBS/curl" <<'EOF'
#!/bin/sh
if [ -n "${CURL_FAIL:-}" ]; then
    echo "curl: simulated network failure" >&2
    exit 1
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

# --- the pipeline stand-in: logs every invocation, exits ${PIPE_RC:-0}
SCRIPTS="$TMP/scripts"
mkdir -p "$SCRIPTS"
cat > "$SCRIPTS/day-open-pipeline.sh" <<'EOF'
#!/bin/bash
echo "pipeline ${1:-plain}" >> "$PIPE_LOG"
exit "${PIPE_RC:-0}"
EOF
chmod +x "$SCRIPTS/day-open-pipeline.sh"

# --- template: the real notify.sh and message templates
TPL="$TMP/template"
mkdir -p "$TPL/roles/strategist" "$TPL/roles/synchronizer/scripts"
ln -s "$ROOT/roles/strategist/prompts" "$TPL/roles/strategist/prompts"
cp "$ROOT/roles/synchronizer/scripts/notify.sh" "$TPL/roles/synchronizer/scripts/notify.sh"
ln -s "$ROOT/roles/synchronizer/scripts/templates" "$TPL/roles/synchronizer/scripts/templates"

# --- a fresh case: workspace with a governance repo (a clone of a local bare origin),
# observer config in the runtime config, Telegram configured
CASE_N=0
new_case() {
    CASE_N=$((CASE_N + 1))
    C="$TMP/case$CASE_N"
    WS="$C/ws"
    TEST_HOME="$C/home"
    RT="$C/runtime"
    mkdir -p "$WS" "$RT" "$TEST_HOME/.config/aist"
    printf 'TELEGRAM_BOT_TOKEN=fake-token-observer\nTELEGRAM_CHAT_ID=observer\n' > "$TEST_HOME/.config/aist/env"
    git init -q --bare "$C/origin.git" 2>/dev/null
    git init -q "$WS/DS-strategy" 2>/dev/null
    mkdir -p "$WS/DS-strategy/exocortex"
    printf 'strategy_day: %s\n' "$STRATEGY_DAY" > "$WS/DS-strategy/exocortex/day-rhythm-config.yaml"
    printf 'day_open:\n  observer: true\n' > "$RT/day-rhythm-config.yaml"
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
    OUT="$C/out.txt"
}

# publish_dayplan: commit and push the DayPlan for today into the fixture origin
publish_dayplan() {
    mkdir -p "$WS/DS-strategy/current"
    printf '# DayPlan %s (fixture)\n' "$TODAY" > "$WS/DS-strategy/current/DayPlan $TODAY.md"
    git -C "$WS/DS-strategy" -c user.name=fixture -c user.email=fixture@example.invalid \
        -c core.hooksPath=/dev/null add "current/DayPlan $TODAY.md"
    git -C "$WS/DS-strategy" -c user.name=fixture -c user.email=fixture@example.invalid \
        -c core.hooksPath=/dev/null commit -q -m "fixture: DayPlan $TODAY"
    git -C "$WS/DS-strategy" push -q origin main 2>/dev/null
}

# break_origin: point the remote at a nonexistent path — every fetch fails
break_origin() {
    git -C "$WS/DS-strategy" remote set-url origin "$C/nonexistent.git"
}

# run_strategist <scenario> [VAR=value ...] -> exit code of the real strategist.sh on stdout
run_strategist() {
    local scenario="$1"
    shift
    env -i HOME="$TEST_HOME" PATH="$STUBS:$PATH" TMPDIR="$TMP/tmp" \
        IWE_WORKSPACE="$WS" IWE_GOVERNANCE_REPO=DS-strategy IWE_TEMPLATE="$TPL" \
        IWE_RUNTIME="$RT" IWE_SCRIPTS="$SCRIPTS" AI_CLI="$STUBS/model" \
        MODEL_LOG="$MODEL_LOG" PIPE_LOG="$PIPE_LOG" CURL_LOG="$CURL_LOG" \
        "$@" "$BASH" "$STRATEGIST" "$scenario" >> "$OUT" 2>&1
    echo $?
}

day_log() { cat "$TEST_HOME"/logs/strategist/2*.log 2>/dev/null; }
count_lines() { # <file> -> number of lines, 0 for a missing file
    if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi
}
log_count() { day_log | grep -cF -- "$1" || true; }   # <literal text>
messages() { count_lines "$CURL_LOG"; }   # messages the Bot API accepted
message_texts() { # the decoded text of every accepted message, one per line
    [ -f "$CURL_LOG" ] || return 0
    python3 -c 'import json, sys
for line in open(sys.argv[1], encoding="utf-8"):
    if line.strip():
        print(json.loads(line)["text"].replace("\n", " / "))' "$CURL_LOG"
}
MISSING_HEADER="План дня не опубликован сервером"

# ---------------------------------------------------------------- 1
echo "== 1: план на origin — молчаливый SKIP, пайплайн не вызывается, тревоги нет"
new_case
publish_dayplan
rc=$(run_strategist morning)
check "1: код выхода" "0" "$rc"
check "1: пайплайн не вызывался" "0" "$(count_lines "$PIPE_LOG")"
check "1: попытка не записывалась" "0" "$(log_count 'RECORDED: day-open attempt')"
check "1: сообщений нет" "0" "$(messages)"
check "1: SKIP с причиной в журнале" "1" "$(log_count 'наблюдатель, пайплайн не запускаю')"

# ---------------------------------------------------------------- 2
echo "== 2: плана нет, окно владельца не прошло — defer (7), без сигнала"
new_case
rc=$(run_strategist morning DAY_OPEN_OBSERVER_AFTER=23:59)
check "2: код выхода (defer)" "7" "$rc"
check "2: сообщений нет" "0" "$(messages)"
check "2: пайплайн не вызывался" "0" "$(count_lines "$PIPE_LOG")"
check "2: причина defer в журнале" "1" "$(log_count 'окно владельца ещё не прошло')"

# ---------------------------------------------------------------- 3
echo "== 3: окно прошло, плана нет — один сигнал «сервер не опубликовал», GAVE UP, дедуп в тот же день"
new_case
rc=$(run_strategist morning DAY_OPEN_OBSERVER_AFTER=00:00)
check "3: код выхода" "0" "$rc"
check "3: пайплайн не вызывался" "0" "$(count_lines "$PIPE_LOG")"
check "3: доставлено одно сообщение" "1" "$(messages)"
check_has "3: заголовок сигнала" "$(message_texts)" "$MISSING_HEADER"
check "3: GAVE UP с причиной" "1" "$(log_count 'GAVE UP scenario: day-plan (плана нет на origin')"
rc=$(run_strategist morning DAY_OPEN_OBSERVER_AFTER=00:00)
check "3: повторный запуск в тот же день: выход 0" "0" "$rc"
check "3: повторный запуск не шлёт второе сообщение" "1" "$(messages)"

# ---------------------------------------------------------------- 4
echo "== 4: fetch невозможен (сеть) — defer, сигнал «нет плана» НЕ шлём"
new_case
break_origin
rc=$(run_strategist morning DAY_OPEN_OBSERVER_AFTER=00:00)
check "4: код выхода (defer, не сигнал)" "7" "$rc"
check "4: сообщений нет" "0" "$(messages)"
check "4: причина в журнале" "1" "$(log_count 'сверка плана с origin не удалась')"

# ---------------------------------------------------------------- 5
echo "== 5: без ключа observer отказ гарда (77) — тихий skip, без тревоги «план не собран»"
new_case
printf 'day_open:\n  observer: false\n' > "$RT/day-rhythm-config.yaml"
rc=$(run_strategist morning PIPE_RC=77)
check "5: код выхода" "0" "$rc"
check "5: пайплайн вызван один раз" "1" "$(count_lines "$PIPE_LOG")"
check "5: сообщений нет" "0" "$(messages)"
check "5: причина skip в журнале" "1" "$(log_count 'не сбой, тревоги нет, пропускаю')"
check "5: ALARM day-open-failed не начиналась" "0" "$(log_count 'ALARM: day-open-failed')"

echo "== 6: контроль: без observer тревога по-прежнему работает для реального сбоя (код 5)"
new_case
printf 'day_open:\n  observer: false\n' > "$RT/day-rhythm-config.yaml"
rc=$(run_strategist morning PIPE_RC=5)
check "6: код сбоя проходит наружу" "5" "$rc"
check "6: тревога «план не собран» доставлена" "1" "$(messages)"
check_has "6: заголовок тревоги" "$(message_texts)" "План дня не собран"

# ---------------------------------------------------------------- 7
echo "== 7: без observer, отказ гарда (77) четыре раза за день — попытки не копятся, ложной тревоги нет"
new_case
printf 'day_open:\n  observer: false\n' > "$RT/day-rhythm-config.yaml"
for i in 1 2 3 4; do
    rc=$(run_strategist morning PIPE_RC=77)
    check "7: запуск $i — тихий skip (код 0)" "0" "$rc"
done
check "7: пайплайн вызван четыре раза" "4" "$(count_lines "$PIPE_LOG")"
check "7: attempts-exhausted не наступил" "0" "$(log_count 'attempts-exhausted')"
check "7: ALARM day-open-failed не начиналась" "0" "$(log_count 'ALARM: day-open-failed')"
check "7: отказ скомпенсирован как отсрочка" "4" "$(log_count 'попытка не засчитана')"

# ---------------------------------------------------------------- 8
echo "== 8: сигнал не доставлен (сеть) — день не отдан, следующий запуск повторяет доставку"
new_case
rc=$(run_strategist morning DAY_OPEN_OBSERVER_AFTER=00:00 CURL_FAIL=1)
check "8: код выхода — повтор доставки (74)" "74" "$rc"
check "8: сообщений не записано" "0" "$(messages)"
check "8: GAVE UP не писался" "0" "$(log_count 'GAVE UP scenario: day-plan')"
rc=$(run_strategist morning DAY_OPEN_OBSERVER_AFTER=00:00)
check "8: повторный запуск доставляет сигнал и отдаёт день (код 0)" "0" "$rc"
check "8: доставлено ровно одно сообщение" "1" "$(messages)"
check_has "8: заголовок сигнала" "$(message_texts)" "$MISSING_HEADER"
check "8: после доставки — GAVE UP" "1" "$(log_count 'GAVE UP scenario: day-plan (плана нет на origin')"

# ---------------------------------------------------------------- 9
echo "== 9: день стратегии — наблюдатель сигналит о пропаже плана, но не блокирует session-prep"
new_case
TODAY_NAME=$(weekday_name "$(date +%u)")
printf 'strategy_day: %s\n' "$TODAY_NAME" > "$WS/DS-strategy/exocortex/day-rhythm-config.yaml"
git -C "$WS/DS-strategy" -c user.name=fixture -c user.email=fixture@example.invalid \
    -c core.hooksPath=/dev/null add exocortex/day-rhythm-config.yaml
git -C "$WS/DS-strategy" -c user.name=fixture -c user.email=fixture@example.invalid \
    -c core.hooksPath=/dev/null commit -q -m "fixture: strategy day today"
git -C "$WS/DS-strategy" push -q origin main 2>/dev/null
rc=$(run_strategist morning DAY_OPEN_OBSERVER_AFTER=00:00)
check "9: код выхода (session-prep не заблокирован)" "0" "$rc"
check_has "9: сигнал «сервер не опубликовал» доставлен" "$(message_texts)" "$MISSING_HEADER"
check "9: пайплайн не вызывался" "0" "$(count_lines "$PIPE_LOG")"
check "9: session-prep запустился" "1" "$(log_count 'running session prep')"

# ---------------------------------------------------------------- 10
echo "== 10: день стратегии, план на origin — без сигнала, session-prep работает"
new_case
TODAY_NAME=$(weekday_name "$(date +%u)")
printf 'strategy_day: %s\n' "$TODAY_NAME" > "$WS/DS-strategy/exocortex/day-rhythm-config.yaml"
git -C "$WS/DS-strategy" -c user.name=fixture -c user.email=fixture@example.invalid \
    -c core.hooksPath=/dev/null add exocortex/day-rhythm-config.yaml
git -C "$WS/DS-strategy" -c user.name=fixture -c user.email=fixture@example.invalid \
    -c core.hooksPath=/dev/null commit -q -m "fixture: strategy day today"
publish_dayplan
rc=$(run_strategist morning DAY_OPEN_OBSERVER_AFTER=00:00)
check "10: код выхода" "0" "$rc"
check "10: сигнала «сервер не опубликовал» нет" "0" "$(log_count 'RECORDED: day-open plan missing on origin')"
check "10: session-prep запустился" "1" "$(log_count 'running session prep')"

# ---------------------------------------------------------------- 11
echo "== 11: день стратегии, fetch невозможен — session-prep ОТЛОЖЕН (код 7), SUCCESS не пишется"
new_case
TODAY_NAME=$(weekday_name "$(date +%u)")
printf 'strategy_day: %s\n' "$TODAY_NAME" > "$WS/DS-strategy/exocortex/day-rhythm-config.yaml"
git -C "$WS/DS-strategy" -c user.name=fixture -c user.email=fixture@example.invalid \
    -c core.hooksPath=/dev/null add exocortex/day-rhythm-config.yaml
git -C "$WS/DS-strategy" -c user.name=fixture -c user.email=fixture@example.invalid \
    -c core.hooksPath=/dev/null commit -q -m "fixture: strategy day today"
git -C "$WS/DS-strategy" push -q origin main 2>/dev/null
break_origin
rc=$(run_strategist morning DAY_OPEN_OBSERVER_AFTER=00:00)
check "11: код выхода (defer)" "7" "$rc"
check "11: session-prep НЕ запускался" "0" "$(log_count 'running session prep')"
check "11: SUCCESS session-prep не записан" "0" "$(log_count 'SUCCESS scenario: session-prep')"
check "11: сообщений нет" "0" "$(messages)"

# ---------------------------------------------------------------- 12
echo "== 12: сверка пересекла полночь — сигнал о вчерашнем плане, не defer"
new_case
YESTERDAY=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d 'yesterday' +%Y-%m-%d)
rc=$(run_strategist morning DAY_OPEN_OBSERVER_AFTER=23:59 STRATEGIST_DATE_OVERRIDE="$YESTERDAY")
check "12: код выхода" "0" "$rc"
check "12: доставлено одно сообщение" "1" "$(messages)"
check_has "12: сигнал назван про вчерашний день" "$(message_texts)" "$YESTERDAY"
check "12: GAVE UP с причиной" "1" "$(log_count 'GAVE UP scenario: day-plan (плана нет на origin')"

# ---------------------------------------------------------------- 13
echo "== 13: день стратегии, сигнал не доставлен (сеть) — session-prep отложен (код 74)"
new_case
TODAY_NAME=$(weekday_name "$(date +%u)")
printf 'strategy_day: %s\n' "$TODAY_NAME" > "$WS/DS-strategy/exocortex/day-rhythm-config.yaml"
git -C "$WS/DS-strategy" -c user.name=fixture -c user.email=fixture@example.invalid \
    -c core.hooksPath=/dev/null add exocortex/day-rhythm-config.yaml
git -C "$WS/DS-strategy" -c user.name=fixture -c user.email=fixture@example.invalid \
    -c core.hooksPath=/dev/null commit -q -m "fixture: strategy day today"
git -C "$WS/DS-strategy" push -q origin main 2>/dev/null
rc=$(run_strategist morning DAY_OPEN_OBSERVER_AFTER=00:00 CURL_FAIL=1)
check "13: код выхода (повтор доставки)" "74" "$rc"
check "13: session-prep НЕ запускался" "0" "$(log_count 'running session prep')"
check "13: SUCCESS session-prep не записан" "0" "$(log_count 'SUCCESS scenario: session-prep')"
rc=$(run_strategist morning DAY_OPEN_OBSERVER_AFTER=00:00)
check "13: повторный запуск доставляет сигнал и отдаёт день" "0" "$rc"
check "13: доставлено одно сообщение" "1" "$(messages)"

[ "$fail" -eq 0 ] && echo "PASS" || { echo "FAILED: $fail"; exit 1; }
