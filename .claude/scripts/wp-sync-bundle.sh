#!/usr/bin/env bash
# wp-sync-bundle.sh — детерминированный bundler контекста РП для sync-фазы WP Gate
# Контракт: вход WP-N или N → stdout markdown bundle, exit 0/1/2
# see WP-294
# Compatible: bash 3.2+

set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
IWE_WORKSPACE="${IWE_WORKSPACE:-$HOME/IWE}"
GOV_REPO="${IWE_GOVERNANCE_REPO:-DS-strategy}"
STRATEGY_DIR="$IWE_WORKSPACE/$GOV_REPO"
INBOX_DIR="$STRATEGY_DIR/inbox"
ARCHIVE_DIR="$STRATEGY_DIR/archive/wp-contexts"
REGISTRY_FILE="$STRATEGY_DIR/docs/WP-REGISTRY.md"
GIT_LOG_DAYS="${WP_SYNC_GIT_DAYS:-14}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log_warn() { echo "[WARN] $*" >&2; }
log_err()  { echo "[ERROR] $*" >&2; }
log_parse_err() { echo "[PARSE-ERROR] $*" >&2; }

# Validate that file has parseable YAML frontmatter (between two `---` markers)
validate_frontmatter() {
  local file="$1"
  local fm_count
  fm_count=$(grep -c '^---$' "$file" 2>/dev/null | head -1 || true)
  fm_count="${fm_count:-0}"
  if [[ "$fm_count" -lt 2 ]]; then
    log_parse_err "Файл не имеет валидного YAML frontmatter (нужно минимум 2 строки '---'): $file"
    return 1
  fi
  return 0
}

normalize_wp_num() {
  local arg="$1"
  echo "${arg#WP-}" | tr -d ' '
}

find_wp_file() {
  local num="$1"
  local found=""

  if [[ -d "$INBOX_DIR" ]]; then
    found=$(grep -rl "^wp: ${num}$" "$INBOX_DIR" 2>/dev/null | head -1 || true)
    if [[ -z "$found" ]]; then
      found=$(find "$INBOX_DIR" -maxdepth 1 -name "WP-${num}.md" 2>/dev/null | head -1 || true)
    fi
    if [[ -z "$found" ]]; then
      local candidates
      candidates=$(find "$INBOX_DIR" -maxdepth 1 -name "WP-${num}-*.md" 2>/dev/null | sort | head -5 || true)
      if [[ -n "$candidates" ]]; then
        while IFS= read -r cand; do
          if [[ -f "$cand" ]] && grep -q "^wp: ${num}$" "$cand" 2>/dev/null; then
            found="$cand"
            break
          fi
        done <<< "$candidates"
        if [[ -z "$found" ]]; then
          # Pick shortest filename
          found=$(echo "$candidates" | awk '{print length, $0}' | sort -n | head -1 | cut -d' ' -f2-)
        fi
      fi
    fi
  fi

  if [[ -z "$found" && -d "$ARCHIVE_DIR" ]]; then
    found=$(grep -rl "^wp: ${num}$" "$ARCHIVE_DIR" 2>/dev/null | head -1 || true)
    if [[ -z "$found" ]]; then
      found=$(find "$ARCHIVE_DIR" -maxdepth 1 -name "WP-${num}*.md" 2>/dev/null | head -1 || true)
    fi
  fi

  echo "$found"
}

file_location_label() {
  local filepath="$1"
  case "$filepath" in
    "$INBOX_DIR"*) echo "inbox" ;;
    "$ARCHIVE_DIR"*) echo "archive/wp-contexts" ;;
    *) echo "unknown" ;;
  esac
}

extract_fm_field() {
  local file="$1"
  local field="$2"
  awk '/^---$/{found++; next} found==1{print} found==2{exit}' "$file" 2>/dev/null \
    | grep -E "^${field}:" \
    | head -1 \
    | sed "s/^${field}:[[:space:]]*//" \
    | tr -d '"' \
    || true
}

