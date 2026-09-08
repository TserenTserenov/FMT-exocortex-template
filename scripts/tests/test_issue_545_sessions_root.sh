#!/usr/bin/env bash
# test_issue_545_sessions_root.sh — regression for issue #545.
#
# The sessions writer (session-guard.sh resolve_orz_sessions_dir, WP-526 Ф2)
# switches to IWE_SESSIONS_ROOT/MC-sessions after migration, but readers
# (day-open-scaffold.sh carry-over/strategy/yesterday-summary, day-close.sh
# consolidation) hardcoded $GOV_REPO/sessions — on a migrated install the
# carry-over silently vanished, and "not found" was indistinguishable from
# "nothing to find". Fix: readers resolve the root via iwe_sessions_dir()
# (lib/common.sh, same contract as the writer), with a visible WARN on a
# broken explicit IWE_SESSIONS_ROOT and a flat-layout fallback in carry-over.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0
check() { # <desc> <expected> <actual>
    if [ "$2" = "$3" ]; then
        echo "PASS: $1"
    else
        echo "FAIL: $1 — ожидалось [$2], получено [$3]"
        fail=$((fail + 1))
    fi
}
check_grep() { # <desc> <pattern> <file>
    if grep -qF "$2" "$3"; then echo "PASS: $1"; else echo "FAIL: $1 — нет строки: $2"; fail=$((fail + 1)); fi
}
check_grep_absent() {
    if grep -qF "$2" "$3"; then echo "FAIL: $1 — строки не должно быть: $2"; fail=$((fail + 1)); else echo "PASS: $1"; fi
}

# --- Юнит: iwe_sessions_dir — контракт резолвера читателей ---
mkdir -p "$TMP/ws/DS-strategy/sessions"
res() { # <ws> [IWE_SESSIONS_ROOT]
    # Полная очистка наследуемого окружения: иначе GOVERNANCE_REPO /
    # IWE_SESSIONS_ROOT боевой машины или CI меняют результат теста.
    env -u IWE_SCRIPTS -u IWE_GOVERNANCE_REPO -u GOVERNANCE_REPO -u IWE_SESSIONS_ROOT \
        IWE_ROOT="$1" ${2:+IWE_SESSIONS_ROOT="$2"} bash -c \
        'source "'"$ROOT"'/scripts/lib/common.sh"; iwe_sessions_dir'
}
check "legacy: без MC-sessions — \$GOV_REPO/sessions" \
    "$TMP/ws/DS-strategy/sessions" "$(res "$TMP/ws")"
mkdir -p "$TMP/ws/MC-sessions"
check "migrated: есть MC-sessions — он и есть корень" \
    "$TMP/ws/MC-sessions" "$(res "$TMP/ws")"
mkdir -p "$TMP/custom-root"
check "explicit: IWE_SESSIONS_ROOT побеждает" \
    "$TMP/custom-root" "$(res "$TMP/ws" "$TMP/custom-root")"
if res "$TMP/ws" "$TMP/nonexistent" >/dev/null 2>&1; then
    echo "FAIL: сломанный явный IWE_SESSIONS_ROOT обязан возвращать ошибку"; fail=$((fail + 1))
else
    echo "PASS: сломанный явный IWE_SESSIONS_ROOT → ошибка (не молчаливый откат)"
fi
# GOVERNANCE_REPO — старший override legacy-пути (семантика day-close.sh).
mkdir -p "$TMP/ws2/MyStrategy/sessions"
check "legacy: GOVERNANCE_REPO=MyStrategy без IWE_GOVERNANCE_REPO" \
    "$TMP/ws2/MyStrategy/sessions" "$(env -u IWE_SCRIPTS -u IWE_GOVERNANCE_REPO -u IWE_SESSIONS_ROOT IWE_ROOT="$TMP/ws2" GOVERNANCE_REPO=MyStrategy bash -c \
        'source "'"$ROOT"'/scripts/lib/common.sh"; iwe_sessions_dir')"
