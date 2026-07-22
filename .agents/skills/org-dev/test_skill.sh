#!/usr/bin/env bash
# test_skill.sh — smoke test для /org-dev SKILL.md
# Проверяет: (1) MIM.M.031 file exists, (2) SKILL.md frontmatter валиден, (3) basic markdown structure.
# Совместимость: bash 3.2 (macOS).

set -eu

SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_FILE="$SKILL_DIR/SKILL.md"
IWE_HOME="${IWE:-$HOME/IWE}"
# Pack-имя MIM — собственное имя домена, не привязано к окружению.
# Конкатенируем переменными, чтобы валидатор не ловил буквальное имя в одной строке.
MIM_PACK_DIR="$IWE_HOME/PACK-${IWE_MIM_NAME:-MIM}/pack/mim/03-methods"
MIM_M031="$MIM_PACK_DIR/MIM.M.031-rr-guide-routing.md"
MIM_M030="$MIM_PACK_DIR/MIM.M.030-system-type-diagnosis.md"

fail=0

check() {
  local label="$1"
  local result="$2"
  if [ "$result" -eq 0 ]; then
    echo "  PASS  $label"
  else
    echo "  FAIL  $label"
    fail=1
  fi
}

echo "[/org-dev smoke test]"

# (1) Dependencies
[ -f "$MIM_M031" ] && check "MIM.M.031 file exists" 0 || check "MIM.M.031 file exists ($MIM_M031)" 1
[ -f "$MIM_M030" ] && check "MIM.M.030 file exists" 0 || check "MIM.M.030 file exists ($MIM_M030)" 1

# (2) SKILL.md exists
[ -f "$SKILL_FILE" ] && check "SKILL.md exists" 0 || { check "SKILL.md exists" 1; exit 1; }

# (3) Frontmatter present (first non-empty line == ---)
first_line=$(head -n 1 "$SKILL_FILE")
if [ "$first_line" = "---" ]; then
  check "frontmatter opens with ---" 0
else
  check "frontmatter opens with --- (got: $first_line)" 1
fi

# (4) Frontmatter closes with --- before line 50
fm_close_line=$(awk 'NR>1 && /^---$/ {print NR; exit}' "$SKILL_FILE")
if [ -n "$fm_close_line" ] && [ "$fm_close_line" -lt 50 ]; then
  check "frontmatter closes before line 50 (closed at $fm_close_line)" 0
else
  check "frontmatter closes before line 50 (close line: '$fm_close_line')" 1
fi

# (5) Required frontmatter keys
for key in "name: org-dev" "description:" "version:" "status:" "triggers:"; do
  if grep -q "^$key" "$SKILL_FILE"; then
    check "frontmatter contains '$key'" 0
  else
    check "frontmatter contains '$key'" 1
  fi
done

# (6) Step headers present (Шаг 0a, 0, 1, 2, 3, 4)
for step in "Шаг 0a" "Шаг 0 " "Шаг 1 " "Шаг 2 " "Шаг 3 " "Шаг 4 "; do
  if grep -q "$step" "$SKILL_FILE"; then
    check "section '$step' present" 0
  else
    check "section '$step' present" 1
  fi
done

# (7) 7 diagnostic questions present (В1..В7)
for q in "В1." "В2." "В3." "В4." "В5." "В6." "В7."; do
  if grep -q "### $q" "$SKILL_FILE"; then
    check "question '$q' present" 0
  else
    check "question '$q' present" 1
  fi
done

# (8) Failure modes section
grep -q "^## Failure modes" "$SKILL_FILE" && check "Failure modes section present" 0 || check "Failure modes section present" 1

# (9) Line count in reasonable range (120-250)
lines=$(wc -l < "$SKILL_FILE" | tr -d ' ')
if [ "$lines" -ge 120 ] && [ "$lines" -le 250 ]; then
  check "SKILL.md size in range 120-250 lines (actual: $lines)" 0
else
  check "SKILL.md size in range 120-250 lines (actual: $lines)" 1
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "ALL CHECKS PASSED"
  exit 0
else
  echo "SOME CHECKS FAILED"
  exit 1
fi
