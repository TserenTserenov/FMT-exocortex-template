#!/usr/bin/env bash
# routing: helper  skill=day-open  called-by=haiku  deterministic=true
# see DP.SC.159, DP.ROLE.059
# day-open-scaffold.sh — детерминированная генерация скелета DayPlan
# see WP-264 (~/IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/WP-264-day-open-enforcement.md), Ф2
#
# Принцип «Enforcement требует наблюдателя вне субъекта» (DP.ARCH.NNN, Ф5):
# секции, извлекаемые из конфига/файлов/git/scheduler reports — генерируются
# bash'ом без LLM. Секции, требующие синтеза или MCP, помечаются <!-- PENDING: X -->.
# Hook protocol-artifact-validate.sh уже проверяет 11 обязательных секций;
# Ф3 добавит проверку отсутствия PENDING перед commit.
#
# INVARIANT: ни одна render_*() функция не делает silent skip.
# При отключённой секции — всегда выводить явный статус в формате:
#   > `flag: false` в `config-file` — секция выключена. Нет данных.
# Нарушение = пропуск секции в DayPlan без объяснения причины.
#
# Использование:
#   bash day-open-scaffold.sh [YYYY-MM-DD] > "${IWE_GOVERNANCE_REPO:-DS-strategy}/current/DayPlan YYYY-MM-DD.md"
#   bash day-open-scaffold.sh                    # дата = сегодня
#   bash day-open-scaffold.sh 2026-04-26         # явная дата
#
# Все 10 обязательных секций (по hook protocol-artifact-validate.sh) присутствуют.

set -uo pipefail

# Load unified environment: WORKSPACE_DIR, IWE_ROOT, IWE_SCRIPTS, etc.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Bootstrap sets IWE_ROOT/WORKSPACE_DIR/etc. It may be ABSENT on some hosts — tsekh-1's
# extension sync does not copy .claude/lib/ — so source it only if present and never let
# its absence abort the scaffold (the old `|| exit 1` killed every run on tsekh-1, which
# is why the night generator always fell back to free-form synthesis).
if [ -f "$SCRIPT_DIR/../.claude/lib/iwe-env-bootstrap.sh" ]; then
  source "$SCRIPT_DIR/../.claude/lib/iwe-env-bootstrap.sh" || exit 1
fi
# Derive the essentials the scaffold + its helpers rely on. Bootstrap exports IWE_ROOT,
# but the script uses $IWE; a clean caller (launchd / pipeline subprocess) exports
# neither, so under `set -u` $IWE tripped «unbound variable» a few lines down.
IWE_ROOT="${IWE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
IWE="${IWE:-$IWE_ROOT}"
export IWE_ROOT IWE
DATE="${1:-$(date +%Y-%m-%d)}"
CONFIG="$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/exocortex/day-rhythm-config.yaml"
SERVER_MODE="${IWE_SERVER_MODE:-0}"  # WP-283: 1 = Linux server, Mac-only MCP недоступен

resolve_iwe_script() {
  local name="$1"
  local candidate
  for candidate in \
    "${IWE_SCRIPTS:-}/$name" \
    "$IWE/scripts/$name" \
    "${IWE_TEMPLATE:-}/scripts/$name" \
    "$IWE/FMT-exocortex-template/scripts/$name"; do
    [ -n "$candidate" ] && [ -x "$candidate" ] && { echo "$candidate"; return 0; }
  done
  return 1
}

# --- Pre-flight healthcheck (WP-7 ФDay-Open-Hardening) ---
PREFLIGHT_SCRIPT=$(resolve_iwe_script "day-open-preflight.sh" || true)
if [ -n "$PREFLIGHT_SCRIPT" ]; then
  PREFLIGHT_JSON=$(bash "$PREFLIGHT_SCRIPT" "$DATE" "$CONFIG" 2>/dev/null || echo '{"calendar":"unknown","scout":"unknown","triage":"unknown","memory":"unknown"}')
else
  PREFLIGHT_JSON='{"calendar":"unknown","scout":"unknown","triage":"unknown","memory":"unknown"}'
fi
CALENDAR_PF=$(echo "$PREFLIGHT_JSON" | jq -r '.calendar // "unknown"')
SCOUT_PF=$(echo "$PREFLIGHT_JSON" | jq -r '.scout // "unknown"')
TRIAGE_PF=$(echo "$PREFLIGHT_JSON" | jq -r '.triage // "unknown"')
MEMORY_PF=$(echo "$PREFLIGHT_JSON" | jq -r '.memory // "unknown"')

# --- Date helpers (cross-platform: macOS BSD date / Linux GNU date) ---
if [[ "$(uname -s)" == "Darwin" ]]; then
  WEEK_NUM=$(date -j -f "%Y-%m-%d" "$DATE" "+%V" 2>/dev/null)
  DOW_NUM=$(date -j -f "%Y-%m-%d" "$DATE" "+%u" 2>/dev/null)
  DAY_NUM=$(date -j -f "%Y-%m-%d" "$DATE" "+%-d" 2>/dev/null)
  MONTH_NUM=$(date -j -f "%Y-%m-%d" "$DATE" "+%-m" 2>/dev/null)
  YEAR=$(date -j -f "%Y-%m-%d" "$DATE" "+%Y" 2>/dev/null)
  MM=$(date -j -f "%Y-%m-%d" "$DATE" "+%m" 2>/dev/null)
  DD=$(date -j -f "%Y-%m-%d" "$DATE" "+%d" 2>/dev/null)
  YDAY=$(date -j -v-1d -f "%Y-%m-%d" "$DATE" "+%Y-%m-%d" 2>/dev/null)
  YDAY_NUM=$(date -j -v-1d -f "%Y-%m-%d" "$DATE" "+%-d" 2>/dev/null)
  YDAY_MNUM=$(date -j -v-1d -f "%Y-%m-%d" "$DATE" "+%-m" 2>/dev/null)
else
  # GNU date (Linux / NixOS)
  WEEK_NUM=$(date -d "$DATE" "+%V" 2>/dev/null)
  DOW_NUM=$(date -d "$DATE" "+%u" 2>/dev/null)
  DAY_NUM=$(date -d "$DATE" "+%-d" 2>/dev/null)
  MONTH_NUM=$(date -d "$DATE" "+%-m" 2>/dev/null)
  YEAR=$(date -d "$DATE" "+%Y" 2>/dev/null)
  MM=$(date -d "$DATE" "+%m" 2>/dev/null)
  DD=$(date -d "$DATE" "+%d" 2>/dev/null)
  YDAY=$(date -d "$DATE - 1 day" "+%Y-%m-%d" 2>/dev/null)
  YDAY_NUM=$(date -d "$DATE - 1 day" "+%-d" 2>/dev/null)
  YDAY_MNUM=$(date -d "$DATE - 1 day" "+%-m" 2>/dev/null)
