#!/bin/bash
# test-session-open-gate.sh — корпус для session-open-gate.sh (WP-561, 16.10.2026).
#
# Прогоняет PreToolUse JSON через хук и проверяет код выхода:
#   exit 2 = блок (нет семафора этой сессии), exit 0 = пропуск.
#
# Запуск: bash .claude/hooks/tests/test-session-open-gate.sh

set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/session-open-gate.sh"
SID="test-wp561-$$"
TMP_ROOT=$(mktemp -d)
SESSION_DIR="$TMP_ROOT/.iwe-runtime/sessions"
mkdir -p "$SESSION_DIR"
PASS=0
FAIL=0

cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

open_semaphore() { # --wp-backed semaphore (satisfies the gate)
  printf 'agent: claude-code\nharness_session_id: %s\nwp: WP-1\nopened_at: test\n' "$SID" \
    > "$SESSION_DIR/claude-code-$SID.open"
}

open_housekeeping_semaphore() { # no wp: field, arbitrary reason — mirrors real session-guard.sh --housekeeping output
  printf 'agent: claude-code\nharness_session_id: %s\nhousekeeping: some-reason\nopened_at: test\n' "$SID" \
    > "$SESSION_DIR/claude-code-$SID.open"
}

open_allowed_housekeeping_semaphore() { # $1 = one of the 4 whitelisted reasons
  printf 'agent: claude-code\nharness_session_id: %s\nhousekeeping: %s\nopened_at: test\n' "$SID" "$1" \
    > "$SESSION_DIR/claude-code-$SID.open"
}

close_semaphore() { rm -f "$SESSION_DIR/claude-code-$SID.open"; }

run_gate() { # $1 = command → печатает exit code хука
  local json_cmd
  json_cmd=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1")
  printf '{"tool_name":"Bash","tool_input":{"command":%s},"session_id":"%s"}' \
    "$json_cmd" "$SID" | IWE_ROOT="$TMP_ROOT" bash "$HOOK" >/dev/null 2>&1
  echo $?
}

