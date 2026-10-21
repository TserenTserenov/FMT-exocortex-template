#!/bin/bash
# Protocol Artifact Validation Hook
# Event: PreToolUse (matcher: Bash)
# Intercepts `git commit` in protocol-managed repos to validate artifacts.
# Returns block decision if artifact fails validation.
# Read-only: only returns JSON, does not modify files.
#
# Validated artifacts:
#   - DayPlan: 11 required sections + ## headings structure + non-empty key sections + carry-over
#   - DayClose: summary, carry-over (day-close protocol) [future]
#
# Parameterized: sections list is a variable, not hardcoded per format.
# Phase3 WP-229: structure checks added (## headings, non-empty sections, multiplier, carry-over)

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
TOOL_INPUT=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Only trigger on Bash tool with git commit command
if [ "$TOOL" != "Bash" ]; then
  echo '{}'
  exit 0
fi

# Check if command contains git commit (but not git commit --amend or other non-standard)
if ! echo "$TOOL_INPUT" | grep -qE 'git (add.*&&.*git )?commit'; then
  echo '{}'
  exit 0
fi

# Governance-repo: from env $IWE_GOVERNANCE_REPO (default ${IWE_GOVERNANCE_REPO:-DS-strategy}).
# Workspace: $IWE_WORKSPACE or $IWE_ROOT (aliases), default ~/IWE.
GOV_REPO="${IWE_GOVERNANCE_REPO:-${IWE_GOVERNANCE_REPO:-DS-strategy}}"
WORKSPACE="${IWE_WORKSPACE:-${IWE_ROOT:-$HOME/IWE}}"
GOV_PATH="$WORKSPACE/$GOV_REPO"

# find-python3.sh resolver (issue #764): $WORKSPACE/scripts/lib/find-python3.sh
# never existed on any install. The manifest delivers find-python3.sh as this
# hook's own sibling (.claude/lib/find-python3.sh), so resolve relative to
# this hook's own location first; $IWE_SCRIPTS is an explicit override.
resolve_find_python3() {
    local candidate
    if [ -n "${IWE_SCRIPTS:-}" ] && [ -f "$IWE_SCRIPTS/lib/find-python3.sh" ]; then
        printf '%s\n' "$IWE_SCRIPTS/lib/find-python3.sh"
        return 0
    fi
    candidate="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd || true)/lib/find-python3.sh"
    if [ -f "$candidate" ]; then
        printf '%s\n' "$candidate"
        return 0
    fi
    return 1
}

# R4.5 fix (WP-273): trigger ONLY on staged files, NOT on the command text.
# The old logic grepped TOOL_INPUT for «DayPlan|day-close» — false positive
# on any commit of the file `day-close/SKILL.md` or messages containing «day-close».
# Principle: «hook trigger = artifact (staged file), not TOOL_INPUT text» (memory/hooks-design.md).
STAGED=$(cd "$GOV_PATH" 2>/dev/null && git diff --cached --name-only 2>/dev/null || echo "")

