#!/usr/bin/env bash
# wp-phase-digest.sh — детерминированный дайджест состояния фаз карточки РП
# Контракт: вход WP-N (или N) → stdout `status=...` + `phase_digest=...` +
#           `phase_count=...`, exit 0/1
#
# Зачем: пир-сессия WP-561 2026-09-03-19 (Kimi+Codex) — snapshot-механизм
# "handoff_snapshot" (при close агент записывает {ref, observed_status,
# observed_phase_state}, при следующем open wp-sync-bundle.sh сверяет)
# требует ОДНОГО И ТОГО ЖЕ парсера на обоих концах, иначе два независимых
# способа читать один файл разойдутся сами по себе — Codex, ход 1 раунда 1.
# Этот скрипт — единственный источник дайджеста; закрывающий агент вызывает
# его напрямую (руками, для записи снимка), wp-sync-bundle.sh вызывает его
# же (для сверки при открытии).
#
# Дайджест — НЕ счётчик открытых фаз (тот слеп к переоткрытию/смене статуса
# при том же числе фаз, Codex ход 1) — это хеш нормализованной
# последовательности "маркер+текст" всех строк-фаз в файле (закрытых и
# открытых), либо (для structured-phases картотек) "id+status" всех записей.
#
# Compatible: bash 3.2+ (macOS), bash 4+ (Linux)

set -euo pipefail

IWE_WORKSPACE="${IWE_WORKSPACE:-$HOME/IWE}"
GOV_REPO="${IWE_GOVERNANCE_REPO:-governance}"
# Portability (template install): same fallback as wp-sync-bundle.sh -- any
# repo with docs/WP-REGISTRY.md when the configured/default one has none.
if [[ ! -f "$IWE_WORKSPACE/$GOV_REPO/docs/WP-REGISTRY.md" ]]; then
  for cand in "$IWE_WORKSPACE"/*/; do
    if [[ -f "${cand}docs/WP-REGISTRY.md" ]]; then GOV_REPO=$(basename "$cand"); break; fi
  done
fi
STRATEGY_DIR="$IWE_WORKSPACE/$GOV_REPO"
INBOX_DIR="$STRATEGY_DIR/inbox"
ARCHIVE_DIR="$STRATEGY_DIR/archive/wp-contexts"

log_err() { echo "[ERROR] $*" >&2; }

# Тот же поиск, что find_wp_file() в wp-sync-bundle.sh (WP-434: папочная
# конвенция первична) — сознательно не source'им весь wp-sync-bundle.sh
# (он объявляет main() и запускает себя), копия одной функции безопаснее.
find_wp_file() {
  local num="$1"
  local found=""
  if [[ -d "$INBOX_DIR" ]]; then
    found=$(find "$INBOX_DIR" -maxdepth 2 -path "*/WP-${num}/WP-${num}.md" 2>/dev/null | head -1 || true)
    [[ -z "$found" ]] && found=$(grep -rl "^wp: ${num}$" "$INBOX_DIR" 2>/dev/null | head -1 || true)
    [[ -z "$found" ]] && found=$(find "$INBOX_DIR" -maxdepth 1 -name "WP-${num}.md" 2>/dev/null | head -1 || true)
  fi
  if [[ -z "$found" && -d "$ARCHIVE_DIR" ]]; then
    found=$(find "$ARCHIVE_DIR" -maxdepth 2 -path "*/WP-${num}/WP-${num}.md" 2>/dev/null | head -1 || true)
    [[ -z "$found" ]] && found=$(grep -rl "^wp: ${num}$" "$ARCHIVE_DIR" 2>/dev/null | head -1 || true)
  fi
  echo "$found"
}

extract_fm_field() {
  local file="$1" field="$2"
  awk '/^---$/{found++; next} found==1{print} found==2{exit}' "$file" 2>/dev/null \
    | grep -E "^${field}:" | head -1 | sed "s/^${field}:[[:space:]]*//" | tr -d '"' || true
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

# Все записи structured-phases (id+status), не только открытые — в отличие
# от extract_structured_open_phases() в wp-sync-bundle.sh, которая по
# назначению фильтрует на pending/in_progress/blocked для отображения.
extract_all_structured_phases() {
  local file="$1"
  awk '
    function emit() { if (id != "") print id "|" status }
    /^---$/ { fm++; if (fm == 2) exit; next }
    fm != 1 { next }
    /^phases:[[:space:]]*$/ { in_phases=1; next }
    in_phases && /^[A-Za-z_][A-Za-z0-9_-]*:/ { emit(); in_phases=0; id=""; status=""; next }
    !in_phases { next }
    /^- id:[[:space:]]*/ {
      emit(); id=$0; sub(/^- id:[[:space:]]*/, "", id); status=""; next
    }
    /^  status:[[:space:]]*/ {
      status=$0; sub(/^  status:[[:space:]]*/, "", status)
      sub(/[[:space:]]+#.*/, "", status); sub(/^[[:space:]]+/, "", status); sub(/[[:space:]]+$/, "", status)
      next
    }
    END { emit() }
  ' "$file" 2>/dev/null || true
}

# Все строки-чекбоксы тела карточки (после закрывающего --- фронтматтера),
# нормализованные к "маркер|текст" — [x]/[ ]/[→] и вычеркнутый ~~[x]~~
# (см. .claude/rules/formatting.md) сводятся к одному маркеру 'x'.
extract_all_checkbox_lines() {
  local file="$1"
  awk '/^---$/{fm++; next} fm<2{next} {print}' "$file" 2>/dev/null \
    | grep -E '^\s*-\s*(~~)?\[.\](~~)?\s' \
    | sed -E 's/^\s*-\s*~~\s*\[(.)\]\s*(.*)~~\s*$/\1|\2/; s/^\s*-\s*\[(.)\]\s*/\1|/' \
    | sed -E 's/[[:space:]]+/ /g; s/^[[:space:]]+//; s/[[:space:]]+$//' \
    || true
}

digest_of() {
  # sha256 в 12 hex-символах — достаточно для detect-changed, не для
  # security-инварианта; shasum есть на macOS и Linux по умолчанию.
  shasum -a 256 2>/dev/null | cut -c1-12 || echo "nodigest"
}

main() {
  if [[ $# -lt 1 ]]; then
    log_err "Usage: wp-phase-digest.sh WP-N (или просто N)"
    exit 1
  fi
  local input="$1"
  local num="${input#WP-}"
  num="${num#wp-}"

  local wp_file
  wp_file=$(find_wp_file "$num")
  if [[ -z "$wp_file" ]]; then
    log_err "WP-${num} не найден (ни inbox, ни archive)"
    exit 1
  fi

  local status
  status=$(extract_fm_field "$wp_file" "status")
  [[ -z "$status" ]] && status="unknown"

  local phase_lines phase_count phase_digest
  if has_structured_phases "$wp_file"; then
    phase_lines=$(extract_all_structured_phases "$wp_file")
  else
    phase_lines=$(extract_all_checkbox_lines "$wp_file")
  fi
  phase_count=$(printf '%s\n' "$phase_lines" | grep -c . || true)
  phase_digest=$(printf '%s\n' "$phase_lines" | digest_of)

  echo "status=${status}"
  echo "phase_digest=${phase_digest}"
  echo "phase_count=${phase_count}"
}

main "$@"
