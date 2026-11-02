#!/usr/bin/env bash
# see ADR-001-local-llm-stack.md (WP-404)
# Wrapper of the local LLM stack (MLX). JOB: privacy + fallback.
# The server binds to localhost only (B7.3).
# The active model and lifecycle are in the catalog via model-lifecycle.py.
# Commands: start | test | stop | status | models | pull <m> | use <m> | archive <m>
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLM_HOME="${IWE_LLM_HOME:-$HOME/.iwe-local-llm}"
PY="$LLM_HOME/.venv/bin/python"
LIFECYCLE="$HERE/model-lifecycle.py"
HOST="127.0.0.1"
PORT="${IWE_LLM_PORT:-8080}"
PIDFILE="$LLM_HOME/server.pid"
LOGFILE="$LLM_HOME/server.log"

die() { echo "error: $*" >&2; exit 1; }
[ -x "$PY" ] || die "venv не найден ($PY). Сначала установщик: install-local-llm.sh"

# Active model: env overrides the catalog
active_model() {
  if [ -n "${IWE_LLM_MODEL:-}" ]; then echo "$IWE_LLM_MODEL"
  else "$PY" "$LIFECYCLE" active; fi
}

download() {
  local model="$1"
  echo "скачиваю $model ..."
  "$PY" -m mlx_lm generate --model "$model" --max-tokens 1 --prompt "ok" >/dev/null
}

start() {
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "уже запущен (pid $(cat "$PIDFILE"))"; return 0
  fi
  local model; model=$(active_model)
  "$PY" -m mlx_lm server --model "$model" --host "$HOST" --port "$PORT" > "$LOGFILE" 2>&1 &
  echo $! > "$PIDFILE"
  for _ in $(seq 1 30); do
    if curl -s -o /dev/null -w '%{http_code}' "http://$HOST:$PORT/v1/models" 2>/dev/null | grep -q 200; then
      echo "запущен на http://$HOST:$PORT (модель $model, pid $(cat "$PIDFILE"))"; return 0
    fi
    sleep 1
  done
  kill "$(cat "$PIDFILE")" 2>/dev/null || true   # do not leave an orphaned mlx_lm and a dead PID
  rm -f "$PIDFILE"
  die "сервер не поднялся за 30с, см. $LOGFILE"
}

test_shim() {
  local out
  out=$(curl -s "http://$HOST:$PORT/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d '{"messages":[{"role":"user","content":"Reply with exactly: SHIM_OK"}],"max_tokens":10,"temperature":0.0}')
  echo "$out" | "$PY" -c "
import sys, json
raw = sys.stdin.read()
try:
    print('shim:', json.loads(raw)['choices'][0]['message']['content'].strip())
except (ValueError, KeyError, IndexError):
    print('shim: невалидный ответ сервера:', raw[:300])   # видно причину, не голый трейс
"
}

stop() {
  [ -f "$PIDFILE" ] || { echo "не запущен"; return 0; }
  if kill "$(cat "$PIDFILE")" 2>/dev/null; then echo "остановлен"; else echo "процесс уже мёртв"; fi
  rm -f "$PIDFILE"
}

status() {
  echo "активная модель: $(active_model)"
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "сервер: запущен (pid $(cat "$PIDFILE"), http://$HOST:$PORT)"
  else
    echo "сервер: остановлен"
  fi
}

restart_if_running() {
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then stop; start; fi
}

# Download a model for testing (status -> testing, if in the catalog)
pull() {
  local model="${1:?usage: pull <model-id>}"
  download "$model"
  if ! "$PY" "$LIFECYCLE" set "$model" testing; then
    echo "(не помечена testing — модели нет в каталоге; добавь: model-lifecycle.py add $model)"
  fi
  echo "готово: $model скачана"
}

# Put a model into service: download + make active (the previous active -> testing) + restart
use() {
  local model="${1:?usage: use <model-id>}"
  download "$model"
  "$PY" "$LIFECYCLE" use "$model"
  echo "активная модель → $model"
  restart_if_running
}

case "${1:-}" in
  start)   start ;;
  test)    test_shim ;;
  stop)    stop ;;
  status)  status ;;
  models)  "$PY" "$LIFECYCLE" list ;;
  pull)    pull "${2:-}" ;;
  use)     use "${2:-}" ;;
  archive) "$PY" "$LIFECYCLE" archive "${2:?usage: archive <model-id>}" ;;
  *) die "usage: $0 start|test|stop|status|models|pull <m>|use <m>|archive <m>" ;;
esac
