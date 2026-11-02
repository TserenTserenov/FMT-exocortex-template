#!/bin/bash
# Test issue #1183: the PreCompact hook writes a snapshot to a file outside the repository
# ($CLAUDE_CONFIG_DIR/iwe-checkpoints/), the SessionStart(compact) hook returns it
# to the agent via stdout. The observable result is checked: the file content and
# the text the model will receive, not just the JSON shape.
#
# Run: bash .claude/hooks/tests/test-issue-1183-precompact-checkpoint.sh

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

check() {
  local desc="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL: $desc (ожидалось '$want', получено '$got')"
  fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export CLAUDE_CONFIG_DIR="$TMP/.claude"
SID="sess-1183_x"

# Transcript: a user turn (JSON string, -p format), a turn with
# multi-line text, a multi-line assistant reply, a service insertion
# as the SECOND block of the same user message (issue #1183, M2).
cat > "$TMP/transcript.jsonl" <<'JSONL'
{"type":"user","message":{"role":"user","content":"Начни протокол ОБРАЗЕЦ"}}
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Доделай РП-777, шаг верификации"},{"type":"text","text":"<system-reminder>служебное</system-reminder>"}]}}
{"type":"user","message":{"role":"user","content":"<system-reminder>чистая строка-напоминание</system-reminder>"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Итог по задаче."},{"type":"text","text":"Остановился на шаге 4: верификация не выполнена. Следом шаг 5"}]}}
JSONL

PRE_IN=$(jq -nc --arg sid "$SID" --arg cwd "$TMP" --arg tp "$TMP/transcript.jsonl" \
  '{session_id:$sid,cwd:$cwd,transcript_path:$tp,hook_event_name:"PreCompact",trigger:"manual"}')

# 1. PreCompact: silent, writes a file outside the project (not in $cwd/.claude/)
OUT=$(printf '%s' "$PRE_IN" | bash "$HOOK_DIR/precompact-checkpoint.sh"); CODE=$?
check "pre: exit 0" "0" "$CODE"
check "pre: stdout пуст (канала к модели нет)" "" "$OUT"
check "pre: файл НЕ создан внутри проекта" "0" "$(find "$TMP" -maxdepth 2 -name 'checkpoint-*.md' | wc -l | tr -d ' ')"
CP="$CLAUDE_CONFIG_DIR/iwe-checkpoints/checkpoint-$SID.md"
check "pre: файл слепка создан вне проекта" "yes" "$([ -f "$CP" ] && echo yes || echo no)"
check "pre: каталог слепков 700" "700" "$(stat -c %a "$CLAUDE_CONFIG_DIR/iwe-checkpoints" 2>/dev/null || stat -f %Lp "$CLAUDE_CONFIG_DIR/iwe-checkpoints")"
check "pre: права файла 600" "600" "$(stat -c %a "$CP" 2>/dev/null || stat -f %Lp "$CP")"
check "pre: запрос-строка (формат -p) попал в слепок" "yes" "$(grep -q 'Начни протокол ОБРАЗЕЦ' "$CP" && echo yes || echo no)"
check "pre: второй запрос попал в слепок" "yes" "$(grep -q 'Доделай РП-777' "$CP" && echo yes || echo no)"
check "pre: служебная вставка (второй блок) не попала" "no" "$(grep -q 'служебное' "$CP" && echo yes || echo no)"
check "pre: многострочный ответ сохранён целиком" "yes" "$(grep -q 'Итог по задаче.*Следом шаг 5' "$CP" && echo yes || echo no)"
check "pre: строка-напоминание (type=string) отфильтрована" "no" "$(grep -q 'чистая строка-напоминание' "$CP" && echo yes || echo no)"

# 2. SessionStart(compact): returns the snapshot for the same session_id, marks it as
# untrusted data, after delivery the snapshot is one-time.
POST_IN=$(jq -nc --arg sid "$SID" --arg cwd "$TMP" '{session_id:$sid,cwd:$cwd,hook_event_name:"SessionStart",source:"compact"}')
OUT=$(printf '%s' "$POST_IN" | bash "$HOOK_DIR/precompact-restore.sh"); CODE=$?
check "restore: exit 0" "0" "$CODE"
check "restore: агент получает слепок" "yes" "$(printf '%s' "$OUT" | grep -q 'Остановился на шаге 4' && echo yes || echo no)"
check "restore: слепок помечен как недоверенные данные" "yes" "$(printf '%s' "$OUT" | grep -q 'недоверенные данные' && echo yes || echo no)"
check "restore: слепок одноразовый (файл удалён)" "no" "$([ -e "$CP" ] && echo yes || echo no)"

# 3. No snapshot (another session) → we print nothing
POST_OTHER=$(jq -nc --arg cwd "$TMP" '{session_id:"other",cwd:$cwd,source:"compact"}')
OUT=$(printf '%s' "$POST_OTHER" | bash "$HOOK_DIR/precompact-restore.sh")
check "restore: без слепка тишина" "" "$OUT"

# 4. Rejection of an unsafe/too long session_id — we write nothing
EVIL=$(jq -nc --arg cwd "$TMP" '{session_id:"../../evil",cwd:$cwd,trigger:"auto"}')
printf '%s' "$EVIL" | bash "$HOOK_DIR/precompact-checkpoint.sh"
check "pre: небезопасный session_id отклонён" "0" "$(find "$CLAUDE_CONFIG_DIR/iwe-checkpoints" -name 'checkpoint-*evil*' 2>/dev/null | wc -l | tr -d ' ')"
LONG_ID=$(printf 'a%.0s' $(seq 1 200))
TOOLONG=$(jq -nc --arg sid "$LONG_ID" --arg cwd "$TMP" '{session_id:$sid,cwd:$cwd,trigger:"auto"}')
printf '%s' "$TOOLONG" | bash "$HOOK_DIR/precompact-checkpoint.sh"
check "pre: слишком длинный session_id отклонён" "0" "$(find "$CLAUDE_CONFIG_DIR/iwe-checkpoints" -maxdepth 1 -name "checkpoint-$LONG_ID.md" 2>/dev/null | wc -l | tr -d ' ')"

# 5. No session_id → no error and no file
printf '%s' '{"cwd":"'"$TMP"'"}' | bash "$HOOK_DIR/precompact-checkpoint.sh"
check "pre: без session_id exit 0" "0" "$?"

# 6. A transcript with long lines (e.g. tool output) and an unfinished
# last line must not abort the parsing of the rest of the tail (issue #1183, H1).
BIGSID="big-sess"
BIG_TRANSCRIPT="$TMP/big.jsonl"
python3 - "$BIG_TRANSCRIPT" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path, "w") as f:
    for i in range(300):
        f.write(json.dumps({"type": "user", "message": {"role": "user", "content": "x" * 2000}}) + "\n")
    f.write(json.dumps({"type": "user", "message": {"role": "user", "content": "финальный запрос перед обрывом"}}) + "\n")
    f.write('{"type": "user", "message": {"role": "user", "content": "обрыв на сер')  # без \n и без закрытия JSON
PYEOF
BIG_IN=$(jq -nc --arg sid "$BIGSID" --arg cwd "$TMP" --arg tp "$BIG_TRANSCRIPT" '{session_id:$sid,cwd:$cwd,transcript_path:$tp,trigger:"auto"}')
printf '%s' "$BIG_IN" | bash "$HOOK_DIR/precompact-checkpoint.sh"
BIG_CP="$CLAUDE_CONFIG_DIR/iwe-checkpoints/checkpoint-$BIGSID.md"
check "pre: большой транскрипт с обрывом — файл создан" "yes" "$([ -f "$BIG_CP" ] && echo yes || echo no)"
check "pre: разбор не оборвался на битой строке, валидная запись видна" "yes" "$(grep -q 'финальный запрос перед обрывом' "$BIG_CP" && echo yes || echo no)"

# 7. A newline INSIDE a single text block must not split an entry into
# parts under an outer tail -n N (issue #1183, cold review round 2, M1):
# join(" ") glues the blocks together, but previously did not clean \n inside a block.
MULTISID="multiline-sess"
MULTI_TRANSCRIPT="$TMP/multiline.jsonl"
cat > "$MULTI_TRANSCRIPT" <<'JSONL'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Многострочный блок:\nстрока два\nстрока три (конец)"}]}}
JSONL
MULTI_IN=$(jq -nc --arg sid "$MULTISID" --arg cwd "$TMP" --arg tp "$MULTI_TRANSCRIPT" '{session_id:$sid,cwd:$cwd,transcript_path:$tp,trigger:"auto"}')
printf '%s' "$MULTI_IN" | bash "$HOOK_DIR/precompact-checkpoint.sh"
MULTI_CP="$CLAUDE_CONFIG_DIR/iwe-checkpoints/checkpoint-$MULTISID.md"
check "pre: перевод строки внутри одного блока не режет запись (M1)" "yes" "$(grep -q 'Многострочный блок:.*строка два.*строка три (конец)' "$MULTI_CP" && echo yes || echo no)"

# 8. A snapshot larger than 6000 bytes — restore reports the truncation rather than staying silent about it.
BIGSNAP_SID="big-snapshot-sess"
BIGSNAP_CP="$CLAUDE_CONFIG_DIR/iwe-checkpoints/checkpoint-$BIGSNAP_SID.md"
python3 -c "print('x' * 7000)" > "$BIGSNAP_CP"
OUT=$(printf '%s' "$(jq -nc --arg sid "$BIGSNAP_SID" --arg cwd "$TMP" '{session_id:$sid,cwd:$cwd,source:"compact"}')" | bash "$HOOK_DIR/precompact-restore.sh")
check "restore: обрезка слепка явно отмечена" "yes" "$(printf '%s' "$OUT" | grep -q 'обрезан до 6000' && echo yes || echo no)"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
