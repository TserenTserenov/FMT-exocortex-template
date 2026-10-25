#!/bin/bash
# test_issue_1340_step_caps.sh — issue #1340:
# в Git Bash на Windows (LC_CTYPE=C.UTF-8) grep -i не сводит кириллицу к одному
# регистру, поэтому форма «Шаг N из M» с заглавной буквы в начале предложения
# не находилась признаком явной нумерации и гейт блокировал честный ход.
# Хук перечисляет регистровые классы явно; здесь это закреплено.

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

PASS=0
FAIL=0

IWE_ROOT="$TMP_DIR/iwe-root"
mkdir -p "$IWE_ROOT/.claude/logs"

write_transcript() {
  local name="$1"
  shift
  printf '%s\n' "$*" > "$TMP_DIR/$name.jsonl"
}

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

msg_skill='{"message":{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"day-open"}}]}}'
msg_capital_ru='{"message":{"role":"assistant","content":[{"type":"text","text":"Шаг 2 из 15 — выполнен"}]}}'
msg_lower_ru='{"message":{"role":"assistant","content":[{"type":"text","text":"сейчас шаг 2 из 15"}]}}'
msg_capital_en='{"message":{"role":"assistant","content":[{"type":"text","text":"Step 2 of 15 done"}]}}'
msg_lower_en='{"message":{"role":"assistant","content":[{"type":"text","text":"now step 2 of 15"}]}}'
msg_capital_of_en='{"message":{"role":"assistant","content":[{"type":"text","text":"Step 2 Of 15"}]}}'
msg_caps_ru='{"message":{"role":"assistant","content":[{"type":"text","text":"ШАГ 2 ИЗ 15 — ГОТОВО"}]}}'
msg_caps_en='{"message":{"role":"assistant","content":[{"type":"text","text":"STEP 2 OF 15 DONE"}]}}'
msg_plain='{"message":{"role":"assistant","content":[{"type":"text","text":"просто текст без нумерации"}]}}'

write_transcript capital-start "$msg_skill" "$msg_capital_ru"
check "«Шаг 2 из 15» с заглавной в начале предложения не firing" "false" "$(run_gate capital-start)"

write_transcript lower-inline "$msg_skill" "$msg_lower_ru"
check "«шаг 2 из 15» со строчной внутри фразы не firing" "false" "$(run_gate lower-inline)"

write_transcript capital-en "$msg_skill" "$msg_capital_en"
check "«Step 2 of 15» с заглавной не firing" "false" "$(run_gate capital-en)"

write_transcript lower-en "$msg_skill" "$msg_lower_en"
check "«step 2 of 15» со строчной не firing" "false" "$(run_gate lower-en)"

write_transcript capital-of-en "$msg_skill" "$msg_capital_of_en"
check "«Step 2 Of 15» (Of с заглавной) не firing" "false" "$(run_gate capital-of-en)"

write_transcript caps-ru "$msg_skill" "$msg_caps_ru"
check "«ШАГ 2 ИЗ 15» в капс-локе не firing" "false" "$(run_gate caps-ru)"

write_transcript caps-en "$msg_skill" "$msg_caps_en"
check "«STEP 2 OF 15» в капс-локе не firing" "false" "$(run_gate caps-en)"

write_transcript no-steps "$msg_skill" "$msg_plain"
check "без нумерации — firing" "true" "$(run_gate no-steps)"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
