#!/usr/bin/env bash
# routing: utility  deterministic=true
# see DP.SC.159, DP.ROLE.059
#
# check-setup-update-parity.sh — статический анализ парных скриптов
# Проверяет что setup.sh ↔ update.sh ↔ migrate-*.sh содержат ключевые паттерны.
#
# macOS-compatible: bash 3.x (no associative arrays).
#
# Usage:
#   bash check-setup-update-parity.sh [--config path/to/parity-contract.yaml]
#
# Exit codes:
#   0 — все пары OK
#   3 — parity mismatch
#   2 — config error
#   1 — usage error
#
# Related: WP-315 Ф4, DP.SC.125

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$REPO_ROOT/.claude/parity-contract.yaml"
VERSION="0.1.1"
ERRORS=0
WARNINGS=0

# ── Colors ───────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; NC=''
fi

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --config    Путь к parity-contract.yaml
  --version   Показать версию
  --help      Показать справку
EOF
}

# ── Parse args ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      shift; CONFIG_FILE="$1" ;;
    --version) echo "check-setup-update-parity v$VERSION"; exit 0 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
  shift
done

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: Config not found: $CONFIG_FILE" >&2
  exit 2
fi

# ── macOS-compatible storage (no associative arrays) ─────────────────────
TMPDIR=$(mktemp -d)
trap "rm -rf '$TMPDIR'" EXIT

# Храним данные в файлах:
# $TMPDIR/pairs/<name>/scripts — список скриптов
# $TMPDIR/pairs/<name>/patterns — список паттернов
# $TMPDIR/patterns/<id>/regex — regex
# $TMPDIR/patterns/<id>/required — true/false

mkdir -p "$TMPDIR/pairs" "$TMPDIR/patterns"

# ── YAML parser (state machine, bash 3 compatible) ───────────────────────
CURRENT_PAIR=""
CURRENT_PATTERN=""
IN_PATTERNS=0
IN_SCRIPTS=0

