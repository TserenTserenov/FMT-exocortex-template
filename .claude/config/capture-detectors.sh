#!/bin/bash
# capture-detectors.sh
# Реестр детекторов для capture-bus.
# Sourced by capture-bus.sh на каждом вызове (hot-reload).
#
# Формат записи (pipe-separated):
#   name|path|event_type|cost_class|enabled|triggers
#
# Поля:
#   name        — уникальный идентификатор детектора (для логов)
#   path        — путь относительно $IWE_ROOT
#   event_type  — что эмитит детектор
#   cost_class  — free | llm (llm выполняется только если CAPTURE_COST_LEVEL=llm)
#   enabled     — true | false
#   triggers    — CSV: PostToolUse,Stop,PreToolUse,UserPromptSubmit

CAPTURE_BUS_VERSION=1
CAPTURE_COST_LEVEL="${CAPTURE_COST_LEVEL:-free}"

DETECTORS=(
  "incident|.claude/detectors/detector_incident.sh|agent_incident|free|true|PostToolUse,Stop"
  "decision|.claude/detectors/detector_decision.sh|decision_user|free|true|Stop"
  "pattern_awareness|.claude/detectors/detector_pattern_awareness.sh|agent_incident|free|true|PostToolUse"
  # permission_request (P5 detector) — fail by architecture обкатки 10-25 апр:
  # 30.7% fire rate (цель <10%), p50=1023ms (цель <150ms). Корневая причина —
  # jq-парсинг полного транскрипта на каждый ToolUse. Замена — harness-гейт через
  # `.claude/hooks/p5-stop-reminder.sh` (S-29 в STAGING.md, обкатка до Week Close W18).
  # "permission_request|.claude/detectors/detector_permission_request.sh|agent_incident|free|true|Stop"
  # "gate_fired|.claude/detectors/detector_gate.sh|gate_fired|free|false|PreToolUse"
  # "archgate|.claude/detectors/detector_archgate.sh|archgate_result|free|false|Stop"
  # "verification|.claude/detectors/detector_verify.sh|verification_result|free|false|Stop"
  # "drift|.claude/detectors/detector_drift.sh|drift_detected|free|false|Stop"
)
