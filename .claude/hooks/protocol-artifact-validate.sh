#!/bin/bash
# Protocol Artifact Validation Hook
# Event: PreToolUse (matcher: Bash)
# Intercepts `git commit` in protocol-managed repos to validate artifacts.
# Returns block decision if artifact fails validation.
# Read-only: only returns JSON, does not modify files.
#
# Validated artifacts:
#   - DayPlan: 11 required sections + ## headings structure + non-empty key sections + carry-over
#   - DayClose: results, carry-over (day-close protocol) [future]
#
# Parameterized: sections list is a variable, not hardcoded per format.
# Phase 3 WP-229: added structure checks (## headings, non-empty sections, multiplier, carry-over)

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

# Governance repo: from env $IWE_GOVERNANCE_REPO (default ${IWE_GOVERNANCE_REPO:-DS-strategy}).
# Workspace: $IWE_WORKSPACE or $IWE_ROOT (synonyms), default ~/IWE.
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
# The old logic grepped TOOL_INPUT for "DayPlan|day-close" — a false positive
# on any commit of the file `day-close/SKILL.md` or a message with "day-close".
# Principle: "hook trigger = artifact (staged file), not TOOL_INPUT text" (memory/hooks-design.md).
STAGED=$(cd "$GOV_PATH" 2>/dev/null && git diff --cached --name-only 2>/dev/null || echo "")

