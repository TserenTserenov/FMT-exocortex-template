#!/bin/bash
# protocol-stop-gate.sh
# see DP.SC.025 (capture-bus), WP-229 Ф4
# Event: Stop
# Проверяет: если в сессии был вызов Skill (day-open|day-close|run-protocol|wp-new),
# то должен быть TodoWrite с ≥3 items. Иначе — block.
# Принцип warn-before-block: action=warn (промоция в block после 2 нед обкатки).
#
# Защита от infinite loop: поле stop_hook_active во входном JSON (issue #819).
# Read-only кроме gate_log.jsonl.

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

INPUT=$(cat)
if [ -z "$INPUT" ]; then
  echo '{}'
  exit 0
fi

# --- Infinite loop guard (issue #819) ---
# Claude Code запускает этот хук новым bash-процессом на каждое Stop-событие,
# поэтому env-переменная не переживает между вызовами — старый guard через
# STOP_HOOK_ACTIVE был мёртвым кодом с рождения. Claude Code сам передаёт
# признак повтора в JSON; читаем его оттуда (boolean или строка "true").
STOP_ACTIVE=$(printf '%s' "$INPUT" | jq -r 'if (.stop_hook_active == true or .stop_hook_active == "true") then "1" else "0" end' 2>/dev/null || echo 0)
if [ "$STOP_ACTIVE" = "1" ]; then
  echo '{}'
  exit 0
fi

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')

# #369 protected the shared sentinel from a NEIGHBOUR session's Stop (matched
# by session_id + owner-token, confirmed still correct by issue #460 path 7).
# It did not protect against the SAME session's own Stop: audit-installation
# creates the sentinel, launches a subagent rehearsal, and the parent turn's
# Stop can fire (session_id matches trivially) while that subagent is still
# writing under it — issue #460 path 6. Fix: this hook no longer deletes the
# shared sentinel at all, matched session or not. Removal is now only the
# explicit `rm -f` at the end of the owning procedure, backed by the
# fail-closed TTL in dry-run-gate.sh (path 3) as the crash fallback. The
# owner-file is still cleared here, but only once it's confirmed residue
# (sentinel already gone) — never while the sentinel it points at is live.
cleanup_owned_dry_run_sentinel() {
  local sid="$1" safe_sid owner_file
  [ -n "$sid" ] || return 0
  safe_sid=$(printf '%s' "$sid" | tr -cd 'A-Za-z0-9._-')
  [ -n "$safe_sid" ] || return 0
  owner_file="/tmp/iwe-dry-run-owner-${safe_sid}.token"
  [ -f "$owner_file" ] || return 0
  [ -f /tmp/iwe-dry-run.flag ] && return 0
  rm -f "$owner_file" 2>/dev/null || true
}

cleanup_owned_dry_run_sentinel "$SESSION_ID"

