#!/bin/bash
# Шаблон уведомлений: Синхронизатор (R8)
# Вызывается из notify.sh через source

LOG_DIR="{{HOME_DIR}}/logs/synchronizer"
DATE=$(date +%Y-%m-%d)

build_message() {
    local scenario="$1"

    case "$scenario" in
        "code-scan")
            local log_file="$LOG_DIR/code-scan-$DATE.log"

            if [ ! -f "$log_file" ]; then
                echo ""
                return
            fi

            local latest_run
            latest_run=$(awk '/=== Code Scan Started ===/{buf=""} {buf=buf"\n"$0} END{print buf}' "$log_file" 2>/dev/null)

            local found
            found=$(echo "$latest_run" | grep -c 'FOUND:' 2>/dev/null || true); found=${found:-0}
            local skipped
            skipped=$(echo "$latest_run" | grep -c 'SKIP:' 2>/dev/null || true); skipped=${skipped:-0}

            local repo_list
            repo_list=$(echo "$latest_run" | grep 'FOUND:' 2>/dev/null | sed 's/.*FOUND: /  /' || echo "")

            printf "<b>🔄 Code Scan</b>\n\n"
            printf "📅 %s\n\n" "$DATE"
            printf "Репо с коммитами: %s\n" "$found"
            printf "Без изменений: %s\n\n" "$skipped"

            if [ "$found" -gt 0 ]; then
                printf "<b>Репо:</b>\n%s" "$repo_list"
            fi
            ;;

        *)
            echo ""
            ;;
    esac
}

build_buttons() {
    echo '[]'
}
