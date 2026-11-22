#!/usr/bin/env bash
# routing: helper  skill=week-close  called-by=sonnet
# see DP.SC.159, DP.ROLE.059
# week-draft-init.sh — create an empty weekly post draft for a new week.
#
# Usage:
#   week-draft-init.sh              # current week
#   week-draft-init.sh --week 17    # explicit week
#
# Run on Mon Day Close (first entry of the weekday).
# If the draft already exists — exits without changes.
#
# Parameters (params.yaml):
#   knowledge_repo: <path relative to WORKSPACE_DIR>  # path to knowledge-index repo
# If not set — the script is skipped with a hint.

set -euo pipefail

WORKSPACE="${WORKSPACE_DIR:-$HOME/IWE}"

PARAMS_FILE="${WORKSPACE}/params.yaml"
KNOWLEDGE_REPO_REL=""
if [[ -f "$PARAMS_FILE" ]]; then
  KNOWLEDGE_REPO_REL=$(grep -E "^knowledge_repo:" "$PARAMS_FILE" | sed 's/^knowledge_repo:[[:space:]]*//; s/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//' || echo "")
fi

if [[ -z "$KNOWLEDGE_REPO_REL" ]]; then
  echo "ℹ️ week-draft-init.sh: parameter knowledge_repo is not set in params.yaml — skipping"
  echo "   To enable the cumulative draft of the weekly post, add to params.yaml:"
  echo "   knowledge_repo: \"DS-Knowledge-Index\""
  exit 0
fi

KNOWLEDGE="${WORKSPACE}/${KNOWLEDGE_REPO_REL}"
if [[ ! -d "$KNOWLEDGE" ]]; then
  echo "⚠️ week-draft-init.sh: knowledge_repo not found: $KNOWLEDGE" >&2
  exit 1
fi

WEEK_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --week) WEEK_ARG="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

YEAR=$(date +%Y)
MONTH_NUM=$(date +%m)
WEEK=${WEEK_ARG:-$(date +%V)}

