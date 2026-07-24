#!/bin/bash
# Dry-run Gate Hook (PreToolUse)
# Контракт: memory/dry-run-contract.md
# WP-265 Ф5.2 (ArchGate v3 — вариант F3 sentinel-only). v2: WP-7/BUGTRIAGE2 (issue #237).
#
# Назначение: блокировать write-tools при наличии валидного sentinel-файла.
# Sentinel: единый файл /tmp/iwe-dry-run.flag (не session-bound).
# Причина единого имени: CLAUDE_SESSION_ID не пробрасывается в окружение
# субагентов, поэтому session-bound имя было ненадёжно в самом частом пути
# smoke-теста — sentinel создавал главный агент, subagent Stop-хук снимал
# по своему (пустому) SID, чужой sentinel оставался и залипал на весь TTL.
# Единый файл убирает рассинхрон создания/очистки одним ходом (issue #237 п.2).
# TTL: 600 секунд (10 минут) от mtime.
#
# Принципы:
# - jq отсутствует → skip с явной диагностикой (setup должен ставить jq; см. issue #192)
# - exit 0 = allow (sentinel отсутствует / TTL истёк / gate skipped из-за missing jq)
# - exit 2 = block (с диагностикой в stderr)

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

SENTINEL=/tmp/iwe-dry-run.flag

# jq нужен для разбора payload. Если его нет, не брикуем все write-tools:
# setup/requirements должны установить jq, а gate явно сообщает, что проверка пропущена.
if ! command -v jq >/dev/null 2>&1; then
    echo "[dry-run-gate] SKIPPED: jq missing; install jq to enable dry-run protection" >&2
    exit 0
fi

# Sentinel отсутствует — dry-run неактивен, allow всё
[ -f "$SENTINEL" ] || exit 0

case "$(uname)" in
    Darwin) MTIME=$(stat -f %m "$SENTINEL" 2>/dev/null) ;;
    *)      MTIME=$(stat -c %Y "$SENTINEL" 2>/dev/null) ;;
esac

if [ -z "$MTIME" ]; then
    # Файл исчез между test и stat (race с параллельной очисткой) — allow.
    exit 0
fi

NOW=$(date +%s)
if [ $((NOW - MTIME)) -gt 600 ]; then
    rm -f "$SENTINEL" 2>/dev/null
    exit 0
fi

# Прочитать tool_name и tool_input из stdin
INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""')
[ -z "$TOOL_NAME" ] && exit 0

# Метаданные sentinel (для диагностики)
SENTINEL_META=$(cat "$SENTINEL" 2>/dev/null || echo '{}')
SENTINEL_INITIATOR=$(echo "$SENTINEL_META" | jq -r '.initiator // "unknown"' 2>/dev/null || echo "unknown")
SENTINEL_CREATED=$(echo "$SENTINEL_META" | jq -r '.created_at // "unknown"' 2>/dev/null || echo "unknown")

block() {
    local target="$1"
    {
        echo "[dry-run-gate] BLOCKED: $TOOL_NAME on $target"
        echo "Reason: dry-run mode active (sentinel created at $SENTINEL_CREATED, by $SENTINEL_INITIATOR)"
        echo "Expected: tool blocked by contract, this is rehearsal failure point"
    } >&2
    exit 2
}

# === Прямые write-tools: Write, Edit, MultiEdit, NotebookEdit ===
case "$TOOL_NAME" in
    Write|Edit|MultiEdit|NotebookEdit)
        FP=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // ""')
        block "${FP:-<no path>}"
        ;;
esac

