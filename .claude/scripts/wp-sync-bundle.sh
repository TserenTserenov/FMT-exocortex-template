#!/usr/bin/env bash
# wp-sync-bundle.sh — детерминированный bundler контекста РП для sync-фазы WP Gate
# Контракт: вход WP-N или N → stdout markdown bundle, exit 0/1/2
# see WP-294
# Compatible: bash 3.2+

set -euo pipefail

# ---------------------------------------------------------------------------
# Config (with resilience fallback — see WP-294)
# ---------------------------------------------------------------------------
IWE_WORKSPACE="${IWE_WORKSPACE:-$HOME/IWE}"
if [[ ! -d "$IWE_WORKSPACE" ]]; then
  echo "[WARN] IWE_WORKSPACE=$IWE_WORKSPACE не существует, fallback на $HOME/IWE" >&2
  IWE_WORKSPACE="$HOME/IWE"
fi

GOV_REPO="${IWE_GOVERNANCE_REPO:-governance}"
# Resilience: если GOV_REPO задан извне, но в нём нет WP-REGISTRY.md — ищем любой repo с ним
if [[ ! -f "$IWE_WORKSPACE/$GOV_REPO/docs/WP-REGISTRY.md" ]]; then
  found_repo=""
  for cand in "$IWE_WORKSPACE"/*/; do
    if [[ -f "${cand}docs/WP-REGISTRY.md" ]]; then
      found_repo=$(basename "$cand")
      break
    fi
  done
  if [[ -n "$found_repo" ]]; then
    echo "[WARN] IWE_GOVERNANCE_REPO=$GOV_REPO не содержит WP-REGISTRY.md, fallback на $found_repo" >&2
    GOV_REPO="$found_repo"
  fi
fi
if [[ ! -f "$IWE_WORKSPACE/$GOV_REPO/docs/WP-REGISTRY.md" ]]; then
  echo "[ERROR] Governance repo с WP-REGISTRY.md не найден в $IWE_WORKSPACE" >&2
  exit 1
fi

STRATEGY_DIR="$IWE_WORKSPACE/$GOV_REPO"
INBOX_DIR="$STRATEGY_DIR/inbox"
ARCHIVE_DIR="$STRATEGY_DIR/archive/wp-contexts"
REGISTRY_FILE="$STRATEGY_DIR/docs/WP-REGISTRY.md"
GIT_LOG_DAYS="${WP_SYNC_GIT_DAYS:-14}"

# ---------------------------------------------------------------------------
# Audit log
# ---------------------------------------------------------------------------
log_sync() {
  local wp_num="${1:-unknown}"
  local result="${2:-unknown}"
  local reason="${3:-}"
  local logfile="$IWE_WORKSPACE/.claude/state/wp-sync.log"
  mkdir -p "$(dirname "$logfile")"
  echo "$(date '+%Y-%m-%d %H:%M:%S') | WP-${wp_num} | ${result} | ${reason}" >> "$logfile"
}

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

wp_path_label() {
  local filepath="$1"
  case "$filepath" in
    "$STRATEGY_DIR"/*) echo "${filepath#"$STRATEGY_DIR"/}" ;;
    *) echo "$filepath" ;;
  esac
}

find_wp_file() {
  local num="$1"
  local found=""

  if [[ -d "$INBOX_DIR" ]]; then
    # WP-434: a canonical folder card wins over stale flat duplicates.
    found=$(find "$INBOX_DIR" -maxdepth 2 -path "*/WP-${num}/WP-${num}.md" 2>/dev/null | head -1 || true)
    if [[ -z "$found" ]]; then
      found=$(grep -rl "^wp: ${num}$" "$INBOX_DIR" 2>/dev/null | head -1 || true)
    fi
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
    found=$(find "$ARCHIVE_DIR" -maxdepth 2 -path "*/WP-${num}/WP-${num}.md" 2>/dev/null | head -1 || true)
    if [[ -z "$found" ]]; then
      found=$(grep -rl "^wp: ${num}$" "$ARCHIVE_DIR" 2>/dev/null | head -1 || true)
    fi
    if [[ -z "$found" ]]; then
      # A numeric prefix is not an ID boundary: `WP-46*.md` also matches
      # `WP-469-*.md`.  Only the exact flat filename or a hyphenated slug is
      # a valid legacy archive candidate for this WP.
      found=$(find "$ARCHIVE_DIR" -maxdepth 1 \( -name "WP-${num}.md" -o -name "WP-${num}-*.md" \) 2>/dev/null | sort | head -1 || true)
    fi
  fi

  echo "$found"
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

# issue #473: колонка статуса регистра — по шапке `| # | ... |`, не по
# жёсткой позиции (совпадает по духу с find_header_columns() в
# scripts/build-active-wp.py: разные реестры называют/переставляют колонки).
registry_status_column() {
  local header
  header=$(grep -E '^\|[[:space:]]*#[[:space:]]*\|' "$REGISTRY_FILE" 2>/dev/null | head -1)
  [[ -z "$header" ]] && return 1
  awk -F'|' -v h="$header" 'BEGIN {
    n = split(h, cells, "|")
    for (i = 1; i <= n; i++) {
      c = cells[i]; gsub(/^[ \t]+|[ \t]+$/, "", c)
      lc = tolower(c)
      if (lc == "статус" || lc == "ст") { print i; exit }
    }
  }'
}