# bug-2026-07-24 fix: the index is read BEFORE the command runs, therefore the combination
# `git add X && git commit` passed without validation — at the moment of the check the index
# is still empty, and the hook exited at the line below. We augment the actual index with paths,
# that the command is about to stage itself.
#
# Principle WP-273 is not violated: not the entire command text is parsed, but ONLY
# segments, starting with `git add`. A commit message mentioning DayPlan
# false positive does not produce, because the segment `git commit -m ...` is not parsed.
extract_git_add_paths() {
  local segments seg args toks tok out=""
  # Split the command into segments by delimiters -- validate only — we validate only `git add`.
  # awk, not `sed 's/&&/\n/g'`: BSD sed (macOS) would insert the literal character n «n».
  segments=$(printf '%s\n' "$TOOL_INPUT" | awk '{gsub(/&&|\|\||;|\|/, "\n"); print}')
  while IFS= read -r seg; do
    echo "$seg" | grep -qE '(^|[[:space:]])git[[:space:]]+add([[:space:]]|$)' || continue
    args=${seg#*git}
    args=${args#*add}
    # xargs xargs parses quotes in shell style-shell style — paths containing spaces are not split.
    toks=$(printf '%s' "$args" | xargs -n1 2>/dev/null) || toks=""
    while IFS= read -r tok; do
      [ -z "$tok" ] && continue
      case "$tok" in
        # Bulk staging (forbidden by CLAUDE.md CLAUDE.md, but we do not leave the gap open):
        # we take modified artifacts from the working tree.
        .|-A|--all|-u|--update)
          # -uall: -uall: without it an untracked directory collapses to `current/`
          # and a new DayPlan is not visible.
          out="$out$(cd "$GOV_PATH" 2>/dev/null && git status --porcelain -uall 2>/dev/null \
            | sed -e 's/^...//' -e 's/^.* -> //' -e 's/^"//' -e 's/"$//')"$'\n'
          continue
          ;;
        -*) continue ;;
      esac
      tok=${tok#./}
      # Absolute or nested path -- convert to repo-relative -> repo-relative.
      case "$tok" in
        */current/*) tok="current/${tok#*/current/}" ;;
      esac
      out="$out$tok"$'\n'
    done <<< "$toks"
  done <<< "$segments"
  printf '%s' "$out"
}

STAGED=$(printf '%s\n%s\n' "$STAGED" "$(extract_git_add_paths)" | sed '/^$/d' | sort -u)

if ! echo "$STAGED" | grep -qE '^current/DayPlan.*\.md$|^current/WeekPlan.*\.md$'; then
  echo '{}'
  exit 0
fi

# --- DayPlan Validation (runs only if DayPlan is staged in this commit) ---
# issue #248 (the same root cause, that was fixed for WeekPlan/WeekReport below): `ls | head -1`
# resolved the alphabetically first (= the oldest by ISO-ISO date) DayPlan on disk, and not the one,
# that is actually being committed — a non-migrated old DayPlan in current/ falsely blocked
# the commit of a correct staged DayPlan DayPlan (or the commit of WeekPlan, since DayPlan at all
# was not involved). Resolve from $STAGED, as WEEKPLAN/WEEKREPORT.
DAYPLAN_STAGED=$(echo "$STAGED" | grep -E '^current/DayPlan.*\.md$' | sort | tail -1)
DAYPLAN=""
[ -n "$DAYPLAN_STAGED" ] && DAYPLAN="$GOV_PATH/$DAYPLAN_STAGED"
MISSING=()
ERRORS=()

if [ -n "$DAYPLAN" ] && [ -f "$DAYPLAN" ]; then

# Required sections (parameterized — update this list when format changes).
# Scout section is optional: checked separately below (see. block "Scout").
SECTIONS=(
  "Plan for Today|Plan for Today|Today.s Plan"
  "Calendar|Calendar"
  "IWE Overnight|IWE Overnight"
  "Notes Review|Notes Review"
  "Yesterday|Yesterday"
)

for section in "${SECTIONS[@]}"; do
  if ! grep -qE "$section" "$DAYPLAN"; then
    MISSING+=("$section")
  fi
done

# Check mandatory format elements

# --- Phase3 Check 1: section headings — ## (Obsidian-compatible) or <summary> (collapsible sections, formatting.md) ---
# issue #221: formatting.md requires <details><summary> for DayPlan/WeekPlan (newer solution,
# replacing the old Obsidian-only prohibition on HTML-tags) — both variants are treated as a section heading.
HEADINGS_COUNT=$(grep -cE '^## |^[[:space:]]*<summary>' "$DAYPLAN" 2>/dev/null || true); HEADINGS_COUNT=${HEADINGS_COUNT:-0}
if [ "$HEADINGS_COUNT" -lt 3 ]; then
  ERRORS+=("Sections (## or <summary>) < 3 found: $HEADINGS_COUNT. DayPlan must have a structure of section headings")
fi