# === MCP-write whitelist (точные совпадения tool_name) ===
case "$TOOL_NAME" in
    mcp__claude_ai_IWE__personal_write|\
    mcp__claude_ai_IWE__personal_delete|\
    mcp__claude_ai_IWE__personal_create_pack|\
    mcp__claude_ai_IWE__personal_propose_capture|\
    mcp__claude_ai_IWE__personal_reindex_source|\
    mcp__claude_ai_IWE__personal_scaffold_notes|\
    mcp__claude_ai_IWE__dt_write_digital_twin|\
    mcp__claude_ai_IWE__create_repository|\
    mcp__claude_ai_IWE__github_connect|\
    mcp__claude_ai_IWE__github_disconnect|\
    mcp__claude_ai_IWE__knowledge_feedback|\
    mcp__claude_ai_Gmail__create_draft|\
    mcp__claude_ai_Gmail__create_label|\
    mcp__claude_ai_Gmail__label_message|\
    mcp__claude_ai_Gmail__label_thread|\
    mcp__claude_ai_Gmail__unlabel_message|\
    mcp__claude_ai_Gmail__unlabel_thread|\
    mcp__claude_ai_Google_Calendar__create_event|\
    mcp__claude_ai_Google_Calendar__delete_event|\
    mcp__claude_ai_Google_Calendar__update_event|\
    mcp__claude_ai_Google_Calendar__respond_to_event|\
    mcp__claude_ai_Google_Drive__create_file|\
    mcp__ext-google-calendar__create-event|\
    mcp__ext-google-calendar__create-events|\
    mcp__ext-google-calendar__delete-event|\
    mcp__ext-google-calendar__update-event|\
    mcp__ext-google-calendar__respond-to-event|\
    mcp__ext-google-drive__copy_file|\
    mcp__ext-google-drive__create_file|\
    mcp__ext-google-drive__create_folder|\
    mcp__ext-google-drive__delete_file|\
    mcp__ext-google-drive__move_file|\
    mcp__ext-google-drive__update_file|\
    mcp__ext-google-drive__share_file|\
    mcp__ext-linear__create_issue|\
    mcp__ext-linear__update_issue|\
    mcp__ext-railway__create-environment|\
    mcp__ext-railway__create-project-and-link|\
    mcp__ext-railway__deploy|\
    mcp__ext-railway__deploy-template|\
    mcp__ext-railway__generate-domain|\
    mcp__ext-railway__link-environment|\
    mcp__ext-railway__link-service|\
    mcp__ext-railway__set-variables)
        block "$TOOL_NAME"
        ;;
esac

# === Bash matchers ===
#
# v3 (2026-07-23, /audit-installation follow-up): два фикса поверх v2 (issue #237):
#  A) Кавычные спаны раньше стирались в фиксированный "QSTR" ДО классификации —
#     это защищало сегментацию (шаг 2) от метасимволов внутри строк, но заодно
#     стирало путь у legit-вызовов вида `bash "$IWE_SCRIPTS/script.sh"`, из-за
#     чего whitelist read-only хелперов (issue #264) никогда не матчился для
#     цитированных путей — только для голых. Теперь каждый кавычный спан
#     заменяется на ИНДЕКСИРОВАННЫЙ плейсхолдер (__Q0__, __Q1__, ...), исходный
#     текст сохраняется в QVALS[] и разворачивается обратно точечно, только при
#     проверке whitelist — сегментация по-прежнему видит безопасный плейсхолдер
#     вместо сырых метасимволов, но классификация может свериться с оригиналом.
#  B) git/rm/mv/tee/sed/curl/psql/bash/sh/zsh матчились только как bareword —
#     вызов по полному пути (напр. /usr/bin/git) не матчил ничего и утекал
#     необнаруженным. Теперь классификация идёт по basename (${W0##*/}), путь
#     не имеет значения для распознавания команды.
#
# Итого три прохода (структура v2 сохранена):
#  1) вырезать кавычные спаны в индексированные плейсхолдеры (см. A выше);
#  2) разбить нормализованную строку на простые команды по разделителям
#     ; & | && || ( ) { } $( ` — раньше `(git commit -am x)` в скобках
#     проходил незамеченным, issue #237 п.1;
#  3) классифицировать каждый фрагмент по basename первого слова (после
#     пропуска VAR=val/command/env/nohup/time/sudo), а не bareword и не
#     искать подстроку где попало.
#
# Единственное исключение из шага 1 — psql: SQL живёт внутри кавычек, поэтому
# SQL-write матчится по НЕнормализованной команде, но только когда первое
# слово фрагмента — psql (иначе `grep "psql -c INSERT" file` снова ложно бьёт).