registry_status() {
  local num="$1"
  # Найдено пир-сессией с Codex (ход 3): единственный вызывающий (строка ~514)
  # сейчас всегда передаёт голое число (та же инвариантность проверяется
  # соседним `grep -cE '^[0-9]+$'` на строке ~608), но публичная функция не
  # обязана полагаться на дисциплину вызывающего — "WP-47" тихо не находился бы.
  num="${num#WP-}"
  num="${num#wp-}"
  if [[ ! "$num" =~ ^[0-9]{1,4}$ ]]; then
    echo "_некорректный номер РП: ${1}_"
    return
  fi
  if [[ ! -f "$REGISTRY_FILE" ]]; then
    echo "_нет файла REGISTRY_"
    return
  fi
  # issue #473: раньше строка искалась через `grep "WP-${num}[^0-9]"` —
  # подстрока, которая срабатывает и на прозу ЧУЖИХ строк (например,
  # "открыт как спин-офф WP-47" в статусе WP-49 возвращал статус WP-49 при
  # запросе WP-47). Строка опознаётся по СВОЕЙ первой ячейке (номер РП),
  # тем же приёмом, что ROW_RE в build-active-wp.py.
  local line
  line=$(grep -E "^\|[[:space:]]*(~~)?(\*\*)?${num}(\*\*)?(~~)?[[:space:]]*\|" "$REGISTRY_FILE" 2>/dev/null | head -1 || true)
  if [[ -z "$line" ]]; then
    echo "_не в реестре_"
    return
  fi
  if echo "$line" | grep -qE '~~'; then
    echo "~~done~~ (зачёркнут)"
    return
  fi
  local status_col status_cell
  status_col=$(registry_status_column)
  if [[ -z "$status_col" ]]; then
    echo "_колонка статуса не найдена в шапке реестра_"
    return
  fi
  # Статус берётся из СВОЕЙ ячейки, не грепом эмодзи по всей строке —
  # эмодзи в описании соседней колонки раньше мог перебить вердикт.
  status_cell=$(echo "$line" | awk -F'|' -v col="$status_col" '{ v=$col; gsub(/^[ \t]+|[ \t]+$/, "", v); print v }')
  if echo "$status_cell" | grep -q '✅'; then
    echo "✅ done"
  elif echo "$status_cell" | grep -q '🔄'; then
    echo "🔄 in_progress"
  elif echo "$status_cell" | grep -q '⏳'; then
    echo "⏳ pending"
  elif echo "$status_cell" | grep -q '📦'; then
    echo "📦 archived"
  elif echo "$status_cell" | grep -q '⏹'; then
    echo "⏹ снят"
  elif echo "$status_cell" | grep -q '🔁'; then
    echo "🔁 свёрнут в спринт"
  else
    echo "$status_cell" | grep -oE '(done|in_progress|pending|closed|open)' | head -1 || echo "_статус неизвестен_"
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
  if has_structured_phases "$file"; then
    extract_structured_open_phases "$file" | head -20
  else
    awk '/^---$/{fm++; next} fm<2{next} {print}' "$file" 2>/dev/null \
      | grep -E '^\s*- \[ \]' \
      | sed 's/^\s*- \[ \] //' \
      | head -20 \
      || true
  fi
}

count_open_phases() {
  local file="$1"
  local cnt
  if has_structured_phases "$file"; then
    cnt=$(extract_structured_open_phases "$file" | wc -l | tr -d ' ')
  else
    cnt=$(awk '/^---$/{fm++; next} fm<2{next} /- \[ \]/{count++} END{print count+0}' "$file" 2>/dev/null || echo "0")
  fi
  echo "$cnt"
}

has_structured_phases() {
  local file="$1"
  awk '
    /^---$/ { fm++; if (fm == 2) exit; next }
    fm != 1 { next }
    /^phases:[[:space:]]*$/ { in_phases=1; next }
    in_phases && /^- id:[[:space:]]*/ { found=1; exit }
    END { exit(found ? 0 : 1) }
  ' "$file" 2>/dev/null
}