# bug-2026-07-24 fix: the index is read BEFORE the command runs, so the chain
# `git add X && git commit` passed without validation — at the time of the check the index
# is still empty, and the hook exited at the line below. We supplement the actual index with the paths
# that the command is going to stage itself.
#
# The WP-273 principle is not violated: not the whole command text is parsed, but ONLY
# segments starting with `git add`. A commit message mentioning DayPlan
# gives no false positive, because the `git commit -m ...` segment is not parsed.
extract_git_add_paths() {
  local segments seg args toks tok out=""
  # Split the command into segments by separators — validate only `git add`.
  # awk, not `sed 's/&&/\n/g'`: BSD sed (macOS) would insert a literal "n".
  segments=$(printf '%s\n' "$TOOL_INPUT" | awk '{gsub(/&&|\|\||;|\|/, "\n"); print}')
  while IFS= read -r seg; do
    echo "$seg" | grep -qE '(^|[[:space:]])git[[:space:]]+add([[:space:]]|$)' || continue
    args=${seg#*git}
    args=${args#*add}
    # xargs parses quotes shell-style — paths with spaces are not split.
    toks=$(printf '%s' "$args" | xargs -n1 2>/dev/null) || toks=""
    while IFS= read -r tok; do
      [ -z "$tok" ] && continue
      case "$tok" in
        # Mass staging (forbidden by CLAUDE.md, but we do not leave the hole):
        # take the changed artifacts from the working tree.
        .|-A|--all|-u|--update)
          # -uall: without it an untracked directory collapses into `current/`
          # and the new DayPlan is not visible.
          out="$out$(cd "$GOV_PATH" 2>/dev/null && git status --porcelain -uall 2>/dev/null \
            | sed -e 's/^...//' -e 's/^.* -> //' -e 's/^"//' -e 's/"$//')"$'\n'
          continue
          ;;
        -*) continue ;;
      esac
      tok=${tok#./}
      # Absolute or nested path -> repo-relative.
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

# --- DayPlan Validation (runs only if a DayPlan is staged in this commit) ---
# issue #248 (same root as what was fixed for WeekPlan/WeekReport below): `ls | head -1`
# resolved the alphabetically first (= oldest by ISO date) DayPlan on disk, not the one
# actually being committed — a non-migrated old DayPlan in current/ falsely blocked
# the commit of a correct staged DayPlan (or a WeekPlan commit, since the DayPlan was not
# involved at all). We resolve from $STAGED, like WEEKPLAN/WEEKREPORT.
DAYPLAN_STAGED=$(echo "$STAGED" | grep -E '^current/DayPlan.*\.md$' | sort | tail -1)
DAYPLAN=""
[ -n "$DAYPLAN_STAGED" ] && DAYPLAN="$GOV_PATH/$DAYPLAN_STAGED"
MISSING=()
ERRORS=()

if [ -n "$DAYPLAN" ] && [ -f "$DAYPLAN" ]; then

# Required sections (parameterized — update this list when format changes).
# The Scout section is optional: checked separately below (see the "Scout" block).
SECTIONS=(
  "План на сегодня|Plan for Today|Today.s Plan"
  "Календарь|Calendar"
  "IWE за ночь|IWE Overnight"
  "Разбор заметок|Notes Review"
  "Итоги вчера|Yesterday"
)

for section in "${SECTIONS[@]}"; do
  if ! grep -qE "$section" "$DAYPLAN"; then
    MISSING+=("$section")
  fi
done

# Check mandatory format elements

# --- Phase 3 Check 1: section headings — ## (Obsidian-compatible) or <summary> (collapsible sections, formatting.md) ---
# issue #221: formatting.md requires <details><summary> for DayPlan/WeekPlan (a newer decision,
# which replaced the old Obsidian-only ban on HTML tags) — we count both variants as a section heading.
HEADINGS_COUNT=$(grep -cE '^## |^[[:space:]]*<summary>' "$DAYPLAN" 2>/dev/null || true); HEADINGS_COUNT=${HEADINGS_COUNT:-0}
if [ "$HEADINGS_COUNT" -lt 3 ]; then
  ERRORS+=("Секций (## или <summary>) < 3 найдено: $HEADINGS_COUNT. DayPlan должен иметь структуру из заголовков секций")
fi

# --- Phase 3 Check 2: non-empty mandatory sections ---
# Calendar: must contain at least one line with | (table) or "нет событий" (no events).
# Flag-range instead of awk-range '/start/,/^## /': the section heading (## Календарь ...)
# matches both the start and the end delimiter /^## /, because of which the range collapses into
# a single line and the section body is lost (false commit block — issue #207).
# EN alternative of the heading (Calendar) — for bilingual DayPlans (issue #210).
CALENDAR_CONTENT=$(awk 'f && /^## /{exit} /Календарь|Calendar/{f=1} f' "$DAYPLAN" 2>/dev/null | wc -l || echo 0)
if [ "$CALENDAR_CONTENT" -lt 3 ]; then
  ERRORS+=("Секция 'Календарь' пустая или слишком короткая (${CALENDAR_CONTENT} строк)")
fi

# Scout: checked only if the section is present in the DayPlan at all (an optional component,
# depends on DS-agent-workspace). If there is no section — Scout is not configured, the validator does not block.
if grep -q "Наработки Scout" "$DAYPLAN" 2>/dev/null; then
  # Flag-range instead of awk-range (see Calendar above, issue #207): the heading
  # '## Наработки Scout' matches the end delimiter /^## /, the range collapses.
  if ! awk 'f && /^## /{exit} /Наработки Scout/{f=1} f' "$DAYPLAN" 2>/dev/null | grep -iqE 'наход|capture|статус|нет|find|disabled|not configured'; then
    ERRORS+=("Секция 'Наработки Scout' пустая (допустимы маркеры 'нет находок', 'disabled', 'not configured')")
  fi
fi

# --- Phase 3 Check 3: multiplier format ---
# issue #328: without configured time tracking there is nothing to compute the multiplier
# from — forcing a number gives a fictitious '~1.0x', which a month later reads
# as a measurement. An explicit textual disclaimer ("мультипликатор не считаю" = multiplier not counted / "не
# настроен" = not configured) is as honest a field state as the number itself.
# issue #870: the fractional part is a dot OR a comma (the Russian Day Open writes "~1,2x").
# The number is only format-checked (grep), it does not take part in calculations.
if ! grep -qE "~[0-9]+[.,]?[0-9]*x" "$DAYPLAN" && ! grep -qiE "мультипликатор.*(не считаю|не наст)" "$DAYPLAN"; then
  ERRORS+=("Мультипликатор не найден — нужен формат '~N.Nx' в строке бюджета, либо явная оговорка 'мультипликатор не считаю'")
fi

# --- Phase 3 Check 4 (legacy): mandatory check and budget ---
# issue #328: "mandatory" was hard-wired in the text of one specific installation (WP-7 +
# the author's content WP). The source of truth is mandatory_daily_wps in
# day-rhythm-config.yaml; commented out/empty → the user explicitly configured
# "no mandatory WPs", we do not require the section in the DayPlan.
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
    # issue #765: the python3 resolver is no less reliable than the YAML itself — the same
    # fail-closed boundary that applies below to a broken/unreadable config.
    ERRORS+=("day-rhythm-config.yaml есть, но python3 не резолвится (find-python3.sh не найден или не вернул интерпретатор) — mandatory-проверка невозможна, fail-closed")
  else
    # Codes: 0 = mandatory configured; 1 = valid config without mandatory;
    # 2+ = broken/unreadable YAML — fail-closed (same contract as sibling
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
      1) : ;; # valid config without mandatory — check not required
      *) ERRORS+=("day-rhythm-config.yaml существует, но не читается (нет PyYAML / битый или пустой YAML / корень не map / интерпретатор упал rc=$_MANDATORY_RC) — mandatory-проверка невозможна, fail-closed") ;;
    esac
  fi