fi

DOW_NAMES=("" "Понедельник" "Вторник" "Среда" "Четверг" "Пятница" "Суббота" "Воскресенье")
MONTH_NAMES=("" "января" "февраля" "марта" "апреля" "мая" "июня" "июля" "августа" "сентября" "октября" "ноября" "декабря")
DOW_RU="${DOW_NAMES[$DOW_NUM]}"
MONTH_RU="${MONTH_NAMES[$MONTH_NUM]}"
YDAY_MONTH_RU="${MONTH_NAMES[$YDAY_MNUM]}"

# --- YAML reader (uses python3 + yaml; fallback to grep) ---
read_yaml() {
  local key="$1"
  python3 -c "
import yaml, sys
try:
    with open('$CONFIG') as f: d = yaml.safe_load(f)
    keys = '$key'.split('.')
    v = d
    for k in keys:
        v = v.get(k) if isinstance(v, dict) else None
        if v is None: break
    print(v if v is not None else '')
except Exception:
    pass
" 2>/dev/null
}

# --- Deterministic context extractors (WP-7 DAP: strategy + day-close) ---
extract_day_close_carry_over() {
  local yday="$1"
  local sessions_dir="$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/sessions"
  local month="${yday:0:7}"
  local carry_over=""

  # 1. Peer-session day-close report.md
  local dc_report
  dc_report=$(find "$sessions_dir/$month" -maxdepth 2 -type f -name "report.md" 2>/dev/null | grep -F "${yday}-" | grep -F "day-close" | head -1)
  if [ -z "$dc_report" ]; then
    dc_report=$(find "$sessions_dir/$month" -maxdepth 1 -type f -name "${yday}-day-close.md" 2>/dev/null | head -1)
  fi
  if [ -n "$dc_report" ] && [ -f "$dc_report" ]; then
    carry_over=$(awk '
      /^## [0-9]+\. Открытые вопросы/ || /^## Открытые вопросы/ { found=1; next }
      /^## [0-9]+\. / && found { exit }
      /^## / && found && !(/^## [0-9]+\. Открытые вопросы/ || /^## Открытые вопросы/) { exit }
      found { print }
    ' "$dc_report" | sed '/^$/d' | head -20)
    if [ -n "$carry_over" ]; then
      echo "$carry_over"
      return 0
    fi
  fi

  # 2. Yesterday DayPlan archive: section "Завтра начать с"
  local ydayplan="$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/archive/day-plans/DayPlan ${yday}.md"
  if [ -f "$ydayplan" ]; then
    carry_over=$(awk '
      /Завтра начать с/ { found=1; next }
      found && /^## / { exit }
      found && /^<\/details>/ { exit }
      found { print }
    ' "$ydayplan" | sed '/^$/d' | head -10)
    if [ -n "$carry_over" ]; then
      echo "$carry_over"
      return 0
    fi
  fi

  echo "нет (Day Close за $yday не найден)"
}

extract_strategy_context() {
  local week_num="$1"
  local sessions_dir="$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/sessions"
  local strategy_file=""

  # 1. Strategy session markdown in current month
  local month_dir
  month_dir=$(ls -d "$sessions_dir"/"$(date +%Y-%m)" 2>/dev/null | head -1)
  if [ -n "$month_dir" ] && [ -d "$month_dir" ]; then
    strategy_file=$(find "$month_dir" -maxdepth 1 -type f -iname "*strategy*W${week_num}*.md" 2>/dev/null | sort | tail -1)
    if [ -z "$strategy_file" ]; then
      strategy_file=$(find "$month_dir" -maxdepth 1 -type f -iname "*strategy*.md" 2>/dev/null | sort | tail -1)
    fi
  fi

  if [ -n "$strategy_file" ] && [ -f "$strategy_file" ]; then
    local priorities
    priorities=$(awk '
      /^## Приоритеты/ { found=1; next }
      /^## / && found { exit }
      found { print }
    ' "$strategy_file" | sed '/^$/d' | head -15)
    if [ -n "$priorities" ]; then
      echo "$priorities"
      return 0
    fi
  fi

  # 2. Fallback: extract TOS lines from WeekPlan
  local weekplan
  weekplan=$(ls "$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/current"/WeekPlan\ W"${week_num}"*.md 2>/dev/null | head -1)
  if [ -n "$weekplan" ] && [ -f "$weekplan" ]; then
    local tos
    tos=$(grep -E "^\s*[-*]\s*(П[0-9]+|ТОС)" "$weekplan" 2>/dev/null | head -10)
    if [ -n "$tos" ]; then
      echo "$tos"
      return 0
    fi
  fi

  echo "не найден"
}

read_morning_priorities() {
  local prio_file="$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/current/priorities.yaml"

  if [ ! -f "$prio_file" ]; then
    return 0
  fi

  # Stale check (>= 3 days)
  local last_updated stale_warn=""
  last_updated=$(grep "^last_updated:" "$prio_file" 2>/dev/null | sed 's/last_updated:[[:space:]]*//' | tr -d '"' | head -1)
  if [ -n "$last_updated" ]; then
    local today_epoch last_epoch diff_days
    today_epoch=$(date +%s)
    last_epoch=$(date -j -f "%Y-%m-%d" "$last_updated" +%s 2>/dev/null \
      || date -d "$last_updated" +%s 2>/dev/null || echo 0)
    if [ "$last_epoch" -gt 0 ]; then
      diff_days=$(( (today_epoch - last_epoch) / 86400 ))
      if [ "$diff_days" -ge 3 ]; then
        stale_warn="⚠️ приоритеты устарели: обновлены $last_updated (${diff_days}д назад) — обнови priorities.yaml"
      fi
    fi
  fi

  local wps
  wps=$(awk '
    /^today:/ { found=1; next }
    /^[^[:space:]]/ && found { exit }
    found && /^[[:space:]]*-/ {
      gsub(/^[[:space:]]*-[[:space:]]*/,"")
      print "- "$0
    }
  ' "$prio_file" 2>/dev/null)

  if [ -z "$wps" ]; then
    return 0
  fi

  [ -n "$stale_warn" ] && echo "$stale_warn"
  echo "$wps"
}

# --- Strategy_day guard (Ф6 WP-264) ---
# Если сегодня strategy_day → не генерировать DayPlan (SKILL.md шаг 4).
# Возвращает exit 2; extension обрабатывает этот код и выводит сообщение Claude.
STRATEGY_DAY_NAME=$(read_yaml "day_open.strategy_day" || true)
case "${STRATEGY_DAY_NAME:-monday}" in
  monday)    STRATEGY_DOW=1 ;;
  tuesday)   STRATEGY_DOW=2 ;;
  wednesday) STRATEGY_DOW=3 ;;
  thursday)  STRATEGY_DOW=4 ;;
  friday)    STRATEGY_DOW=5 ;;
  saturday)  STRATEGY_DOW=6 ;;
  sunday)    STRATEGY_DOW=7 ;;
  *)         STRATEGY_DOW=0 ;;
