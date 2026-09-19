#!/bin/bash
# test-protocol-stop-gate-task-replacement.sh — issue #862 follow-up:
# protocol-stop-gate.sh учитывает TaskCreate/TaskUpdate как замену TodoWrite,
# включая одиночные вызовы с полями одной задачи (не массив) и JSONL-транскрипты.
#
# Запуск: bash .claude/hooks/tests/test-protocol-stop-gate-task-replacement.sh

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

# run_gate <transcript-name> -> true|false (fired?)
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
msg_skill='{"message":{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"day-open"}}]}}'
msg_todo_3='{"message":{"role":"assistant","content":[{"type":"tool_use","name":"TodoWrite","input":{"todos":[{"title":"a"},{"title":"b"},{"title":"c"}]}}]}}'
msg_todo_1='{"message":{"role":"assistant","content":[{"type":"tool_use","name":"TodoWrite","input":{"todos":[{"title":"a"}]}}]}}'
msg_taskcreate_batch3='{"message":{"role":"assistant","content":[{"type":"tool_use","name":"TaskCreate","input":{"tasks":[{"title":"a"},{"title":"b"},{"title":"c"}]}}]}}'
msg_taskcreate_single_a='{"message":{"role":"assistant","content":[{"type":"tool_use","name":"TaskCreate","input":{"name":"a","description":"do a"}}]}}'
msg_taskcreate_single_b='{"message":{"role":"assistant","content":[{"type":"tool_use","name":"TaskCreate","input":{"name":"b","description":"do b"}}]}}'
msg_taskcreate_single_c='{"message":{"role":"assistant","content":[{"type":"tool_use","name":"TaskCreate","input":{"name":"c","description":"do c"}}]}}'
msg_taskupdate_batch3='{"message":{"role":"assistant","content":[{"type":"tool_use","name":"TaskUpdate","input":{"task_list":[{"status":"done"},{"status":"done"},{"status":"done"}]}}]}}'
msg_taskupdate_single='{"message":{"role":"assistant","content":[{"type":"tool_use","name":"TaskUpdate","input":{"name":"a","status":"done"}}]}}'
msg_text_3of5='{"message":{"role":"assistant","content":[{"type":"text","text":"Шаг 3 из 5: завершить день"}]}}'
msg_text_1of2='{"message":{"role":"assistant","content":[{"type":"text","text":"Шаг 1 из 2"}]}}'
msg_text_plain='{"message":{"role":"assistant","content":[{"type":"text","text":"просто текст"}]}}'
msg_user_text_3of5='{"message":{"role":"user","content":[{"type":"text","text":"Шаг 3 из 5: вопрос"}]}}'

# === JSONL single-object baseline ===
write_transcript todo-three "$msg_skill" "$msg_todo_3"
check "JSONL TodoWrite с 3 задачами не firing" "false" "$(run_gate todo-three)"

write_transcript todo-one "$msg_skill" "$msg_todo_1"
check "JSONL TodoWrite с 1 задачей firing" "true" "$(run_gate todo-one)"

# === TaskCreate batch (array) ===
write_transcript taskcreate-batch "$msg_skill" "$msg_taskcreate_batch3"
check "TaskCreate batch из 3 не firing" "false" "$(run_gate taskcreate-batch)"

# === TaskCreate single-task form (issue #862 follow-up) ===
write_transcript taskcreate-single-three "$msg_skill" "$msg_taskcreate_single_a" "$msg_taskcreate_single_b" "$msg_taskcreate_single_c"
check "3 одиночных TaskCreate не firing" "false" "$(run_gate taskcreate-single-three)"

write_transcript taskcreate-single-one "$msg_skill" "$msg_taskcreate_single_a"
check "1 одиночный TaskCreate firing" "true" "$(run_gate taskcreate-single-one)"

# === TaskUpdate array (max, not sum) ===
write_transcript taskupdate-batch "$msg_skill" "$msg_taskupdate_batch3"
check "TaskUpdate batch из 3 не firing" "false" "$(run_gate taskupdate-batch)"

write_transcript taskupdate-three-singles "$msg_skill" "$msg_taskupdate_single" "$msg_taskupdate_single" "$msg_taskupdate_single"
check "3 одиночных TaskUpdate одной задачи — firing (не суммируем обновления)" "true" "$(run_gate taskupdate-three-singles)"

# === Text step numbering ===
write_transcript text-steps "$msg_skill" "$msg_text_3of5"
check "Шаг 3 из 5 в тексте не firing" "false" "$(run_gate text-steps)"

write_transcript text-steps-short "$msg_skill" "$msg_text_1of2"
check "Шаг 1 из 2 в тексте firing" "true" "$(run_gate text-steps-short)"

# === User message with step numbering should not count ===
write_transcript user-text-steps "$msg_skill" "$msg_user_text_3of5"
check "Шаг 3 из 5 в сообщении пользователя — firing" "true" "$(run_gate user-text-steps)"

# === No task list at all ===
write_transcript no-tasks "$msg_skill" "$msg_text_plain"
check "Нет задач — firing" "true" "$(run_gate no-tasks)"

# === Mixed sources ===
write_transcript mixed-todo-taskcreate "$msg_skill" "$msg_todo_1" "$msg_taskcreate_single_a" "$msg_taskcreate_single_b"
check "TodoWrite 1 + 2 одиночных TaskCreate не firing" "false" "$(run_gate mixed-todo-taskcreate)"

write_transcript mixed-taskcreate-update "$msg_skill" "$msg_taskcreate_single_a" "$msg_taskupdate_batch3"
check "TaskCreate 1 + TaskUpdate batch 3 не firing" "false" "$(run_gate mixed-taskcreate-update)"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