# issue #549 stage 2: идемпотентный fallback — если репетиция этой сессии
# ещё active (сессия умерла до штатного завершения), Stop переводит её в
# completed. Переход выполняется САМИМ хуком (доверенный код рантайма), без
# helper'а и флага --trusted-stop. Строгость (Codex r3): весь скан под одним
# замком; продолжаем только при РОВНО одном валидном v2 active-state этой
# сессии — corruption/множественные active не превращаем в allow, ничего не
# трогаем. Sentinel снимается только после УСПЕШНОГО перехода.
complete_dry_run_on_stop() {
  local sid="$1" dry_dir lock_dir sf gid recorded tmp nonce tries lock_pid lock_start cur_start
  local active_file="" active_gid="" corrupted=0 active_count=0
  [ -n "$sid" ] || return 0
  dry_dir="${IWE_DRY_RUN_DIR:-/tmp/iwe-dry-run-$(id -u)}"
  local sentinel="${IWE_DRY_RUN_SENTINEL:-/tmp/iwe-dry-run.flag}"
  # Единый резолвер путей (Codex r3): ЛЮБОЙ override без маркера сбрасывает
  # ОБА пути на production — как у gate/begin/complete.
  if [ -n "${IWE_DRY_RUN_DIR:-}" ] || [ -n "${IWE_DRY_RUN_SENTINEL:-}" ]; then
    if [ ! -f "${IWE_DRY_RUN_DIR:-/nonexistent}/.iwe-dry-run-test-mode" ]; then
      dry_dir="/tmp/iwe-dry-run-$(id -u)"
      sentinel="/tmp/iwe-dry-run.flag"
    fi
  fi
  [ -d "$dry_dir" ] && [ ! -L "$dry_dir" ] || return 0
  lock_dir="$dry_dir/transaction.lock"

  # Замок на весь скан+переход.
  tries=0
  while ! mkdir "$lock_dir" 2>/dev/null; do
    tries=$((tries + 1))
    [ "$tries" -gt 20 ] && return 0
    lock_pid=$(sed -n '1p' "$lock_dir/pid" 2>/dev/null || true)
    lock_start=$(sed -n '3p' "$lock_dir/pid" 2>/dev/null || true)
    cur_start=$(ps -o lstart= -p "$lock_pid" 2>/dev/null || true)
    if [ -n "$lock_pid" ] && { ! kill -0 "$lock_pid" 2>/dev/null || { [ -n "$lock_start" ] && [ -n "$cur_start" ] && [ "$lock_start" != "$cur_start" ]; }; }; then
      mv "$lock_dir" "$dry_dir/.stale-lock-$$-$(date +%s)" 2>/dev/null || true
      rm -rf "$dry_dir"/.stale-lock-* 2>/dev/null || true
      mkdir "$lock_dir" 2>/dev/null && break
    fi
    sleep 0.1 2>/dev/null || sleep 1
  done
  nonce=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
  if ! { echo "$$"; echo "$nonce"; ps -o lstart= -p $$ 2>/dev/null || echo "unknown"; } > "$lock_dir/pid" 2>/dev/null; then
    rm -rf "$lock_dir" 2>/dev/null || true
    return 0
  fi
  trap 'if [ "$(sed -n "2p" "$lock_dir/pid" 2>/dev/null)" = "$nonce" ]; then rm -rf "$lock_dir" 2>/dev/null; fi' RETURN 2>/dev/null || true

  # Строгий скан: битый/чужая версия/mismatch — corruption (ничего не трогаем).
  shopt -s nullglob
  for sf in "$dry_dir"/gate-*.state; do
    jq -e . "$sf" >/dev/null 2>&1 || { corrupted=1; break; }
    [ "$(jq -r '.version // empty' "$sf" 2>/dev/null)" = "2" ] || { corrupted=1; break; }
    gid=$(jq -r '.gate_id // empty' "$sf" 2>/dev/null || true)
    [ -n "$gid" ] && [ "gate-$gid.state" = "$(basename "$sf")" ] || { corrupted=1; break; }
    case "$(jq -r '.state // empty' "$sf" 2>/dev/null)" in
      active)
        active_count=$((active_count + 1))
        if [ "$(jq -r '.owner_session_id // empty' "$sf" 2>/dev/null)" = "$sid" ]; then
          active_file="$sf"; active_gid="$gid"
        fi
        ;;
      completed) ;;
      *) corrupted=1; break ;;
    esac
  done
  shopt -u nullglob

  if [ "$corrupted" = "0" ] && [ "$active_count" -le 1 ] && [ -n "$active_file" ]; then
    # Ровно один валидный active, и он наш — безопасный переход.
    if [ "$(jq -r '.state // empty' "$active_file" 2>/dev/null)" = "active" ]; then
      tmp=$(mktemp "$dry_dir/.complete.XXXXXX" 2>/dev/null || true)
      if [ -n "$tmp" ] && \
         jq --arg completed "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '.state="completed" | .completed_at=$completed | .completion_reason="stop-hook-fallback"' \
            "$active_file" > "$tmp" 2>/dev/null && mv -f "$tmp" "$active_file" 2>/dev/null; then
        # Sentinel — только ПОСЛЕ успешного перехода и только своего gate_id.
        if [ -f "$sentinel" ] && [ ! -L "$sentinel" ] && \
           [ "$(jq -r '.gate_id // empty' "$sentinel" 2>/dev/null)" = "$active_gid" ]; then
          rm -f "$sentinel"
        fi
      else
        rm -f "$tmp" 2>/dev/null || true
      fi
    fi
  fi
  # corruption / active_count>1 / чужой active — ничего не трогаем (fail-closed
  # со стороны гейта: сам he разберёт состояние при следующем tool-call).
  if [ "$(sed -n '2p' "$lock_dir/pid" 2>/dev/null)" = "$nonce" ]; then
    rm -rf "$lock_dir" 2>/dev/null || true
  fi
  # issue #818: RETURN trap (строка ~98) переживает эту функцию — bash не
  # скоупит `trap ... RETURN` к функции, где он поставлен, он остаётся
  # армированным для ЛЮБОГО следующего возврата функции/sourced-скрипта в
  # этом же процессе. Без явной очистки здесь — обычный Stop без активной
  # репетиции падает под `set -u`, когда хук позже сорсит bootstrap: trap
  # срабатывает повторно на уже мёртвых $lock_dir/$nonce.
  trap - RETURN 2>/dev/null || true
  return 0
}

