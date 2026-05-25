#!/usr/bin/env bash
# routing: helper  executor=script  called-by=agent-inbox-dispatcher
# see DP.SC.159, DP.ROLE.059
# headless-runner.sh — точка входа Headless-адаптера (DP.IWE.011-adapter-headless)
#
# Устанавливает env по контракту DP.IWE.011, затем вызывает iwe-agent-dispatcher.py
# для запуска ОРЗ-протокола или произвольной задачи через `claude -p`.
#
# Использование:
#   headless-runner.sh [--protocol open|close|work] [--task TASK-ID] [--model sonnet|opus|haiku]
#                      [--workdir PATH] [--dry-run] [--help]
#
# Примеры:
#   headless-runner.sh --protocol open
#   headless-runner.sh --protocol close --dry-run
#   headless-runner.sh --task TASK-2026-05-21-analyse --model opus
#
# see DP.IWE.011, DP.IWE.011-adapter-headless

set -euo pipefail

# === Defaults ===
PROTOCOL=""
TASK_ID=""
MODEL="${IWE_DEFAULT_MODEL:-sonnet}"
WORKDIR="${IWE_DISPATCHER_WORKDIR:-/tmp/iwe-headless}"
DRY_RUN=0
STATE_DIR="${IWE_STATE_DIR:-$HOME/.iwe/state}"
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SCRIPTS_DIR/iwe-agent-dispatcher.py"

# === Parse args ===
while [[ $# -gt 0 ]]; do
  case "$1" in
    --protocol)  PROTOCOL="$2"; shift 2 ;;
    --task)      TASK_ID="$2"; shift 2 ;;
    --model)     MODEL="$2"; shift 2 ;;
    --workdir)   WORKDIR="$2"; shift 2 ;;
    --dry-run)   DRY_RUN=1; shift ;;
    --help|-h)
      awk '/^# see /{exit} /^#[^!]/ && !/^# ===/{sub(/^# ?/,""); print}' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *) echo "[headless-runner] Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# === Validate ===
if [[ -z "$PROTOCOL" && -z "$TASK_ID" ]]; then
  echo "[headless-runner] ERROR: укажи --protocol или --task" >&2
  exit 1
fi
if [[ -z "${IWE_DISPATCHER_REPO_URL:-}" ]]; then
  echo "[headless-runner] ERROR: IWE_DISPATCHER_REPO_URL не задан" >&2
  exit 1
fi

# === Set IWE_RUNTIME env (контракт DP.IWE.011 §C) ===
export IWE_RUNTIME="headless"

# === Generate AGENT_SESSION_ID ===
AGENT_SESSION_ID="$(date +%s%N | md5 | cut -c1-16 2>/dev/null || date +%s%N | md5sum | cut -c1-16)"
export AGENT_SESSION_ID
export CLAUDE_TASK_ID="${TASK_ID}"  # CC-совместимость для agent-trace-recorder.sh
export AGENT_TASK_ID="${TASK_ID}"
export AGENT_MODEL_ID="${MODEL}"
export IWE_STATE_DIR="${STATE_DIR}"

# === Write session env file (совместимость с хуками) ===
mkdir -p "$STATE_DIR"
cat > "$STATE_DIR/current-session.env" <<EOF
IWE_RUNTIME=headless
AGENT_SESSION_ID=${AGENT_SESSION_ID}
AGENT_TASK_ID=${TASK_ID}
AGENT_MODEL_ID=${MODEL}
IWE_STATE_DIR=${STATE_DIR}
SESSION_START_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

echo "[headless-runner] IWE_RUNTIME=headless AGENT_SESSION_ID=${AGENT_SESSION_ID} MODEL=${MODEL}"

# === Если указан --protocol, создать task из шаблона ===
if [[ -n "$PROTOCOL" ]]; then
  _create_protocol_task() {
    local protocol="$1"
    local task_id="TASK-$(date +%Y-%m-%d)-protocol-${protocol}-${AGENT_SESSION_ID}"
    local repo_name
    repo_name="$(basename "${IWE_DISPATCHER_REPO_URL%.git}")"
    local tasks_dir="${WORKDIR}/${repo_name}/inbox/agent/tasks"

    # Если dispatcher ещё не клонировал репо — клонировать
    if [[ ! -d "${WORKDIR}/${repo_name}" ]]; then
      echo "[headless-runner] Клонирую репо для создания task..." >&2
      git clone -b "${IWE_DISPATCHER_REPO_BRANCH:-main}" \
        "$IWE_DISPATCHER_REPO_URL" "${WORKDIR}/${repo_name}" >&2
    fi
    mkdir -p "$tasks_dir"

    local template_name
    case "$protocol" in
      open)  template_name="protocol-open" ;;
      close) template_name="protocol-close" ;;
      work)  template_name="protocol-work" ;;
      *)     echo "[headless-runner] Unknown protocol: $protocol" >&2; exit 1 ;;
    esac

    local task_file="${tasks_dir}/${task_id}.md"
    local due_ts today
    due_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    today="$(date +%Y-%m-%d)"

    cat > "$task_file" <<TASKEOF
---
id: ${task_id}
template: ${template_name}
status: pending
due: ${due_ts}
model: ${MODEL}
session_id: ${AGENT_SESSION_ID}
result_location:
  repo: ${IWE_DISPATCHER_REPO_URL}
  branch: ${IWE_DISPATCHER_REPO_BRANCH:-main}
  path: inbox/agent/results/RESULT-${task_id#TASK-}.md
acceptance:
  - Протокол ${protocol} выполнен без ошибок
  - git status чист в целевых репо
params:
  date: ${today}
  context_note: "headless session ${AGENT_SESSION_ID}"
---

Автоматическая задача: выполнить ОРЗ-протокол «${protocol}» через headless-адаптер.
Session: ${AGENT_SESSION_ID}
TASKEOF

    echo "[headless-runner] Создана task: ${task_id}" >&2
    echo "$task_id"
  }

  TASK_ID="$(_create_protocol_task "$PROTOCOL")"
  export CLAUDE_TASK_ID="$TASK_ID"
  export AGENT_TASK_ID="$TASK_ID"
fi

# === Запуск dispatcher ===
DISPATCHER_ARGS=(
  --workdir "$WORKDIR"
  --task "$TASK_ID"
)
[[ $DRY_RUN -eq 1 ]] && DISPATCHER_ARGS+=(--dry-run)

echo "[headless-runner] Запускаю dispatcher: python3 $DISPATCHER ${DISPATCHER_ARGS[*]}"
python3 "$DISPATCHER" "${DISPATCHER_ARGS[@]}"
EXIT_CODE=$?

# === Log завершения ===
echo "[headless-runner] Завершено. exit=$EXIT_CODE session=$AGENT_SESSION_ID"

# Обновить session env с временем завершения
echo "SESSION_END_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$STATE_DIR/current-session.env"
echo "SESSION_EXIT_CODE=${EXIT_CODE}" >> "$STATE_DIR/current-session.env"

exit $EXIT_CODE
