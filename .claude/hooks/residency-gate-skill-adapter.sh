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
SKILL_NAME=$(jq -r '.tool_input.skill // empty' <<<"$INPUT" 2>/dev/null || true)
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
[ -f "$RESIDENCY_GATE_PY" ] || exit 0

# Resolved once, before residency-gate.py runs at all (issue #521A, the exact
# hook from the live traceback in the issue report): a missing PyYAML then
# reads as a dependency error here, not a fabricated "requires data consent"
# from a crash three layers down.
PY3=$("$PROJECT_ROOT/scripts/lib/find-python3.sh" 2>&1) || {
  echo "BLOCKED: ResidencyGate dependency error — skill '$SKILL_NAME' could not be checked." >&2
  echo "  $PY3" >&2
  exit 2
}

RESULT=$("$PY3" "$RESIDENCY_GATE_PY" check-activation "$SKILL_NAME" "$MANIFEST" 2>&1) && RC=0 || RC=$?

if [ "$RC" -eq 0 ]; then
  exit 0
fi

# check-activation exits non-zero for four distinct reasons now (issue #521A
# contract: 1 policy_denial, 2 invalid_manifest, 3 dependency_error, 4
# runtime_error) — this hook does not second-guess any of them (any non-zero
# exit still blocks the skill, the library's own fail-closed choice), but it
# no longer claims "requires data consent" for a reason that isn't consent.
# `jq -e . <<<"$RESULT"` is a distinct check from the field extraction below:
# it tells apart valid JSON with no error_class (a genuine policy_denial —
# residency-gate.py's own contract) from $RESULT not being JSON at all (a
# crash outside that contract entirely, e.g. a SyntaxError in a corrupted
# lib/*.py — caught here with `2>&1`, unlike the other two hooks). Without
# this check the second case fell into the same branch as the first and
# printed "requires data consent" — and the grant hint below — for a reason
# that has nothing to do with consent (found in second-round cold review).
if jq -e . <<<"$RESULT" >/dev/null 2>&1; then
  ERROR_CLASS=$(jq -r '.error_class // empty' <<<"$RESULT" 2>/dev/null || echo "")
else
  ERROR_CLASS="unparseable"
fi
case "$ERROR_CLASS" in
  dependency_error) HEADER="ResidencyGate dependency error" ;;
  invalid_manifest) HEADER="ResidencyGate declaration error" ;;
  runtime_error) HEADER="ResidencyGate runtime error" ;;
  unparseable) HEADER="ResidencyGate crashed — skill '$SKILL_NAME' could not be checked" ;;
  *) HEADER="ResidencyGate — skill '$SKILL_NAME' requires data consent not yet granted." ;;
esac
# `|| DETAIL=""` guards the whole pipeline, not just `jq`: this script runs
# under `pipefail` (line 26), and $RESULT can be non-JSON (a stray stderr
# line merged by the `2>&1` above, from something outside residency-gate.py's
# own JSON contract) — jq then fails, pipefail propagates that through `grep`
# and `head`, and an unguarded assignment would abort the script under `set
# -e` before the BLOCKED message below ever prints (found in cold review).
DETAIL=$(jq -r '(.blocking // [] | join("; ")), .error // empty' <<<"$RESULT" 2>/dev/null | grep -v '^$' | head -1) || DETAIL=""
[ -n "$DETAIL" ] || DETAIL="$RESULT"
echo "BLOCKED: $HEADER" >&2
echo "  $DETAIL" >&2
# The grant hint only makes sense for an actual consent decision — a broken
# manifest or a runtime crash isn't fixed by granting consent to it.
[ -z "$ERROR_CLASS" ] && echo "  Выдать согласие: python3 $RESIDENCY_GATE_PY grant $SKILL_NAME <type> <flow> <name>" >&2
exit 2
