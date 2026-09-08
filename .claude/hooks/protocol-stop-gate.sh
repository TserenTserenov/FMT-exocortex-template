#!/bin/bash
# protocol-stop-gate.sh
# see DP.SC.025 (capture-bus), WP-229 Ф4
# Event: Stop
# Проверяет: если в сессии был вызов Skill (day-open|day-close|run-protocol|wp-new),
# то должен быть TodoWrite с ≥3 items. Иначе — block.
# Принцип warn-before-block: action=warn (промоция в block после 2 нед обкатки).
#
# Защита от infinite loop: переменная STOP_HOOK_ACTIVE.
# Read-only кроме gate_log.jsonl.

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

# --- Infinite loop guard ---
if [ "${STOP_HOOK_ACTIVE:-}" = "1" ]; then
  echo '{}'
  exit 0
fi
export STOP_HOOK_ACTIVE=1

INPUT=$(cat)
if [ -z "$INPUT" ]; then
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
PROTOCOL_SKILL=$(jq -r '
  select(.type == "tool_use" and .name == "Skill")
  | .input.skill // empty
' "$TRANSCRIPT_PATH" 2>/dev/null \
  | grep -E '^(day-open|day-close|run-protocol|wp-new)$' \
  | head -1)

if [ -z "$PROTOCOL_SKILL" ]; then
  # Протокольный скилл не запускался — gate не нужен
  echo '{}'
  exit 0
fi

# --- Шаг 2: был ли TodoWrite с ≥3 items? ---
TODO_MAX=$(jq -r '
  select(.type == "tool_use" and .name == "TodoWrite")
  | .input.todos
  | if type == "array" then length else 0 end
' "$TRANSCRIPT_PATH" 2>/dev/null \
  | sort -n | tail -1)

TODO_MAX="${TODO_MAX:-0}"
THRESHOLD=3

# --- Шаг 3: логировать событие ---
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
FIRED=0
if [ "$TODO_MAX" -lt "$THRESHOLD" ]; then
  FIRED=1
fi

LOG_ENTRY=$(jq -nc \
  --arg ts "$TIMESTAMP" \
  --arg sid "$SESSION_ID" \
  --arg skill "$PROTOCOL_SKILL" \
  --arg todo_max "$TODO_MAX" \
  --arg threshold "$THRESHOLD" \
  --arg fired "$FIRED" \
  '{ts: $ts, gate: "protocol-stop-gate", session_id: $sid, skill: $skill,
    todo_max: ($todo_max|tonumber), threshold: ($threshold|tonumber),
    fired: ($fired == "1"), action: "warn"}' 2>/dev/null || true)

if [ -n "$LOG_ENTRY" ]; then
  echo "$LOG_ENTRY" >> "$GATE_LOG" 2>/dev/null || true
fi

# --- Шаг 4: action=warn (не block — обкатка 2 нед, WP-229 принцип warn-before-block) ---
if [ "$FIRED" = "1" ]; then
  cat <<EOF
{"decision": "block", "reason": "⚠️ PROTOCOL-STOP-GATE [warn]: Скилл '$PROTOCOL_SKILL' был вызван, но TodoWrite с ≥$THRESHOLD задачами не найден (найдено: $TODO_MAX). Протокол требует таск-лист ДО начала исполнения. Действие: создай TodoWrite с шагами скилла и пройди протокол заново. (gate_log: $GATE_LOG)"}
EOF
else
  echo '{}'
fi

exit 0