# Пустой root — честная ошибка, не путь от корня файловой системы.
if env -u IWE_SCRIPTS -u IWE_ROOT -u IWE_WORKSPACE -u IWE_SESSIONS_ROOT bash -c \
    'source "'"$ROOT"'/scripts/lib/common.sh"; iwe_sessions_dir' >/dev/null 2>&1; then
    echo "FAIL: пустой root обязан возвращать ошибку"; fail=$((fail + 1))
else
    echo "PASS: пустой root (нет IWE_ROOT/IWE_WORKSPACE) → ошибка"
fi

# --- Контракт читателей: корень резолвится контрактом писателя ---
check_grep_absent "scaffold: нет безусловного хардкода legacy-пути" \
    'local sessions_dir="$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/sessions"' \
    "$ROOT/scripts/day-open-scaffold.sh"
check_grep "scaffold: читатели через iwe_sessions_dir" \
    'sessions_dir=$(iwe_sessions_dir)' "$ROOT/scripts/day-open-scaffold.sh"
check_grep_absent "scaffold: WARN не ссылается на несуществующий \$GOV_REPO" \
    '$GOV_REPO' "$ROOT/scripts/day-open-scaffold.sh"
check_grep "scaffold: плоская раскладка — запасной путь carry-over" \
    'find "$sessions_dir" -maxdepth 1 -type f -name "${yday}*day-close*"' \
    "$ROOT/scripts/day-open-scaffold.sh"
check_grep "day-close: подключает lib/common.sh" \
    'source "$SCRIPT_DIR/lib/common.sh"' "$ROOT/scripts/day-close.sh"
check_grep "day-close: консолидация через iwe_sessions_dir" \
    'sessions_base=$(iwe_sessions_dir)' "$ROOT/scripts/day-close.sh"
check_grep "day-close: пропуск называет фактический путь" \
    'Папка $sessions_root не найдена' "$ROOT/scripts/day-close.sh"

# --- Интеграция: консолидация day-close читает MC-sessions на мигрированной
# установке (журналы только там, legacy-папка пуста) ---
WSI="$TMP/ws-int"
mkdir -p "$WSI/FMT-exocortex-template/scripts/lib" \
         "$WSI/FMT-exocortex-template/.claude/lib" \
         "$WSI/DS-strategy/current" \
         "$WSI/DS-strategy/sessions" \
         "$WSI/MC-sessions/$(date +%Y-%m)/$(date +%Y-%m-%d)-demo"
cp "$ROOT/scripts/day-close.sh" "$WSI/FMT-exocortex-template/scripts/"
cp "$ROOT/scripts/lib/common.sh" "$WSI/FMT-exocortex-template/scripts/lib/"
cp "$ROOT/scripts/lib/find-python3.sh" "$WSI/FMT-exocortex-template/scripts/lib/" 2>/dev/null || true
cp "$ROOT/.claude/lib/iwe-env-bootstrap.sh" "$WSI/FMT-exocortex-template/.claude/lib/"
cat > "$WSI/MC-sessions/$(date +%Y-%m)/$(date +%Y-%m-%d)-demo/meta.yaml" <<YAML
task_id: WP-545
task_description: "демо-сессия переноса"
start_time: "10:00"
date: $(date +%Y-%m-%d)
YAML
env -u IWE_SCRIPTS -u IWE_ROOT -u IWE_TEMPLATE -u IWE_GOVERNANCE_REPO \
    -u IWE_DS_MY_STRATEGY -u IWE_RUNTIME -u IWE_WORKSPACE -u IWE_SESSIONS_ROOT \
    -u GOVERNANCE_REPO \
    WORKSPACE_DIR="$WSI" bash "$WSI/FMT-exocortex-template/scripts/day-close.sh" --sessions > "$TMP/out-int.txt" 2>&1 || true
check_grep "интеграция: сессия из MC-sessions попала в сводку" \
    "WP-545" "$WSI/DS-strategy/current/sessions-today.md"

