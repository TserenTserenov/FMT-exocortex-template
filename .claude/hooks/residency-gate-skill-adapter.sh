#!/bin/bash
# claude-hook: true
# Event: PreToolUse (matcher: Skill)
#
# Mechanizes ResidencyGate Point A (activation-time consent) for the one place
# Claude Code itself knows "a function is starting": the Skill tool call. Before
# this hook, a skill author had to remember to `source residency-gate-init.sh`
# at the top of their own script — a cognitive gate (issue #323, WP-7
# ResidencyGate-Event-Adapter): nothing enforced the call existed, so a skill
# with declared data_needs but a forgotten source line ran with no consent
# check at all. This hook reads the same manifest (SKILL.md `data_needs`) and
# runs the same check (residency-gate.py check-activation) unconditionally,
# before the skill's own code runs — the check now happens whether or not the
# skill remembered to ask for it.
#
# Scope, honestly stated: this covers Point A only, and only for skills
# invoked through Claude Code's own Skill tool. Point B (lazy, mid-execution
# data access — "about to fetch the digital twin right now") has no Claude
# Code tool-call boundary to hook: it fires from inside a skill's own running
# code, not from a tool call Claude Code can see. Point B stays a library call
# (residency-gate-lazy.sh) by design, not a gap this adapter forgot. The same
# is true for functions that never go through Claude Code at all (day-open's
# own launchd-triggered pipeline, bot handlers) — residency-gate-init.sh
# remains their integration point; there is no Claude Code hook to mechanize
# for a process Claude Code never launches.
set -euo pipefail

INPUT=$(cat)
if ! command -v jq >/dev/null 2>&1; then
  echo "BLOCKED: ResidencyGate [dependency_error] — jq is required to validate the Skill hook payload." >&2
  exit 2
fi
if ! SKILL_NAME=$(jq -r '
  if type != "object" then error("hook payload must be an object")
  elif (.tool_name? | type) != "string" then error("hook payload has no tool_name string")
  elif .tool_name != "Skill" then ""
  elif (.tool_input? | type) != "object" then error("Skill payload has no tool_input object")
  elif (.tool_input.skill? | type) != "string" or (.tool_input.skill | length) == 0
    then error("Skill payload has no non-empty skill name")
  else .tool_input.skill
  end
' <<<"$INPUT" 2>/dev/null); then
  echo "BLOCKED: ResidencyGate [runtime_error] — Skill hook payload is malformed and cannot be checked safely." >&2
  exit 2
fi
[ -z "$SKILL_NAME" ] && exit 0

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "$HOOK_DIR/../.." && pwd -P)"
MANIFEST="$PROJECT_ROOT/.claude/skills/$SKILL_NAME/SKILL.md"

# No manifest, or the skill directory doesn't exist under this project root:
# not this hook's business to validate skill names — that's the Skill tool's
# own resolution. Absence of a manifest is not a data_needs declaration to
# enforce; residency-gate.py itself already treats "no needs found" as
# allowed, so a skill with no data_needs block reaches the same place either
# way, just without a subprocess.
[ -f "$MANIFEST" ] || exit 0

RESIDENCY_GATE_PY="$PROJECT_ROOT/.claude/skills/residency-gate/residency-gate.py"
if [ ! -f "$RESIDENCY_GATE_PY" ]; then
  echo "BLOCKED: ResidencyGate [dependency_error] — gate implementation is missing: $RESIDENCY_GATE_PY" >&2
  exit 2
fi
RUNNER="$PROJECT_ROOT/.claude/lib/residency-gate-run.sh"
if [ ! -r "$RUNNER" ]; then
  echo "BLOCKED: ResidencyGate [dependency_error] — shared runner is missing: $RUNNER" >&2
  exit 2
fi

# shellcheck source=/dev/null
source "$RUNNER"
residency_gate_run "$PROJECT_ROOT" "$RESIDENCY_GATE_PY" \
  check-activation "$SKILL_NAME" "$MANIFEST"

DETAIL=$(residency_gate_human_detail)
case "$RESIDENCY_GATE_OUTCOME" in
  allowed)
    exit 0
    ;;
  policy_denied)
    echo "BLOCKED: ResidencyGate [policy_denied] — skill '$SKILL_NAME' requires data consent not yet granted." >&2
    echo "  $DETAIL" >&2
    echo "  Выдать согласие: $RESIDENCY_GATE_PYTHON3 $RESIDENCY_GATE_PY grant $SKILL_NAME <type> <flow> <name>" >&2
    ;;
  manifest_invalid)
    echo "BLOCKED: ResidencyGate [manifest_invalid] — skill '$SKILL_NAME' has an invalid data-needs declaration." >&2
    echo "  $DETAIL" >&2
    ;;
  dependency_error)
    echo "BLOCKED: ResidencyGate [dependency_error] — PyYAML-capable Python is unavailable." >&2
    echo "  $DETAIL" >&2
    ;;
  *)
    echo "BLOCKED: ResidencyGate [runtime_error] — consent could not be checked safely for skill '$SKILL_NAME'." >&2
    echo "  $DETAIL" >&2
    ;;
esac
exit 2
