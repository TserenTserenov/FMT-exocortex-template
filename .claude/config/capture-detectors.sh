#!/bin/bash
# capture-detectors.sh
# Detector registry for capture-bus.
# Sourced by capture-bus.sh on every call (hot-reload).
#
# Record format (pipe-separated):
#   name|path|event_type|cost_class|enabled|triggers
#
# Fields:
#   name        — unique detector identifier (for logs)
#   path        — path relative to $IWE_ROOT
#   event_type  — what the detector emits
#   cost_class  — free | llm (llm executed only if CAPTURE_COST_LEVEL=llm)
#   enabled     — true | false
#   triggers    — CSV: PostToolUse,Stop,PreToolUse,UserPromptSubmit

CAPTURE_BUS_VERSION=1
CAPTURE_COST_LEVEL="${CAPTURE_COST_LEVEL:-free}"
# issue #339: timeout per detector call (gtimeout/timeout) — 0 < N seconds.
CAPTURE_DETECTOR_TIMEOUT_SECONDS="${CAPTURE_DETECTOR_TIMEOUT_SECONDS:-30}"

DETECTORS=(
  "incident|.claude/detectors/detector_incident.sh|agent_incident|free|true|PostToolUse,Stop"
  "decision|.claude/detectors/detector_decision.sh|decision_user|free|true|Stop"
  "pattern_awareness|.claude/detectors/detector_pattern_awareness.sh|agent_incident|free|true|PostToolUse"
  # permission_request (P5 detector) — fail by architecture trial run 10-25 Apr:
  # 30.7% fire rate (target <10%), p50=1023ms (target <150ms). Root cause —
  # jq-jq-parsing of the full transcript on every ToolUse. Replacement — harness-gate via
  # `.claude/hooks/p5-stop-reminder.sh` (S-29 in STAGING.md, trial run until Week Close W18).
  # "permission_request|.claude/detectors/detector_permission_request.sh|agent_incident|free|true|Stop"
  # "gate_fired|.claude/detectors/detector_gate.sh|gate_fired|free|false|PreToolUse"
  # "archgate|.claude/detectors/detector_archgate.sh|archgate_result|free|false|Stop"
  # "verification|.claude/detectors/detector_verify.sh|verification_result|free|false|Stop"
  # "drift|.claude/detectors/detector_drift.sh|drift_detected|free|false|Stop"
)