expect() { # $1 = описание, $2 = ожидаемый код (0|2), $3 = команда
  local got
  got=$(run_gate "$3")
  if [ "$got" = "$2" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL: $1 (ожидалось $2, получено $got): $3"
  fi
}

# === Нет семафора → блок на commit/push, формы как у close-runner-gate.sh ===
close_semaphore
expect "no semaphore: bare commit"    2 'git commit -m x'
expect "no semaphore: -C commit"      2 'git -C DS-strategy commit -m x'
expect "no semaphore: push"           2 'git push'
expect "no semaphore: push after ;"   2 'git add x; git push'

# === Нет семафора, но команда не commit/push → пропуск (гейт не об этом) ===
expect "no semaphore: status"         0 'git -C repo status --short'
expect "no semaphore: commit-tree"    0 'git commit-tree -m x'
expect "no semaphore: non-git"        0 'ls -la'
expect "no semaphore: echo mentions"  0 'echo "git commit"'

# === Семафор этой сессии открыт (--wp) → пропуск ===
open_semaphore
expect "wp semaphore open: commit"    0 'git commit -m x'
expect "wp semaphore open: -C push"   0 'git -C repo push'

# === Семафор этой сессии открыт, но без wp: и с произвольной housekeeping-причиной → по-прежнему блок (S-68) ===
close_semaphore
open_housekeeping_semaphore
expect "arbitrary housekeeping semaphore: commit" 2 'git commit -m x'
close_semaphore

# === Семафор с одной из 4 разрешённых housekeeping-причин (day-open/day-close/week-close/month-close) → пропуск ===
for reason in day-open day-close week-close month-close; do
  open_allowed_housekeeping_semaphore "$reason"
  expect "allowed housekeeping ($reason): commit" 0 'git commit -m x'
  close_semaphore
done

# === Похожая, но не точно разрешённая причина (подстрока/префикс) → по-прежнему блок ===
open_allowed_housekeeping_semaphore "day-open-extra"
expect "near-miss housekeeping reason: commit" 2 'git commit -m x'
close_semaphore

# === Семафор чужой сессии (другой harness_session_id) → не считается ===
printf 'agent: claude-code\nharness_session_id: %s\nwp: WP-1\nopened_at: test\n' "other-$$" \
  > "$SESSION_DIR/claude-code-other-$$.open"
expect "foreign semaphore: commit"    2 'git commit -m x'
rm -f "$SESSION_DIR/claude-code-other-$$.open"

# === Семафор с ID, у которого наш SID — префикс (не должен матчиться подстрокой) ===
printf 'agent: claude-code\nharness_session_id: %sX\nwp: WP-1\nopened_at: test\n' "$SID" \
  > "$SESSION_DIR/claude-code-${SID}X.open"
expect "prefix-collision semaphore: commit" 2 'git commit -m x'
rm -f "$SESSION_DIR/claude-code-${SID}X.open"

# === Ф51 (27.10.2026), Ф274 (29.10.2026): Kimi — tool "Shell", payload без session_id → режим по агенту ===
run_kimi_gate() { # $1 = command → exit code хука (IWE_AGENT=kimi, без session_id)
  local json_cmd
  json_cmd=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1")
  printf '{"tool_name":"Shell","tool_input":{"command":%s}}' "$json_cmd" \
    | CLAUDE_CODE_SESSION_ID= IWE_AGENT=kimi IWE_ROOT="$TMP_ROOT" bash "$HOOK" >/dev/null 2>&1
  echo $?
}
expect_kimi() { # $1 = описание, $2 = ожидаемый код, $3 = команда
  local got
  got=$(run_kimi_gate "$3")
  if [ "$got" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 (ожидалось $2, получено $got): $3"; fi
}
rm -f "$SESSION_DIR"/kimi-*

# Ф274 (29.10.2026): без открытого семафора на РП, из закрытого списка или планового запуска — блок,
# закрытые семафоры больше не читаются (прежний fail-open Ф51 снят решением пилота)
expect_kimi "kimi: no semaphores at all" 2 'git commit -m x'
expect_kimi "kimi: no semaphores, push" 2 'git push'
expect_kimi "kimi: no semaphores, non-commit command" 0 'git status --short'

printf 'agent: kimi\nwp: WP-1\nopened_at: test\n' > "$SESSION_DIR/kimi-c.open.closed"
expect_kimi "kimi: closed regular session, nothing open" 2 'git commit -m x'
rm -f "$SESSION_DIR"/kimi-*

# обычная сессия с wp открыта → пропуск
printf 'agent: kimi\nwp: WP-1\nopened_at: test\n' > "$SESSION_DIR/kimi-b.open"
expect_kimi "kimi: wp session open" 0 'git commit -m x'
rm -f "$SESSION_DIR"/kimi-*

# открытый служебный семафор из закрытого списка (идёт Day Close) → пропуск
printf 'agent: kimi\nhousekeeping: day-close\nopened_at: test\n' > "$SESSION_DIR/kimi-e.open"
expect_kimi "kimi: open day-close semaphore" 0 'git commit -m x'
rm -f "$SESSION_DIR"/kimi-*

# открытая служебная сессия с произвольной причиной — не РП → блок (сессия без РП только на чтение)
for reason in research note-file wp388-f25-something Sched-1; do
  printf 'agent: kimi\nhousekeeping: %s\nopened_at: test\n' "$reason" > "$SESSION_DIR/kimi-r.open"
  expect_kimi "kimi: open housekeeping '$reason'" 2 'git commit -m x'
done
rm -f "$SESSION_DIR"/kimi-*

# плановый запуск: причина целиком sched-<id> → пропуск и строка в журнале
SCHED_LOG="$TMP_ROOT/.iwe-runtime/session-open-gate-sched.log"
rm -f "$SCHED_LOG"
printf 'agent: kimi\nhousekeeping: sched-abc123\nopened_at: test\n' > "$SESSION_DIR/kimi-s1.open"
expect_kimi "kimi: scheduled run (sched-*) open" 0 'git commit -m x'
if grep -qE '^[0-9TZ:-]+ agent=kimi reason=sched-abc123$' "$SCHED_LOG" 2>/dev/null; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: kimi: пропуск sched-* не записан в журнал (Ф274)"; fi
rm -f "$SESSION_DIR"/kimi-*

# причина похожа на sched-, но не совпадает целиком → блок, журнал не растёт
for reason in 'sched-1 extra' 'sched-1 ' "$(printf 'sched-1\tx')" 'sched-' 'xsched-1'; do
  printf 'agent: kimi\nhousekeeping: %s\nopened_at: test\n' "$reason" > "$SESSION_DIR/kimi-s2.open"
  expect_kimi "kimi: near-sched reason '$reason'" 2 'git commit -m x'
done
if [ "$(wc -l < "$SCHED_LOG" | tr -d ' ')" = 1 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: kimi: журнал sched вырос на отказах (Ф274)"; fi
rm -f "$SESSION_DIR"/kimi-*

# открыты и сессия на РП, и плановый запуск → пропуск по РП, журнал sched не пишется (имя sched сортируется раньше)
rm -f "$SCHED_LOG"
printf 'agent: kimi\nhousekeeping: sched-1\nopened_at: test\n' > "$SESSION_DIR/kimi-a.open"
printf 'agent: kimi\nwp: WP-1\nopened_at: test\n' > "$SESSION_DIR/kimi-z.open"
expect_kimi "kimi: wp and sched both open" 0 'git commit -m x'
if [ ! -e "$SCHED_LOG" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: kimi: sched-пропуск записан при открытой сессии на РП (Ф274)"; fi
rm -f "$SESSION_DIR"/kimi-*

# журнал sched записать нельзя (на его месте каталог) → решение то же, предупреждение в stderr
mkdir -p "$SCHED_LOG"
printf 'agent: kimi\nhousekeeping: sched-1\nopened_at: test\n' > "$SESSION_DIR/kimi-s3.open"
err=$(printf '{"tool_name":"Shell","tool_input":{"command":"git commit -m x"}}' \
  | CLAUDE_CODE_SESSION_ID= IWE_AGENT=kimi IWE_ROOT="$TMP_ROOT" bash "$HOOK" 2>&1 >/dev/null)
got=$?
if [ "$got" = 0 ] && printf '%s' "$err" | grep -q 'не удалось записать'; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: kimi: сбой журнала sched изменил решение или не предупредил (получено $got)"; fi
rmdir "$SCHED_LOG"; rm -f "$SESSION_DIR"/kimi-*

# имя агента — префикс чужого: семафоры kimi-peer и claude-code чужие → блок (холодное ревью Ф274)
printf 'agent: kimi-peer\nwp: WP-1\nopened_at: test\n' > "$SESSION_DIR/kimi-peer-x.open"
expect_kimi "kimi: only kimi-peer wp semaphore" 2 'git commit -m x'
rm -f "$SESSION_DIR"/kimi-*
open_semaphore
printf '{"tool_name":"Shell","tool_input":{"command":"git commit -m x"}}' \
  | CLAUDE_CODE_SESSION_ID= IWE_AGENT=claude IWE_ROOT="$TMP_ROOT" bash "$HOOK" >/dev/null 2>&1
got=$?
if [ "$got" = 2 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: IWE_AGENT=claude с открытым claude-code wp (ожидалось 2, получено $got)"; fi
close_semaphore

# семафор с двумя строками agent: не считается своим
printf 'agent: kimi\nagent: other\nwp: WP-1\nopened_at: test\n' > "$SESSION_DIR/kimi-d2.open"
expect_kimi "kimi: semaphore with two agent lines" 2 'git commit -m x'
rm -f "$SESSION_DIR"/kimi-*

# Claude: плановый запуск sched- не принимается (исключение только для не-Claude агентов)
printf 'agent: claude-code\nharness_session_id: %s\nhousekeeping: sched-1\nopened_at: test\n' "$SID" > "$SESSION_DIR/claude-code-$SID.open"
expect "claude: sched- housekeeping is not a binding" 2 'git commit -m x'
close_semaphore

# каталог с именем семафора не читается как семафор, даже если в каталоге запуска лежит «правильный» файл (ревью 2 Ф274)
mkdir -p "$SESSION_DIR/kimi-d.open"; printf 'agent: kimi\nwp: WP-1\n' > "$SESSION_DIR/kimi-d.open/inner"
printf 'agent: kimi\nwp: WP-1\n' > "$TMP_ROOT/inner"
got=$( cd "$TMP_ROOT" && printf '{"tool_name":"Shell","tool_input":{"command":"git commit -m x"}}' \
  | CLAUDE_CODE_SESSION_ID= IWE_AGENT=kimi IWE_ROOT="$TMP_ROOT" bash "$HOOK" >/dev/null 2>&1; echo $? )
if [ "$got" = 2 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: kimi: каталог kimi-d.open принят за семафор (получено $got)"; fi
rm -rf "$SESSION_DIR/kimi-d.open" "$TMP_ROOT/inner"

# wp: из одних пробелов — не привязка
printf 'agent: kimi\nwp:   \nopened_at: test\n' > "$SESSION_DIR/kimi-w.open"
expect_kimi "kimi: blank wp value" 2 'git commit -m x'
rm -f "$SESSION_DIR"/kimi-*

# семафор без строки agent: не считается своим (и для Claude)
printf 'harness_session_id: %s\nwp: WP-1\nopened_at: test\n' "$SID" > "$SESSION_DIR/claude-code-$SID.open"
expect "claude: semaphore without agent line" 2 'git commit -m x'
close_semaphore

# Kimi, запущенный из оболочки Claude, наследует CLAUDE_CODE_SESSION_ID: переменная не должна влиять
printf 'agent: kimi\nwp: WP-1\nopened_at: test\n' > "$SESSION_DIR/kimi-i.open"
json_inh=$(python3 -c 'import json; print(json.dumps("git commit -m x"))')
printf '{"tool_name":"Shell","tool_input":{"command":%s},"session_id":"kimi-own-id"}' "$json_inh" \
  | CLAUDE_CODE_SESSION_ID="claude-$$" IWE_AGENT=kimi IWE_ROOT="$TMP_ROOT" bash "$HOOK" >/dev/null 2>&1
got=$?
if [ "$got" = 0 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: kimi with inherited CLAUDE_CODE_SESSION_ID and wp semaphore (ожидалось 0, получено $got)"; fi
rm -f "$SESSION_DIR"/kimi-*

# Claude без session_id и без переменной окружения: поведение прежнее (пропуск), даже если последний закрытый служебный
printf 'agent: claude-code\nhousekeeping: day-close\nopened_at: test\n' > "$SESSION_DIR/claude-code-j.open.closed"
printf '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"}}' \
  | CLAUDE_CODE_SESSION_ID= IWE_ROOT="$TMP_ROOT" bash "$HOOK" >/dev/null 2>&1
got=$?
if [ "$got" = 0 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: claude without session id must stay fail-open (ожидалось 0, получено $got)"; fi
rm -f "$SESSION_DIR"/claude-code-j.open.closed

# Claude с инструментом Shell и своим session_id ведёт себя как с Bash (нет семафора → блок)
close_semaphore
printf '{"tool_name":"Shell","tool_input":{"command":"git commit -m x"},"session_id":"%s"}' "$SID" \
  | IWE_ROOT="$TMP_ROOT" bash "$HOOK" >/dev/null 2>&1
got=$?
if [ "$got" = 2 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: claude Shell without semaphore (ожидалось 2, получено $got)"; fi

# имя агента с символами шаблона поиска не находит чужие семафоры: '*' при открытом claude-code с wp → блок (Ф274)
open_semaphore
for bad_agent in '*' 'kimi*' '[ck]*' 'ki mi'; do
  printf '{"tool_name":"Shell","tool_input":{"command":"git commit -m x"}}' \
    | CLAUDE_CODE_SESSION_ID= IWE_AGENT="$bad_agent" IWE_ROOT="$TMP_ROOT" bash "$HOOK" >/dev/null 2>&1
  got=$?
  if [ "$got" = 2 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: IWE_AGENT='$bad_agent' (ожидалось 2, получено $got)"; fi
done
printf '{"tool_name":"Shell","tool_input":{"command":"git status"}}' \
  | CLAUDE_CODE_SESSION_ID= IWE_AGENT='*' IWE_ROOT="$TMP_ROOT" bash "$HOOK" >/dev/null 2>&1
got=$?
if [ "$got" = 0 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: IWE_AGENT='*' на git status (ожидалось 0, получено $got)"; fi
close_semaphore

# === Пропуск на Git Bash по session_open_gate_skip_until (Ф271, issue #1281) ===
# Платформа читается из $OSTYPE: тест подставляет его в окружение хука (в настоящем
# Git Bash он равен msys). Подмена `uname` через PATH на решение не влияет.
close_semaphore
PARAMS="$TMP_ROOT/params.yaml"
SKIP_LOG="$TMP_ROOT/.iwe-runtime/session-open-gate-skip.log"

day_offset() { # $1 = сдвиг в днях от сегодня -> ГГГГ-ММ-ДД (GNU date, затем BSD)
  date -d "$1 days" +%Y-%m-%d 2>/dev/null || date -v"$1"d +%Y-%m-%d
}

run_gate_os() { # $1 = OSTYPE, $2 = команда -> печатает код выхода хука
  local json_cmd
  json_cmd=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$2")
  printf '{"tool_name":"Bash","tool_input":{"command":%s},"session_id":"%s"}' \
    "$json_cmd" "$SID" | OSTYPE="$1" IWE_ROOT="$TMP_ROOT" bash "$HOOK" >/dev/null 2>&1
  echo $?
}

expect_skip() { # $1 = описание, $2 = ожидаемый код, $3 = OSTYPE, $4 = содержимое params.yaml
  local got
  printf '%b' "$4" > "$PARAMS"
  got=$(run_gate_os "$3" 'git commit -m x')
  if [ "$got" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: skip: $1 (ожидалось $2, получено $got)"; fi
}

K=session_open_gate_skip_until
rm -f "$SKIP_LOG" "$PARAMS"
expect_skip "нет params.yaml → блок"                 2 msys ""
rm -f "$PARAMS"
got=$(run_gate_os msys 'git commit -m x'); [ "$got" = 2 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: skip: файла params.yaml нет (получено $got)"; }
expect_skip "ключ валиден, Linux → блок"             2 linux-gnu "$K: $(day_offset +5)\n"
expect_skip "ключ валиден, macOS → блок"             2 darwin23 "$K: $(day_offset +5)\n"
expect_skip "ключ валиден, Git Bash (msys) → пропуск" 0 msys "$K: $(day_offset +5)\n"
expect_skip "ключ валиден, cygwin → пропуск"         0 cygwin "$K: $(day_offset +5)\n"
expect_skip "срок = сегодня → пропуск"               0 msys "$K: $(day_offset +0)\n"
expect_skip "срок = +30 дней → пропуск"              0 msys "$K: $(day_offset +30)\n"
expect_skip "срок = +31 день → блок"                 2 msys "$K: $(day_offset +31)\n"
expect_skip "срок вчера → блок"                      2 msys "$K: $(day_offset -1)\n"
expect_skip "31 февраля → блок"                      2 msys "$K: 2026-02-31\n"
expect_skip "29 февраля невисокосного → блок"        2 msys "$K: 2027-02-29\n"
expect_skip "тринадцатый месяц → блок"               2 msys "$K: 2026-13-01\n"
expect_skip "CRLF в файле → пропуск"                 0 msys "$K: $(day_offset +5)\r\n"
expect_skip "комментарий после пробела → пропуск"    0 msys "$K: $(day_offset +5) # временно\n"
expect_skip "комментарий без пробела → блок"         2 msys "$K: $(day_offset +5)# x\n"
expect_skip "закомментированный ключ → блок"         2 msys "# $K: $(day_offset +5)\n"
expect_skip "ключ с отступом → блок"                 2 msys "  $K: $(day_offset +5)\n"
expect_skip "ключ в кавычках → блок"                 2 msys "$K: \"$(day_offset +5)\"\n"
expect_skip "пустое значение → блок"                 2 msys "$K:\n"
expect_skip "нет пробела после двоеточия → блок"     2 msys "$K:$(day_offset +5)\n"
expect_skip "хвост после даты → блок"                2 msys "$K: $(day_offset +5) x\n"
expect_skip "дубликат с разными датами → блок"       2 msys "$K: $(day_offset +5)\n$K: $(day_offset +6)\n"
expect_skip "опечатка в имени ключа → блок"          2 msys "session_open_gate_skip_untill: $(day_offset +5)\n"

# журнал: пропуск оставляет строку с датой окончания; сбой записи решение не меняет
rm -f "$SKIP_LOG"
printf '%s: %s\n' "$K" "$(day_offset +5)" > "$PARAMS"
run_gate_os msys 'git commit -m x' >/dev/null
if grep -q "until=$(day_offset +5)" "$SKIP_LOG" 2>/dev/null; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: skip: строка журнала не записана"; fi
if grep -qE "ostype=msys uname_s=[^ ]+$" "$SKIP_LOG" 2>/dev/null; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: skip: в журнале нет ostype=msys и uname_s= (F272)"; fi
# поля журнала независимы: при подменённом OSTYPE uname_s равен настоящей платформе хоста —
# выводу uname -s из системного PATH, на любой ОС (Linux, macOS, Git Bash: MINGW64_NT-...) (F274)
HOST_UNAME_S=$(command -p uname -s 2>/dev/null)
LOGGED_UNAME_S=$(grep -E "ostype=msys uname_s=" "$SKIP_LOG" 2>/dev/null | tail -1 | sed -E 's/.* uname_s=//')
if [ -z "$HOST_UNAME_S" ]; then FAIL=$((FAIL+1)); echo "FAIL: skip: command -p uname -s на хосте теста пуст — проверку uname_s не выполнить (F274)"
elif [ "$LOGGED_UNAME_S" = "$HOST_UNAME_S" ] && [ "$LOGGED_UNAME_S" != UNKNOWN ] && [ "$LOGGED_UNAME_S" != msys ]; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); echo "FAIL: skip: uname_s='$LOGGED_UNAME_S' не равен настоящей платформе '$HOST_UNAME_S' при подменённом OSTYPE (F274)"; fi
# фальшивый uname в PATH не попадает в поле uname_s
FAKE_BIN="$TMP_ROOT/fakebin"; mkdir -p "$FAKE_BIN"; printf '#!/bin/sh\necho MSYS_NT-FAKE\n' > "$FAKE_BIN/uname"; chmod +x "$FAKE_BIN/uname"
rm -f "$SKIP_LOG"
printf '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"},"session_id":"%s"}' "$SID" | PATH="$FAKE_BIN:$PATH" OSTYPE=msys IWE_ROOT="$TMP_ROOT" bash "$HOOK" >/dev/null 2>&1
if ! grep -q "uname_s=" "$SKIP_LOG" 2>/dev/null; then FAIL=$((FAIL+1)); echo "FAIL: skip: журнал с uname_s не записан при фальшивом uname (F272)"
elif grep -q "uname_s=MSYS_NT-FAKE" "$SKIP_LOG" 2>/dev/null; then FAIL=$((FAIL+1)); echo "FAIL: skip: uname_s взят из пользовательского PATH (F272)"; else PASS=$((PASS+1)); fi
rm -rf "$FAKE_BIN"
rm -rf "$TMP_ROOT/.iwe-runtime/session-open-gate-skip.log"
mkdir -p "$SKIP_LOG"   # каталог вместо файла: запись невозможна
got=$(run_gate_os msys 'git commit -m x')
if [ "$got" = 0 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: skip: сбой журнала не должен менять решение (получено $got)"; fi
rmdir "$SKIP_LOG"

# фальшивый uname в PATH не включает пропуск на Linux
FAKE_BIN=$(mktemp -d)
printf '#!/bin/sh\necho MINGW64_NT\n' > "$FAKE_BIN/uname"; chmod +x "$FAKE_BIN/uname"
printf '%s: %s\n' "$K" "$(day_offset +5)" > "$PARAMS"
json_fake=$(python3 -c 'import json; print(json.dumps("git commit -m x"))')
printf '{"tool_name":"Bash","tool_input":{"command":%s},"session_id":"%s"}' "$json_fake" "$SID" \
  | PATH="$FAKE_BIN:$PATH" OSTYPE=linux-gnu IWE_ROOT="$TMP_ROOT" bash "$HOOK" >/dev/null 2>&1
got=$?
if [ "$got" = 2 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: skip: фальшивый uname в PATH дал обход (получено $got)"; fi
rm -rf "$FAKE_BIN"

# есть семафор с wp: → ключ не читается, журнал не пишется
rm -f "$SKIP_LOG"
open_semaphore
got=$(run_gate_os msys 'git commit -m x')
if [ "$got" = 0 ] && [ ! -e "$SKIP_LOG" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: skip: при открытом семафоре ключ не должен читаться (код $got)"; fi
close_semaphore

# команды без commit/push под действующим пропуском остаются как были (пропуск и так)
got=$(run_gate_os linux-gnu 'git status')
if [ "$got" = 0 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: skip: git status должен проходить (получено $got)"; fi
rm -f "$PARAMS"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