# Extract WP numbers from related: block in frontmatter
extract_related_wps() {
  local file="$1"
  awk '
    /^---$/ { fm_count++; next }
    fm_count != 1 { next }
    /^related:/ { in_related=1; next }
    in_related && /^[a-z_]+:/ && !/^  / { in_related=0; next }
    in_related { print }
  ' "$file" 2>/dev/null \
    | grep -oE 'WP-[0-9]+' \
    || true
}

# Get relation type for a given WP number from current file's frontmatter
get_rel_type() {
  local file="$1"
  local target_num="$2"
  awk '
    /^---$/ { fm++; next }
    fm != 1 { next }
    /^related:/ { in_r=1; next }
    in_r && /^[a-z_]+:/ && !/^  / { in_r=0 }
    in_r { print }
  ' "$file" 2>/dev/null \
    | grep "WP-${target_num}" \
    | grep -oE '(depends_on|references|complementary|parent|child)' \
    | head -1 \
    || echo "body_ref"
}

grep_body_wps() {
  local file="$1"
  awk '/^---$/{fm++; next} fm<2{next} {print}' "$file" 2>/dev/null \
    | grep -oE 'WP-[0-9]+' \
    | grep -oE '[0-9]+' \
    | sort -u \
    || true
}

registry_status() {
  local num="$1"
  if [[ ! -f "$REGISTRY_FILE" ]]; then
    echo "_нет файла REGISTRY_"
    return
  fi
  local line
  line=$(grep -E "WP-${num}[^0-9]" "$REGISTRY_FILE" 2>/dev/null | head -1 || true)
  if [[ -z "$line" ]]; then
    echo "_не в реестре_"
    return
  fi
  if echo "$line" | grep -qE '~~'; then
    echo "~~done~~ (зачёркнут)"
    return
  fi
  if echo "$line" | grep -q '✅'; then
    echo "✅ done"
  elif echo "$line" | grep -q '🔄'; then
    echo "🔄 in_progress"
  elif echo "$line" | grep -q '⏳'; then
    echo "⏳ pending"
  elif echo "$line" | grep -q '📦'; then
    echo "📦 archived"
  else
    echo "$line" | grep -oE '(done|in_progress|pending|closed|open)' | head -1 || echo "_статус неизвестен_"
  fi
}

git_log_for_file() {
  local filepath="$1"
  if [[ ! -d "$STRATEGY_DIR/.git" ]]; then
    echo "_git недоступен_"
    return
  fi
  local relpath
  relpath=$(python3 -c "import os; print(os.path.relpath('$filepath', '$STRATEGY_DIR'))" 2>/dev/null || echo "$filepath")
  local commits
  commits=$(
    cd "$STRATEGY_DIR" && \
    git log -5 --oneline --since="${GIT_LOG_DAYS} days ago" -- "$relpath" 2>/dev/null || true
  )
  if [[ -z "$commits" ]]; then
    echo "_нет коммитов за ${GIT_LOG_DAYS}д_"
  else
    echo "$commits"
  fi
}

extract_open_phases() {
  local file="$1"
  awk '/^---$/{fm++; next} fm<2{next} {print}' "$file" 2>/dev/null \
    | grep -E '^\s*- \[ \]' \
    | sed 's/^\s*- \[ \] //' \
    | head -20 \
    || true
}