esac
if [ "${DOW_NUM:-0}" = "$STRATEGY_DOW" ]; then
  exit 2
fi

# --- Section: Pomodoro/ритм ---
render_pomodoro() {
  local work brk long n
  work=$(read_yaml "pomodoro.work_minutes")
  brk=$(read_yaml "pomodoro.break_minutes")
  long=$(read_yaml "pomodoro.long_break_minutes")
  n=$(read_yaml "pomodoro.sessions_before_long_break")
  echo "**Помидорки:** ${work:-?} мин работа / ${brk:-?} мин перерыв / ${long:-?} мин длинный после ${n:-?} сессий"
}

# --- Section: Видео (новые сегодня) ---
render_video() {
  local enabled
  enabled=$(read_yaml "video.enabled")
  if [ "$enabled" != "True" ]; then
    echo "> \`video.enabled: false\` в \`day-rhythm-config.yaml\` — секция выключена. Нет данных."
    return
  fi
  local dirs=("$HOME/Documents/Zoom" "$HOME/Documents/Телемост" "$HOME/Видеозаписи Телемост")
  local count=0
  for d in "${dirs[@]}"; do
    [ -d "$d" ] || continue
    local n
    n=$(find "$d" -mtime 0 \( -name "*.mp4" -o -name "*.mov" -o -name "*.webm" -o -name "*.m4a" -o -name "*.mp3" \) 2>/dev/null | wc -l | tr -d ' ')
    count=$((count + n))
  done
  if [ "$count" -eq 0 ]; then
    echo "**Видео:** 0 новых записей сегодня"
  else
    echo "**Видео:** $count новых записей сегодня (директории: Zoom / Телемост / Видеозаписи Телемост)"
  fi
}

# DOC5/DOC10 (WP-7): секция «Мир» рендерится ВСЕГДА.
# При news.enabled: false — секция содержит явное «выключено», не опускается.
# При true — данные из server-news.sh или PENDING-маркеры.
render_world() {
  local enabled
  enabled=$(read_yaml "news.enabled")
  # DOC5/DOC10 (WP-7): секция «Мир» рендерится только при news.enabled: true.
  # Сознательно выключено (news.enabled: false) → секция опускается ЦЕЛИКОМ (не «нет данных», не «выключено»).
  # no-silent-skip остаётся для ПОЛОМОК (включено, но server-news.sh упал) — см. PENDING-блок ниже.
  [ "$enabled" != "True" ] && return 0
  echo "<details>"
  echo "<summary><b>Мир</b></summary>"
  echo ""
  bash "$IWE/scripts/server-news.sh" "$CONFIG" 2>/dev/null || {
    echo "<!-- PENDING: world — RSS feeds недоступны (server-news.sh завершился с ошибкой). Каждый пункт = markdown URL. -->"
    echo ""
    echo "> ⚠️ Data-contract: каждый тезис в секции «Мир» обязан содержать markdown-ссылку на источник [заголовок](url)."
    echo "> Если источник недоступен — использовать placeholder [источник недоступен](n/a) и пометить 🔴 в «Требует внимания»."
    echo ""
    echo "**AI/LLM:** <!-- PENDING --> [заголовок](url) · [заголовок](url)"
    echo "**Инженерия:** <!-- PENDING --> [заголовок](url) · [заголовок](url)"
    echo "**Мировые события:** <!-- PENDING --> [заголовок](url) · [заголовок](url)"
  }
  echo ""
  echo "**Вывод:** <!-- PENDING: news-lens — 2-4 предложения: какие из этих новостей релевантны активным РП (WP-350, WP-330, WP-351 и др.). Использовать контекст WeekPlan + WP-Registry. -->"
  echo ""
  echo "</details>"
}

# --- Section: Здоровье платформы (feedback-triage report) ---
render_bot_qa() {
  local file="$IWE/DS-agent-workspace/scheduler/feedback-triage/$DATE.md"
  if [ -f "$file" ]; then
    awk '/^\*\*Дельта/,/^### ✏️/' "$file" 2>/dev/null | head -40
    echo
    echo "*Полный отчёт: \`$file\`*"
  else
    if [ "${TRIAGE_PF:-unknown}" = "fail" ]; then
      echo "**Дельта:** ⚠️ Отчёт feedback-triage за $DATE отсутствует. Scheduler, вероятно, не запущен (простой ≥1 дня)."
    else
      echo "**Дельта:** нет данных (отчёт за $DATE отсутствует)"
    fi
    echo
    echo "| Метрика | Значение |"
    echo "|---------|----------|"
    echo "| Сегодня | нет данных |"
    echo "| Urgent | нет данных |"
  fi
  echo
  # Шаг 5 SKILL: core smoke синхронно. Раньше оставлялся PENDING-placeholder (bug-2026-06-12).
  local smoke_script="$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/day-open-smoke.sh" smoke_json
  if [ -f "$smoke_script" ]; then
    smoke_json=$(bash "$smoke_script" 2>/dev/null)
    if [ -n "$smoke_json" ]; then
      echo "**Smoke-tests:** \`$smoke_json\`"
    else
      echo "**Smoke-tests:** скрипт вернул пусто — проверить \`$smoke_script\`"
    fi
  else
    echo "**Smoke-tests:** скрипт не найден (\`$smoke_script\`)"
  fi
}

