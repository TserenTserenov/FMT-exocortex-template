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

open_housekeeping_semaphore() { # no wp: field, mirrors real session-guard.sh --housekeeping output
  printf 'agent: claude-code\nharness_session_id: %s\nhousekeeping: some-reason\nopened_at: test\n' "$SID" \
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

# === Семафор этой сессии открыт, но без wp: (--housekeeping) → по-прежнему блок (S-68) ===
close_semaphore
open_housekeeping_semaphore
expect "housekeeping semaphore: commit" 2 'git commit -m x'
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

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
