#!/usr/bin/env bash
# routing: helper  called-by=wp-gate  deterministic=true
# see DP.SC.159, DP.ROLE.059
# create-wp.sh — атомарное создание РП в локальных местах (inbox, REGISTRY, WeekPlan);
# внешний трекер (Linear) — условный пост-шаг, только при подключённом MCP (issue #321)
# see WP-297 Ф6.2 (<governance-repo>/inbox/WP-297-wp-lifecycle-architecture.md)
# see DP.M.010, DP.ROLE.037
#
# Использование:
#   bash create-wp.sh --title "Название" --budget 5h --priority P3 [--slug slug] [--repo "репо"] [--related "WP-150:dependency,WP-167:продукт"]
#   bash create-wp.sh --title "Название" --budget 5h --priority P3 --state "belonging (Оснащённость): из → в" --hypothesis "H-101 | —:infra|techdebt|order|spinoff" [--hypothesis-relation tests]
#   bash create-wp.sh --title "Название" --budget 5h --priority P3 --no-consent-check
#
# --state (WP-505): target state transition (WP-457 State-Transition Gate).
#   REQUIRED when <governance>/docs/state-axes-registry.yaml exists (author install);
#   optional otherwise (typical user install — gate inactive per template contract).
#   Must mention at least one gate_ready axis code from the registry file.
# --hypothesis (WP-496 Ф8): REQUIRED when <governance>/current/hypotheses-log.md exists —
#   H-NNN anchored in the log, or explicit dash with reason code (—:infra|techdebt|order|spinoff).
# --hypothesis-relation: tests|enables|responds|researches|operational|unclassified.
# New work must resolve unclassified before it is started; the default preserves
# older callers while making the missing strategic basis visible in frontmatter.
#
# Предусловие: consent state file должен существовать:
#   touch ${IWE_ROOT:-$HOME/IWE}/.claude/state/wp-consent-{N}
#
# Совместимость: bash 3.2+ (macOS), bash 4+ (Linux)

set -uo pipefail

IWE="${IWE_ROOT:-$HOME/IWE}"

# --- Определить governance-репо ---
# Приоритет: (1) явная переменная IWE_GOVERNANCE_REPO → (2) DS-strategy (конвенция по умолчанию)
GOV_REPO="${IWE_GOVERNANCE_REPO:-DS-strategy}"
if [[ -z "${IWE_GOVERNANCE_REPO:-}" ]] && [[ ! -d "$IWE/$GOV_REPO" ]]; then
  echo "ERROR: IWE_GOVERNANCE_REPO not set and $GOV_REPO not found in $IWE" >&2
  exit 1
fi

STRATEGY="$IWE/$GOV_REPO"
REGISTRY="$STRATEGY/docs/WP-REGISTRY.md"
INBOX="$STRATEGY/inbox"
STATE_DIR="$IWE/.claude/state"

# --- Параметры ---
TITLE=""
BUDGET=""
PRIORITY="P3"
SLUG=""
REPO=""
RELATED=""
RESULT=""
STATE=""
HYPOTHESIS=""
HYPOTHESIS_RELATION="unclassified"
SKIP_CONSENT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title)    TITLE="$2";    shift 2 ;;
    --budget)   BUDGET="$2";   shift 2 ;;
    --priority) PRIORITY="$2"; shift 2 ;;
    --slug)     SLUG="$2";     shift 2 ;;
    --repo)     REPO="$2";     shift 2 ;;
    --related)  RELATED="$2";  shift 2 ;;
    --result)   RESULT="$2";   shift 2 ;;
    --state)    STATE="$2";    shift 2 ;;
    --hypothesis) HYPOTHESIS="$2"; shift 2 ;;
    --hypothesis-relation) HYPOTHESIS_RELATION="$2"; shift 2 ;;
    --no-consent-check) SKIP_CONSENT=1; shift ;;
    *) echo "Неизвестный флаг: $1" >&2; exit 1 ;;
  esac
done