# --- Интеграция: сломанный явный IWE_SESSIONS_ROOT — видимый WARN в выводе
# самого day-close (не молчаливый промах и не падение на unbound variable) ---
env -u IWE_SCRIPTS -u IWE_ROOT -u IWE_TEMPLATE -u IWE_GOVERNANCE_REPO \
    -u IWE_DS_MY_STRATEGY -u IWE_RUNTIME -u IWE_WORKSPACE \
    WORKSPACE_DIR="$WSI" IWE_SESSIONS_ROOT="$TMP/nonexistent" \
    bash "$WSI/FMT-exocortex-template/scripts/day-close.sh" --sessions > "$TMP/out-broken.txt" 2>&1 || true
check_grep "интеграция: сломанный IWE_SESSIONS_ROOT → WARN виден" \
    "недоступен" "$TMP/out-broken.txt"
check_grep_absent "интеграция: нет падения на unbound variable" \
    "unbound variable" "$TMP/out-broken.txt"

# --- Интеграция: custom GOVERNANCE_REPO + сломанный IWE_SESSIONS_ROOT —
# fallback обязан читать legacy-каталог ИМЕННО этого репозитория ---
WSG="$TMP/ws-gov"
mkdir -p "$WSG/FMT-exocortex-template/scripts/lib" \
         "$WSG/FMT-exocortex-template/.claude/lib" \
         "$WSG/MyStrategy/current" \
         "$WSG/MyStrategy/sessions/$(date +%Y-%m)/$(date +%Y-%m-%d)-demo"
cp "$ROOT/scripts/day-close.sh" "$WSG/FMT-exocortex-template/scripts/"
cp "$ROOT/scripts/lib/common.sh" "$WSG/FMT-exocortex-template/scripts/lib/"
cp "$ROOT/scripts/lib/find-python3.sh" "$WSG/FMT-exocortex-template/scripts/lib/" 2>/dev/null || true
cp "$ROOT/.claude/lib/iwe-env-bootstrap.sh" "$WSG/FMT-exocortex-template/.claude/lib/"
cat > "$WSG/MyStrategy/sessions/$(date +%Y-%m)/$(date +%Y-%m-%d)-demo/meta.yaml" <<YAML
task_id: WP-545
task_description: "демо custom governance repo"
start_time: "10:00"
date: $(date +%Y-%m-%d)
YAML
env -u IWE_SCRIPTS -u IWE_ROOT -u IWE_TEMPLATE -u IWE_GOVERNANCE_REPO \
    -u IWE_DS_MY_STRATEGY -u IWE_RUNTIME -u IWE_WORKSPACE \
    WORKSPACE_DIR="$WSG" GOVERNANCE_REPO=MyStrategy IWE_SESSIONS_ROOT="$TMP/nonexistent" \
    bash "$WSG/FMT-exocortex-template/scripts/day-close.sh" --sessions > "$TMP/out-gov.txt" 2>&1 || true
check_grep "интеграция: fallback читает legacy-каталог custom-репо" \
    "WP-545" "$WSG/MyStrategy/current/sessions-today.md"
check_grep "интеграция: WARN про сломанный override виден" \
    "недоступен" "$TMP/out-gov.txt"

# --- Интеграция: настоящий day-open-scaffold.sh на мигрированной установке
# находит carry-over в MC-sessions (ревью раунд 2 — Claude: grep-контракты не
# доказывают выполнение). До фикса здесь печаталось «Day Close не найден». ---
WSS="$TMP/ws-scaffold"
YESTERDAY=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d "yesterday" +%Y-%m-%d)
YMONTH="${YESTERDAY:0:7}"
mkdir -p "$WSS/FMT-exocortex-template/scripts/lib" \
         "$WSS/FMT-exocortex-template/.claude/lib" \
         "$WSS/DS-strategy/exocortex" \
         "$WSS/DS-strategy/sessions" \
         "$WSS/MC-sessions/$YMONTH/${YESTERDAY}-demo-day-close"