fi
if [ "$MANDATORY_WPS_CONFIGURED" = "true" ] && ! grep -qi "mandatory" "$DAYPLAN"; then
  ERRORS+=("Mandatory check не найден (mandatory_daily_wps сконфигурирован в day-rhythm-config.yaml)")
fi

# issue #328: the Russian 'ч' is the standard formatting.md format, the Latin 'h' is the old
# format, kept for backward compatibility with already existing artifacts.
if ! grep -qE "~[0-9]+[.,]?[0-9]* ?[hч] РП" "$DAYPLAN"; then
  ERRORS+=("Бюджет дня не в формате '~Xч РП / ~Yч физ' (латинская 'h' тоже принимается)")
fi

# --- Phase 3 Check 5: Carry-over quote (if there is a previous DayPlan) ---
# issue #870: the predecessor of the STAGED plan in the sorted list, not the
# "second-to-last on disk": when committing not the newest plan, it would be compared
# with its own future. The oldest plan has no predecessor — nothing to compare with.
# The staged plan itself is added to the list: a name outside the canon ("DayPlan_…", not "DayPlan …")
# also gets a predecessor, as before this fix.
PREV_DAYPLAN=$({ ls "$GOV_PATH"/current/DayPlan\ *.md 2>/dev/null; printf '%s\n' "$DAYPLAN"; } | sort -u \
  | CUR="$DAYPLAN" awk '$0 == ENVIRON["CUR"] { print prev; exit } { prev = $0 }')
if [ -n "$PREV_DAYPLAN" ] && [ "$PREV_DAYPLAN" != "$DAYPLAN" ]; then
  # The previous DayPlan exists — the current one must contain Carry-over
  if ! grep -qiE 'carry.over|carry_over' "$DAYPLAN"; then
    ERRORS+=("Carry-over цитата из предыдущего Day Close отсутствует (предыдущий DayPlan: $(basename "$PREV_DAYPLAN"))")
  fi
fi

fi  # endif [ -n "$DAYPLAN" ]