# --- Валидация ---
if [[ -z "$TITLE" || -z "$BUDGET" ]]; then
  echo "Использование: $0 --title \"Название\" --budget 5h [--priority P3] [--slug slug] [--repo репо] [--related \"WP-NNN:тип\"] [--result R3] [--state \"ось: из → в\"] [--hypothesis H-NNN] [--hypothesis-relation tests]" >&2
  exit 1
fi

case "$HYPOTHESIS_RELATION" in
  tests|enables|responds)
    [[ "${HYPOTHESIS:-—}" =~ ^H-[0-9]{3}$ ]] || {
      echo "❌ Для связи '$HYPOTHESIS_RELATION' нужен --hypothesis H-NNN" >&2
      exit 1
    }
    ;;
  researches|operational)
    [[ -z "$HYPOTHESIS" || "$HYPOTHESIS" == "—" || "$HYPOTHESIS" =~ ^—:(infra|techdebt|order|spinoff)$ ]] || {
      echo "❌ Для связи '$HYPOTHESIS_RELATION' укажите --hypothesis — или код причины —:<infra|techdebt|order|spinoff>" >&2
      exit 1
    }
    ;;
  unclassified) ;;
  *)
    echo "❌ Неизвестная связь с гипотезой: $HYPOTHESIS_RELATION" >&2
    exit 1
    ;;
esac

# --- State-Transition Gate (WP-457 / WP-505) ---
# When the axes registry exists, --state is mandatory and must reference a
# gate_ready axis; without the registry (typical user install) the gate is off.
AXES_FILE="$STRATEGY/docs/state-axes-registry.yaml"
GATE_READY_AXES=""
if [[ -f "$AXES_FILE" ]]; then
  GATE_READY_AXES=$(python3 - "$AXES_FILE" <<'PYEOF'
import sys, re
codes, code = [], None
for line in open(sys.argv[1], encoding="utf-8"):
    m = re.match(r"\s*-\s*code:\s*(\S+)", line)
    if m:
        code = m.group(1)
    elif re.match(r"\s*gate_ready:\s*true\b", line) and code:
        codes.append(code)
        code = None
print(" ".join(codes))
PYEOF
)
  if [[ -z "$STATE" ]]; then
    echo "🚫 State-Transition Gate (WP-457): --state обязателен — реестр осей найден:" >&2
    echo "   $AXES_FILE" >&2
    echo "   Формат: --state \"<ось> (<русское имя>): <из> → <в>\"" >&2
    echo "   Допустимые оси (gate_ready): $GATE_READY_AXES" >&2
    exit 1
  fi
  STATE_AXES=""
  for ax in $GATE_READY_AXES; do
    if [[ "$STATE" == *"$ax"* ]]; then
      STATE_AXES="$STATE_AXES $ax"
    fi
  done
  if [[ -z "$STATE_AXES" ]]; then
    echo "🚫 State-Transition Gate: в --state не найден ни один gate_ready код оси" >&2
    echo "   Допустимые: $GATE_READY_AXES" >&2
    echo "   Передано: $STATE" >&2
    exit 1
  fi
fi

# --- Hypothesis Gate (WP-496 Ф8) ---
# Mirror of the State-Transition Gate: when the hypotheses log exists (author
# install), --hypothesis is mandatory — either an H-NNN recorded in the log or
# an explicit dash with a reason code. A WP references an EXISTING bet
# (many WPs per hypothesis); new hypotheses enter only via the pilot's entry
# filter, never as a side effect of creating a WP. Installs without the log
# keep the gate off.
HYP_LOG="$STRATEGY/current/hypotheses-log.md"
if [[ -f "$HYP_LOG" ]]; then
  HYP_USAGE="H-NNN (из current/hypotheses-log.md) либо —:infra | —:techdebt | —:order | —:spinoff"
  if [[ -z "$HYPOTHESIS" ]]; then
    echo "🚫 Hypothesis Gate (WP-496): --hypothesis обязателен — журнал гипотез найден:" >&2
    echo "   $HYP_LOG" >&2
    echo "   Формат: $HYP_USAGE" >&2
    exit 1
  fi
  case "$HYPOTHESIS" in
    "—:infra"|"—:techdebt"|"—:order"|"—:spinoff") : ;;
    *)
      HYP_IDS=$(grep -oE '\bH-[0-9]{3}\b' <<<"$HYPOTHESIS" | sort -u)
      if [[ -z "$HYP_IDS" ]]; then
        echo "🚫 Hypothesis Gate: не распознан ни H-NNN, ни код причины" >&2
        echo "   Передано: $HYPOTHESIS" >&2
        echo "   Формат: $HYP_USAGE" >&2
        exit 1
      fi
      for HID in $HYP_IDS; do
        if ! grep -q "id=$HID " "$HYP_LOG"; then
          echo "🚫 Hypothesis Gate: $HID не найден среди якорей журнала ($HYP_LOG)" >&2
          echo "   Новая гипотеза заводится через входной фильтр журнала, не через create-wp" >&2
          exit 1
        fi
      done
      ;;
  esac