# QVALS[i] — исходный (нерасширенный, как написано в команде) текст i-го
# кавычного спана. Заполняется normalize_cmd(), читается только внутри
# check_indirect() для whitelist-сверки — нигде не eval'ится и не расширяется,
# чистая substring-операция, инъекция переменных через окружение хука невозможна.
declare -a QVALS=()
# Результат normalize_cmd() — глобальная переменная, НЕ $(...). Функция пишет
# в QVALS (ассоциативный побочный эффект по индексам) и вызов через command
# substitution породил бы subshell, где эта запись мгновенно терялась бы —
# NORM тогда оставался пуст (тихий баг, найден этим же прогоном тестов).
NORM_RAW=""

normalize_cmd() {
    local s="$1" out="" c q content i=0 j len idx=0
    len=${#s}
    while [ "$i" -lt "$len" ]; do
        c="${s:$i:1}"
        if [ "$c" = "'" ] || [ "$c" = '"' ]; then
            q="$c"
            j=$((i + 1))
            while [ "$j" -lt "$len" ] && [ "${s:$j:1}" != "$q" ]; do
                j=$((j + 1))
            done
            content="${s:$((i + 1)):$((j - i - 1))}"
            QVALS[$idx]="$content"
            out="${out}__Q${idx}__"
            idx=$((idx + 1))
            i=$((j + 1))
        else
            out="${out}${c}"
            i=$((i + 1))
        fi
    done
    NORM_RAW="$out"
}

# check_indirect <candidate> — общий whitelist-or-block для «непрямого запуска»
# (bash/sh/zsh <script> И прямой запуск скрипта по пути без интерпретатора).
# Список синхронизирован с memory/dry-run-contract.md §Bash matchers;
# добавление нового read-only хелпера = правка контракта + этой функции +
# code review на отсутствие write-путей в коде скрипта (redirect/tee/sed -i/mv/rm).
# Абсолютные пути привязаны к $HOME/IWE и захардкожены буквально (review-01 High,
# review-02 H1): glob */.claude/... пропускал /tmp-подделку, а ${IWE_ROOT:-...}
# открывал тот же обход через env-инъекцию — здесь та же дисциплина сохранена.
check_indirect() {
    local candidate="$1" idx
    case "$candidate" in
        __Q[0-9]*__)
            idx="${candidate#__Q}"
            idx="${idx%__}"
            case "$idx" in
                ''|*[!0-9]*) ;;  # не чисто число — не разворачиваем, candidate остаётся плейсхолдером (не матчит whitelist → block)
                *) candidate="${QVALS[$idx]:-}" ;;
            esac
            ;;
    esac
    case "$candidate" in
        .claude/scripts/load-extensions.sh) return 0 ;;
        "$HOME/IWE/.claude/scripts/load-extensions.sh") return 0 ;;
        FMT-exocortex-template/scripts/day-close-prepare.sh) return 0 ;;
        "$HOME/IWE/FMT-exocortex-template/scripts/day-close-prepare.sh") return 0 ;;
        '$IWE_SCRIPTS/day-close-prepare.sh') return 0 ;;
        *) block "$CMD (indirect execution under dry-run)" ;;
    esac
}

