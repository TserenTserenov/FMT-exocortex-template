#!/bin/bash
# Шаблон уведомлений: Стратег (R1)
# Вызывается из notify.sh через source

STRATEGY_DIR="${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}/current"
STRATEGY_REPO_DIR="${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}"
DATE=$(date +%Y-%m-%d)

find_strategy_file() {
    case "$1" in
        "day-plan"|"evening"|"day-close"|"note-review")
            echo "$STRATEGY_DIR/DayPlan $DATE.md"
            ;;
        "session-prep")
            ls -t "$STRATEGY_DIR"/WeekPlan\ W*.md 2>/dev/null | head -1
            ;;
        "week-review")
            ls -t "$STRATEGY_DIR"/WeekPlan\ W*.md 2>/dev/null | head -1
            ;;
        *)
            echo ""
            ;;
    esac
}

# HTML-escape для контента из markdown-источника (parse_mode=HTML).
# Применять к переменным, которые приходят из DayPlan/WeekPlan текста, ДО подстановки в printf.
# Не применять к статическим <b>/<a> тегам из printf — они должны остаться буквальными.
# Причина: фразы вида "<4/5", "a < b" в markdown ломают Telegram parser (Bad Request: Unsupported start tag).
escape_html() {
    python3 -c 'import sys, html; sys.stdout.write(html.escape(sys.stdin.read()))'
}

# Plan table -> Telegram list (#982). Columns are found by the header row, not by
# position: DayPlan is `🚦 | ТВС | # | РП | h | Статус`, WeekPlan is
# `🚦 | # | РП | h | Статус | ...`, an older WeekPlan has no 🚦 at all. The icon is the
# done/in-progress marker from Статус, else the traffic light from 🚦, else ⬜.
# No `#` before the number: Telegram turns `#WP-17` into the hashtag `#WP`.
table_to_list() {
    local file="$1"
    local section="$2"

    sed -n -E "/^## ${section}|<summary>.*${section}/,/^---|^<\/details>/p" "$file" \
        | grep '^|' \
        | awk -F'|' '
            function trim(x) { gsub(/^[ \t]+|[ \t]+$/, "", x); return x }
            function strip(x) { gsub(/\*\*/, "", x); return trim(x) }
            NR == 1 {
                for (i = 2; i < NF; i++) {
                    h = trim($i)
                    if (h == "🚦") ci = i
                    else if (h == "#") ni = i
                    else if (h == "РП") ri = i
                    else if (h == "h" || h == "Бюджет") hi = i
                    else if (h == "Статус") si = i
                }
                next
            }
            NR == 2 { next }
            ri == "" { next }
            {
                light = ci ? trim($ci) : ""
                num = ni ? trim($ni) : ""
                rp = strip($ri)
                hours = hi ? strip($hi) : ""
                status = si ? trim($si) : ""
                icon = "⬜"
                if (light != "" && light != "—" && light != "-") icon = light
                if (status ~ /done|✅/) icon = "✅"
                else if (status ~ /in_progress|in.progress/) icon = "🔄"
                out = icon
                if (num != "" && num != "—" && num != "-") out = out " " num
                out = out " " rp
                if (hours != "") out = out " (" hours ")"
                print out
            }'
}

get_github_link() {
    local file="$1"
    local filename
    filename=$(basename "$file")
    local repo_url
    repo_url=$(cd "$STRATEGY_REPO_DIR" && git remote get-url origin 2>/dev/null | sed 's/\.git$//' | sed 's|git@github.com:|https://github.com/|')
    if [ -n "$repo_url" ]; then
        local branch
        branch=$(cd "$STRATEGY_REPO_DIR" && git rev-parse --abbrev-ref HEAD 2>/dev/null)
        if [ -z "$branch" ]; then
            echo "ERROR: unable to determine git branch for $STRATEGY_REPO_DIR" >&2
            return 1
        fi
        local encoded_name
        encoded_name=$(printf '%s' "$filename" | python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read().strip()))')
        printf '\n\n<a href="%s/blob/%s/current/%s">📄 Открыть в GitHub</a>' "$repo_url" "$branch" "$encoded_name"
    fi
}

