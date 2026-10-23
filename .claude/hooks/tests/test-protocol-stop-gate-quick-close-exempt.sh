#!/bin/bash
# test-protocol-stop-gate-quick-close-exempt.sh — issue #1311:
# run-protocol close/close session (Quick Close, по дизайну "inline, без
# TodoWrite" — memory/protocol-close.md) не должен требовать TodoWrite/Task
# чеклист из 3+ пунктов. Тяжёлые протоколы (week-close/month-close/day-close
# и прямые skill-имена day-open/day-close/wp-new) продолжают требовать его
# как раньше — регрессия не допускается.
#
# Запуск: bash .claude/hooks/tests/test-protocol-stop-gate-quick-close-exempt.sh

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

PASS=0
FAIL=0

IWE_ROOT="$TMP_DIR/iwe-root"
mkdir -p "$IWE_ROOT/.claude/logs"

# write_transcript <name> <jsonl-content> (one JSON object per line)
write_transcript() {
  local name="$1"
  shift
  printf '%s\n' "$*" > "$TMP_DIR/$name.jsonl"
}

# run_gate <transcript-name> -> true|false (fired?) — отсутствие новой
# строки в gate_log (ранний выход Quick Close ничего не логирует, как и
# ветка "протокольный скилл не вызывался") читается как "false".
run_gate() {
  local transcript="$TMP_DIR/$1.jsonl"
  local log="$IWE_ROOT/.claude/logs/gate_log.jsonl"
  local lines_before=0
  [ -f "$log" ] && lines_before=$(wc -l < "$log" | tr -d ' ')

  local code=0
  printf '{"session_id":"test-session","transcript_path":"%s"}\n' "$transcript" \
    | IWE_ROOT="$IWE_ROOT" bash "$HOOK_DIR/protocol-stop-gate.sh" >/dev/null 2>&1 || code=$?
  if [ "$code" -ne 0 ]; then
    echo "HOOK-ERROR:$code"
    return
  fi

  local lines_after=0
  [ -f "$log" ] && lines_after=$(wc -l < "$log" | tr -d ' ')
  if [ "$lines_after" -le "$lines_before" ]; then
    echo "false"
    return
  fi

  tail -1 "$log" | python3 -c 'import sys,json; print(str(json.loads(sys.stdin.read()).get("fired", False)).lower())'
}

check() {
  local desc="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL: $desc (ожидалось '$want', получено '$got')"
  fi
}

# transcript fragments
msg_rp_close='{"message":{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"run-protocol","args":"close"}}]}}'
msg_rp_close_session='{"message":{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"run-protocol","args":"close session"}}]}}'
msg_rp_close_padded='{"message":{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"run-protocol","args":"  CLOSE  "}}]}}'
msg_rp_no_args='{"message":{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"run-protocol"}}]}}'
msg_rp_week_close='{"message":{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"run-protocol","args":"week-close"}}]}}'
msg_rp_object_args='{"message":{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"run-protocol","args":{"scope":"day"}}}]}}'
msg_rp_bool_false_args='{"message":{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"run-protocol","args":false}}]}}'
msg_rp_null_args='{"message":{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"run-protocol","args":null}}]}}'
msg_day_close='{"message":{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"day-close"}}]}}'
msg_text_plain='{"message":{"role":"assistant","content":[{"type":"text","text":"просто текст"}]}}'

# === Quick Close exempt: run-protocol close/close session/empty, без чеклиста ===
write_transcript rp-close-no-todo "$msg_rp_close" "$msg_text_plain"
check "run-protocol close без чеклиста не firing" "false" "$(run_gate rp-close-no-todo)"

write_transcript rp-close-session-no-todo "$msg_rp_close_session" "$msg_text_plain"
check "run-protocol 'close session' без чеклиста не firing" "false" "$(run_gate rp-close-session-no-todo)"

write_transcript rp-close-padded-no-todo "$msg_rp_close_padded" "$msg_text_plain"
check "run-protocol '  CLOSE  ' (регистр/пробелы) без чеклиста не firing" "false" "$(run_gate rp-close-padded-no-todo)"

write_transcript rp-no-args-no-todo "$msg_rp_no_args" "$msg_text_plain"
check "run-protocol без args вовсе (пусто = Quick Close) не firing" "false" "$(run_gate rp-no-args-no-todo)"

# === Регрессия: тяжёлые протоколы продолжают требовать чеклист ===
write_transcript rp-week-close-no-todo "$msg_rp_week_close" "$msg_text_plain"
check "run-protocol week-close без чеклиста firing (не экземптится)" "true" "$(run_gate rp-week-close-no-todo)"

write_transcript rp-object-args-no-todo "$msg_rp_object_args" "$msg_text_plain"
check "run-protocol с args-объектом (не строка) firing (fail-closed)" "true" "$(run_gate rp-object-args-no-todo)"

write_transcript day-close-direct-no-todo "$msg_day_close" "$msg_text_plain"
check "day-close (прямое имя скилла) без чеклиста firing (ветка не тронута)" "true" "$(run_gate day-close-direct-no-todo)"

write_transcript rp-bool-false-args-no-todo "$msg_rp_bool_false_args" "$msg_text_plain"
check "run-protocol с args=false (не строка) firing (fail-closed, не путать с '')" "true" "$(run_gate rp-bool-false-args-no-todo)"

write_transcript rp-null-args-no-todo "$msg_rp_null_args" "$msg_text_plain"
check "run-protocol с явным args=null (как отсутствие) не firing" "false" "$(run_gate rp-null-args-no-todo)"

write_transcript rp-array-args-no-todo '{"message":{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"run-protocol","args":["close"]}}]}}' "$msg_text_plain"
check "run-protocol с args-массивом (не строка) firing (fail-closed)" "true" "$(run_gate rp-array-args-no-todo)"

# === Самый важный регресс: ПОЗДНИЙ тяжёлый вызов после РАННЕГО Quick Close
# в одном транскрипте не должен застревать на раннем "close" (issue #1311
# cold-review, Critical) — гейт должен смотреть на ПОСЛЕДНИЙ вызов run-protocol.
write_transcript rp-early-close-late-week-close "$msg_rp_close" "$msg_rp_week_close" "$msg_text_plain"
check "ранний close + поздний week-close без чеклиста firing (не застревает на первом вызове)" "true" "$(run_gate rp-early-close-late-week-close)"

write_transcript rp-early-week-close-late-close "$msg_rp_week_close" "$msg_rp_close" "$msg_text_plain"
check "ранний week-close + поздний close без чеклиста не firing (последний вызов — Quick Close)" "false" "$(run_gate rp-early-week-close-late-close)"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