if [ "$TOOL_NAME" = "Bash" ]; then
    CMD=$(echo "$INPUT" | jq -r '.tool_input.command // ""')
    [ -z "$CMD" ] && exit 0

    # Шаг 1: кавычные спаны → индексированные плейсхолдеры, плюс безвредные redirect-в-null.
    # normalize_cmd вызывается КАК ОБЫЧНАЯ функция (не $(...)) — иначе QVALS[]
    # заполнялся бы в subshell и мгновенно терялся для check_indirect() ниже.
    normalize_cmd "$CMD"
    NORM=$(printf '%s' "$NORM_RAW" | sed -E \
        -e 's@[0-9]?>[[:space:]]*/dev/null@ @g' \
        -e 's@2>&1@ @g')

    # Редирект в реальный файл — проверяем по нормализованной строке целиком
    # (позиционно-независим относительно сегментации ниже, как и раньше).
    if echo "$NORM" | grep -qE '[[:space:]]>>?[[:space:]]'; then
        block "$CMD (redirect to file)"
    fi

    # Шаг 2: разбить на простые команды.
    SPLIT=$(printf '%s\n' "$NORM" | sed -E 's/\$\(|`|[(){}&;]|\|\|?|&&/\n/g')

    while IFS= read -r SEG; do
        [ -z "$SEG" ] && continue
        # shellcheck disable=SC2086
        set -- $SEG
        # Пропустить VAR=val / command / env / nohup / time / sudo — переход к реальной команде.
        while [ $# -gt 0 ]; do
            case "$1" in
                *=*) shift ;;
                command|env|nohup|time|sudo) shift ;;
                *) break ;;
            esac
        done
        [ $# -eq 0 ] && continue
        W0=$1
        W0B="${W0##*/}"

        case "$W0B" in
            git)
                shift
                # Пропустить global opts: -C dir, --git-dir=X, --work-tree=X, -c key=val
                while [ $# -gt 0 ]; do
                    case "$1" in
                        -C|--git-dir|--work-tree) shift 2 ;;
                        --git-dir=*|--work-tree=*) shift ;;
                        -c) shift 2 ;;
                        -c*) shift ;;
                        *) break ;;
                    esac
                done
                case "${1:-}" in
                    add|commit|push|pull|reset|merge|rebase|mv|rm) block "$CMD (git write)" ;;
                    checkout) case "${2:-}" in -*) block "$CMD (git checkout -)" ;; esac ;;
                esac
                ;;
            rm|mv)
                shift
                ARGS=""
                for a in "$@"; do
                    case "$a" in
                        -*) ;;
                        *) ARGS="$ARGS $a" ;;
                    esac
                done
                # Cleanup-исключение: собственный dry-run sentinel — единственный allow.
                [ "$ARGS" = " $SENTINEL" ] && continue
                block "$CMD (filesystem mutation)"
                ;;
            tee)
                case "${2:-}" in
                    /dev/null) ;;
                    *) block "$CMD (tee write)" ;;
                esac
                ;;
            sed)
                echo "$SEG" | grep -qE '(^|[[:space:]])-[a-zA-Z]*i' && block "$CMD (sed in-place)"
                ;;
            curl)
                echo "$SEG" | grep -qE '(-X[[:space:]]*)?(POST|PUT|DELETE|PATCH)|--data|(^|[[:space:]])-d([[:space:]]|$)' \
                    && block "$CMD (HTTP write)"
                ;;
            psql)
                # SQL живёт в кавычках исходной команды — проверяем оригинал $CMD,
                # но только т.к. первое слово фрагмента уже подтверждено как psql.
                echo "$CMD" | grep -qiE '(INSERT|UPDATE|DELETE|TRUNCATE|DROP|ALTER)[[:space:]]' \
                    && block "$CMD (SQL write)"
                ;;
            bash|sh|zsh)
                shift
                check_indirect "${1:-}"
                ;;
            eval|source|.|xargs)
                block "$CMD (indirect execution under dry-run)"
                ;;
            *)
                # Не распознанная как watched-команда basename'ом — если W0 сам
                # выглядит как путь к скрипту (прямой запуск без интерпретатора,
                # issue найден /audit-installation smoke-test 2026-07-23), тот же
                # whitelist-or-block, что и для bash|sh|zsh <script>. Голые команды
                # без слэша (ls, cat, python3 и т.п.) вне зоны ответственности этого
                # гейта — не трогаем.
                case "$W0" in
                    */*) check_indirect "$W0" ;;
                esac
                ;;
        esac
    done <<< "$SPLIT"
fi

# Read-only: allow
exit 0