# --- WeekPlan Validation (Phase 6.1 WP-265) ---
# issue #248: previously the LAST WeekPlan on disk by mtime/name was validated,
# even if only the DayPlan changed in this commit — an old, non-migrated
# WeekPlan blocked commits it had nothing to do with. Now we validate
# ONLY if the WeekPlan itself is staged in this commit.
WEEKPLAN_STAGED=$(echo "$STAGED" | grep -E '^current/WeekPlan.*\.md$' | sort | tail -1)
WEEKPLAN=""
[ -n "$WEEKPLAN_STAGED" ] && WEEKPLAN="$GOV_PATH/$WEEKPLAN_STAGED"
if [ -n "$WEEKPLAN" ] && [ -f "$WEEKPLAN" ]; then
  WP_LINES=$(wc -l < "$WEEKPLAN" | tr -d ' ')
  WP_ERRORS=()
  WP_MISSING_LIST=()

  # Detector (a): >80 lines without a sufficient number of headings — ## or <summary> (issue #221, see Check 1 above)
  WP_HEADINGS_COUNT=$(grep -cE '^## |^[[:space:]]*<summary>' "$WEEKPLAN" 2>/dev/null || true); WP_HEADINGS_COUNT=${WP_HEADINGS_COUNT:-0}
  if [ "$WP_LINES" -gt 80 ] && [ "$WP_HEADINGS_COUNT" -lt 3 ]; then
    WP_ERRORS+=("WeekPlan >80 строк ($WP_LINES) но секций (## или <summary>) < 3 ($WP_HEADINGS_COUNT). Используй ## заголовки или <details><summary> для структурирования.")
  fi

  # Detector (c) — mandatory WeekPlan sections — removed (issue #318 hotfix,
  # 2026-07-28): the list of headings twice in a row lagged behind the real structure
  # and when checked against the pilot's entire history blocked 23 of 24 archived files
  # (sections like "## Carry-over" appear only at Week Close, not during
  # the week). The WeekPlan structure changes too often for a hard gate on
  # heading names — detector (a) above stays, it does not depend on them.

  # Detector (d): WeekReport validation (OPT-5 WP-297)
  # issue #248: the same disease — the LAST WeekReport on disk was taken,
  # which may belong to an already closed past week. We validate only
  # if the WeekReport itself is staged in this commit.
  WEEKREPORT_STAGED=$(echo "$STAGED" | grep -E '^current/WeekReport.*\.md$' | sort | tail -1)
  if [ -n "$WEEKREPORT_STAGED" ]; then
    WEEKREPORT="$GOV_PATH/$WEEKREPORT_STAGED"
    if [ -f "$WEEKREPORT" ] && ! grep -q "Итоги" "$WEEKREPORT"; then
      WP_MISSING_LIST+=("Итоги (в WeekReport)")
    fi
  fi

  if [ ${#WP_MISSING_LIST[@]} -gt 0 ] || [ ${#WP_ERRORS[@]} -gt 0 ]; then
    WP_MISSING_STR=$(IFS=', '; echo "${WP_MISSING_LIST[*]:-}")
    WP_ERRORS_STR=$(IFS=', '; echo "${WP_ERRORS[*]:-}")
    WP_MSG="⛔ WEEKPLAN VALIDATION FAILED."
    [ ${#WP_MISSING_LIST[@]} -gt 0 ] && WP_MSG="$WP_MSG Пропущены секции (${#WP_MISSING_LIST[@]}): $WP_MISSING_STR."
    [ ${#WP_ERRORS[@]} -gt 0 ] && WP_MSG="$WP_MSG Ошибки структуры: $WP_ERRORS_STR."
    WP_MSG="$WP_MSG Исправь WeekPlan перед коммитом."
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
  [ ${#MISSING[@]} -gt 0 ] && MSG="$MSG Пропущены секции (${#MISSING[@]}): $MISSING_STR."
  [ ${#ERRORS[@]} -gt 0 ] && MSG="$MSG Ошибки формата/структуры: $ERRORS_STR."
  MSG="$MSG Исправь DayPlan перед коммитом."

  jq -n --arg reason "$MSG" '{"decision": "block", "reason": $reason}'
else
  jq -n '{"hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": "✅ DayPlan прошёл валидацию: секции, ## заголовки, непустые блоки, мультипликатор, carry-over."}}'
fi

exit 0
