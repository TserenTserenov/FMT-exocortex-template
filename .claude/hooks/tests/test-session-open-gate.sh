#!/bin/bash
# test-session-open-gate.sh — test corpus for session-open-gate.sh (WP-561, 16.10.2026).
#
# Runs PreToolUse JSON through the hook and checks the exit code:
#   exit 2 = block (no semaphore for this session), exit 0 = pass.
#
# Run: bash .claude/hooks/tests/test-session-open-gate.sh

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

run_gate() { # $1 = command → prints the hook exit code
  local json_cmd
  json_cmd=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1")
  printf '{"tool_name":"Bash","tool_input":{"command":%s},"session_id":"%s"}' \
    "$json_cmd" "$SID" | IWE_ROOT="$TMP_ROOT" bash "$HOOK" >/dev/null 2>&1
  echo $?
}

expect() { # $1 = description, $2 = expected code (0|2), $3 = command
  local got
  got=$(run_gate "$3")
  if [ "$got" = "$2" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL: $1 (ожидалось $2, получено $got): $3"
  fi
}

# === No semaphore → block on commit/push, forms as in close-runner-gate.sh ===
close_semaphore
expect "no semaphore: bare commit"    2 'git commit -m x'
expect "no semaphore: -C commit"      2 'git -C DS-strategy commit -m x'
expect "no semaphore: push"           2 'git push'
expect "no semaphore: push after ;"   2 'git add x; git push'

# === No semaphore, but the command is not commit/push → pass (the gate is not about this) ===
expect "no semaphore: status"         0 'git -C repo status --short'
expect "no semaphore: commit-tree"    0 'git commit-tree -m x'
expect "no semaphore: non-git"        0 'ls -la'
expect "no semaphore: echo mentions"  0 'echo "git commit"'

# === This session's semaphore is open (--wp) → pass ===
open_semaphore
expect "wp semaphore open: commit"    0 'git commit -m x'
expect "wp semaphore open: -C push"   0 'git -C repo push'

# === This session's semaphore is open, but without wp: and with an arbitrary housekeeping reason → still blocked (S-68) ===
close_semaphore
open_housekeeping_semaphore
expect "arbitrary housekeeping semaphore: commit" 2 'git commit -m x'
close_semaphore

# === Semaphore with one of the 4 allowed housekeeping reasons (day-open/day-close/week-close/month-close) → pass ===
for reason in day-open day-close week-close month-close; do
  open_allowed_housekeeping_semaphore "$reason"
  expect "allowed housekeeping ($reason): commit" 0 'git commit -m x'
  close_semaphore
done

# === A similar but not exactly allowed reason (substring/prefix) → still blocked ===
open_allowed_housekeeping_semaphore "day-open-extra"
expect "near-miss housekeeping reason: commit" 2 'git commit -m x'
close_semaphore

# === Another session's semaphore (different harness_session_id) → not counted ===
printf 'agent: claude-code\nharness_session_id: %s\nwp: WP-1\nopened_at: test\n' "other-$$" \
  > "$SESSION_DIR/claude-code-other-$$.open"
expect "foreign semaphore: commit"    2 'git commit -m x'
rm -f "$SESSION_DIR/claude-code-other-$$.open"

# === Semaphore with an ID that has our SID as a prefix (must not match by substring) ===
printf 'agent: claude-code\nharness_session_id: %sX\nwp: WP-1\nopened_at: test\n' "$SID" \
  > "$SESSION_DIR/claude-code-${SID}X.open"
expect "prefix-collision semaphore: commit" 2 'git commit -m x'
rm -f "$SESSION_DIR/claude-code-${SID}X.open"

# === Phase 51 (27.10.2026), Phase 274 (29.10.2026): Kimi — tool "Shell", payload without session_id → per-agent mode ===
run_kimi_gate() { # $1 = command → hook exit code (IWE_AGENT=kimi, no session_id)
  local json_cmd
  json_cmd=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1")
  printf '{"tool_name":"Shell","tool_input":{"command":%s}}' "$json_cmd" \
    | CLAUDE_CODE_SESSION_ID= IWE_AGENT=kimi IWE_ROOT="$TMP_ROOT" bash "$HOOK" >/dev/null 2>&1
  echo $?
}
expect_kimi() { # $1 = description, $2 = expected code, $3 = command
  local got
  got=$(run_kimi_gate "$3")
  if [ "$got" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 (ожидалось $2, получено $got): $3"; fi
}
rm -f "$SESSION_DIR"/kimi-*

# Phase 274 (29.10.2026): without an open semaphore for a WP, from the closed list, or a scheduled run — block,
# closed semaphores are no longer read (the former fail-open of Phase 51 was lifted by the pilot's decision)
expect_kimi "kimi: no semaphores at all" 2 'git commit -m x'
expect_kimi "kimi: no semaphores, push" 2 'git push'
expect_kimi "kimi: no semaphores, non-commit command" 0 'git status --short'

printf 'agent: kimi\nwp: WP-1\nopened_at: test\n' > "$SESSION_DIR/kimi-c.open.closed"
expect_kimi "kimi: closed regular session, nothing open" 2 'git commit -m x'
rm -f "$SESSION_DIR"/kimi-*

# regular session with a WP open → pass
printf 'agent: kimi\nwp: WP-1\nopened_at: test\n' > "$SESSION_DIR/kimi-b.open"
expect_kimi "kimi: wp session open" 0 'git commit -m x'
rm -f "$SESSION_DIR"/kimi-*

# open service semaphore from the closed list (Day Close in progress) → pass
printf 'agent: kimi\nhousekeeping: day-close\nopened_at: test\n' > "$SESSION_DIR/kimi-e.open"
expect_kimi "kimi: open day-close semaphore" 0 'git commit -m x'
rm -f "$SESSION_DIR"/kimi-*

# open service session with an arbitrary reason — not a WP → block (a session without a WP is read-only)
for reason in research note-file wp388-f25-something Sched-1; do
  printf 'agent: kimi\nhousekeeping: %s\nopened_at: test\n' "$reason" > "$SESSION_DIR/kimi-r.open"
  expect_kimi "kimi: open housekeeping '$reason'" 2 'git commit -m x'
done
rm -f "$SESSION_DIR"/kimi-*

# scheduled run: the reason is exactly sched-<id> → pass and a line in the log
SCHED_LOG="$TMP_ROOT/.iwe-runtime/session-open-gate-sched.log"
rm -f "$SCHED_LOG"
printf 'agent: kimi\nhousekeeping: sched-abc123\nopened_at: test\n' > "$SESSION_DIR/kimi-s1.open"
expect_kimi "kimi: scheduled run (sched-*) open" 0 'git commit -m x'
if grep -qE '^[0-9TZ:-]+ agent=kimi reason=sched-abc123$' "$SCHED_LOG" 2>/dev/null; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: kimi: пропуск sched-* не записан в журнал (Ф274)"; fi
rm -f "$SESSION_DIR"/kimi-*

# reason looks like sched- but does not match fully → block, the log does not grow
for reason in 'sched-1 extra' 'sched-1 ' "$(printf 'sched-1\tx')" 'sched-' 'xsched-1'; do
  printf 'agent: kimi\nhousekeeping: %s\nopened_at: test\n' "$reason" > "$SESSION_DIR/kimi-s2.open"
  expect_kimi "kimi: near-sched reason '$reason'" 2 'git commit -m x'
done
if [ "$(wc -l < "$SCHED_LOG" | tr -d ' ')" = 1 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: kimi: журнал sched вырос на отказах (Ф274)"; fi
rm -f "$SESSION_DIR"/kimi-*

# both a WP session and a scheduled run are open → pass by WP, the sched log is not written (the sched name sorts earlier)
rm -f "$SCHED_LOG"
printf 'agent: kimi\nhousekeeping: sched-1\nopened_at: test\n' > "$SESSION_DIR/kimi-a.open"
printf 'agent: kimi\nwp: WP-1\nopened_at: test\n' > "$SESSION_DIR/kimi-z.open"
expect_kimi "kimi: wp and sched both open" 0 'git commit -m x'
if [ ! -e "$SCHED_LOG" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: kimi: sched-пропуск записан при открытой сессии на РП (Ф274)"; fi
rm -f "$SESSION_DIR"/kimi-*

# the sched log cannot be written (a directory is in its place) → same decision, warning on stderr
mkdir -p "$SCHED_LOG"
printf 'agent: kimi\nhousekeeping: sched-1\nopened_at: test\n' > "$SESSION_DIR/kimi-s3.open"
err=$(printf '{"tool_name":"Shell","tool_input":{"command":"git commit -m x"}}' \
  | CLAUDE_CODE_SESSION_ID= IWE_AGENT=kimi IWE_ROOT="$TMP_ROOT" bash "$HOOK" 2>&1 >/dev/null)
got=$?
if [ "$got" = 0 ] && printf '%s' "$err" | grep -q 'не удалось записать'; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: kimi: сбой журнала sched изменил решение или не предупредил (получено $got)"; fi
rmdir "$SCHED_LOG"; rm -f "$SESSION_DIR"/kimi-*

# agent name is a prefix of another's: kimi-peer and claude-code semaphores are foreign → block (cold review Phase 274)
printf 'agent: kimi-peer\nwp: WP-1\nopened_at: test\n' > "$SESSION_DIR/kimi-peer-x.open"
expect_kimi "kimi: only kimi-peer wp semaphore" 2 'git commit -m x'
rm -f "$SESSION_DIR"/kimi-*

# Phase 275 (WP-484 Phase 261): claude and claude-code are one agent. IWE_AGENT=claude is normalized,
# this conversation's semaphore is counted by session_id; per-agent mode is not enabled by the alias
open_semaphore
printf '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"},"session_id":"%s"}' "$SID" \
  | IWE_AGENT=claude IWE_ROOT="$TMP_ROOT" bash "$HOOK" >/dev/null 2>&1
got=$?
if [ "$got" = 0 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: IWE_AGENT=claude с семафором этой беседы (ожидалось 0, получено $got)"; fi
close_semaphore
printf 'agent: claude-code\nwp: WP-1\nopened_at: test\n' > "$SESSION_DIR/claude-code-other.open"
printf '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"},"session_id":"%s"}' "$SID" \
  | IWE_AGENT=claude IWE_ROOT="$TMP_ROOT" bash "$HOOK" >/dev/null 2>&1
got=$?
if [ "$got" = 2 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: IWE_AGENT=claude не должен засчитывать семафор другой беседы (ожидалось 2, получено $got)"; fi
rm -f "$SESSION_DIR/claude-code-other.open"

# semaphore under the short name (claude-<id>.open, agent: claude) is counted for the claude-code conversation
printf 'agent: claude\nharness_session_id: %s\nwp: WP-1\nopened_at: test\n' "$SID" > "$SESSION_DIR/claude-$SID.open"
expect "claude: alias-named semaphore of this session" 0 'git commit -m x'
rm -f "$SESSION_DIR/claude-$SID.open"
# a foreign agent name in a claude-*.open file is not counted
printf 'agent: kimi\nharness_session_id: %s\nwp: WP-1\nopened_at: test\n' "$SID" > "$SESSION_DIR/claude-$SID.open"
expect "claude: claude-*.open owned by another agent" 2 'git commit -m x'
rm -f "$SESSION_DIR/claude-$SID.open"
# per-agent mode (kimi) does not accept semaphores of the claude family
printf 'agent: claude\nwp: WP-1\nopened_at: test\n' > "$SESSION_DIR/kimi-k.open"
expect_kimi "kimi: does not count agent: claude semaphore" 2 'git commit -m x'
rm -f "$SESSION_DIR/kimi-k.open"
# forms of the agent: line that must not be counted for the claude family (Phase 275 review)
for agent_lines in 'agent: claude claude-code' 'agent:claude' "$(printf 'agent: claude\nagent: claude-code')" 'agent: claude-headless' 'agent: claude '; do
  printf '%s\nharness_session_id: %s\nwp: WP-1\nopened_at: test\n' "$agent_lines" "$SID" > "$SESSION_DIR/claude-$SID.open"
  expect "claude: agent line '$agent_lines'" 2 'git commit -m x'
done
rm -f "$SESSION_DIR/claude-$SID.open"
printf 'agent: claude\nharness_session_id: %s\nwp: WP-1\nopened_at: test\n' "$SID" > "$TMP_ROOT/alias-target"
ln -s "$TMP_ROOT/alias-target" "$SESSION_DIR/claude-$SID.open"
expect "claude: symlinked alias semaphore" 2 'git commit -m x'
rm -f "$SESSION_DIR/claude-$SID.open" "$TMP_ROOT/alias-target"

# semaphore with two agent: lines is not counted as own
printf 'agent: kimi\nagent: other\nwp: WP-1\nopened_at: test\n' > "$SESSION_DIR/kimi-d2.open"
expect_kimi "kimi: semaphore with two agent lines" 2 'git commit -m x'
rm -f "$SESSION_DIR"/kimi-*

# Claude: scheduled run sched- is not accepted (the exception is only for non-Claude agents)
printf 'agent: claude-code\nharness_session_id: %s\nhousekeeping: sched-1\nopened_at: test\n' "$SID" > "$SESSION_DIR/claude-code-$SID.open"
expect "claude: sched- housekeeping is not a binding" 2 'git commit -m x'
close_semaphore

# a directory named like a semaphore is not read as a semaphore, even if a "correct" file lies in the launch directory (review 2 Phase 274)
mkdir -p "$SESSION_DIR/kimi-d.open"; printf 'agent: kimi\nwp: WP-1\n' > "$SESSION_DIR/kimi-d.open/inner"
printf 'agent: kimi\nwp: WP-1\n' > "$TMP_ROOT/inner"
got=$( cd "$TMP_ROOT" && printf '{"tool_name":"Shell","tool_input":{"command":"git commit -m x"}}' \
  | CLAUDE_CODE_SESSION_ID= IWE_AGENT=kimi IWE_ROOT="$TMP_ROOT" bash "$HOOK" >/dev/null 2>&1; echo $? )
if [ "$got" = 2 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: kimi: каталог kimi-d.open принят за семафор (получено $got)"; fi
rm -rf "$SESSION_DIR/kimi-d.open" "$TMP_ROOT/inner"

# wp: of only spaces — not a binding
printf 'agent: kimi\nwp:   \nopened_at: test\n' > "$SESSION_DIR/kimi-w.open"
expect_kimi "kimi: blank wp value" 2 'git commit -m x'
rm -f "$SESSION_DIR"/kimi-*

# semaphore without an agent: line is not counted as own (also for Claude)
printf 'harness_session_id: %s\nwp: WP-1\nopened_at: test\n' "$SID" > "$SESSION_DIR/claude-code-$SID.open"
expect "claude: semaphore without agent line" 2 'git commit -m x'
close_semaphore

# Kimi launched from a Claude shell inherits CLAUDE_CODE_SESSION_ID: the variable must not affect it
printf 'agent: kimi\nwp: WP-1\nopened_at: test\n' > "$SESSION_DIR/kimi-i.open"
json_inh=$(python3 -c 'import json; print(json.dumps("git commit -m x"))')
printf '{"tool_name":"Shell","tool_input":{"command":%s},"session_id":"kimi-own-id"}' "$json_inh" \
  | CLAUDE_CODE_SESSION_ID="claude-$$" IWE_AGENT=kimi IWE_ROOT="$TMP_ROOT" bash "$HOOK" >/dev/null 2>&1
got=$?
if [ "$got" = 0 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: kimi with inherited CLAUDE_CODE_SESSION_ID and wp semaphore (ожидалось 0, получено $got)"; fi
rm -f "$SESSION_DIR"/kimi-*

# Phase 275: Claude without session_id and without the environment variable — a failure: commit is blocked, other commands are not
NO_ID_ERR="$TMP_ROOT/no-id.err"
run_claude_no_id() { # $1 = command, $2 = OSTYPE -> exit code; stderr in $NO_ID_ERR
  local json_cmd
  json_cmd=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1")
  printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$json_cmd" \
    | CLAUDE_CODE_SESSION_ID= OSTYPE="$2" IWE_ROOT="$TMP_ROOT" bash "$HOOK" >/dev/null 2>"$NO_ID_ERR"
  echo $?
}
expect_no_id_block() { # $1 = description, $2 = exit code; the dedicated branch must have fired
  if [ "$2" = 2 ] && grep -q 'без пригодного идентификатора сессии' "$NO_ID_ERR"; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); echo "FAIL: $1 (ожидалось 2 и текст про идентификатор, получено $2): $(head -c 200 "$NO_ID_ERR")"; fi
}
open_semaphore
expect_no_id_block "claude without session id: commit" "$(run_claude_no_id 'git commit -m x' linux-gnu)"
expect_no_id_block "claude without session id: push" "$(run_claude_no_id 'git push' linux-gnu)"
got=$(run_claude_no_id 'git status --short' linux-gnu)
if [ "$got" = 0 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: claude without session id: git status (ожидалось 0, получено $got)"; fi
# unsafe session_id — same as a missing one
printf '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"},"session_id":"a b"}' \
  | CLAUDE_CODE_SESSION_ID="$SID" IWE_ROOT="$TMP_ROOT" bash "$HOOK" >/dev/null 2>"$NO_ID_ERR"
expect_no_id_block "claude with unsafe session id" "$?"
# Git Bash skip by key works even without an identifier (the check is before the block)
printf 'session_open_gate_skip_until: %s\n' "$(python3 -c 'import datetime; print(datetime.date.today() + datetime.timedelta(days=3))')" > "$TMP_ROOT/params.yaml"
got=$(run_claude_no_id 'git commit -m x' msys)
if [ "$got" = 0 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: claude without session id in Git Bash with skip key (ожидалось 0, получено $got)"; fi
rm -f "$TMP_ROOT/params.yaml" "$TMP_ROOT/.iwe-runtime/session-open-gate-skip.log"
close_semaphore

# Claude with the Shell tool and its own session_id behaves as with Bash (no semaphore → block)
close_semaphore
printf '{"tool_name":"Shell","tool_input":{"command":"git commit -m x"},"session_id":"%s"}' "$SID" \
  | IWE_ROOT="$TMP_ROOT" bash "$HOOK" >/dev/null 2>&1
got=$?
if [ "$got" = 2 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: claude Shell without semaphore (ожидалось 2, получено $got)"; fi

# an agent name with glob characters does not find foreign semaphores: '*' with claude-code open with wp → block (Phase 274)
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

# === Skip on Git Bash via session_open_gate_skip_until (Phase 271, issue #1281) ===
# The platform is read from $OSTYPE: the test injects it into the hook environment (in real
# Git Bash it equals msys). Substituting `uname` via PATH does not affect the decision.
close_semaphore
PARAMS="$TMP_ROOT/params.yaml"
SKIP_LOG="$TMP_ROOT/.iwe-runtime/session-open-gate-skip.log"

day_offset() { # $1 = offset in days from today -> YYYY-MM-DD (GNU date, then BSD)
  date -d "$1 days" +%Y-%m-%d 2>/dev/null || date -v"$1"d +%Y-%m-%d
}

run_gate_os() { # $1 = OSTYPE, $2 = command -> prints the hook exit code
  local json_cmd
  json_cmd=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$2")
  printf '{"tool_name":"Bash","tool_input":{"command":%s},"session_id":"%s"}' \
    "$json_cmd" "$SID" | OSTYPE="$1" IWE_ROOT="$TMP_ROOT" bash "$HOOK" >/dev/null 2>&1
  echo $?
}

expect_skip() { # $1 = description, $2 = expected code, $3 = OSTYPE, $4 = params.yaml content
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

# log: a skip leaves a line with the end date; a write failure does not change the decision
rm -f "$SKIP_LOG"
printf '%s: %s\n' "$K" "$(day_offset +5)" > "$PARAMS"
run_gate_os msys 'git commit -m x' >/dev/null
if grep -q "until=$(day_offset +5)" "$SKIP_LOG" 2>/dev/null; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: skip: строка журнала не записана"; fi
if grep -qE "ostype=msys uname_s=[^ ]+$" "$SKIP_LOG" 2>/dev/null; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: skip: в журнале нет ostype=msys и uname_s= (F272)"; fi
# log fields are independent: with a substituted OSTYPE, uname_s equals the host's real platform —
# the output of uname -s from the system PATH, on any OS (Linux, macOS, Git Bash: MINGW64_NT-...) (F274)
HOST_UNAME_S=$(command -p uname -s 2>/dev/null)
LOGGED_UNAME_S=$(grep -E "ostype=msys uname_s=" "$SKIP_LOG" 2>/dev/null | tail -1 | sed -E 's/.* uname_s=//')
if [ -z "$HOST_UNAME_S" ]; then FAIL=$((FAIL+1)); echo "FAIL: skip: command -p uname -s на хосте теста пуст — проверку uname_s не выполнить (F274)"
elif [ "$LOGGED_UNAME_S" = "$HOST_UNAME_S" ] && [ "$LOGGED_UNAME_S" != UNKNOWN ] && [ "$LOGGED_UNAME_S" != msys ]; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); echo "FAIL: skip: uname_s='$LOGGED_UNAME_S' не равен настоящей платформе '$HOST_UNAME_S' при подменённом OSTYPE (F274)"; fi
# a fake uname in PATH does not end up in the uname_s field
FAKE_BIN="$TMP_ROOT/fakebin"; mkdir -p "$FAKE_BIN"; printf '#!/bin/sh\necho MSYS_NT-FAKE\n' > "$FAKE_BIN/uname"; chmod +x "$FAKE_BIN/uname"
rm -f "$SKIP_LOG"
printf '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"},"session_id":"%s"}' "$SID" | PATH="$FAKE_BIN:$PATH" OSTYPE=msys IWE_ROOT="$TMP_ROOT" bash "$HOOK" >/dev/null 2>&1
if ! grep -q "uname_s=" "$SKIP_LOG" 2>/dev/null; then FAIL=$((FAIL+1)); echo "FAIL: skip: журнал с uname_s не записан при фальшивом uname (F272)"
elif grep -q "uname_s=MSYS_NT-FAKE" "$SKIP_LOG" 2>/dev/null; then FAIL=$((FAIL+1)); echo "FAIL: skip: uname_s взят из пользовательского PATH (F272)"; else PASS=$((PASS+1)); fi
rm -rf "$FAKE_BIN"
rm -rf "$TMP_ROOT/.iwe-runtime/session-open-gate-skip.log"
mkdir -p "$SKIP_LOG"   # directory instead of a file: writing is impossible
got=$(run_gate_os msys 'git commit -m x')
if [ "$got" = 0 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: skip: сбой журнала не должен менять решение (получено $got)"; fi
rmdir "$SKIP_LOG"

# a fake uname in PATH does not enable the skip on Linux
FAKE_BIN=$(mktemp -d)
printf '#!/bin/sh\necho MINGW64_NT\n' > "$FAKE_BIN/uname"; chmod +x "$FAKE_BIN/uname"
printf '%s: %s\n' "$K" "$(day_offset +5)" > "$PARAMS"
json_fake=$(python3 -c 'import json; print(json.dumps("git commit -m x"))')
printf '{"tool_name":"Bash","tool_input":{"command":%s},"session_id":"%s"}' "$json_fake" "$SID" \
  | PATH="$FAKE_BIN:$PATH" OSTYPE=linux-gnu IWE_ROOT="$TMP_ROOT" bash "$HOOK" >/dev/null 2>&1
got=$?
if [ "$got" = 2 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: skip: фальшивый uname в PATH дал обход (получено $got)"; fi
rm -rf "$FAKE_BIN"

# a semaphore with wp: exists → the key is not read, the log is not written
rm -f "$SKIP_LOG"
open_semaphore
got=$(run_gate_os msys 'git commit -m x')
if [ "$got" = 0 ] && [ ! -e "$SKIP_LOG" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: skip: при открытом семафоре ключ не должен читаться (код $got)"; fi
close_semaphore

# commands without commit/push under an active skip stay as they were (skip anyway)
got=$(run_gate_os linux-gnu 'git status')
if [ "$got" = 0 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: skip: git status должен проходить (получено $got)"; fi
rm -f "$PARAMS"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