extract_structured_open_phases() {
  local file="$1"
  awk '
    function emit() {
      if (id != "" && (status == "pending" || status == "in_progress" || status == "blocked")) {
        print id " (" status ")"
      }
    }
    /^---$/ { fm++; if (fm == 2) exit; next }
    fm != 1 { next }
    /^phases:[[:space:]]*$/ { in_phases=1; next }
    in_phases && /^[A-Za-z_][A-Za-z0-9_-]*:/ {
      emit(); in_phases=0; id=""; status=""; next
    }
    !in_phases { next }
    /^- id:[[:space:]]*/ {
      emit()
      id=$0
      sub(/^- id:[[:space:]]*/, "", id)
      status=""
      next
    }
    /^  status:[[:space:]]*/ {
      status=$0
      sub(/^  status:[[:space:]]*/, "", status)
      sub(/[[:space:]]+#.*/, "", status)
      sub(/^[[:space:]]+/, "", status)
      sub(/[[:space:]]+$/, "", status)
      next
    }
    END { emit() }
  ' "$file" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  if [[ $# -lt 1 ]]; then
    log_err "Usage: wp-sync-bundle.sh WP-N (или просто N) [--self-test]"
    exit 1
  fi

  local input="$1"

  # Self-test mode (diagnostic — see WP-294 Ф7)
  if [[ "$input" == "--self-test" ]]; then
    echo "=== WP Sync Bundle Self-Test ==="
    echo "IWE_WORKSPACE: $IWE_WORKSPACE"
    echo "GOV_REPO: $GOV_REPO"
    echo "STRATEGY_DIR: $STRATEGY_DIR"
    if [[ -f "$REGISTRY_FILE" ]]; then
      echo "REGISTRY_FILE: OK"
    else
      echo "REGISTRY_FILE: MISSING"
      exit 1
    fi
    # Find any real WP from inbox instead of hardcoded number
    local test_num=""
    if [[ -d "$INBOX_DIR" ]]; then
      local first_wp
      first_wp=$(find "$INBOX_DIR" -maxdepth 1 -name "WP-*.md" 2>/dev/null | sort | head -1 || true)
      if [[ -n "$first_wp" ]]; then
        test_num=$(basename "$first_wp" | grep -oE '^WP-[0-9]+' | grep -oE '[0-9]+' || true)
      fi
    fi
    if [[ -z "$test_num" ]]; then
      test_num=$(grep -oE 'WP-[0-9]+' "$REGISTRY_FILE" 2>/dev/null | head -1 | grep -oE '[0-9]+' || true)
    fi
    if [[ -z "$test_num" ]]; then
      echo "WP lookup: SKIP (no WP files found in inbox or registry)"
      exit 0
    fi
    local test_file
    test_file=$(find_wp_file "$test_num")
    if [[ -n "$test_file" ]]; then
      echo "WP-${test_num} lookup: OK ($test_file)"
      exit 0
    else
      echo "WP-${test_num} lookup: FAIL"
      exit 1
    fi
  fi

  local wp_num
  wp_num=$(normalize_wp_num "$input")

  if ! echo "$wp_num" | grep -qE '^[0-9]+$'; then
    log_err "Неверный формат: '$input'. Ожидается WP-N или N."
    exit 1
  fi

  log_sync "$wp_num" "START" ""

  local wp_file
  wp_file=$(find_wp_file "$wp_num")

  if [[ -z "$wp_file" ]]; then
    log_err "WP-${wp_num}: файл не найден в inbox/ или archive/wp-contexts/"
    log_sync "$wp_num" "FAIL" "file_not_found"
    exit 1
  fi

  # Exit 2: parsing error (frontmatter не валиден)
  if ! validate_frontmatter "$wp_file"; then
    log_sync "$wp_num" "FAIL" "parse_error"
    exit 2
  fi

  local wp_path
  wp_path=$(wp_path_label "$wp_file")

  local status name spawned updated created last_session
  status=$(extract_fm_field "$wp_file" "status")
  name=$(extract_fm_field "$wp_file" "name")
  spawned=$(extract_fm_field "$wp_file" "spawned")
  updated=$(extract_fm_field "$wp_file" "updated")
  # F19 (REVIEW-ARCHITECTURE.md, WP-503 Ф6.6 план): карточки без `updated:` в
  # frontmatter (created вручную, не auto-touched) молча выключали drift-детектор
  # №2 ("коммиты завершения после ref_date") — сам ref_date оставался пустым для
  # них, включая WP-503. `created`/`last_session` расширяют цепочку без изменения
  # приоритета уже используемых полей (updated по-прежнему первый — самый свежий
  # признак реальной активности карточки).
  created=$(extract_fm_field "$wp_file" "created")
  last_session=$(extract_fm_field "$wp_file" "last_session")

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

  local ref_date="${updated:-${last_session:-${spawned:-$created}}}"

  # ---------------------------------------------------------------------------
  # Output header
  # ---------------------------------------------------------------------------
  echo "# WP Sync Bundle для WP-${wp_num}"
  echo ""
  echo "## Текущий РП"
  echo "- Файл: \`${wp_path}\`"
  echo "- Название: ${name}"
  echo "- Status: ${status}"
  echo "- Spawned: ${spawned}"
  [[ -n "${updated:-}" ]] && echo "- Updated: ${updated}"
  echo "- Открытых фаз: ${open_phases_count}"
  echo ""

  if [[ "$open_phases_count" -gt 0 ]]; then
    echo "## Открытые фазы"
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
        local rpath rstatus rname
        rpath=$(wp_path_label "$rfile")
        rstatus=$(extract_fm_field "$rfile" "status")
        rname=$(extract_fm_field "$rfile" "name")
        [[ -z "$rstatus" ]] && rstatus="_не указан_"
        [[ -z "$rname" ]] && rname="_не указано_"

        echo "- Файл: \`${rpath}\`"
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

  log_sync "$wp_num" "SUCCESS" "related=${related_count} drift=${drift_count}"
}

main "$@"