# --- Phase3 Check 2: non-empty required sections ---
# Calendar: must contain at least one line with | (table) or "no events".
# Flag-range instead of awk-range '/start/,/^## /': section heading (## Calendar ...)
# matches both the start, and the end-end delimiter /^## /, because of-which the range collapses to
# one line and the section body is lost (false commit block — issue #207).
# EN-EN alternative heading (Calendar) — for bilingual DayPlan (issue #210).
CALENDAR_CONTENT=$(awk 'f && /^## /{exit} /Calendar|Calendar/{f=1} f' "$DAYPLAN" 2>/dev/null | wc -l || echo 0)
if [ "$CALENDAR_CONTENT" -lt 3 ]; then
  ERRORS+=("Section 'Calendar' is empty or too short (${CALENDAR_CONTENT} lines)")
fi

# Scout: is checked only if the section is present at all in DayPlan (optional component,
# depends on DS-agent-workspace). If the section is absent — Scout is not configured, the validator does not block.
if grep -q "Findings Scout" "$DAYPLAN" 2>/dev/null; then
  # Flag-range instead of awk-range (see. Calendar above, issue #207): heading
  # '## Findings Scout' matches end-end delimiter /^## /, range collapses.
  if ! awk 'f && /^## /{exit} /Findings Scout/{f=1} f' "$DAYPLAN" 2>/dev/null | grep -iqE 'find|capture|status|none|find|disabled|not configured'; then
    ERRORS+=("Section 'Findings Scout' is empty (allowed markers are 'no findings', 'disabled', 'not configured')")
  fi
fi

# --- Phase3 Check 3: multiplier format ---
# issue #328: without configured time tracking there is nothing to calculate the multiplier from
# anything — coercing to a number produces a fictitious '~1.0x', which a month later reads
# as a measurement. An explicit textual disclaimer ("multiplier not calculated"/"not
# configured") — an equally honest field state, as the number itself.
# issue #870: fractional part — period OR comma (Russian-locale Day Open writes «~1,2x»).
# The number is only checked for format (grep), it is not used in calculations.
if ! grep -qE "~[0-9]+[.,]?[0-9]*x" "$DAYPLAN" && ! grep -qiE "multiplier.*(not counting|not set)" "$DAYPLAN"; then
  ERRORS+=("Multiplier not found — required format '~N.Nx' in the budget line, or an explicit disclaimer 'multiplier not counting'")
fi

# --- Phase3 Check 4 (legacy): mandatory check and budget ---
# issue #328: "mandatory" was hardcoded as the text of one specific setup (WP-7 +
# author content WP). Source of truth — mandatory_daily_wps in
# day-rhythm-config.yaml; commented out/empty → the user has explicitly configured
# "no mandatory WPs", the section in DayPlan is not required.
MANDATORY_WPS_CONFIGURED=false
DAY_RHYTHM_CONFIG="$WORKSPACE/memory/day-rhythm-config.yaml"
if [ -f "$DAY_RHYTHM_CONFIG" ]; then
  # WP-529 (continuation, 19.08): resolved here, inside the existing
  # [ -f "$DAY_RHYTHM_CONFIG" ] guard — same lazy-placement rationale as the
  # other sites in this migration (peer-session 2026-08-19-29, codex turn 1).
  # No bare-python3 fallback: the resolver's own first candidate is already
  # bare `python3` from PATH.
  _RESOLVER=$(resolve_find_python3) || _RESOLVER=""
  _RESOLVED_PYTHON3=""
  [ -n "$_RESOLVER" ] && _RESOLVED_PYTHON3=$("$_RESOLVER" 2>/dev/null) || true
  if [ -z "$_RESOLVED_PYTHON3" ]; then
    # issue #765: resolver python3 is no less reliable, than the YAML — the same
    # fail-closed boundary, that applies below to a broken/unreadable config.
    ERRORS+=("day-rhythm-config.yaml exists, but python3 cannot be resolved (find-python3.sh not found or did not return an interpreter) — mandatory-check is not possible, fail-closed")
  else
    # Codes: 0 = mandatory is configured; 1 = valid config without mandatory;
    # 2+ = broken/unreadable YAML — fail-closed (the same contract, as sibling
    # validate-staged-artifacts.sh).
    _MANDATORY_RC=0
    "$_RESOLVED_PYTHON3" -c "
