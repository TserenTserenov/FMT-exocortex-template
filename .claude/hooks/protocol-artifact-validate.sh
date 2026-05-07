#!/bin/bash
# Protocol Artifact Validation Hook
# Event: PreToolUse (matcher: Bash)
# Intercepts `git commit` in protocol-managed repos to validate artifacts.
# Returns block decision if artifact fails validation.
# Read-only: only returns JSON, does not modify files.
#
# Validated artifacts:
#   - DayPlan: 11 required sections + collapsible + non-empty key sections + carry-over
#   - DayClose: итоги, carry-over (day-close protocol) [future]
#
# Parameterized: sections list is a variable, not hardcoded per format.
# Ф3 WP-229: добавлены проверки структуры (collapsible, непустые секции, мультипликатор, carry-over)

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

# Governance-репо: из env $IWE_GOVERNANCE_REPO (по умолчанию DS-strategy).
# Workspace: $IWE_WORKSPACE или $IWE_ROOT (синонимы), default ~/IWE.
GOV_REPO="${IWE_GOVERNANCE_REPO:-DS-strategy}"
WORKSPACE="${IWE_WORKSPACE:-${IWE_ROOT:-$HOME/IWE}}"
GOV_PATH="$WORKSPACE/$GOV_REPO"

# R4.5 fix (WP-273): trigger ТОЛЬКО по staged files, НЕ по тексту команды.
# Старая логика грепала TOOL_INPUT на «DayPlan|day-close» — false positive
# на любой коммит файла `day-close/SKILL.md` или сообщения с «day-close».
# Принцип: «hook trigger = artifact (staged file), не TOOL_INPUT текст» (memory/hooks-design.md).
STAGED=$(cd "$GOV_PATH" 2>/dev/null && git diff --cached --name-only 2>/dev/null || echo "")
if ! echo "$STAGED" | grep -qE '^current/DayPlan.*\.md$|^current/WeekPlan.*\.md$'; then
  echo '{}'
  exit 0
fi

# --- DayPlan Validation (выполняется только если DayPlan-файл существует) ---
DAYPLAN=$(ls "$GOV_PATH"/current/DayPlan\ *.md 2>/dev/null | head -1)
MISSING=()
ERRORS=()

if [ -n "$DAYPLAN" ]; then

# Required sections (parameterized — update this list when format changes).
# Scout раздел опционален: проверяется отдельно ниже (см. блок "Scout").
SECTIONS=(
  "План на сегодня"
  "Календарь"
  "IWE за ночь"
  "Разбор заметок"
  "Итоги вчера"
)

for section in "${SECTIONS[@]}"; do
  if ! grep -q "$section" "$DAYPLAN"; then
    MISSING+=("$section")
  fi
done

# Check mandatory format elements

# --- Ф3 Check 1: collapsible <details> блоки ---
DETAILS_COUNT=$(grep -c '<details' "$DAYPLAN" 2>/dev/null || true); DETAILS_COUNT=${DETAILS_COUNT:-0}
if [ "$DETAILS_COUNT" -lt 3 ]; then
  ERRORS+=("Collapsible секции (<details>) < 3 найдено: $DETAILS_COUNT. DayPlan должен иметь collapsible-структуру")
fi

# --- Ф3 Check 2: непустые обязательные секции ---
# Календарь: должна содержать хотя бы одну строку с | (таблица) или "нет событий"
CALENDAR_CONTENT=$(awk '/Календарь/,/^<\/details>/' "$DAYPLAN" 2>/dev/null | wc -l || echo 0)
if [ "$CALENDAR_CONTENT" -lt 3 ]; then
  ERRORS+=("Секция 'Календарь' пустая или слишком короткая (${CALENDAR_CONTENT} строк)")
fi

# Scout: проверяется только если секция вообще присутствует в DayPlan (опциональный компонент,
# зависит от DS-agent-workspace). Если секции нет — Scout не сконфигурирован, валидатор не блокирует.
if grep -q "Наработки Scout" "$DAYPLAN" 2>/dev/null; then
  if ! awk '/Наработки Scout/,/^<\/details>/' "$DAYPLAN" 2>/dev/null | grep -iqE 'наход|capture|статус|нет|find|disabled|not configured'; then
    ERRORS+=("Секция 'Наработки Scout' пустая (допустимы маркеры 'нет находок', 'disabled', 'not configured')")
  fi