# --- Section: Новые задачи в репозиториях (issue sweep, 2 дня) ---
# Сигнальный канал из day-open/SKILL.md:54 (раньше был только в спеке, не в коде).
# Ленивый: кэш 1ч + fallback при недоступности gh — не ломает pipeline (требование peer-сессии 2026-06-04-32).
render_repo_issues() {
  command -v gh >/dev/null 2>&1 || { echo "_gh CLI недоступен — обзор задач пропущен._"; return; }
  local cache="/tmp/iwe-issue-sweep-$DATE.md"
  if [ -f "$cache" ] && [ -n "$(find "$cache" -mmin -60 2>/dev/null)" ]; then
    cat "$cache"; return
  fi
  if ! gh auth status >/dev/null 2>&1; then
    echo "_gh не авторизован — обзор задач пропущен (проверьте \`gh auth login\`)._"; return
  fi
  local since
  since=$(date -v-2d +%Y-%m-%d 2>/dev/null || date -d "2 days ago" +%Y-%m-%d 2>/dev/null)
  [ -z "$since" ] && { echo "_не удалось вычислить дату фильтра — пропуск._"; return; }
  local out="" any=0 repo slug rows stale_count stale_url
  for repo in "$IWE"/*/; do
    [ -d "${repo}.git" ] || continue
    git -C "$repo" remote get-url origin 2>/dev/null | grep -qi github || continue
    slug=$(basename "$repo")
    # New issues (last 2 days)
    rows=$( (cd "$repo" && gh issue list --state open --search "created:>=$since" \
             --json number,title --jq '.[] | "| #\(.number) | \(.title) |"' 2>/dev/null) )
    if [ -n "$rows" ]; then
      out="${out}\n**${slug} (новые):**\n\n| # | Заголовок |\n|---|---|\n${rows}\n"
      any=1
    fi
    # Stale issues: open + labeled stale-unattended (pipeline gap fix, issue #pipeline)
    stale_count=$( (cd "$repo" && gh issue list --state open --label "stale-unattended" \
                   --json number --jq 'length' 2>/dev/null) || echo "0" )
    if [ "${stale_count:-0}" -gt 0 ] 2>/dev/null; then
      local remote_url
      remote_url=$(git -C "$repo" remote get-url origin 2>/dev/null \
                   | sed 's|git@github.com:|https://github.com/|; s|\.git$||')
      stale_url="${remote_url}/issues?q=is:open+label:stale-unattended"
      out="${out}\n⚠️ **${slug}:** ${stale_count} старых issues без движения → [открыть фильтр](${stale_url})\n"
      any=1
    fi
  done
  if [ "$any" = "1" ]; then
    printf "%b" "$out" | tee "$cache"
  else
    echo "Новых задач за 2 дня нет. Зависших (stale-unattended) тоже нет." | tee "$cache"
  fi
}

# --- Section: Обзор активности по всем репо (коммиты, 2 дня) — WP-5 Ф 2026-06-11 П2 ---
# Дополняет issue-sweep: что менялось в каждом репо (включая Шаблон IWE / FMT),
# а не только новые issues. Сигнал «где шла работа» для плана дня/недели.
render_repo_activity() {
  local since out="" any=0 repo slug n last
  since=$(date -v-2d +%Y-%m-%d 2>/dev/null || date -d "2 days ago" +%Y-%m-%d 2>/dev/null)
  [ -z "$since" ] && { echo "_не удалось вычислить дату фильтра — пропуск._"; return; }
  out="| Репозиторий | Коммитов (2д) | Последний |\n|---|---|---|\n"
  for repo in "$IWE"/*/; do
    [ -d "${repo}.git" ] || continue
    slug=$(basename "$repo")
    n=$(git -C "$repo" log --since="$since 00:00:00" --oneline 2>/dev/null | wc -l | tr -d ' ')
    [ "${n:-0}" -eq 0 ] && continue
    last=$(git -C "$repo" log -1 --format='%s' 2>/dev/null | cut -c1-50)
    out="${out}| ${slug} | ${n} | ${last} |\n"
    any=1
  done
  if [ "$any" = "1" ]; then
    printf "%b" "$out"
  else
    echo "Активности в репозиториях за 2 дня нет."
  fi
}