complete_dry_run_on_stop "$SESSION_ID"

TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty')

# Нет транскрипта — пропустить
if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
  echo '{}'
  exit 0
fi

# Load unified environment: WORKSPACE_DIR, IWE_ROOT, IWE_SCRIPTS, etc.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$(cd "$HOOK_DIR/.." && pwd)"
# shellcheck source=../lib/iwe-env-bootstrap.sh
source "$CLAUDE_DIR/lib/iwe-env-bootstrap.sh" || exit 1
GATE_LOG="$IWE_ROOT/.claude/logs/gate_log.jsonl"
mkdir -p "$(dirname "$GATE_LOG")" 2>/dev/null || true

# --- Шаг 1: был ли вызов протокольного скилла? ---
# issue #758: в транскрипте Claude Code tool_use лежит вложенно, в
# .message.content[], а не на верхнем уровне строки (там type=assistant/
# user/attachment) — select(.type=="tool_use") на верхнем уровне не
# совпадал никогда. `[]?` гасит ошибку, если .message/.content отсутствует
# или не массив, — этого достаточно, широкий `try` не нужен.
# issue #862 follow-up (Codex r3): транскрипт — JSONL (по одному JSON-объекту
# на строку/сообщение), поэтому все jq-запросы используют -s и разворачивают
# массив сообщений через .[].
PROTOCOL_SKILL=$(jq -s -r '
  [.[] | select((.message.role // "assistant") == "assistant") | .message.content[]?]
  | .[]
  | select(.type == "tool_use" and .name == "Skill")
  | .input.skill // empty
' "$TRANSCRIPT_PATH" 2>/dev/null \
  | grep -E '^(day-open|day-close|run-protocol|wp-new)$' \
  | head -1)

if [ -z "$PROTOCOL_SKILL" ]; then
  # Протокольный скилл не запускался — gate не нужен
  echo '{}'
  exit 0
fi

# --- Шаг 2: был ли таск-лист с ≥3 items? --- (та же вложенность, что в Шаге 1)
# issue #862: TodoWrite устарел и заменён TaskCreate/TaskUpdate; кроме того,
# SKILL.md явно разрешает нумерацию шагов в ответах, когда Task-инструменты
# недоступны. Учитываем все три признака.
# issue #862 follow-up (Codex r3): транскрипт JSONL, считаем только сообщения
# ассистента, TaskCreate и TaskUpdate разделяем (обновления одной задачи не
# должны множиться), TodoWrite берём по максимальному списку.
TODO_MAX=$(jq -s -r '
  [.[] | select((.message.role // "assistant") == "assistant") | .message]
  | .[] | .content[]?
  | select(.type == "tool_use" and .name == "TodoWrite")
  | .input.todos
  | if type == "array" then length else 0 end
' "$TRANSCRIPT_PATH" 2>/dev/null \
  | sort -n | tail -1)
TODO_MAX="${TODO_MAX:-0}"

TASK_CREATE_MAX=$(jq -s -r '
  [.[] | select((.message.role // "assistant") == "assistant") | .message]
  | .[] | .content[]?
  | select(.type == "tool_use" and .name == "TaskCreate")
  | .input
  | if (.tasks // .task_list // .items) | type == "array" then
      (.tasks // .task_list // .items) | length
    elif (.tasks // .task_list // .items) != null then
      1
    elif (.name // .title // .description // .status) then
      1
    else
      0
    end
' "$TRANSCRIPT_PATH" 2>/dev/null \
  | awk '{s+=$1} END {print s+0}')
TASK_CREATE_MAX="${TASK_CREATE_MAX:-0}"

TASK_UPDATE_MAX=$(jq -s -r '
  [.[] | select((.message.role // "assistant") == "assistant") | .message]
  | .[] | .content[]?
  | select(.type == "tool_use" and .name == "TaskUpdate")
  | .input
  | if (.tasks // .task_list // .items) | type == "array" then
      (.tasks // .task_list // .items) | length
    elif (.tasks // .task_list // .items) != null then
      1
    elif (.name // .title // .description // .status) then
      1
    else
      0
    end
' "$TRANSCRIPT_PATH" 2>/dev/null \
  | sort -n | tail -1)
TASK_UPDATE_MAX="${TASK_UPDATE_MAX:-0}"

# Явная нумерация шагов в ответах ассистента: "Шаг N из M" / "Step N of M".
# Берём максимальный общий знаменатель M, потому что ответ может содержать
# промежуточные шаги без полной формулы.
STEP_MAX=$(jq -s -r '
  [.[] | select((.message.role // "assistant") == "assistant") | .message]
  | .[] | .content[]?
  | select(.type == "text" and (.text // "") != "")
  | .text
' "$TRANSCRIPT_PATH" 2>/dev/null \
  | grep -oiE '(шаг|step)[[:space:]]+[0-9]+[[:space:]]+(из|of)[[:space:]]+[0-9]+' \
  | grep -oiE '[0-9]+$' \
  | sort -n | tail -1)
STEP_MAX="${STEP_MAX:-0}"

# TodoWrite и TaskCreate — сигналы планирования (список задач); суммируем,
# потому что отдельные TaskCreate = отдельные шаги, а TodoWrite может быть
# дополнен TaskCreate. TaskUpdate — обновления, берём max, чтобы обновления
# одной задачи не размножались. Явная нумерация в тексте — независимый
# источник; берём max.
LIST_MAX=$(( TODO_MAX + TASK_CREATE_MAX ))
if [ "$TASK_UPDATE_MAX" -gt "$LIST_MAX" ]; then LIST_MAX="$TASK_UPDATE_MAX"; fi
if [ "$STEP_MAX" -gt "$LIST_MAX" ]; then LIST_MAX="$STEP_MAX"; fi

THRESHOLD=3

# --- Шаг 3: логировать событие ---
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
FIRED=0
if [ "$LIST_MAX" -lt "$THRESHOLD" ]; then
  FIRED=1
fi

TASK_MAX_SIGNAL="$TASK_CREATE_MAX"
if [ "$TASK_UPDATE_MAX" -gt "$TASK_MAX_SIGNAL" ]; then TASK_MAX_SIGNAL="$TASK_UPDATE_MAX"; fi

LOG_ENTRY=$(jq -nc \
  --arg ts "$TIMESTAMP" \
  --arg sid "$SESSION_ID" \
  --arg skill "$PROTOCOL_SKILL" \
  --arg todo_max "$TODO_MAX" \
  --arg task_max "$TASK_MAX_SIGNAL" \
  --arg task_create_max "$TASK_CREATE_MAX" \
  --arg task_update_max "$TASK_UPDATE_MAX" \
  --arg step_max "$STEP_MAX" \
  --arg list_max "$LIST_MAX" \
  --arg threshold "$THRESHOLD" \
  --arg fired "$FIRED" \
  '{ts: $ts, gate: "protocol-stop-gate", session_id: $sid, skill: $skill,
    todo_max: ($todo_max|tonumber), task_max: ($task_max|tonumber),
    task_create_max: ($task_create_max|tonumber),
    task_update_max: ($task_update_max|tonumber),
    step_max: ($step_max|tonumber), list_max: ($list_max|tonumber),
    threshold: ($threshold|tonumber), fired: ($fired == "1"), action: "warn"}' 2>/dev/null || true)

if [ -n "$LOG_ENTRY" ]; then
  echo "$LOG_ENTRY" >> "$GATE_LOG" 2>/dev/null || true
fi

# --- Шаг 4: action=warn (не block — обкатка 2 нед, WP-229 принцип warn-before-block) ---
# issue #819: раньше здесь стоял {"decision": "block", ...} — для Stop-события
# это реальный запрет остановиться, а не предупреждение (расходился с
# action:"warn" в том же LOG_ENTRY выше). systemMessage без decision — тот же
# паттерн ненавязчивого уведомления, что уже используют secret-leak-block.sh /
# secret-file-read-block.sh / secret-mcp-dump-guard.sh.
if [ "$FIRED" = "1" ]; then
  cat <<EOF
{"systemMessage": "⚠️ PROTOCOL-STOP-GATE [warn]: Скилл '$PROTOCOL_SKILL' был вызван, но признак исполнения по шагам (TodoWrite/Task-инструменты/явная нумерация) с ≥$THRESHOLD задачами не найден (найдено: $LIST_MAX). Протокол требует пошаговый план ДО начала исполнения. Действие: создай TodoWrite/Task-лист с шагами скилла либо явно пронумеруй шаги в ответах, как разрешено SKILL.md, и пройди протокол заново. (gate_log: $GATE_LOG)"}
EOF
else
  echo '{}'
fi

exit 0