MONTH_REVERSE=$((13 - 10#$MONTH_NUM))
MONTH_REVERSE_PADDED=$(printf "%02d" "$MONTH_REVERSE")
MONTH_NAME_RU=("January" "February" "March" "April" "May" "June" "July" "August" "September" "October" "November" "December")
MONTH_NAME="${MONTH_NAME_RU[$((10#$MONTH_NUM-1))]}"

DRAFT_DIR="${KNOWLEDGE}/docs/${YEAR}/${MONTH_REVERSE_PADDED}-${MONTH_NAME}"
DRAFT_FILE="${DRAFT_DIR}/week-draft-w${WEEK}.md"

if [[ -f "$DRAFT_FILE" ]]; then
  echo "Draft already exists: $DRAFT_FILE"
  exit 0
fi

mkdir -p "$DRAFT_DIR"

# Computing dates for Mon-Sun of the current ISO-ISO week
# Bug-fix 24.07: "monday this week"/"sunday this week" in GNU date do not anchor to the current
# calendar week — it is "the next occurrence of the weekday", which depends on whether, has already passed
# whether that weekday has already occurred today. On Friday (%u=5) Mon (day 1) has already passed → "monday this week"
# jumps to the NEXT Monday, while Sun (day 7) has not yet arrived → "sunday this week" remains
# in the CURRENT week — producing an inconsistent range on output (e.g.. «27-26 July», Mon from the next week
# + Sun from the current week). Fix: the same day offset from today, which already works correctly in the -v branch -v (BSD).
MON_DATE=$(date -v-$(($(date +%u)-1))d +%Y-%m-%d 2>/dev/null || date -d "today - $(($(date +%u)-1)) days" +%Y-%m-%d)
SUN_DATE=$(date -v+$((7-$(date +%u)))d +%Y-%m-%d 2>/dev/null || date -d "today + $((7-$(date +%u))) days" +%Y-%m-%d)

# issue #155: || fallback to GNU date (Linux) — otherwise date -j fails, 2>/dev/null suppresses, day is empty
MON_DAY=$(date -j -f %Y-%m-%d "$MON_DATE" +%d 2>/dev/null || date -d "$MON_DATE" +%d 2>/dev/null); MON_DAY=${MON_DAY#0}
SUN_DAY=$(date -j -f %Y-%m-%d "$SUN_DATE" +%d 2>/dev/null || date -d "$SUN_DATE" +%d 2>/dev/null); SUN_DAY=${SUN_DAY#0}
MONTH_FOR_DATES="${MONTH_NAME:0:3}"

# Generate metrics table rows with Mon dates-Sun (WD1 fix: compatibility with week-draft-append.sh)
DOW_RU=("Mon" "Tue" "Wed" "Thu" "Fri" "Sat" "Sun")
TABLE_ROWS=""
for i in 0 1 2 3 4 5 6; do
  day_date=$(date -v+${i}d -j -f %Y-%m-%d "$MON_DATE" +%Y-%m-%d 2>/dev/null || date -d "$MON_DATE + $i days" +%Y-%m-%d)
  # issue #245: `||` after the pipe to sed did not trigger, if only `date -j` (GNU date) —
  # sed exits successfully on empty input, so the fallback never ran.
  day_num=$(date -j -f %Y-%m-%d "$day_date" +%d 2>/dev/null || date -d "$day_date" +%d 2>/dev/null); day_num=${day_num#0}
  TABLE_ROWS="${TABLE_ROWS}| ${DOW_RU[$i]} ${day_num} | | | | | |"$'\n'
done

cat > "$DRAFT_FILE" <<EOF
---
type: week-draft
week: W${WEEK}
dates: ${MON_DAY}-${SUN_DAY} ${MONTH_FOR_DATES} ${YEAR}
status: draft-internal
created: $(date +%Y-%m-%d)
---

# Weekly post draft W${WEEK} (${MON_DAY}-${SUN_DAY} ${MONTH_FOR_DATES} ${YEAR})

> **Purpose:** cumulative draft for the weekly post. Filled in every day at Day Close.
> **Not published.** At Week Close the author writes the final post based on this draft.
> **Structure:** 4 levels of impact (world → community → person → personal) + metrics + carry-over.

---

## World (ideas/universal principles)

> What from the work done during the day — universal approach/principle, applicable beyond the project?

- [Mon] —
- [Tue] —
- [Wed] —
- [Thu] —
- [Fri] —
- [Sat] —
- [Sun] —

## Community (what will help members)

> What from the work done can help community members in their learning/projects?

- [Mon] —
- [Tue] —
- [Wed] —
- [Thu] —
- [Fri] —
- [Sat] —
- [Sun] —

## Individual (what one reader can try right now)

> What single tip/tool/method from the day can the reader try today?

- [Mon] —
- [Tue] —
- [Wed] —
- [Thu] —
- [Fri] —
- [Sat] —
- [Sun] —

## Personal (what I myself realized / what has changed)

> What did I realize during the day? What has changed for me? Honestly, without embellishment.

- [Mon] —
- [Tue] —
- [Wed] —
- [Thu] —
- [Fri] —
- [Sat] —
- [Sun] —

## Insights / discoveries / quotes (miscellaneous)

> Free bucket: phrases, links, recurring themes of the week. ⭐ — marker for a candidate for the top insight.

-

## Published posts of the week

-

## Ideas for W$((WEEK + 1)) (carry-over)

-

---

## Weekly metrics

| Day | WakaTime | Commits | Closed WP | Budget closed | Month progress |
|------|----------|---------|------------|---------------|-----------------|
${TABLE_ROWS}| **Total W${WEEK}** | | | | | |

---

## What goes into the final post (filled in at Week Close)

### Title (3-5 options)

1.
2.
3.

### Main insight of the week

>

### Closing (what is next, 2-3 sentences)

>

### Summary metrics line-metrics

>
EOF

echo "Draft created: $DRAFT_FILE"