# --- Section: IWE за ночь (светофор) ---
render_iwe_status() {
  echo "| Подсистема | Статус | Детали |"
  echo "|------------|--------|--------|"

  # Per-role launchd agents (старый com.exocortex.scheduler отключён с марта 2026)
  # Проверяем exit-status ключевых per-role агентов через launchctl list
  if command -v launchctl &>/dev/null; then
    local agents_bad=""
    for agent in com.strategist.morning com.strategist.notereview com.pulse.daily com.aisystant.profiler.recalculate; do
      local line status
      line=$(launchctl list 2>/dev/null | awk -v a="$agent" '$3==a{print}')
      [ -z "$line" ] && { agents_bad="$agents_bad $agent(missing)"; continue; }
      status=$(echo "$line" | awk '{print $2}')
      [ "$status" != "0" ] && [ "$status" != "-" ] && agents_bad="$agents_bad $agent(exit=$status)"
    done
    if [ -z "$agents_bad" ]; then
      echo "| LaunchAgents | 🟢 | per-role агенты OK |"
    else
      echo "| LaunchAgents | 🟡 |${agents_bad} |"
    fi
  else
    echo "| LaunchAgents | ⚪ | launchctl недоступен |"
  fi

  # template-sync (FMT last commit)
  if [ -d "$IWE/FMT-exocortex-template/.git" ]; then
    local fmt_last
    fmt_last=$(git -C "$IWE/FMT-exocortex-template" log -1 --format="%cr" 2>/dev/null || echo "?")
    echo "| template-sync | 🟢 | FMT last commit: $fmt_last |"
  else
    echo "| template-sync | 🔴 | FMT не найден |"
  fi

  # Scout findings
  if [ "${SCOUT_PF:-unknown}" = "ok" ]; then
    local scout_dir="$IWE/DS-agent-workspace/scout/results/$YEAR/$MM/$DD"
    if [ -d "$scout_dir" ]; then
      local findings=0 captures=0
      [ -f "$scout_dir/report.md" ] && findings=$(grep -c '^### ' "$scout_dir/report.md" 2>/dev/null || echo 0)
      [ -f "$scout_dir/capture-candidates.md" ] && captures=$(grep -c '^### ' "$scout_dir/capture-candidates.md" 2>/dev/null || echo 0)
      echo "| Scout | 🟢 | $findings находок, $captures capture-кандидатов |"
    else
      echo "| Scout | 🟡 | нет отчёта на $DATE |"
    fi
  elif [ "${SCOUT_PF:-unknown}" = "fail" ]; then
    local last_log
    last_log=$(ls -t "$IWE/DS-autonomous-agents/logs/scout-"*.log 2>/dev/null | head -1 || echo "")
    if [ -n "$last_log" ]; then
      local last_date
      last_date=$(basename "$last_log" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}')
      echo "| Scout | 🔴 | нет отчёта на $DATE. Последний лог: $last_date (>20 дней простоя) — диагностика службы |"
    else
      echo "| Scout | 🔴 | нет отчёта на $DATE. Логи не найдены — служба не настроена |"
    fi
  else
    echo "| Scout | 🟡 | статус Scout не определён (preflight unavailable) |"
  fi

  # Scheduler / feedback-triage healthcheck с failure mode A/B/C
  # see: peer-сессия 2026-05-30-07-gap-list-day-open подэтап 4
  # Mode A — cron не запущен (нет юнита, нет логов 7+ дней)
  # Mode B — cron запустился, отчёт пустой (всё чисто, жалоб нет) = норм 🟢
  # Mode C — юнит загружен, но cron ещё не сработал (grace window до 06:30) = 🟡 pending
  local triage_file="$IWE/DS-agent-workspace/scheduler/feedback-triage/$DATE.md"
  local watchdog_log="$HOME/logs/synchronizer/feedback-watchdog-$DATE.log"
  local feedback_triage_log="$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/logs/feedback-triage.log"
  local last_watchdog_log
  last_watchdog_log=$(ls -t "$HOME/logs/synchronizer/feedback-watchdog-"*.log 2>/dev/null | head -1 || echo "")
  local last_feedback_triage_log
  last_feedback_triage_log=$(ls -t "$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/logs/feedback-triage"*.log 2>/dev/null | head -1 || echo "")
  local has_launchd_unit=false
  if launchctl list 2>/dev/null | grep -qE "iwe\.(scheduler|feedback-watchdog|synchronizer|feedback-triage)"; then
    has_launchd_unit=true
  fi

  # Grace window: feedback-triage запускается в 06:00, до 06:30 отсутствие отчёта — норма
  local current_hour current_min in_grace_window=false
  current_hour=$(date +%H)
  current_min=$(date +%M)
  if [ "$current_hour" -lt 6 ] || { [ "$current_hour" -eq 6 ] && [ "$current_min" -lt 30 ]; }; then
    in_grace_window=true
  fi

  if [ -f "$triage_file" ] || [ -f "$watchdog_log" ] || [ -f "$feedback_triage_log" ]; then
    # Mode B-1: отчёт/лог за сегодня есть → норм
    echo "| Scheduler/триаж | 🟢 | отчёт/лог за $DATE присутствует (Mode B норм) |"
  elif [ "$has_launchd_unit" = "true" ] && [ "$in_grace_window" = "true" ]; then
    # Mode C: юнит загружен, но cron ещё не сработал (до 06:30)
    echo "| Scheduler/триаж | 🟡 | Mode C: юнит загружен, ожидание cron (06:00) — grace window до 06:30 |"
  elif [ "$has_launchd_unit" = "true" ] && { [ -n "$last_watchdog_log" ] || [ -n "$last_feedback_triage_log" ]; }; then
    # Mode B-2: юнит зарегистрирован, есть свежий лог < 2 дней → норм (тишина = нет жалоб)
    local last_log_age_days=-1
    local last_log_file=""
    if [ -n "$last_feedback_triage_log" ]; then
      last_log_file="$last_feedback_triage_log"
    else
      last_log_file="$last_watchdog_log"
    fi
    if [ -n "$last_log_file" ]; then
      last_log_age_days=$(( ( $(date +%s) - $(stat -f %m "$last_log_file" 2>/dev/null || stat -c %Y "$last_log_file" 2>/dev/null || echo 0) ) / 86400 ))
    fi
    if [ "$last_log_age_days" -le 1 ] || [ "$last_log_age_days" -eq -1 ]; then
      echo "| Scheduler/триаж | 🟢 | Mode B: feedback-triage зарегистрирован, последний лог присутствует (нет жалоб = тишина) |"
    else
      echo "| Scheduler/триаж | 🟡 | Mode B: feedback-triage зарегистрирован, но лог не обновлялся ${last_log_age_days}д — возможно cron skipped |"
    fi
  else
    # Mode A: cron не запущен (нет юнита в launchctl) + нет свежих логов
    local last_log_age_days="∞"
    if [ -n "$last_feedback_triage_log" ]; then
      last_log_age_days=$(( ( $(date +%s) - $(stat -f %m "$last_feedback_triage_log" 2>/dev/null || stat -c %Y "$last_feedback_triage_log" 2>/dev/null || echo 0) ) / 86400 ))
    elif [ -n "$last_watchdog_log" ]; then
      last_log_age_days=$(( ( $(date +%s) - $(stat -f %m "$last_watchdog_log" 2>/dev/null || stat -c %Y "$last_watchdog_log" 2>/dev/null || echo 0) ) / 86400 ))
    fi
    echo "| Scheduler/триаж | 🔴 | **Mode A** (cron не отработал): юнит feedback-triage не зарегистрирован в launchctl, последний лог ${last_log_age_days}д назад |"

    # Auto-create incident-файл если ещё нет за сегодня
    local incident_file="$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/INCIDENT-scheduler-cron-not-fired-$DATE.md"
    if [ ! -f "$incident_file" ]; then
      mkdir -p "$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox"
      cat > "$incident_file" <<INCEOF
---
type: incident
incident_id: INC-$DATE-scheduler-cron-not-fired
severity: critical
opened: $DATE
detected_by: day-open-scaffold.sh (auto Mode A)
mode: A (cron не запущен)
status: open
owner: pilot
related_wp: WP-7, WP-178, WP-356
auto_generated: true
---

# Инцидент: scheduler/feedback-watchdog не запущен ($DATE)

## Симптом (auto-detected)

- launchctl: юнит \`iwe.scheduler\` или \`iwe.feedback-watchdog\` отсутствует
- Последний лог \`~/logs/synchronizer/feedback-watchdog-*.log\` старше 24ч (или отсутствует)
- Mode A классификация (см. peer-сессия 2026-05-30-07 §Gap 3)

## Action items

1. Проверить \`~/Library/LaunchAgents/\` на наличие plist
2. \`bash $IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/install-launchd.sh\` для регистрации
3. Запустить руками: \`bash \${IWE_SCHEDULER_PATH:-$IWE/scripts/scheduler.sh} --dry-run\`

## Auto-generation note

Этот файл создан автоматически day-open-scaffold.sh при каждом обнаружении Mode A.
Если решено отложить fix — поставить \`status: deferred\` и убрать \`auto_generated\` поле, чтобы скаффолд не перезаписывал контекст.
INCEOF
    fi
  fi

  # gate_log активность (Ф1 проверка)
  local gate_log="$IWE/.claude/logs/gate_log.jsonl"
  if [ -f "$gate_log" ]; then
    local recent
    recent=$(awk -v d="$DATE" '$0 ~ d' "$gate_log" 2>/dev/null | wc -l | tr -d ' ')
    echo "| gate_log | 🟢 | $recent записей за $DATE |"
  else
    echo "| gate_log | 🟡 | $gate_log не найден |"
  fi

  # active-wp freshness
  if [ "${MEMORY_PF:-unknown}" = "ok" ]; then
    echo "| active-wp | 🟢 | актуален (<7 дней) |"
  elif [ "${MEMORY_PF:-unknown}" = "stale" ]; then
    echo "| active-wp | 🟡 | устарел (>7 дней) — обновить через build-active-wp.py |"
  else
    echo "| active-wp | ⚪ | статус не определён |"
  fi

  # update.sh check (FMT) — bounded: Day Open scaffold must not hang on network/update checks.
  if [ -d "$IWE/FMT-exocortex-template" ]; then
    local upd_status upd_output
    if command -v timeout >/dev/null 2>&1; then
      upd_output=$(cd "$IWE/FMT-exocortex-template" && timeout 20 bash update.sh --check 2>&1 || true)
    else
      upd_output=$(cd "$IWE/FMT-exocortex-template" && bash update.sh --check 2>&1 || true)
    fi
    upd_status=$(printf '%s\n' "$upd_output" | grep -oE '[0-9]+ обновлен|нет обновлен|актуал|Всё актуально' | head -1)
    echo "| Update IWE | 🟢 | ${upd_status:-проверено} |"
  fi

  # Base repos (FPF/SPF/ZP) — fetch + behind count
  for repo in FPF SPF ZP; do
    local d="$IWE/$repo"
    if [ -d "$d/.git" ]; then
      git -C "$d" fetch --quiet 2>/dev/null
      local behind
      behind=$(git -C "$d" rev-list --count HEAD..origin/main 2>/dev/null || echo 0)
      if [ "$behind" -gt 0 ]; then
        echo "| $repo | 🟡 | $behind новых коммитов upstream |"
      else
        echo "| $repo | 🟢 | актуален |"
      fi
    fi
  done
}

# --- Section: Scout (ссылка на отчёт) ---
render_scout() {
  local scout_dir="$IWE/DS-agent-workspace/scout/results/$YEAR/$MM/$DD"
  if [ -d "$scout_dir" ]; then
    local findings=0 captures=0
    [ -f "$scout_dir/report.md" ] && findings=$(grep -c '^### ' "$scout_dir/report.md" 2>/dev/null || echo 0)
    [ -f "$scout_dir/capture-candidates.md" ] && captures=$(grep -c '^### ' "$scout_dir/capture-candidates.md" 2>/dev/null || echo 0)
    echo "> Отчёт за $DAY_NUM $MONTH_RU — $findings находок, $captures capture-кандидатов"
    echo "> **Статус ревью:** ⬜ не проверен"
    echo
    echo "Путь: \`$scout_dir/\`"
  else
    echo "> Нет отчёта на $DATE — Scout не запускался или ещё не закончил"
    echo "> **Статус ревью:** — (нет находок)"
  fi
}

# --- Section: Gate-метрики (WP-423 Ф6.4) ---
render_gate_metrics() {
  local script="$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/gate-metrics.sh"
  local log="${HOME}/.iwe/gate-decisions.jsonl"
  echo "<details>"
  echo "<summary><b>Gate-метрики</b></summary>"
  echo ""
  if [ ! -f "$script" ]; then
    echo "> ⚠️ Скрипт gate-metrics.sh не найден: \`$script\`"
  elif [ ! -f "$log" ]; then
    echo "> Лог gate-решений не найден: \`$log\`"
    echo "> Запустите \`iwe-agent-dispatcher.py\` или \`overnight-auditor.sh\`, чтобы появились данные."
  else
    bash "$script" "$log" 2>/dev/null || echo "> ⚠️ gate-metrics.sh завершился с ошибкой"
  fi
  echo ""
  echo "</details>"
}

# --- Section: KE-очередь (отчёты на разбор) ---
# Считает extraction-reports со status: pending-review. Якорь '^status:' обязателен:
# без него grep ловит упоминания статуса в теле отчётов (cross-batch ID awareness, баг-файлы)
# и инфлейтит счёт. Выводит ИМЕНА файлов, не только число — самопроверка для пилота.
# SLA на разбор — ≤24ч (DP.SC.004). Заменил ручной <!-- PENDING -->, где 10.06.2026
# проскользнул ложный «0 pending-review» при реально висящем отчёте (bug-2026-06-10-ke-queue-drift).
render_ke_candidates() {
  local dir="$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/extraction-reports"
  local files
  files=$(grep -l -- '^status:[[:space:]]*pending-review' "$dir"/*.md 2>/dev/null)
  if [ -z "$files" ]; then
    echo "> Очередь чиста — 0 отчётов ожидают разбора."
    return
  fi
  local count
  count=$(printf '%s\n' "$files" | grep -c . )
  echo "> **$count ожидают разбора** (SLA ≤24ч, DP.SC.004) → запустить /apply-captures"
  echo
  printf '%s\n' "$files" | while read -r f; do
    [ -n "$f" ] && echo "- \`$(basename "$f")\`"
  done
}

# --- Section: Итоги вчера (commits stats + sessions) ---
render_yesterday() {
  local total=0 repos=0
  for repo in "$IWE"/*/; do
    [ -d "$repo/.git" ] || continue
    local n
    n=$(git -C "$repo" log --since="$YDAY 00:00" --until="$YDAY 23:59" --oneline 2>/dev/null | wc -l | tr -d ' ')
    if [ "$n" -gt 0 ]; then
      total=$((total + n))
      repos=$((repos + 1))
    fi
  done
  echo "**Коммиты:** $total в $repos репо | **РП закрыто:** <!-- PENDING: count из git log + WeekPlan -->"
  echo
  # Sessions consolidation (DAP1-B/1-C, WP-7): включить РП сессий вчерашнего дня
  local day_report_file="$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/current/DayReport-${YDAY}.md"
  if [ -f "$day_report_file" ]; then
    grep "^| " "$day_report_file" | grep -v "^| РП\|^| Время\|^|---" | sed 's/^/- /'
  else
    # Fallback: сканировать sessions напрямую за вчера если DayReport отсутствует
    local sessions_dir="$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/sessions"
    local found=0
    for session_dir in "$sessions_dir/${YDAY:0:7}"/${YDAY}-*/; do
      [ -d "$session_dir" ] || continue
      if [ -f "$session_dir/meta.yaml" ]; then
        local wp_id
        wp_id=$(python3 -c "import yaml; d=yaml.safe_load(open('$session_dir/meta.yaml')); print(d.get('task_id','') or '')" 2>/dev/null)
        if [ -n "$wp_id" ]; then
          echo "- $wp_id"
          found=1
        fi
      fi
    done
    if [ "$found" = "0" ]; then
      echo "_Нет сессий за вчера_"
    fi
  fi
  echo
  echo "<!-- PENDING: ключевое — 1-3 значимых результата вчерашнего дня (требует синтеза из коммитов) -->"
}

# --- Section: Compact Dashboard (WP-7 Block DOC) ---
# Выводится в stdout ПОСЛЕ EOF-блока DayPlan через маркер ---COMPACT-DASHBOARD---
# Читается агентом/пилотом как сводка дня; не входит в DayPlan-файл.
# INVARIANT: скаффолд НЕ заполняет топ-7 РП — план ещё пуст (PENDING).
# Топ-7 формирует day-open-llm-fill.py из готовой секции «План на сегодня»
# (функция rebuild_compact_dashboard, WP-5 Ф 2026-06-11 П1).
render_compact_dashboard() {
  echo ""
  echo "---COMPACT-DASHBOARD---"
  echo "## Compact Dashboard — $DAY_NUM $MONTH_RU $YEAR ($DOW_RU)"
  echo ""

  # Placeholder для топ-7 — будет заменён LLM-fill после наполнения плана.
  # Если видишь эту строку в итоговом файле — значит LLM-fill не отработал
  # или rebuild_compact_dashboard не сработала (bug-2026-06-11).
  echo "**Сегодня (топ-7 по приоритету):** <!-- filled by day-open-llm-fill.py from 'План на сегодня' -->"
  echo ""

  # Дедлайны из календаря (если preflight OK)
  if [[ "$CALENDAR_PF" == "ok" ]]; then
    echo "**Календарь:** доступен — запустить server-calendar.sh для деталей"
  else
    echo "**Календарь:** недоступен (${CALENDAR_PF})"
  fi
  echo ""

  # Светофор — критические позиции
  echo "**IWE за ночь:**"
  echo "  Scheduler: $(launchctl list 2>/dev/null | grep -qE 'iwe\.(scheduler|feedback)' && echo '🟢' || echo '🔴 не запущен')"
  local fpf_status
  if [ -d "$IWE/FPF/.git" ] && git -C "$IWE/FPF" fetch --quiet 2>/dev/null; then
    local behind; behind=$(git -C "$IWE/FPF" rev-list --count HEAD..origin/main 2>/dev/null || echo "?")
    fpf_status=$( [ "$behind" = "0" ] && echo "🟢" || echo "🟡 новых: $behind" )
  else
    fpf_status="⚪ недоступен"
  fi
  echo "  FPF upstream: $fpf_status"
  echo ""
  echo "---END-COMPACT-DASHBOARD---"
}

# --- Pre-compute sweep list для инжекта в PENDING (избежать двойного вызова внутри heredoc) ---
SWEEP_WP_LIST=$(bash "$IWE/scripts/active-wp-sweep.sh" "$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox" "$IWE" 2>/dev/null \
  | grep -oE '\*\*WP-[0-9]+\*\*' | tr -d '*' | tr '\n' ' ' | sed 's/  */ /g' || true)

# --- Deterministic context injection (WP-7 DAP) ---
DAY_CLOSE_CARRY_OVER=$(extract_day_close_carry_over "$YDAY" | sed 's/^/  /')
STRATEGY_CONTEXT=$(extract_strategy_context "$WEEK_NUM" | sed 's/^/  /')
MORNING_PRIORITIES=$(read_morning_priorities | sed 's/^/  /')

# --- Output ---
cat <<EOF
---
type: daily-plan
date: $DATE
week: W$WEEK_NUM
status: active
agent: Стратег
generated_by: day-open-scaffold.sh (WP-264 Ф2)
---

# Day Plan: $DAY_NUM $MONTH_RU $YEAR ($DOW_RU)

<!-- СРОЧНОЕ (ТВС=С): вывести ТОЛЬКО при 🔴 (упавший smoke / сломанная интеграция / EMERGENCY в priorities.yaml / заблокированный конвейер). В зелёный день — «нет срочного». -->
<details>
<summary><b>🚨 Срочное</b></summary>

<!-- PENDING: urgent — если в «Здоровье платформы» есть 🔴 ИЛИ в priorities.yaml пометка EMERGENCY: таблица | Что | Система | Действие | ETA |. Иначе одна строка: «— нет срочного (зелёный день)». -->

</details>

<details>
<summary><b>Саморазвитие</b></summary>

- **Изучи персональное руководство:** [personal-guide](https://github.com/TserenTserenov/personal-guide)

<!-- PENDING: self_dev — прочитать drafts/draft-list.md и выбрать активный D-NNN. Обязательно:
  1. Номер черновика и тема: [D-NNN](drafts/D-NNN-тема.md)
  2. Где остановился: параграф / раздел / последний написанный тезис
  3. Сколько времени сегодня и на что именно
  4. TTL истекает? (из «Требует внимания» предыдущего DayPlan)
  Минимум: одна строка в таблице плана + эта секция с D-NNN. -->

**Активный черновик:** <!-- PENDING: [D-NNN](drafts/D-NNN-тема.md) -->
**Где остановился:** <!-- PENDING: раздел/параграф/последний тезис -->
**Сегодня:** <!-- PENDING: X мин/h — на что именно (ревью / дописать / структурировать) -->

</details>

<details open>
<summary><b>План на сегодня</b></summary>

<!-- PENDING: today_plan — синтез таблицы плана дня.

АВТОРИТЕТНЫЙ ИСТОЧНИК ПОРЯДКА: «Утренние приоритеты (priorities.yaml)» ниже.
ПРАВИЛО: КАЖДЫЙ РП из priorities.yaml ОБЯЗАН быть в таблице — в том же порядке (первый = самая верхняя строка).
ИСКЛЮЧЕНИЕ: РП можно не включать только если его status в inbox/WP-NNN.md явно равен 'done' или 'closed' (или он помечен ✅ в WP-REGISTRY с зачёркиванием). Перед исключением — проверить.
ЛОВУШКА: «Ф1-Ф3 ✅ закрыто вчера» НЕ означает, что весь РП закрыт. Фаза ≠ РП. Проверить status в inbox/WP-NNN.md.
ЗАПРЕЩЕНО: включать в план РП, закрытые вчера (есть в «закрыто вчера» + ✅ в REGISTRY). Например, WP-362 закрыт — его нет в плане.

После priorities.yaml — дополнить из carry-over и SWEEP_WP_LIST теми РП, которых нет в priorities.yaml и которые ещё open.
Применить mandatory_daily_wps + daily_checkpoint_wps из day-rhythm-config.yaml.
KE-строка: bash $IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/ke-queue-stats.sh --dayplan-row (реальный бюджет, не литерал «1h»).
Active WPs to include (из sweep + WeekPlan union): $SWEEP_WP_LIST
-->

**Утренние приоритеты (priorities.yaml):**
${MORNING_PRIORITIES:-  (не задано — обнови current/priorities.yaml)}

**Стратегические приоритеты (из Strategy Session W${WEEK_NUM}):**
${STRATEGY_CONTEXT:-не найдены}

| 🚦 | ТВС | # | РП | h | Статус |
|----|-----|---|-----|---|--------|
| ⚫ | В | N | **Саморазвитие** — [тема] | 1-2 | pending |
| 🔴 | С | NNN | **<!-- PENDING -->** | X | pending |

> ТВС: **В** = Важное (развитие / критичное для R1-R6) · **Т** = Текущее (плановая работа) · **С** = Срочное (угроза конвейеру, дублируется в шапке 🚨)

**Бюджет дня:** <!-- PENDING: budget — посчитать после плана, формат см. templates-dayplan.md (бюджет РП всего / физ / мультипликатор). -->

**Mandatory check:** WP-7 (техдолг бота, ≥30 мин) + ≥1 контентный РП — <!-- PENDING: проверить наличие в плане -->

**Carry-over из Day Close вчера ($YDAY):**
${DAY_CLOSE_CARRY_OVER:-нет (Day Close не найден)}

</details>

<details>
<summary><b>Разбор заметок</b></summary>

<!-- PENDING: notes_review — категоризация fleeting-notes.md (НЭП/Задача/Черновик/Знание/Шум) или carry-over из вчерашнего Note-Review коммита. Каждая заметка — markdown-ссылка с якорем на заголовок: [«текст заметки»](inbox/fleeting-notes.md#якорь-заголовка). Якорь = текст заголовка в нижнем регистре, пробелы → дефисы, без эмодзи. См. SKILL.md шаг 1c. -->

| Заметка | Тип | Предложение | ✅ |
|---------|-----|-------------|---|
| [<!-- PENDING -->](../inbox/fleeting-notes.md#якорь-заметки) | — | — | [ ] |

</details>

<details>
<summary><b>Календарь ($DAY_NUM $MONTH_RU)</b></summary>

<!-- PENDING: calendar — вызвать mcp__ext-google-calendar__list-events для calendar_ids:
  - Календарь Церен: i0f6eu8fnpt912c38glhgokfkg@group.calendar.google.com
  - IWE Platform Ops: 0b141e8bb8367d75b444ae2595ff9d6575095aeaf04da1969fb716300e94bd53@group.calendar.google.com
  - primary: tserenov72@gmail.com
  timeMin=$DATE 00:00 МСК, timeMax=$DATE 23:59 МСК.
  Показать ВСЕ события дня, включая платформенные напоминания из IWE Platform Ops.
  Формат: таблица + строка свободных блоков ≥1h. -->

| Время (МСК) | Событие | Длит. | Связь с РП |
|-------------|---------|-------|------------|
| <!-- PENDING --> | <!-- PENDING --> | — | — |

⏱ Свободных блоков ≥1h: <!-- PENDING -->

</details>

<details>
<summary><b>Здоровье платформы (QA)</b></summary>

$(render_bot_qa)

**IWE за ночь (светофор):**

$(render_iwe_status)

**Новые задачи в репозиториях (за 2 дня):**

$(render_repo_issues)

**Активность по репозиториям (за 2 дня, включая Шаблон IWE):**

$(render_repo_activity)

</details>

<details>
<summary><b>Наработки агентов</b></summary>

<details>
<summary><b>Ночные отчёты</b></summary>

$(render_scout)

</details>

<details>
<summary><b>📚 KE-кандидаты (Knowledge Extraction)</b></summary>

$(render_ke_candidates)

</details>

$(render_gate_metrics)

</details>

<details>
<summary><b>Контент-план</b></summary>

**Стратегия:** <!-- PENDING: 1 строка из Strategy.md (пример: club → Telegram → Дзен/Habr, N постов/нед) -->
**TTL просрочены:** <!-- PENDING: D-NNN (истёк YYYY-MM-DD), ... или «нет просроченных» -->
**TTL скоро:** <!-- PENDING: D-NNN (истекает YYYY-MM-DD, через N дн), ... или «нет» -->

<!-- PENDING: content — таблица 1-3 тем из плана публикаций W{N}. Источник: WeekPlan или Strategy.md. -->

</details>

$(render_world)

<details>
<summary><b>Контекст недели (W$WEEK_NUM)</b></summary>

<!-- PENDING: bottleneck-week — запустить /bottleneck-pick --target weekplan --layer intra --horizon week --depth 1 и вставить 4-6 строк ПЕРВОЙ подсекцией: SC-failing, Bottleneck, Class (Policy/Resource/Cognitive), Этап 1, Сигнал. Source: extensions/day-open.after.md:158-191 -->

**Горлышко недели (SC-first, $DATE):** <!-- PENDING -->

<!-- PENDING: week_context — фокус недели + текущий бюджет/мультипликатор + ТОС. Источник: ${IWE_GOVERNANCE_REPO:-DS-strategy}/current/WeekPlan W$WEEK_NUM*.md. -->

</details>

<details>
<summary><b>Активные РП</b></summary>

$(bash "$IWE/scripts/active-wp-sweep.sh" "$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox" "$IWE" 2>/dev/null || echo "<!-- active-wp-sweep: ошибка запуска -->")

</details>

<details>
<summary><b>Итоги вчера ($YDAY_NUM $YDAY_MONTH_RU)</b></summary>

$(render_yesterday)

</details>

<details>
<summary><b>Помидорки/ритм</b></summary>

$(render_pomodoro)

</details>

<details>
<summary><b>Видео</b></summary>

$(render_video)

</details>

<details>
<summary><b>Требует внимания</b></summary>

<!-- PENDING: attention — собрать из: (1) carry-over WP, (2) IWE-светофор 🟡/🔴, (3) Scout не проверен, (4) обновления Base/IWE, (5) urgent feedback бота, (6) застрявшие заметки, (7) Мир без URL-ссылок, (8) Scheduler/триаж 🔴 (Mode A автоматически создаёт INCIDENT-файл), (9) KE-SLA 🔴 при oldest ≥3д, (10) Орг-сигналы R31 — прочитать ${IWE_GOVERNANCE_REPO:-DS-strategy}/current/orgdev-signals.md и инжектить строки с ⚠ статусом (WP-377 Ф2.7). Если пусто — написать «—» или удалить секцию. -->
<!-- PENDING: self-check world — если секция «Мир» не содержит «](http» → добавить пункт: «🔴 Мир: данные без источников — требуется ручное заполнение URL» -->

</details>

*Создан: $DATE (Day Open / day-open-scaffold.sh WP-264 Ф2)*
EOF
