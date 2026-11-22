#!/usr/bin/env bash
# routing: helper  skill=week-close  called-by=sonnet
# see DP.SC.159, DP.ROLE.059
# week-draft-append.sh — update the current day metrics in the weekly post draft.
#
# Collects: WakaTime (--today), commits (all repos, since today 00:00),
# closed WPs (from commits "close/done WP-NNN").
#
# Usage:
#   week-draft-append.sh              # current day, current week
#   week-draft-append.sh --week 16    # explicit week
#   week-draft-append.sh --dry-run    # print, but do not write
#
# Parameters (params.yaml):
#   knowledge_repo: <path relative to WORKSPACE_DIR>  # path to knowledge-index repo
# If not set — the script is skipped with a hint.

set -euo pipefail

WORKSPACE="${WORKSPACE_DIR:-$HOME/IWE}"
WAKATIME_CLI="${WAKATIME_CLI:-$HOME/.wakatime/wakatime-cli}"
if [[ ! -x "$WAKATIME_CLI" ]]; then
  # issue #1151: the VS Code WakaTime extension on Windows downloads the
  # binary as wakatime-cli-windows-amd64.exe, not the bare name above.
  WAKATIME_CLI=$(ls -d "$HOME"/.wakatime/wakatime-cli* 2>/dev/null | head -1 || true)
  WAKATIME_CLI="${WAKATIME_CLI:-$HOME/.wakatime/wakatime-cli}"
fi

PARAMS_FILE="${WORKSPACE}/params.yaml"
KNOWLEDGE_REPO_REL=""
if [[ -f "$PARAMS_FILE" ]]; then
  KNOWLEDGE_REPO_REL=$(grep -E "^knowledge_repo:" "$PARAMS_FILE" | sed 's/^knowledge_repo:[[:space:]]*//; s/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//' || echo "")
fi

if [[ -z "$KNOWLEDGE_REPO_REL" ]]; then
  echo "ℹ️ week-draft-append.sh: knowledge_repo is not set in params.yaml — skipping"
  exit 0
fi

KNOWLEDGE="${WORKSPACE}/${KNOWLEDGE_REPO_REL}"
if [[ ! -d "$KNOWLEDGE" ]]; then
  echo "⚠️ week-draft-append.sh: knowledge_repo not found: $KNOWLEDGE" >&2
  exit 1
fi

DRY_RUN=0
WEEK_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --week) WEEK_ARG="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

TODAY_ISO=$(date +%Y-%m-%d)
DOW=$(date +%u)
DOM=$(date +%d)
MONTH_NUM=$(date +%m)
YEAR=$(date +%Y)

DOW_RU=("Mon" "Tue" "Wed" "Thu" "Fri" "Sat" "Sun")
DOW_LABEL="${DOW_RU[$((DOW-1))]} ${DOM#0}"

WEEK=${WEEK_ARG:-$(date +%V)}

MONTH_REVERSE=$((13 - 10#$MONTH_NUM))
MONTH_REVERSE_PADDED=$(printf "%02d" "$MONTH_REVERSE")
MONTH_NAME_RU=("January" "February" "March" "April" "May" "June" "July" "August" "September" "October" "November" "December")
MONTH_NAME="${MONTH_NAME_RU[$((10#$MONTH_NUM-1))]}"

DRAFT_DIR="${KNOWLEDGE}/docs/${YEAR}/${MONTH_REVERSE_PADDED}-${MONTH_NAME}"
DRAFT_FILE="${DRAFT_DIR}/week-draft-w${WEEK}.md"

if [[ ! -f "$DRAFT_FILE" ]]; then
  echo "ERR: draft not found: $DRAFT_FILE" >&2
  echo "Run week-draft-init.sh (W${WEEK}) on Mon Day Close." >&2
  exit 1
fi

# 1. WakaTime
WAKA="—"
if [[ -x "$WAKATIME_CLI" ]]; then
  WAKA=$("$WAKATIME_CLI" --today 2>/dev/null | awk -F'[ ,]' '{
    total=0
    for(i=1;i<=NF;i++){
      if($i=="hrs"||$i=="hr") total += $(i-2)*60 + ($(i-1)=="and"?0:$(i-1))
      else if($i=="mins"||$i=="min") total += $(i-1)
    }
    if(total>=60) printf "%dh %02dmin", int(total/60), total%60
    else printf "%dmin", total
  }')
  [[ -z "$WAKA" ]] && WAKA="—"
fi

# iwe_repo_dirs — prints subdirectories with .git, deduplicated by real
# physical path (repo-symlink alias would otherwise be counted as a separate repository
# alongside the original — inflated commit count, discovered 2026-07-17).
iwe_repo_dirs() {
  local repo real seen=""
  for repo in "$@"; do
    [ -d "$repo/.git" ] || continue
    real=$(cd -P "$repo" 2>/dev/null && pwd) || continue
    case " $seen " in
      *" $real "*) continue ;;
    esac
    seen="$seen $real"
    echo "$repo"
  done
}

# 2. Commits across all repos since today 00:00
COMMITS=0
while IFS= read -r repo; do
  count=$(git -C "$repo" log --since="today 00:00" --oneline --no-merges 2>/dev/null | wc -l | tr -d ' ')
  COMMITS=$((COMMITS + count))
done < <(iwe_repo_dirs "$WORKSPACE"/*/)

# 3. Closed WPs today (best effort — by commit message)
WPS_CLOSED=0
while IFS= read -r repo; do
  count=$(git -C "$repo" log --since="today 00:00" --pretty=%s 2>/dev/null | grep -ciE "(close|done|complete).*(wp-|WP-)[0-9]+" || true)
  WPS_CLOSED=$((WPS_CLOSED + count))
done < <(iwe_repo_dirs "$WORKSPACE"/*/)

# Fields «Budget closed» and «Month progress» — for manual entry
BUDGET="—"
PROGRESS="—"

NEW_ROW="| ${DOW_LABEL} | ${WAKA} | ${COMMITS} | ${WPS_CLOSED} | ${BUDGET} | ${PROGRESS} |"

echo "== Draft: $DRAFT_FILE"
echo "== New row:"
echo "$NEW_ROW"
echo

if [[ $DRY_RUN -eq 1 ]]; then
  echo "(dry-run — dry-run, changes not written)"
  exit 0
fi

if grep -qE "^\| ${DOW_LABEL} \|" "$DRAFT_FILE"; then
  python3 - "$DRAFT_FILE" "$DOW_LABEL" "$NEW_ROW" <<'PYEOF'
import sys, re
path, label, new_row = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    content = f.read()
pattern = re.compile(r"^\| " + re.escape(label) + r" \|[^\n]*$", re.MULTILINE)
if pattern.search(content):
    content = pattern.sub(new_row, content, count=1)
    with open(path, "w") as f:
        f.write(content)
    print(f"OK: row «{label}» updated")
else:
    print(f"ERR: could not find row «{label}»", file=sys.stderr)
    sys.exit(1)
PYEOF
else
  echo "ERR: could not find row for ${DOW_LABEL} in the draft table" >&2
  exit 1
fi
