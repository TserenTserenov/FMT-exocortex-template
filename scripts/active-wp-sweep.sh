#!/usr/bin/env bash
# routing: helper  called-by=day-open,session-prep  deterministic=true
# see DP.SC.159, DP.ROLE.059
# active-wp-sweep.sh — heartbeat sweep активных РП
# see WP-283 Шаг E (${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/WP-283-server-day-open-crossplatform.md)
#
# Обходит ${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/WP-*.md, находит файлы с status: in_progress | active | awaiting-batch,
# плюс union с WP-IDs из текущего WeekPlan (для pending-РП, которые в плане недели),
# кросс-чекает с git activity, выводит markdown-таблицу кандидатов.
#
# Совместимость: bash 3.2+ (macOS), bash 4+ (Linux/NixOS)
#
# Использование:
#   bash active-wp-sweep.sh [INBOX_DIR] [IWE_ROOT]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../.claude/lib/iwe-env-bootstrap.sh" || exit 1
IWE="${2:-$IWE_ROOT}"
INBOX="${1:-$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox}"
GIT_DAYS="${WP_SWEEP_GIT_DAYS:-7}"

# --- Найти python3 с yaml ---
_find_python3() {
  if python3 -c "import yaml" 2>/dev/null; then echo "python3"; return; fi
  local p
  for p in \
    /nix/store/aj1smkrsnv16lbz9g8qancb04b3kv0va-python3-3.12.8-env/bin/python3 \
    /usr/bin/python3 /usr/local/bin/python3; do
    [[ -x "$p" ]] && "$p" -c "import yaml" 2>/dev/null && { echo "$p"; return; }
  done
  echo ""
}

PYTHON=$(_find_python3)

if [[ -z "$PYTHON" ]]; then
  echo "<!-- active-wp-sweep: python3+yaml не найден, sweep пропущен -->"
  exit 0
fi

if [[ ! -d "$INBOX" ]]; then
  echo "<!-- active-wp-sweep: INBOX не найден: $INBOX -->"
  exit 0
fi

# --- Python-хелпер: извлекает wp + title из frontmatter ---
# Передаём WP_FILE через env-var (защита от спецсимволов в путях).
# Python-код через quoted heredoc <<'PYEOF' — bash не раскрывает.
_extract_wp_meta() {
  WP_FILE_ENV="$1" $PYTHON <<'PYEOF' 2>/dev/null
import sys, re, os
path = os.environ["WP_FILE_ENV"]
wp_num = ""
title = ""
try:
    with open(path, "r", encoding="utf-8") as f:
        in_fm = False
        for line in f:
            line = line.rstrip()
            if line == "---":
                if not in_fm:
                    in_fm = True
                    continue
                else:
                    break
            if not in_fm:
                continue
            # wp: 283 | wp: WP-283 | id: WP-283 — все варианты
            m = re.match(r"^(?:wp|id):\s*(\S+)", line)
            if m and not wp_num:
                raw = m.group(1).strip("\"' ")
                wp_num = re.sub(r"^WP-", "", raw)
            m = re.match(r'^title:\s*["\']?(.+?)["\']?\s*$', line)
            if m:
                title = m.group(1).strip("\"' ")[:60]
    # Fallback: если в frontmatter ничего не нашли — извлечь из filename
    if not wp_num:
        fname = os.path.basename(path)
        m = re.match(r"^WP-(\d+)", fname)
        if m:
            wp_num = m.group(1)
except Exception:
    pass
print(wp_num + "|" + title)
PYEOF
}

# --- WP-REGISTRY drift helper ---
# Возвращает 0 (done) если WP помечен ✅ в REGISTRY (строка вида | ~~N~~ ...)
REGISTRY_FILE="$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/docs/WP-REGISTRY.md"
_wp_done_in_registry() {
  local wp_num="$1"
  [[ -f "$REGISTRY_FILE" ]] || return 1
  grep -qE "^\| ~~0*${wp_num}~~" "$REGISTRY_FILE" 2>/dev/null
}

# --- Discovery helpers for two-level inbox structure ---
# _gather_wp_files: enumerates all candidate WP context files from both
#   inbox/WP-NNN.md (flat) and inbox/WP-NNN/WP-NNN.md (nested folder).
#   Duplicates handled upstream via SEEN_WP_NUMS.
_gather_wp_files() {
  local inbox="$1"
  # Flat files at top level
  for f in "$inbox"/WP-*.md; do [[ -f "$f" ]] && echo "$f"; done
  # Nested files: inbox/WP-NNN/WP-NNN.md (folder name == file name)
  for d in "$inbox"/WP-*/; do
    [[ -d "$d" ]] || continue
    local dname num
    dname=$(basename "$d")   # WP-426
    num="${dname#WP-}"       # 426
    local nested="${d%/}/WP-${num}.md"
    [[ -f "$nested" ]] && echo "$nested"
  done
}

# _find_wp_context: given a WP number, returns the path to its context file.
#   Checks flat path first, then nested — matches INBOX-CONVENTION.md rules.
_find_wp_context() {
  local inbox="$1" num="$2"
  local flat="$inbox/WP-${num}.md"
  local nested="$inbox/WP-${num}/WP-${num}.md"
  [[ -f "$flat" ]] && echo "$flat" && return
  [[ -f "$nested" ]] && echo "$nested"
}

# --- Union: WP-IDs из текущего WeekPlan (для pending-РП в плане недели) ---
# Находит первый файл WeekPlan W*.md в current/ и извлекает все WP-NNN из него.
_weekplan_wp_ids() {
  local weekplan
  weekplan=$(ls -t "$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/current/WeekPlan"*.md 2>/dev/null | head -1)
  [[ -f "$weekplan" ]] || return
  grep -oE 'WP-[0-9]+' "$weekplan" 2>/dev/null | grep -oE '[0-9]+' | sort -u
}

