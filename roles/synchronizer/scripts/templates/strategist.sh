#!/bin/bash
# Шаблон уведомлений: Стратег (R1)
# Вызывается из notify.sh через source

STRATEGY_DIR="{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/current"
STRATEGY_REPO_DIR="{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}"
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

table_to_list() {
    local file="$1"
    local section="$2"

    sed -n "/^## ${section}/,/^---/p" "$file" \
        | grep '^|' \
        | tail -n +3 \
        | while IFS='|' read -r _ num rp budget priority status _rest; do
            num=$(echo "$num" | xargs)
            rp=$(echo "$rp" | xargs | sed 's/\*\*//g')
            budget=$(echo "$budget" | xargs)
            status=$(echo "$status" | xargs)

            local icon="⬜"
            case "$status" in
                *done*|*"✅"*) icon="✅" ;;
                *in_progress*|*in.progress*) icon="🔄" ;;
                *pending*) icon="⬜" ;;
            esac

            printf "%s #%s %s (%s)\n" "$icon" "$num" "$rp" "$budget"
        done
}

get_github_link() {
    local file="$1"
    local filename
    filename=$(basename "$file")
    local repo_url
    repo_url=$(cd "$STRATEGY_REPO_DIR" && git remote get-url origin 2>/dev/null | sed 's/\.git$//' | sed 's|git@github.com:|https://github.com/|')
    if [ -n "$repo_url" ]; then
        local encoded_name
        encoded_name=$(printf '%s' "$filename" | python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read().strip()))')
        printf '\n\n<a href="%s/blob/main/current/%s">📄 Открыть в GitHub</a>' "$repo_url" "$encoded_name"
    fi
}

build_message() {
    local scenario="$1"
    local file
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
            printf "<b>📝 Note-Review завершён</b>\n\nЗаметки обработаны, inbox почищен."
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
