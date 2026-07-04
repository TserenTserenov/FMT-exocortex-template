#!/bin/bash
# Protocol Artifact Validation Hook
# Event: PreToolUse (matcher: Bash)
# Intercepts `git commit` in protocol-managed repos to validate artifacts.
# Returns block decision if artifact fails validation.
# Read-only: only returns JSON, does not modify files.
#
# Validated artifacts:
#   - DayPlan: 11 required sections + ## headings structure + non-empty key sections + carry-over
#   - DayClose: итоги, carry-over (day-close protocol) [future]
#
# Parameterized: sections list is a variable, not hardcoded per format.
# Ф3 WP-229: добавлены проверки структуры (## заголовки, непустые секции, мультипликатор, carry-over)

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

# Governance-репо: из env $IWE_GOVERNANCE_REPO (по умолчанию ${IWE_GOVERNANCE_REPO:-DS-strategy}).
# Workspace: $IWE_WORKSPACE или $IWE_ROOT (синонимы), default ~/IWE.
GOV_REPO="${IWE_GOVERNANCE_REPO:-${IWE_GOVERNANCE_REPO:-DS-strategy}}"
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

# --- Ф3 Check 1: заголовки секций — ## (Obsidian-совместимый) или <summary> (сворачиваемые секции, formatting.md) ---
# issue #221: formatting.md требует <details><summary> для DayPlan/WeekPlan (более новое решение,
# заменившее старый Obsidian-only запрет на HTML-теги) — считаем оба варианта заголовком секции.
HEADINGS_COUNT=$(grep -cE '^## |^[[:space:]]*<summary>' "$DAYPLAN" 2>/dev/null || true); HEADINGS_COUNT=${HEADINGS_COUNT:-0}
if [ "$HEADINGS_COUNT" -lt 3 ]; then
  ERRORS+=("Секций (## или <summary>) < 3 найдено: $HEADINGS_COUNT. DayPlan должен иметь структуру из заголовков секций")
fi

# --- Ф3 Check 2: непустые обязательные секции ---
# Календарь: должна содержать хотя бы одну строку с | (таблица) или "нет событий".
# Флаг-диапазон вместо awk-range '/start/,/^## /': заголовок секции (## Календарь ...)
# совпадает и со start, и с end-ограничителем /^## /, из-за чего range схлопывается в
# одну строку и тело секции теряется (ложный блок коммита — issue #207).
# EN-альтернатива заголовка (Calendar) — для двуязычных DayPlan (issue #210).
CALENDAR_CONTENT=$(awk 'f && /^## /{exit} /Календарь|Calendar/{f=1} f' "$DAYPLAN" 2>/dev/null | wc -l || echo 0)
if [ "$CALENDAR_CONTENT" -lt 3 ]; then
  ERRORS+=("Секция 'Календарь' пустая или слишком короткая (${CALENDAR_CONTENT} строк)")
fi

# Scout: проверяется только если секция вообще присутствует в DayPlan (опциональный компонент,
# зависит от DS-agent-workspace). Если секции нет — Scout не сконфигурирован, валидатор не блокирует.
if grep -q "Наработки Scout" "$DAYPLAN" 2>/dev/null; then
  # Флаг-диапазон вместо awk-range (см. Календарь выше, issue #207): заголовок
  # '## Наработки Scout' совпадает с end-ограничителем /^## /, range схлопывается.
  if ! awk 'f && /^## /{exit} /Наработки Scout/{f=1} f' "$DAYPLAN" 2>/dev/null | grep -iqE 'наход|capture|статус|нет|find|disabled|not configured'; then
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

  # Детектор (а): >80 строк без достаточного числа заголовков — ## или <summary> (issue #221, см. Check 1 выше)
  WP_HEADINGS_COUNT=$(grep -cE '^## |^[[:space:]]*<summary>' "$WEEKPLAN" 2>/dev/null || true); WP_HEADINGS_COUNT=${WP_HEADINGS_COUNT:-0}
  if [ "$WP_LINES" -gt 80 ] && [ "$WP_HEADINGS_COUNT" -lt 3 ]; then
    WP_ERRORS+=("WeekPlan >80 строк ($WP_LINES) но секций (## или <summary>) < 3 ($WP_HEADINGS_COUNT). Используй ## заголовки или <details><summary> для структурирования.")
  fi

  # Детектор (в): обязательные секции WeekPlan (по templates-dayplan.md)
  # ОПТ-5 (WP-297, 8 май): «Итоги» переехали в WeekReport — больше не required в WeekPlan
  WP_REQUIRED=(
    "Повестка|Agenda"
    "Inbox Triage"
    "План на неделю|Week Plan"
    "Контент-план|Content Plan"
  )
  for wp_section in "${WP_REQUIRED[@]}"; do
    if ! grep -qE "$wp_section" "$WEEKPLAN"; then
      WP_MISSING_LIST+=("$wp_section")
    fi
  done

  # Детектор (г): WeekReport валидация (ОПТ-5 WP-297)
  WEEKREPORT=$(ls "$GOV_PATH"/current/WeekReport\ *.md 2>/dev/null | sort | tail -1)
  if [ -n "$WEEKREPORT" ]; then
    if ! grep -q "Итоги" "$WEEKREPORT"; then
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
  cat <<'EOF'
{"additionalContext": "✅ DayPlan прошёл валидацию: секции, ## заголовки, непустые блоки, мультипликатор, carry-over."}
EOF
fi

exit 0