cp "$ROOT/scripts/day-open-scaffold.sh" "$WSS/FMT-exocortex-template/scripts/"
cp "$ROOT/scripts/lib/common.sh" "$ROOT/scripts/lib/find-python3.sh" \
   "$WSS/FMT-exocortex-template/scripts/lib/"
cp "$ROOT/.claude/lib/iwe-env-bootstrap.sh" "$WSS/FMT-exocortex-template/.claude/lib/"
# Скелет по дизайну НЕ генерирует DayPlan в strategy_day (exit 2) — дефолт
# monday. Фикстура обязана ставить strategy_day на заведомо НЕ сегодняшний
# будний день, иначе тест падает каждый понедельник (поймано 31.08).
STRAT_DAY=$(date -v+1d +%A 2>/dev/null | tr 'A-Z' 'a-z' || date -d "tomorrow" +%A | tr 'A-Z' 'a-z')
printf 'day_open:\n  strategy_day: %s\n' "$STRAT_DAY" > "$WSS/DS-strategy/exocortex/day-rhythm-config.yaml"
printf '## 1. Открытые вопросы\n\n- КАНАРЕЙКА_ПЕРЕНОС: доделать X\n\n## 2. Прочее\n' \
    > "$WSS/MC-sessions/$YMONTH/${YESTERDAY}-demo-day-close/report.md"
env -u IWE_ROOT -u IWE_TEMPLATE -u IWE_GOVERNANCE_REPO -u IWE_DS_MY_STRATEGY \
    -u IWE_RUNTIME -u IWE_WORKSPACE -u IWE_SESSIONS_ROOT -u GOVERNANCE_REPO \
    WORKSPACE_DIR="$WSS" IWE_SCRIPTS="$WSS/FMT-exocortex-template/scripts" \
    bash "$WSS/FMT-exocortex-template/scripts/day-open-scaffold.sh" "$(date +%Y-%m-%d)" \
    > "$TMP/out-scaffold.txt" 2>&1 || true
check_grep "интеграция: scaffold находит carry-over в MC-sessions" \
    "КАНАРЕЙКА_ПЕРЕНОС" "$TMP/out-scaffold.txt"

# Тот же прогон БЕЗ IWE_SCRIPTS в окружении (реальная среда CI T26, issue
# #581-регрессия): PENDING-комментарий скелета не должен тащить \$IWE_SCRIPTS
# в раскрываемый шаблон — под set -u это было «unbound variable».
env -u IWE_ROOT -u IWE_TEMPLATE -u IWE_GOVERNANCE_REPO -u IWE_DS_MY_STRATEGY \
    -u IWE_RUNTIME -u IWE_WORKSPACE -u IWE_SESSIONS_ROOT -u GOVERNANCE_REPO \
    -u IWE_SCRIPTS \
    WORKSPACE_DIR="$WSS" \
    bash "$WSS/FMT-exocortex-template/scripts/day-open-scaffold.sh" "$(date +%Y-%m-%d)" \
    > "$TMP/out-scaffold-noenv.txt" 2>&1 || true
check_grep_absent "интеграция: scaffold работает без IWE_SCRIPTS (нет unbound variable)" \
    "unbound variable" "$TMP/out-scaffold-noenv.txt"
check_grep "интеграция: carry-over находится и без IWE_SCRIPTS" \
    "КАНАРЕЙКА_ПЕРЕНОС" "$TMP/out-scaffold-noenv.txt"
# NB: строка сводки «РП закрыто: нет данных (Day Close не найден)» здесь
# ожидаема и честна — она ключуется на git-коммит закрытия дня в governance
# (render_yesterday), а не на файлы журналов; в фиктивном workspace его нет.
# Предмет #545 — carry-over из журналов, он проверен канарейкой выше.

if [ "$fail" -gt 0 ]; then
    echo "FAIL: $fail проверок упало"
    exit 1
fi
echo "PASS: sessions readers resolve the writer's root contract (issue #545)"