fi

# Registry cell «Ставка»: Russian axis names + hypothesis id (WP-505).
axis_ru() {
  case "$1" in
    permission) echo "Доверие" ;;
    belonging)  echo "Оснащённость" ;;
    engagement) echo "Увлечённость" ;;
    mastery)    echo "Компетентность" ;;
    community)  echo "Включённость" ;;
    mentorship) echo "Забота" ;;
    *)          echo "$1" ;;
  esac
}
STAKE_CELL="—"
if [[ -n "$STATE" && -n "${STATE_AXES:-}" ]]; then
  STAKE_CELL=""
  for ax in $STATE_AXES; do
    [[ -n "$STAKE_CELL" ]] && STAKE_CELL="${STAKE_CELL}+"
    STAKE_CELL="${STAKE_CELL}$(axis_ru "$ax")"
  done
  if [[ -n "$HYPOTHESIS" && "$HYPOTHESIS" != "—" ]]; then
    STAKE_CELL="${STAKE_CELL} · ${HYPOTHESIS}"
  fi
fi

# --- Найти следующий номер WP ---
WP_NUM=$(python3 - "$REGISTRY" <<'PYEOF' 2>/dev/null
import sys, re
registry = sys.argv[1]
max_num = 0
try:
    with open(registry, "r", encoding="utf-8") as f:
        for line in f:
            # Ищем строки вида | 297 |, | ~~297~~ | или legacy-формат | WP-297 |
            m = re.match(r"^\|\s*[*~]*(?:WP-)?(\d+)[*~]*\s*\|", line)
            if m:
                n = int(m.group(1))
                if n > max_num:
                    max_num = n
except Exception as e:
    print(0, file=sys.stderr)
print(max_num + 1)
PYEOF
)

if [[ -z "$WP_NUM" || "$WP_NUM" -le 0 ]]; then
  echo "❌ Не удалось определить следующий номер WP из REGISTRY" >&2
  exit 1
fi

echo "📋 Следующий номер WP: $WP_NUM"

# issue #338 п.4: без паддинга "WP-9" в листинге сортируется после "WP-10".
# WP_ID — только для строк с префиксом "WP-" (пути, заголовки); frontmatter
# wp:, consent-файл и колонки "#" REGISTRY/WeekPlan остаются bare-числом.
WP_ID=$(printf '%03d' "$WP_NUM")

# --- Проверка consent ---
CONSENT_FILE="$STATE_DIR/wp-consent-${WP_NUM}"
if [[ "$SKIP_CONSENT" -eq 0 ]]; then
  if [[ ! -f "$CONSENT_FILE" ]]; then
    echo "🚫 WP Gate: нет согласия пользователя на создание WP-${WP_NUM}" >&2
    echo "   Создайте consent file и повторите:" >&2
    echo "   touch $CONSENT_FILE" >&2
    exit 1
  fi
  echo "✅ Consent: $CONSENT_FILE"
fi

# --- Дата ---
TODAY=$(date +%Y-%m-%d)