fi

# --- Ф3 Check 3: формат мультипликатора ---
if ! grep -qE "~[0-9]+\.?[0-9]*x" "$DAYPLAN"; then
  ERRORS+=("Мультипликатор не найден — нужен формат '~N.Nx' в строке бюджета")
fi

# --- Ф3 Check 4 (legacy): mandatory check и бюджет ---
if ! grep -qi "mandatory" "$DAYPLAN"; then
  ERRORS+=("Mandatory check (WP-7 + контентный РП) не найден")
fi

if ! grep -qE "~[0-9]+\.?[0-9]*h РП" "$DAYPLAN"; then
  ERRORS+=("Бюджет дня не в формате '~Xh РП / ~Yh физ'")
fi

# --- Ф3 Check 5: Carry-over цитата (если есть предыдущий DayPlan) ---
PREV_DAYPLAN=$(ls "$GOV_PATH"/current/DayPlan\ *.md 2>/dev/null | sort | tail -2 | head -1)
if [ -n "$PREV_DAYPLAN" ] && [ "$PREV_DAYPLAN" != "$DAYPLAN" ]; then
  # Предыдущий DayPlan существует — текущий должен содержать Carry-over
  if ! grep -qiE 'carry.over|carry_over' "$DAYPLAN"; then
    ERRORS+=("Carry-over цитата из предыдущего Day Close отсутствует (предыдущий DayPlan: $(basename "$PREV_DAYPLAN"))")
  fi
fi

fi  # endif [ -n "$DAYPLAN" ]

# --- WeekPlan Validation (Ф6.1 WP-265) ---
WEEKPLAN=$(ls "$GOV_PATH"/current/WeekPlan\ *.md 2>/dev/null | sort | tail -1)
if [ -n "$WEEKPLAN" ]; then
  WP_LINES=$(wc -l < "$WEEKPLAN" | tr -d ' ')
  WP_ERRORS=()
  WP_MISSING_LIST=()

  # Детектор (а): >80 строк без достаточного числа <details>
  WP_DETAILS_COUNT=$(grep -c '<details' "$WEEKPLAN" 2>/dev/null || true); WP_DETAILS_COUNT=${WP_DETAILS_COUNT:-0}
  if [ "$WP_LINES" -gt 80 ] && [ "$WP_DETAILS_COUNT" -lt 3 ]; then
    WP_ERRORS+=("WeekPlan >80 строк ($WP_LINES) но collapsible секций < 3 ($WP_DETAILS_COUNT). Используй <details>/<summary> (formatting.md)")
  fi

  # Детектор (б): баланс <details> / </details>
  DETAILS_OPEN=$(grep -c '<details' "$WEEKPLAN" 2>/dev/null || true); DETAILS_OPEN=${DETAILS_OPEN:-0}
  DETAILS_CLOSE=$(grep -c '</details>' "$WEEKPLAN" 2>/dev/null || true); DETAILS_CLOSE=${DETAILS_CLOSE:-0}
  if [ "$DETAILS_OPEN" != "$DETAILS_CLOSE" ]; then
    WP_ERRORS+=("WeekPlan: несбалансированные <details> (открытий=$DETAILS_OPEN, закрытий=$DETAILS_CLOSE)")
  fi

  # Детектор (в): обязательные секции WeekPlan (5 минимальных по templates-dayplan.md)
  WP_REQUIRED=(
    "Итоги"
    "Повестка"
    "Inbox Triage"
    "План на неделю"
    "Контент-план"
  )
  for wp_section in "${WP_REQUIRED[@]}"; do
    if ! grep -q "$wp_section" "$WEEKPLAN"; then
      WP_MISSING_LIST+=("$wp_section")
    fi
  done

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
  cat <<'EOF'
{"additionalContext": "✅ DayPlan прошёл валидацию: секции, collapsible, непустые блоки, мультипликатор, carry-over."}
EOF
fi

exit 0