while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%%#*}"
  line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

  [[ -z "$line" ]] && continue

  if [[ "$line" == "pairs:" ]]; then continue; fi

  if [[ "$line" =~ ^-[[:space:]]+name:[[:space:]]*\"(.+)\" ]]; then
    CURRENT_PAIR="${BASH_REMATCH[1]}"
    mkdir -p "$TMPDIR/pairs/$CURRENT_PAIR"
    touch "$TMPDIR/pairs/$CURRENT_PAIR/scripts"
    touch "$TMPDIR/pairs/$CURRENT_PAIR/patterns"
    IN_PATTERNS=0; IN_SCRIPTS=0
    continue
  fi

  if [[ "$line" =~ ^-[[:space:]]+name:[[:space:]]*(.+) ]]; then
    CURRENT_PAIR="${BASH_REMATCH[1]}"
    mkdir -p "$TMPDIR/pairs/$CURRENT_PAIR"
    touch "$TMPDIR/pairs/$CURRENT_PAIR/scripts"
    touch "$TMPDIR/pairs/$CURRENT_PAIR/patterns"
    IN_PATTERNS=0; IN_SCRIPTS=0
    continue
  fi

  if [[ "$line" == "scripts:" ]]; then
    IN_SCRIPTS=1; IN_PATTERNS=0; continue
  fi
  if [[ "$line" == "patterns:" ]]; then
    IN_PATTERNS=1; IN_SCRIPTS=0; continue
  fi

  if [[ "$IN_SCRIPTS" -eq 1 && "$line" =~ ^-[[:space:]]+\"(.+)\" ]]; then
    echo "${BASH_REMATCH[1]}" >> "$TMPDIR/pairs/$CURRENT_PAIR/scripts"
    continue
  fi

  if [[ "$IN_PATTERNS" -eq 1 && "$line" =~ ^-[[:space:]]+id:[[:space:]]*(.+) ]]; then
    CURRENT_PATTERN="${BASH_REMATCH[1]}"
    echo "$CURRENT_PATTERN" >> "$TMPDIR/pairs/$CURRENT_PAIR/patterns"
    mkdir -p "$TMPDIR/patterns/$CURRENT_PATTERN"
    echo "true" > "$TMPDIR/patterns/$CURRENT_PATTERN/required"
    continue
  fi

  if [[ "$IN_PATTERNS" -eq 1 && "$line" =~ ^regex:[[:space:]]*(.+) ]]; then
    regex="${BASH_REMATCH[1]}"
    # Single quotes are the YAML-valid way to write a backslash regex (issue #1006): "\." is an
    # invalid escape in a double-quoted scalar and a strict YAML parser rejects the file.
    case "$regex" in
      \'*\') regex="${regex#\'}"; regex="${regex%\'}" ;;
      *) regex="${regex#\"}"; regex="${regex%\"}" ;;
    esac
    echo "$regex" > "$TMPDIR/patterns/$CURRENT_PATTERN/regex"
    continue
  fi

  if [[ "$IN_PATTERNS" -eq 1 && "$line" =~ ^required_in_both:[[:space:]]*(false|False|FALSE) ]]; then
    echo "false" > "$TMPDIR/patterns/$CURRENT_PATTERN/required"
    continue
  fi
done < "$CONFIG_FILE"

# ── Check each pair ──────────────────────────────────────────────────────
echo "=== Parity Check v${VERSION} ==="
echo "Config: $CONFIG_FILE"
echo ""

for pair_dir in "$TMPDIR/pairs/"*; do
  [[ -d "$pair_dir" ]] || continue
  pair_name="$(basename "$pair_dir")"
  echo "Pair: $pair_name"

  script_file="$pair_dir/scripts"
  pattern_file="$pair_dir/patterns"

  if [[ ! -s "$script_file" ]]; then
    echo -e "  ${YELLOW}WARN:${NC} no scripts defined"
    ((WARNINGS++)) || true
    continue
  fi

  # Читаем скрипты в массив (bash 3 compatible)
  scripts=()
  while IFS= read -r s; do
    [[ -n "$s" ]] && scripts+=("$s")
  done < "$script_file"

  if [[ ${#scripts[@]} -lt 2 ]]; then
    echo -e "  ${YELLOW}WARN:${NC} less than 2 scripts, skipping"
    ((WARNINGS++)) || true
    continue
  fi

  # Читаем паттерны
  patterns=()
  while IFS= read -r p; do
    [[ -n "$p" ]] && patterns+=("$p")
  done < "$pattern_file"

  for pattern_id in "${patterns[@]}"; do
    regex_file="$TMPDIR/patterns/$pattern_id/regex"
    required_file="$TMPDIR/patterns/$pattern_id/required"

    if [[ ! -f "$regex_file" ]]; then
      echo -e "  ${YELLOW}WARN:${NC} pattern '$pattern_id' has no regex"
      ((WARNINGS++)) || true || true
      continue
    fi

    regex="$(cat "$regex_file")"
    required="$(cat "$required_file")"

    all_match=true
    any_match=false
    missing_scripts=""

    for script_rel in "${scripts[@]}"; do
      script_path="$REPO_ROOT/$script_rel"
      if [[ ! -f "$script_path" ]]; then
        echo -e "  ${YELLOW}WARN:${NC} $script_rel not found"
        ((WARNINGS++)) || true || true || true
        all_match=false
        continue
      fi

      if grep -qE -e "$regex" "$script_path" 2>/dev/null; then
        any_match=true
      else
        all_match=false
        missing_scripts="$missing_scripts $script_rel"
      fi
    done

    if [[ "$required" == "true" ]]; then
      if $all_match; then
        echo -e "  ${GREEN}OK:${NC}  [$pattern_id] all scripts match"
      else
        echo -e "  ${RED}FAIL:${NC} [$pattern_id] missing in:$missing_scripts"
        ((ERRORS++)) || true
      fi
    else
      if $all_match || ! $any_match; then
        echo -e "  ${GREEN}OK:${NC}  [$pattern_id] (optional) consistent"
      else
        echo -e "  ${YELLOW}WARN:${NC} [$pattern_id] partial match (optional but inconsistent)"
        ((WARNINGS++)) || true || true || true
      fi
    fi
  done
done

echo ""
if [[ "$ERRORS" -gt 0 ]]; then
  echo -e "${RED}RESULT: $ERRORS error(s), $WARNINGS warning(s)${NC}"
  exit 3
elif [[ "$WARNINGS" -gt 0 ]]; then
  echo -e "${YELLOW}RESULT: 0 errors, $WARNINGS warning(s)${NC}"
  exit 0
else
  echo -e "${GREEN}RESULT: all pairs OK${NC}"
  exit 0
fi