import sys
try:
    import yaml
    d = yaml.safe_load(open(sys.argv[1]))
except Exception:
    sys.exit(2)
if not isinstance(d, dict):
    sys.exit(2)
sys.exit(0 if d.get('mandatory_daily_wps') else 1)
" "$DAY_RHYTHM_CONFIG" 2>/dev/null || _MANDATORY_RC=$?
    case "$_MANDATORY_RC" in
      0) MANDATORY_WPS_CONFIGURED=true ;;
      1) : ;; # valid config without mandatory — check is not required
      *) ERRORS+=("day-rhythm-config.yaml exists, but cannot be read (no PyYAML / broken or empty YAML / root is not a map / interpreter exited with error rc=$_MANDATORY_RC) — mandatory-check is not possible, fail-closed") ;;
    esac
  fi
fi
if [ "$MANDATORY_WPS_CONFIGURED" = "true" ] && ! grep -qi "mandatory" "$DAYPLAN"; then
  ERRORS+=("Mandatory check not found (mandatory_daily_wps is configured in day-rhythm-config.yaml)")
fi

# issue #328: Russian 'ch' — standard format formatting.md, Latin 'h' — old
# format, retained for backward compatibility with already existing artifacts.
if ! grep -qE "~[0-9]+[.,]?[0-9]* ?[hch] WP" "$DAYPLAN"; then
  ERRORS+=("Day budget is not in the format '~Xh WP / ~Yh phys' (Latin 'h' is also accepted)")
fi

# --- Phase3 Check 5: Carry-over quote (if a previous DayPlan exists DayPlan) ---
# issue #870: the predecessor of the STAGED plan in the sorted list, not
# «the second-to-last on disk»: when committing a plan that is not the most recent it would be compared
# with its own future. the oldest plan has no predecessor — there is nothing to compare it against.
# The staged plan itself is added to the list: name is outside the canon («DayPlan_…», not «DayPlan …»)
# also gets a predecessor, as it did before this fix.
PREV_DAYPLAN=$({ ls "$GOV_PATH"/current/DayPlan\ *.md 2>/dev/null; printf '%s\n' "$DAYPLAN"; } | sort -u \
  | CUR="$DAYPLAN" awk '$0 == ENVIRON["CUR"] { print prev; exit } { prev = $0 }')
if [ -n "$PREV_DAYPLAN" ] && [ "$PREV_DAYPLAN" != "$DAYPLAN" ]; then
  # Previous DayPlan exists — the current one must contain Carry-over
  if ! grep -qiE 'carry.over|carry_over' "$DAYPLAN"; then
    ERRORS+=("Carry-over quote from the previous Day Close is missing (previous DayPlan: $(basename "$PREV_DAYPLAN"))")
  fi
fi

fi  # endif [ -n "$DAYPLAN" ]

