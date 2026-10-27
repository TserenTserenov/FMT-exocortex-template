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

# === Ф51 (27.10.2026): Kimi — tool "Shell", payload без session_id → режим по агенту ===
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

# нет ни открытых, ни закрытых семафоров → fail-open (нет доказательства сценария)
expect_kimi "kimi: no semaphores at all" 0 'git commit -m x'

# последний закрытый — служебный (day-close), открытого нет → блок (инцидент 24→25.10)
printf 'agent: kimi\nhousekeeping: day-close\nopened_at: test\n' > "$SESSION_DIR/kimi-a.open.closed"
expect_kimi "kimi: closed day-close, nothing open: commit" 2 'git commit -m x'
expect_kimi "kimi: closed day-close, nothing open: push"   2 'git push'
expect_kimi "kimi: closed day-close, non-commit command"   0 'git status --short'

# обычная сессия с wp открыта → пропуск
printf 'agent: kimi\nwp: WP-1\nopened_at: test\n' > "$SESSION_DIR/kimi-b.open"
expect_kimi "kimi: wp session open after day-close" 0 'git commit -m x'
rm -f "$SESSION_DIR/kimi-b.open"

# последний закрытый — обычный (wp), открытого нет → fail-open
rm -f "$SESSION_DIR/kimi-a.open.closed"
printf 'agent: kimi\nwp: WP-1\nopened_at: test\n' > "$SESSION_DIR/kimi-c.open.closed"
expect_kimi "kimi: closed regular session, nothing open" 0 'git commit -m x'
rm -f "$SESSION_DIR"/kimi-*

# служебная причина вне закрытого списка в последнем закрытом → fail-open
printf 'agent: kimi\nhousekeeping: wp388-f25-something\nopened_at: test\n' > "$SESSION_DIR/kimi-d.open.closed"
expect_kimi "kimi: closed housekeeping outside the list" 0 'git commit -m x'
rm -f "$SESSION_DIR"/kimi-*

# открытый служебный семафор (идёт Day Close) → пропуск
printf 'agent: kimi\nhousekeeping: day-close\nopened_at: test\n' > "$SESSION_DIR/kimi-e.open"
printf 'agent: kimi\nhousekeeping: day-close\nopened_at: test\n' > "$SESSION_DIR/kimi-f.open.closed"
expect_kimi "kimi: open day-close semaphore" 0 'git commit -m x'
rm -f "$SESSION_DIR"/kimi-*

# плановый запуск Kimi: открытый служебный семафор sched-* (причина вне закрытого списка) после закрытого day-close → пропуск
printf 'agent: kimi\nhousekeeping: day-close\nopened_at: test\n' > "$SESSION_DIR/kimi-s0.open.closed"
printf 'agent: kimi\nhousekeeping: sched-abc123\nopened_at: test\n' > "$SESSION_DIR/kimi-s1.open"
expect_kimi "kimi: scheduled run (sched-*) open after day-close" 0 'git commit -m x'
rm -f "$SESSION_DIR"/kimi-*

# порядок закрытых по времени изменения: свежий обычный после служебного → пропуск, и наоборот
# (ctime нельзя выставить напрямую, поэтому файлы создаются друг за другом с паузой)
printf 'agent: kimi\nhousekeeping: day-close\nopened_at: test\n' > "$SESSION_DIR/kimi-g.open.closed"
sleep 1.1
printf 'agent: kimi\nwp: WP-1\nopened_at: test\n' > "$SESSION_DIR/kimi-h.open.closed"
expect_kimi "kimi: regular closed newer than day-close" 0 'git commit -m x'
rm -f "$SESSION_DIR"/kimi-*
printf 'agent: kimi\nwp: WP-1\nopened_at: test\n' > "$SESSION_DIR/kimi-h.open.closed"
sleep 1.1
printf 'agent: kimi\nhousekeeping: day-close\nopened_at: test\n' > "$SESSION_DIR/kimi-g.open.closed"
expect_kimi "kimi: day-close closed newer than regular" 2 'git commit -m x'
rm -f "$SESSION_DIR"/kimi-*

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

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