# D16 (#983, #981): the morning Day Open built no plan and the strategist no longer replaces it with
# the free-form prompt. Static like week-review-failed: there is no file to look up. strategist.sh
# passes a reason code in DAY_OPEN_FAILED_REASON and the exit code in DAY_OPEN_FAILED_RC; only digits
# of the code reach the HTML message.
build_day_open_failed_message() {
    local rc="${DAY_OPEN_FAILED_RC:-}" reason
    local advice="Откройте день в сессии Claude Code командой «открывай». Подробности - в журнале стратега за сегодня (logs/strategist/$DATE.log в домашнем каталоге)."
    case "$rc" in ''|*[!0-9]*) rc="" ;; esac
    case "${DAY_OPEN_FAILED_REASON:-}" in
        update-incomplete)
            reason="Обновление шаблона не завершено: оставлен маркер .update-incomplete. Автоматическое Открытие дня отложено${rc:+ (код $rc)}."
            advice="Завершите или восстановите update.sh; после снятия маркера планировщик повторит попытку. Если план нужен сейчас, откройте день в сессии Claude Code командой «открывай»."
            ;;
        not-delivered)
            reason="Конвейер Открытия дня (scripts/day-open-pipeline.sh) не установлен на этой машине."
            advice="Запустите update.sh, чтобы его установить. План на сегодня соберите в сессии Claude Code командой «открывай»."
            ;;
        scaffold-only-failed)
            reason="Шлюз модели не настроен, а сборка каркаса плана без модели тоже не дошла до конца${rc:+ (код $rc)}."
            ;;
        scaffold-incomplete)
            local draft_path="${IWE_WORKSPACE:-$HOME/IWE}/.tmp/day-open-scaffold/DayPlan $DATE.md"
            draft_path=$(printf '%s' "$draft_path" | escape_html)
            reason="Шлюз модели не настроен. Неполный каркас сохранён локально: <code>$draft_path</code>. День не открыт${rc:+ (код $rc)}."
            advice="Правки в черновике не переносятся автоматически в полный план. Настройте шлюз модели или откройте день в сессии Claude Code командой «открывай»."
            ;;
        pipeline-failed)
            reason="Конвейер Открытия дня завершился с ошибкой${rc:+ (код $rc)}. Если включён планировщик Синхронизатора, он повторит попытку позже; если план нужен сейчас, не ждите."
            ;;
        attempts-exhausted)
            reason="Попытки собрать план за сегодня исчерпаны (ошибка или прерывание по тайм-ауту${rc:+, последний код $rc}), автоматических повторов сегодня больше не будет."
            ;;
        *)
            reason="Конвейер Открытия дня не собрал план${rc:+ (код $rc)}."
            ;;
    esac
    printf "<b>🔴 План дня не собран</b>\n\n%s\n\n%s" "$reason" "$advice"
}

build_message() {
    local scenario="$1"
    local file

    # WP-561 Ф25: a failed week-review must alarm even when no WeekPlan file is found or the
    # model wrote nothing, so this message is static and skips the file lookup below.
    if [ "$scenario" = "week-review-failed" ]; then
        printf "<b>🔴 Week-Review не доведён до сервера</b>\n\nОтчёт недели не подтверждён на origin/main (запуск не начался, модель упала или отчёт не доставлен), последующие сценарии могут остаться без итогов недели. Причина - в логе стратега за сегодня, строки POSTCONDITION или FAILED."
        return
    fi
    if [ "$scenario" = "day-open-failed" ]; then
        build_day_open_failed_message
        return
    fi

    file=$(find_strategy_file "$scenario")

    if [ -z "$file" ] || [ ! -f "$file" ]; then
        echo ""
        return
    fi

    case "$scenario" in
        "day-plan")
            local title
            title=$(grep '^# ' "$file" | head -1 | sed 's/^# //' | escape_html)
            local plan_items
            plan_items=$(table_to_list "$file" "План на сегодня" | escape_html)

            printf "<b>📋 %s</b>\n\n" "$title"
            printf "<b>План:</b>\n%s" "$plan_items"
            ;;

        "session-prep")
            local title
            title=$(grep '^# ' "$file" | head -1 | sed 's/^# //' | escape_html)
            local plan_items
            plan_items=$(table_to_list "$file" "Рабочие продукты" | escape_html)
            [ -z "$plan_items" ] && plan_items=$(table_to_list "$file" "План на неделю" | escape_html)

            printf "<b>📅 %s</b>\n\n" "$title"
            printf "<b>Рабочие продукты:</b>\n%s" "$plan_items"
            ;;

        "week-review")
            local title
            title=$(grep '^# ' "$file" | head -1 | sed 's/^# //' | escape_html)

            printf "<b>📊 Week-Review завершён</b>\n\n%s" "$title"
            ;;

        "note-review")
            # The notifier cannot see what the model did, so the text claims nothing about written proposals
            printf "<b>📝 Note-Review завершён</b>\n\nЗаметки остаются в inbox, пока вы не примете по ним решение."
            ;;

        *)
            local title
            title=$(grep '^# ' "$file" | head -1 | sed 's/^# //' | escape_html)
            printf "<b>📋 %s</b>\n\nСценарий <b>%s</b> завершён." "$title" "$scenario"
            ;;
    esac

    get_github_link "$file"
}

build_buttons() {
    local scenario="$1"
    echo '[]'
}