# --- WeekPlan Validation (Phase6.1 WP-265) ---
# issue #248: previously the LAST WeekPlan on disk was validated WeekPlan on disk by mtime/name,
# even when only a DayPlan was changed in this commit DayPlan — old, not migrated
# WeekPlan was blocking commits, that it had no relation to. Now we validate
# ONLY if the WeekPlan is staged in this commit.
WEEKPLAN_STAGED=$(echo "$STAGED" | grep -E '^current/WeekPlan.*\.md$' | sort | tail -1)
WEEKPLAN=""
[ -n "$WEEKPLAN_STAGED" ] && WEEKPLAN="$GOV_PATH/$WEEKPLAN_STAGED"
if [ -n "$WEEKPLAN" ] && [ -f "$WEEKPLAN" ]; then
  WP_LINES=$(wc -l < "$WEEKPLAN" | tr -d ' ')
  WP_ERRORS=()
  WP_MISSING_LIST=()

  # Detector (a): >80 lines without a sufficient number of headings — ## or <summary> (issue #221, see. Check 1 above)
  WP_HEADINGS_COUNT=$(grep -cE '^## |^[[:space:]]*<summary>' "$WEEKPLAN" 2>/dev/null || true); WP_HEADINGS_COUNT=${WP_HEADINGS_COUNT:-0}
  if [ "$WP_LINES" -gt 80 ] && [ "$WP_HEADINGS_COUNT" -lt 3 ]; then
    WP_ERRORS+=("WeekPlan >80 lines ($WP_LINES) but sections (## or <summary>) < 3 ($WP_HEADINGS_COUNT). Use ## headings or <details><summary> for structuring.")
  fi

  # Detector (c) — required sections WeekPlan — removed (issue #318 hotfix,
  # 2026-07-28): the heading list twice in a row lagged behind the actual structure
  # and when checked against the full pilot history it blocked 23 of 24 archive files
  # (sections such as "## Carry-over" appear only at Week Close, not during
  # the week). The structure of WeekPlan WeekPlan changes too often for a strict gate by gate by
  # heading names — detector (a) above remains, it does not depend on them.

  # Detector (d): WeekReport validation (OPT-5 WP-297)
  # issue #248: the same problem — previously the LAST WeekReport on disk was taken WeekReport on disk,
  # which may belong to an already closed previous week. Validate only
  # if WeekReport is itself staged in this commit.
  WEEKREPORT_STAGED=$(echo "$STAGED" | grep -E '^current/WeekReport.*\.md$' | sort | tail -1)
  if [ -n "$WEEKREPORT_STAGED" ]; then
    WEEKREPORT="$GOV_PATH/$WEEKREPORT_STAGED"
    if [ -f "$WEEKREPORT" ] && ! grep -q "Results" "$WEEKREPORT"; then
      WP_MISSING_LIST+=("Results (in WeekReport)")
    fi
  fi

  if [ ${#WP_MISSING_LIST[@]} -gt 0 ] || [ ${#WP_ERRORS[@]} -gt 0 ]; then
    WP_MISSING_STR=$(IFS=', '; echo "${WP_MISSING_LIST[*]:-}")
    WP_ERRORS_STR=$(IFS=', '; echo "${WP_ERRORS[*]:-}")
    WP_MSG="⛔ WEEKPLAN VALIDATION FAILED."
    [ ${#WP_MISSING_LIST[@]} -gt 0 ] && WP_MSG="$WP_MSG Missing sections (${#WP_MISSING_LIST[@]}): $WP_MISSING_STR."
    [ ${#WP_ERRORS[@]} -gt 0 ] && WP_MSG="$WP_MSG Structure errors: $WP_ERRORS_STR."
    WP_MSG="$WP_MSG Fix WeekPlan before committing."
    jq -n --arg reason "$WP_MSG" '{"decision": "block", "reason": $reason}'
    exit 0
  fi
fi

# Report results
if [ ${#MISSING[@]} -gt 0 ] || [ ${#ERRORS[@]} -gt 0 ]; then
  MISSING_STR=$(printf ', %s' "${MISSING[@]}")
  MISSING_STR=${MISSING_STR:2}
  ERRORS_STR=$(printf ', %s' "${ERRORS[@]}")
  ERRORS_STR=${ERRORS_STR:2}

  MSG="⛔ DAYPLAN VALIDATION FAILED."
  [ ${#MISSING[@]} -gt 0 ] && MSG="$MSG Missing sections (${#MISSING[@]}): $MISSING_STR."
  [ ${#ERRORS[@]} -gt 0 ] && MSG="$MSG Format errors/structure: $ERRORS_STR."
  MSG="$MSG Fix DayPlan before commit."

  jq -n --arg reason "$MSG" '{"decision": "block", "reason": $reason}'
else
  jq -n '{"hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": "✅ DayPlan passed validation: sections, ## headings, non-empty blocks, multiplier, carry-over."}}'
fi

exit 0