# --- Slug из title (если не задан) ---
if [[ -z "$SLUG" ]]; then
  SLUG=$(echo "$TITLE" | python3 -c "
import sys, re, unicodedata
s = sys.stdin.read().strip().lower()
# Транслитерация кириллицы
tr = {
  'а':'a','б':'b','в':'v','г':'g','д':'d','е':'e','ё':'yo','ж':'zh',
  'з':'z','и':'i','й':'j','к':'k','л':'l','м':'m','н':'n','о':'o',
  'п':'p','р':'r','с':'s','т':'t','у':'u','ф':'f','х':'kh','ц':'ts',
  'ч':'ch','ш':'sh','щ':'shch','ъ':'','ы':'y','ь':'','э':'e','ю':'yu','я':'ya'
}
result = ''
for c in s:
    result += tr.get(c, c)
result = re.sub(r'[^a-z0-9]+', '-', result)
result = result[:40].strip('-')
print(result)
" 2>/dev/null || echo "wp-$(echo "$TITLE" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-' | cut -c1-30)")
fi

# Inbox convention (WP-434): every WP is a folder inbox/WP-N/ with main file WP-N.md.
# Slug lives in the title/frontmatter.  Архив появляется только при закрытии:
# предварительный stub конфликтовал с close-wp.sh и мог затереть контекст.
WP_DIR="$INBOX/WP-${WP_ID}"
WP_FILE="$WP_DIR/WP-${WP_ID}.md"
mkdir -p "$WP_DIR"

echo "🚀 Создаю WP-${WP_ID}: $TITLE"
echo "   Папка: inbox/WP-${WP_ID}/WP-${WP_ID}.md"
echo "   Бюджет: $BUDGET | Приоритет: $PRIORITY"

# --- Atomicity (Ф-script-contract-gate, Этап 2): шаги 1-4 пишут в 3 разных
# места (inbox, REGISTRY, WeekPlan) без общей транзакции. Раньше отказ на шаге
# 3/4 оставлял частично созданный WP и не считался ошибкой — падение WeekPlan
# просто печаталось в stderr и скрипт продолжал к «✅ WP создан». Снимок +
# откат ниже гарантируют: либо все 4 шага прошли, либо ни один след не остался.
#
# Снимки — файловые копии, не `$(cat file)`: command substitution обрезает
# завершающий перевод строки, а `printf '%s' "$snapshot" > "$file"` на откате
# его не возвращает — тихо портит форматирование REGISTRY/WeekPlan на КАЖДОМ
# срабатывании отката (найдено код-ревью 03.08, оба файла seed сегодня
# заканчиваются на \n). `cp` сохраняет содержимое байт-в-байт, включая случай
# отсутствующего файла (тогда снимка нет — откат просто убирает файл, а не
# создаёт пустой там, где раньше не было никакого).
SNAPSHOT_DIR=$(mktemp -d)
trap 'rm -rf "$SNAPSHOT_DIR"' EXIT
REGISTRY_SNAPSHOT="$SNAPSHOT_DIR/registry.snapshot"
[[ -f "$REGISTRY" ]] && cp "$REGISTRY" "$REGISTRY_SNAPSHOT"
WEEKPLAN=$(find "$STRATEGY/current" -maxdepth 1 -name "WeekPlan*.md" 2>/dev/null | sort -r | head -1)
WEEKPLAN_SNAPSHOT="$SNAPSHOT_DIR/weekplan.snapshot"
[[ -n "$WEEKPLAN" ]] && cp "$WEEKPLAN" "$WEEKPLAN_SNAPSHOT"

rollback_wp_creation() {
  echo "↩️  Откат: WP-${WP_ID} не создан целиком, отменяю частичные записи" >&2
  rm -rf "$WP_DIR"
  if [[ -f "$REGISTRY_SNAPSHOT" ]]; then
    cp "$REGISTRY_SNAPSHOT" "$REGISTRY"
  else
    rm -f "$REGISTRY"
  fi
  if [[ -n "$WEEKPLAN" ]]; then
    if [[ -f "$WEEKPLAN_SNAPSHOT" ]]; then
      cp "$WEEKPLAN_SNAPSHOT" "$WEEKPLAN"
    else
      rm -f "$WEEKPLAN"
    fi
  fi
}

# --- Сформировать строки таблицы связок ---
RELATED_ROWS="| — | — | — | нет связок |"
if [[ -n "$RELATED" ]]; then
  RELATED_ROWS=""
  IFS=',' read -ra REL_ITEMS <<< "$RELATED"
  for rel_item in "${REL_ITEMS[@]}"; do
    rel_item="${rel_item# }"
    rel_wp="${rel_item%%:*}"
    rel_type="${rel_item#*:}"
    [[ "$rel_wp" == "$rel_type" ]] && rel_type="—"
    RELATED_ROWS+="| ${rel_wp} | 🟡 | ${rel_type} | — |
"
  done
fi

# --- Шаг 1: context file ---
echo ""
echo "1/5 context file..."

# state_transition goes into frontmatter only when provided (gate off on
# installs without the axes registry); hypothesis always present, "—" = no bet.
FM_STAKE=""
if [[ -n "$STATE" ]]; then
  FM_STAKE="state_transition: \"${STATE}\"
"
fi
FM_STAKE="${FM_STAKE}hypothesis: \"${HYPOTHESIS:-—}\"
hypothesis_relation: \"${HYPOTHESIS_RELATION}\""

if ! cat > "$WP_FILE" <<WPEOF
---
wp: ${WP_NUM}
title: "${TITLE}"
status: pending
priority: ${PRIORITY}
budget: ${BUDGET}
created: ${TODAY}
last_session: ${TODAY}
related: []
${FM_STAKE}
activation: on-demand
---

# WP-${WP_ID}: ${TITLE}

## Проблема

[Описать неудовлетворённость / проблему, которую решает этот РП]

## Артефакт

[Конкретный результат — существительное-артефакт с критериями]

## Связки с РП

| РП | Сила | Тип | Что передаётся |
|----|------|-----|----------------|
${RELATED_ROWS}

## Фазы реализации

### Ф1 — [Название фазы] (~?h)

- [ ] ...

## Что узнали

[Заполняется при сессиях]

## Осталось

**Что пробовали:** не начат
**Что узнали:** —
  → memory: не нужно
**Что дальше:**
- [ ] Открыть сессию, прочитать задачу, составить план
**Следующий шаг:** Открыть сессию — прочитать задачу, составить план
**Контекст для следующей сессии:** РП только создан, нет контекста
WPEOF
then
  echo "❌ Не удалось записать context file: $WP_FILE" >&2
  rollback_wp_creation
  exit 1
fi

echo "   ✅ $WP_FILE"
if [[ "$HYPOTHESIS_RELATION" == "unclassified" ]]; then
  echo "   ⚠️  Связь с гипотезой не определена: до начала РП выберите tests/enables/responds/researches/operational" >&2
fi

# --- Шаг 2: WP-REGISTRY.md ---
echo "2/5 WP-REGISTRY.md..."

if ! python3 - "$REGISTRY" "$WP_NUM" "$PRIORITY" "$TITLE" "$REPO" "$BUDGET" "$GOV_REPO" "$STAKE_CELL" "$WP_ID" <<'PYEOF'
import sys
registry_path, wp_num, priority, title, repo, budget, gov_repo, stake, wp_id = sys.argv[1:10]

with open(registry_path, "r", encoding="utf-8") as f:
    lines = f.readlines()

# Найти строку-разделитель после заголовка таблицы (|---|---|...)
insert_at = None
header_line = None
for i, line in enumerate(lines):
    if line.strip().startswith("|---") and i > 0 and lines[i-1].strip().startswith("| #"):
        insert_at = i + 1
        header_line = lines[i-1]
        break

if insert_at is None:
    print("❌ Не найден заголовок таблицы REGISTRY", file=sys.stderr)
    sys.exit(1)

# Схема-гард (issue #263, расширено issue #276): раньше писатель требовал ровно
# 6 колонок в заголовке — REGISTRY с легитимно другим числом/порядком колонок
# (та же семантика, доп. колонка сверху) блокировался целиком, хотя читатель
# (check-wp-format.py::find_column_indices) уже толерантен к такой вариации.
# Вместо счёта колонок — строим {имя: индекс} по фактическому заголовку и
# проверяем наличие 6 канонических имён, не их порядок/количество.
header_cols = [c.strip() for c in header_line.strip().strip("|").split("|")]
CANONICAL_NAMES = ["#", "P", "Название", "Ст", "Репо", "Бюджет"]
# issue #297: вендорский skeleton (templates/strategy-skeleton/docs/WP-REGISTRY.md)
# пишет полные русские имена («Приоритет», «Статус», «Репозитории»), а не короткие
# канонические («P», «Ст», «Репо») — та же семантика, другое написание. Раньше
# сверка требовала буквального совпадения и падала даже на только что созданном
# из вендорского skeleton реестре. Синонимы резолвятся к канонической колонке до
# проверки — те же строки find_column_indices() в check-wp-format.py уже читают
# оба варианта позиционным fallback'ом, здесь та же терпимость явным списком.
COLUMN_SYNONYMS = {
    "Приоритет": "P",
    "Статус": "Ст",
    "Репозитории": "Репо",
    "Репозиторий": "Репо",
}
col_index = {}
for i, name in enumerate(header_cols):
    canonical = COLUMN_SYNONYMS.get(name, name)
    col_index.setdefault(canonical, i)
missing_names = [name for name in CANONICAL_NAMES if name not in col_index]
if missing_names:
    # issue #364: old installs cannot receive seed/template changes through
    # update.sh, so migrate the first writable registry table in place. Existing
    # columns (including the useful legacy «Активация») remain untouched; missing
    # canonical columns are appended and old rows receive an explicit em dash.
    def append_cell(line, value):
        newline = "\n" if line.endswith("\n") else ""
        body = line.rstrip("\n").rstrip()
        if not body.endswith("|"):
            raise ValueError("not a markdown table row")
        return body[:-1].rstrip() + " | " + value + " |" + newline

    header_idx = insert_at - 2
    separator_idx = insert_at - 1
    for name in missing_names:
        lines[header_idx] = append_cell(lines[header_idx], name)
        lines[separator_idx] = append_cell(lines[separator_idx], "---")

    row_idx = insert_at
    while row_idx < len(lines) and lines[row_idx].lstrip().startswith("|"):
        for _ in missing_names:
            lines[row_idx] = append_cell(lines[row_idx], "—")
        row_idx += 1

    header_line = lines[header_idx]
    header_cols = [c.strip() for c in header_line.strip().strip("|").split("|")]
    col_index = {}
    for i, name in enumerate(header_cols):
        canonical = COLUMN_SYNONYMS.get(name, name)
        col_index.setdefault(canonical, i)
    print(
        "   ⚠ REGISTRY: добавлены отсутствовавшие колонки {} (legacy-колонки сохранены)".format(
            ", ".join(missing_names)
        )
    )

repo_cell = repo if repo else "{}/inbox/WP-{}/".format(gov_repo, wp_id)
values_by_name = {
    "#": wp_num,
    "P": priority,
    "Название": "**{}**".format(title),
    "Ст": "⏳",
    "Репо": repo_cell,
    "Бюджет": budget,
    # WP-505: optional column; silently skipped when the header lacks it
    "Ставка": stake,
}
row_cells = ["—"] * len(header_cols)
for name, idx in col_index.items():
    if name in values_by_name:
        row_cells[idx] = values_by_name[name]
new_row = "| " + " | ".join(row_cells) + " |\n"
lines.insert(insert_at, new_row)

with open(registry_path, "w", encoding="utf-8") as f:
    f.writelines(lines)

print("   ✅ REGISTRY: строка {} добавлена".format(wp_num))
PYEOF
then
  rollback_wp_creation
  exit 1
fi

# Post-write verification (issue #256): create-wp.sh once reported success here
# without the row actually landing in REGISTRY — the writer above has no retry/lock,
# so confirm the row is really there before moving on.
# issue #263: некоторые репо исторически пишут номер РП с префиксом (| WP-N |),
# не голым числом (| N |) — grep должен принимать оба формата.
if ! grep -qE "\| \*?\*?(WP-)?${WP_NUM}\*?\*? \|" "$REGISTRY"; then
  echo "❌ REGISTRY write verification FAILED: строка WP-${WP_NUM} не найдена после записи" >&2
  rollback_wp_creation
  exit 1
fi

# --- Шаг 3: WeekPlan ---
echo "3/5 WeekPlan..."

# WEEKPLAN уже найден выше (снимок для отката, issue WP-507 про формат имени файла
# применён там же) — здесь используется тот же путь, не ищем повторно.
if [[ -n "$WEEKPLAN" ]]; then
  if ! python3 - "$WEEKPLAN" "$WP_NUM" "$TITLE" "$PRIORITY" "$BUDGET" <<'PYEOF'
import sys, re
weekplan_path, wp_num, title, priority, budget = sys.argv[1:6]

# Маппинг приоритета → светофор
flag_map = {"P1": "🔴", "P2": "🟡", "P3": "🟢", "P4": "⚪", "P5": "⚪"}
flag = flag_map.get(priority, "⚪")
h_val = re.sub(r"[^0-9\-]", "", budget) or "?"

with open(weekplan_path, "r", encoding="utf-8") as f:
    lines = f.readlines()

# issue (2026-07-27, WP-507 registration): the old writer matched a text anchor
# ("**Бюджет недели:**"/"**Бюджет итого:**") and a fixed 7-field column order —
# neither exists in the current WeekPlan format (summary line is now "**Бюджет:**",
# table header is "🚦 | # | РП | h | Источник | P | Статус | Результат"). Locate the table by
# its actual header instead, same name-based technique as the REGISTRY writer, so
# column order/extra columns don't silently corrupt the row.
header_line = None
insert_at = None
for i, line in enumerate(lines):
    if line.strip().startswith("|---") and i > 0 and "РП" in lines[i - 1] and "Статус" in lines[i - 1]:
        header_line = lines[i - 1]
        insert_at = i + 1
        break

if insert_at is None:
    print("   ⚠️  WeekPlan: таблица недели (заголовок РП/Статус) не найдена — добавить вручную", file=sys.stderr)
else:
    header_cols = [c.strip() for c in header_line.strip().strip("|").split("|")]
    values_by_name = {
        "🚦": flag,
        "#": wp_num,
        "РП": "**{}** — [описание]".format(title),
        "h": h_val,
        "Источник": "—",
        "P": priority,
        "Статус": "pending",
        "Результат": "[заполнить]",
    }
    row_cells = ["—"] * len(header_cols)
    for idx, name in enumerate(header_cols):
        if name in values_by_name:
            row_cells[idx] = values_by_name[name]
    new_row = "| " + " | ".join(row_cells) + " |\n"
    lines.insert(insert_at, new_row)
    with open(weekplan_path, "w", encoding="utf-8") as f:
        f.writelines(lines)
    print("   ✅ WeekPlan: строка WP-{} добавлена".format(wp_num))
PYEOF
  then
    echo "❌ WeekPlan write FAILED — WP-${WP_NUM} не создан" >&2
    rollback_wp_creation
    exit 1
  fi
else
  echo "   ⚠️  WeekPlan не найден в current/ — добавить вручную" >&2
fi

# --- Шаг 4: Strategy.md (только если --result задан и бюджет ≥3h) ---
echo "4/5 Strategy.md..."

BUDGET_H=$(echo "$BUDGET" | sed 's/[^0-9]//g')
if [[ -n "$RESULT" && "${BUDGET_H:-0}" -ge 3 ]]; then
  STRATEGY_FILE="$STRATEGY/docs/Strategy.md"
  python3 - "$STRATEGY_FILE" "$WP_ID" "$REPO" "$RESULT" <<'PYEOF'
import sys

strategy_path, wp_id, repo, result = sys.argv[1:5]

section_anchor = "### РП → Результаты"

with open(strategy_path, "r", encoding="utf-8") as f:
    content = f.read()

if section_anchor not in content:
    print("   ⚠️  Strategy.md: секция «{}» не найдена — добавить вручную".format(section_anchor))
    sys.exit(0)

section_start = content.index(section_anchor)
table_sep = content.find("|---|", section_start)
if table_sep == -1:
    print("   ⚠️  Strategy.md: разделитель таблицы не найден в секции — добавить вручную")
    sys.exit(0)

insert_at = content.index("\n", table_sep) + 1
repo_cell = repo if repo else "—"
new_row = "| WP-{} | {} | {} | pending |\n".format(wp_id, repo_cell, result)
content = content[:insert_at] + new_row + content[insert_at:]

with open(strategy_path, "w", encoding="utf-8") as f:
    f.write(content)
print("   ✅ Strategy.md: WP-{} → {} добавлен".format(wp_id, result))
PYEOF
elif [[ "${BUDGET_H:-0}" -ge 3 ]]; then
  echo "   ℹ️  РП ≥3h, но --result не задан — добавить маппинг в Strategy.md вручную"
else
  echo "   ℹ️  РП <3h — маппинг в Strategy.md не требуется"
fi

# --- Шаг 5: active-wp.md ---
echo "5/5 active-wp.md..."

BUILD_ACTIVE_WP=""
if [[ -f "$STRATEGY/scripts/build-active-wp.py" ]]; then
  BUILD_ACTIVE_WP="$STRATEGY/scripts/build-active-wp.py"
elif [[ -f "$IWE/FMT-exocortex-template/scripts/build-active-wp.py" ]]; then
  BUILD_ACTIVE_WP="$IWE/FMT-exocortex-template/scripts/build-active-wp.py"
fi

if [[ -n "$BUILD_ACTIVE_WP" ]]; then
  python3 "$BUILD_ACTIVE_WP" \
    && echo "   ✅ active-wp.md пересобран" \
    || echo "   ⚠️  build-active-wp.py завершился с ошибкой — пересобрать вручную" >&2
else
  echo "   ⚠️  scripts/build-active-wp.py не найден (искали в \`$STRATEGY/scripts/\` и \`$IWE/FMT-exocortex-template/scripts/\`) — пересобрать вручную" >&2
fi

# --- Внешний трекер (условный пост-шаг, #432) ---
# The local transaction above is already complete.  The adapter is deliberately
# best-effort: its UNAVAILABLE/INVALID_CONFIG result is visible but never rolls
# back a valid local WP.
echo ""
TRACKER_ADAPTER=""
if [[ -x "$IWE/scripts/external-tracker.py" ]]; then
  TRACKER_ADAPTER="$IWE/scripts/external-tracker.py"
elif [[ -x "$IWE/FMT-exocortex-template/scripts/external-tracker.py" ]]; then
  TRACKER_ADAPTER="$IWE/FMT-exocortex-template/scripts/external-tracker.py"
fi

if [[ -n "$TRACKER_ADAPTER" && "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  TRACKER_OUTPUT=$(python3 "$TRACKER_ADAPTER" create --context "$WP_FILE" --repository "$REPO" 2>&1 || true)
  echo "ℹ️  Внешний трекер: $TRACKER_OUTPUT"
elif [[ -n "$TRACKER_ADAPTER" ]]; then
  echo "ℹ️  Внешний трекер не вызывался: --repo должен иметь формат owner/repository"
else
  echo "ℹ️  Внешний трекер не установлен; локальная регистрация РП завершена"
fi

# --- Consent file остаётся в папке WP для аудит-следа ---
# Ранее consent file удалялся здесь; это ломало последующие wp-gate-check
# редактирования в той же сессии. Файл сохраняется; уборка по усмотрению пилота.
if [[ "$SKIP_CONSENT" -eq 0 && -f "$CONSENT_FILE" ]]; then
  echo ""
  echo "ℹ️  Consent file сохранён: $CONSENT_FILE"
fi

echo ""
echo "✅ WP-${WP_ID} создан: $TITLE"
echo "   context: inbox/WP-${WP_ID}/WP-${WP_ID}.md"
echo "   archive: будет создан close-wp.sh при закрытии РП"
echo "   Следующий шаг: заполнить «Проблема», «Артефакт», «Фазы» в context file"
echo "   Не забыть: issue во внешнем трекере (если подключён)"