WEEKPLAN_IDS=$(_weekplan_wp_ids)

# --- Собрать WP-файлы с in_progress, active или awaiting-batch ---
FOUND=0
DRIFT_ROWS=""
OUTPUT_ROWS=""
SEEN_WP_NUMS=""

while IFS= read -r WP_FILE; do

  # Быстрый grep: есть ли нужный статус?
  grep -qE "^status: (in_progress|active|awaiting-batch)" "$WP_FILE" 2>/dev/null || continue

  FILENAME=$(basename "$WP_FILE" .md)

  # Извлечь номер и заголовок
  META=$(_extract_wp_meta "$WP_FILE")
  WP_NUM="${META%%|*}"
  WP_TITLE="${META##*|}"
  [[ -z "$WP_TITLE" ]] && WP_TITLE="$FILENAME"

  WP_LABEL="WP-${WP_NUM:-??}"

  # Drift-check: если в REGISTRY помечен ✅ — это zombie, вывести предупреждение
  if [[ -n "$WP_NUM" ]] && _wp_done_in_registry "$WP_NUM"; then
    DRIFT_ROWS="${DRIFT_ROWS}| ⚠️ **${WP_LABEL}** ${WP_TITLE} | frontmatter=active, REGISTRY=✅ done — archive: \`mv inbox/ → archive/wp-contexts/\` |
"
    continue
  fi

  FOUND=$((FOUND + 1))
  # Запомнить номер — чтобы не дублировать в union-блоке
  [[ -n "$WP_NUM" ]] && SEEN_WP_NUMS="${SEEN_WP_NUMS} ${WP_NUM} "

  # Git activity: ищем во всех git-репо под IWE
  GIT_INFO=""
  if [[ -n "$WP_NUM" ]]; then
    while IFS= read -r GIT_DIR; do
      REPO_DIR="$(dirname "$GIT_DIR")"
      HIT=$(git -C "$REPO_DIR" log \
        --since="${GIT_DAYS} days ago" \
        --oneline \
        --grep="WP-${WP_NUM}" \
        --all \
        2>/dev/null | head -1)
      if [[ -n "$HIT" ]]; then
        GIT_INFO="$HIT"
        break
      fi
    done < <(find "$IWE" -maxdepth 2 -name ".git" -type d 2>/dev/null)
  fi

  GIT_CELL="${GIT_INFO:0:55}"
  [[ -z "$GIT_CELL" ]] && GIT_CELL="нет (${GIT_DAYS}д)"

  OUTPUT_ROWS="${OUTPUT_ROWS}| **${WP_LABEL}** ${WP_TITLE} | ${GIT_CELL} |
"
done < <(_gather_wp_files "$INBOX")

# --- Union: добавить pending-РП из WeekPlan, которых ещё нет в результатах ---
if [[ -n "$WEEKPLAN_IDS" ]]; then
  while IFS= read -r WP_NUM; do
    [[ -z "$WP_NUM" ]] && continue
    # Пропустить если уже найден через inbox-статус
    [[ " $SEEN_WP_NUMS " == *" $WP_NUM "* ]] && continue
    # Пропустить если помечен ✅ в REGISTRY
    _wp_done_in_registry "$WP_NUM" && continue
    # Найти inbox-файл
    WP_FILE=$(_find_wp_context "$INBOX" "$WP_NUM")
    [[ -n "$WP_FILE" ]] || continue
    META=$(_extract_wp_meta "$WP_FILE")
    WP_TITLE="${META##*|}"
    [[ -z "$WP_TITLE" ]] && WP_TITLE="WP-${WP_NUM}"
    WP_LABEL="WP-${WP_NUM}"
    FOUND=$((FOUND + 1))
    GIT_INFO=""
    while IFS= read -r GIT_DIR; do
      REPO_DIR="$(dirname "$GIT_DIR")"
      HIT=$(git -C "$REPO_DIR" log \
        --since="${GIT_DAYS} days ago" --oneline --grep="WP-${WP_NUM}" --all 2>/dev/null | head -1)
      if [[ -n "$HIT" ]]; then GIT_INFO="$HIT"; break; fi
    done < <(find "$IWE" -maxdepth 2 -name ".git" -type d 2>/dev/null)
    GIT_CELL="${GIT_INFO:0:55}"
    [[ -z "$GIT_CELL" ]] && GIT_CELL="нет (${GIT_DAYS}д)"
    OUTPUT_ROWS="${OUTPUT_ROWS}| **${WP_LABEL}** ${WP_TITLE} | ${GIT_CELL} |
"
  done <<< "$WEEKPLAN_IDS"
fi

# --- Вывод ---
if [[ $FOUND -eq 0 ]] && [[ -z "$DRIFT_ROWS" ]]; then
  echo "<!-- active-wp-sweep: активных РП не найдено -->"
  exit 0
fi

if [[ $FOUND -gt 0 ]]; then
  echo ""
  echo "### 🔄 Активные РП (sweep по inbox/WP-*.md)"
  echo ""
  echo "| РП | Последний коммит (${GIT_DAYS}д) |"
  echo "|----|---------------------------------|"
  printf '%s' "$OUTPUT_ROWS"
  echo ""
fi

if [[ -n "$DRIFT_ROWS" ]]; then
  echo ""
  echo "### ⚠️ Drift: frontmatter=active, REGISTRY=✅ (нужна архивация)"
  echo ""
  echo "| РП | Расхождение |"
  echo "|----|-------------|"
  printf '%s' "$DRIFT_ROWS"
  echo ""
fi
