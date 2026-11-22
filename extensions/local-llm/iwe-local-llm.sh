#!/usr/bin/env bash
# see ADR-001-local-llm-stack.md (WP404)
# Wrapper for the local LLM-stack (MLX). JOB: privacy + fallback.
# The server binds only to localhost (B7.3).
# Active model and lifecycle — in the catalog via model-lifecycle.py.
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
[ -x "$PY" ] || die "venv not found ($PY). Run the installer first: install-local-llm.sh"

# Active model: env env overrides the catalog
active_model() {
  if [ -n "${IWE_LLM_MODEL:-}" ]; then echo "$IWE_LLM_MODEL"
  else "$PY" "$LIFECYCLE" active; fi
}

download() {
  local model="$1"
  echo "downloading $model ..."
  "$PY" -m mlx_lm generate --model "$model" --max-tokens 1 --prompt "ok" >/dev/null
}

start() {
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "already running (pid $(cat "$PIDFILE"))"; return 0
  fi
  local model; model=$(active_model)
  "$PY" -m mlx_lm server --model "$model" --host "$HOST" --port "$PORT" > "$LOGFILE" 2>&1 &
  echo $! > "$PIDFILE"
  for _ in $(seq 1 30); do
    if curl -s -o /dev/null -w '%{http_code}' "http://$HOST:$PORT/v1/models" 2>/dev/null | grep -q 200; then
      echo "running on http://$HOST:$PORT (model $model, pid $(cat "$PIDFILE"))"; return 0
    fi
    sleep 1
  done
  kill "$(cat "$PIDFILE")" 2>/dev/null || true   # do not leave an orphaned mlx_lm mlx_lm and a stale PID
  rm -f "$PIDFILE"
  die "server did not start within 30s, see 30s, see. $LOGFILE"
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
    print('shim: invalid server response:', raw[:300])   # reason is visible, not a bare traceback, not a bare traceback
"
}

stop() {
  [ -f "$PIDFILE" ] || { echo "not running"; return 0; }
  if kill "$(cat "$PIDFILE")" 2>/dev/null; then echo "stopped"; else echo "process is already dead"; fi
  rm -f "$PIDFILE"
}

status() {
  echo "active model: $(active_model)"
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "server: running (pid $(cat "$PIDFILE"), http://$HOST:$PORT)"
  else
    echo "server: stopped"
  fi
}

restart_if_running() {
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then stop; start; fi
}

# Download model for testing (status -> testing, if present in catalog)
pull() {
  local model="${1:?usage: pull <model-id>}"
  download "$model"
  if ! "$PY" "$LIFECYCLE" set "$model" testing; then
    echo "(not marked testing testing — model is not in the catalog; add it with: model-lifecycle.py add $model)"
  fi
  echo "done: $model downloaded"
}

# Put model into production: download + make active (previous active -> testing) + restart
use() {
  local model="${1:?usage: use <model-id>}"
  download "$model"
  "$PY" "$LIFECYCLE" use "$model"
  echo "active model → $model"
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