count_open_phases() {
  local file="$1"
  local cnt
  cnt=$(awk '/^---$/{fm++; next} fm<2{next} /- \[ \]/{count++} END{print count+0}' "$file" 2>/dev/null || echo "0")
  echo "$cnt"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  if [[ $# -lt 1 ]]; then
    log_err "Usage: wp-sync-bundle.sh WP-N (или просто N)"
    exit 1
  fi

  local input="$1"
  local wp_num
  wp_num=$(normalize_wp_num "$input")

  if ! echo "$wp_num" | grep -qE '^[0-9]+$'; then
    log_err "Неверный формат: '$input'. Ожидается WP-N или N."
    exit 1
  fi

  local wp_file
  wp_file=$(find_wp_file "$wp_num")

  if [[ -z "$wp_file" ]]; then
    log_err "WP-${wp_num}: файл не найден в inbox/ или archive/wp-contexts/"
    exit 1
  fi

  # Exit 2: parsing error (frontmatter не валиден)
  if ! validate_frontmatter "$wp_file"; then
    exit 2
  fi

  local location
  location=$(file_location_label "$wp_file")
  local basename_file
  basename_file=$(basename "$wp_file")

  local status name spawned updated
  status=$(extract_fm_field "$wp_file" "status")
  name=$(extract_fm_field "$wp_file" "name")
  spawned=$(extract_fm_field "$wp_file" "spawned")
  updated=$(extract_fm_field "$wp_file" "updated")

  [[ -z "$status" ]] && status="_не указан_"
  [[ -z "$name" ]] && name="_не указано_"
  [[ -z "$spawned" ]] && spawned="_не указан_"

  local open_phases_count
  open_phases_count=$(count_open_phases "$wp_file")

  # Collect related WPs
  local related_from_fm
  related_from_fm=$(extract_related_wps "$wp_file" | grep -oE '[0-9]+' || true)
  local related_from_body
  related_from_body=$(grep_body_wps "$wp_file")

  # Merge, deduplicate, exclude self, limit to 30
  local all_related
  all_related=$(
    { echo "$related_from_fm"; echo "$related_from_body"; } \
    | grep -E '^[0-9]+$' \
    | grep -v "^${wp_num}$" \
    | sort -nu \
    | head -30 \
    || true
  )

  # Drift accumulator (use temp file for bash 3.2 compatibility)
  local drift_file
  drift_file=$(mktemp /tmp/wp-sync-drift.XXXXXX)
  # Use ${drift_file:-} in trap to avoid unbound variable with set -u
  local _df="$drift_file"
  trap 'rm -f "${_df:-}"' EXIT

  local ref_date="${updated:-$spawned}"

  # ---------------------------------------------------------------------------
  # Output header
  # ---------------------------------------------------------------------------
  echo "# WP Sync Bundle для WP-${wp_num}"
  echo ""
  echo "## Текущий РП"
  echo "- Файл: \`${location}/${basename_file}\`"
  echo "- Название: ${name}"
  echo "- Status: ${status}"
  echo "- Spawned: ${spawned}"
  [[ -n "${updated:-}" ]] && echo "- Updated: ${updated}"
  echo "- Открытых фаз: ${open_phases_count}"
  echo ""

  if [[ "$open_phases_count" -gt 0 ]]; then
    echo "## Открытые фазы (незакрытые чекбоксы)"
    local phases_list
    phases_list=$(extract_open_phases "$wp_file")
    if [[ -n "$phases_list" ]]; then
      while IFS= read -r phase_line; do
        [[ -n "$phase_line" ]] && echo "- ${phase_line}"
      done <<< "$phases_list"
    fi
    echo ""
  fi

  # ---------------------------------------------------------------------------
  # Related WPs
  # ---------------------------------------------------------------------------
  echo "## Связанные РП"
  echo ""

  if [[ -z "$all_related" ]]; then
    echo "_Связанные РП не найдены_"
    echo ""
  else
    while IFS= read -r rnum; do
      [[ -z "$rnum" ]] && continue

      # Get relation type
      local rtype
      rtype=$(get_rel_type "$wp_file" "$rnum")

      local rfile
      rfile=$(find_wp_file "$rnum")

      echo "### WP-${rnum} (${rtype})"

      local reg_status
      reg_status=$(registry_status "$rnum")

      if [[ -z "$rfile" ]]; then
        echo "- Файл: _не найден_"
        echo "- Status (frontmatter): _н/д_"
        echo "- Status (REGISTRY): ${reg_status}"
        echo "- Recent commits (${GIT_LOG_DAYS}д): _файл не найден, skip_"
      else
        local rloc rbasename rstatus rname
        rloc=$(file_location_label "$rfile")
        rbasename=$(basename "$rfile")
        rstatus=$(extract_fm_field "$rfile" "status")
        rname=$(extract_fm_field "$rfile" "name")
        [[ -z "$rstatus" ]] && rstatus="_не указан_"
        [[ -z "$rname" ]] && rname="_не указано_"

        echo "- Файл: \`${rloc}/${rbasename}\`"
        echo "- Название: ${rname}"
        echo "- Status (frontmatter): ${rstatus}"
        echo "- Status (REGISTRY): ${reg_status}"

        echo "- Recent commits (${GIT_LOG_DAYS}д):"
        local commits
        commits=$(git_log_for_file "$rfile")
        while IFS= read -r cline; do
          [[ -n "$cline" ]] && echo "  - ${cline}"
        done <<< "$commits"

        # Drift: related is closed, but open phase references it
        local is_closed=0
        if echo "$reg_status" | grep -qiE '✅|done|closed|~~'; then
          is_closed=1
        fi
        if echo "$rstatus" | grep -qiE '^(closed|done|complete)$'; then
          is_closed=1
        fi

        if [[ $is_closed -eq 1 && "$open_phases_count" -gt 0 ]]; then
          local open_phase_with_ref
          open_phase_with_ref=$(
            awk '/^---$/{fm++; next} fm<2{next} /- \[ \]/{print}' "$wp_file" 2>/dev/null \
            | grep "WP-${rnum}" || true
          )
          if [[ -n "$open_phase_with_ref" ]]; then
            echo "DRIFT: WP-${rnum} закрыт (${reg_status}), но текущий РП имеет открытую фазу со ссылкой на него" >> "$drift_file"
          fi
        fi

        # Drift: significant commits after ref_date
        if [[ -n "$ref_date" ]] && echo "$ref_date" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
          local relpath_r
          relpath_r=$(python3 -c "import os; print(os.path.relpath('$rfile', '$STRATEGY_DIR'))" 2>/dev/null || echo "$rfile")
          local sig_commits
          sig_commits=$(
            cd "$STRATEGY_DIR" 2>/dev/null && \
            git log --oneline --after="${ref_date}" -- "$relpath_r" 2>/dev/null \
            | grep -iE '\b(LIVE|deployed|merged|DROPPED|done|complete|closed)\b' \
            | head -1 \
            || true
          )
          if [[ -n "$sig_commits" ]]; then
            echo "DRIFT: WP-${rnum} имеет коммит после ${ref_date} со словом завершения: \"${sig_commits}\"" >> "$drift_file"
          fi
        fi
      fi
      echo ""
    done <<< "$all_related"
  fi

  # ---------------------------------------------------------------------------
  # Drift summary
  # ---------------------------------------------------------------------------
  local drift_count=0
  if [[ -s "$drift_file" ]]; then
    drift_count=$(wc -l < "$drift_file" | tr -d ' ')
  fi

  echo "## Drift-сигналы"
  if [[ $drift_count -eq 0 ]]; then
    echo "- Кол-во: 0"
    echo "- Список: _нет_"
  else
    echo "- Кол-во: ${drift_count}"
    echo "- Список:"
    while IFS= read -r sig; do
      [[ -n "$sig" ]] && echo "  - ${sig}"
    done < "$drift_file"
  fi
  echo ""

  # ---------------------------------------------------------------------------
  # Recommendation
  # ---------------------------------------------------------------------------
  local related_count=0
  if [[ -n "$all_related" ]]; then
    related_count=$(echo "$all_related" | grep -cE '^[0-9]+$' || true)
  fi

  echo "## Рекомендация (для главного агента)"
  if [[ "$related_count" -le 1 && $drift_count -eq 0 ]]; then
    echo "- **Простой случай** (${related_count} связанных, нет drift) → main agent применяет diff сам"
  else
    echo "- **Нетривиальный случай** (${related_count} связанных, ${drift_count} drift-сигналов) → Task tool → sub-agent wp-sync-actualizer (Sonnet)"
    if [[ $drift_count -gt 0 ]]; then
      echo "- ⚠️ Есть drift-сигналы — требуют ручной проверки перед применением"
    fi
  fi
}

main "$@"
