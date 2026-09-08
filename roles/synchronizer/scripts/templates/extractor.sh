#!/bin/bash
# Шаблон уведомлений: Экстрактор (R2)
# Вызывается из notify.sh через source

REPORTS_DIR="${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/extraction-reports"
DATE=$(date +%Y-%m-%d)

build_message() {
    local process="$1"

    case "$process" in
        "inbox-check")
            local report
            report=$(ls -t "$REPORTS_DIR"/${DATE}-*.md 2>/dev/null | head -1)

            if [ -z "$report" ] || [ ! -f "$report" ]; then
                echo ""
                return
            fi

            local candidates
            candidates=$(grep -c '^## Кандидат' "$report" 2>/dev/null || true); candidates=${candidates:-0}
            local accept
            accept=$(grep -c 'Вердикт.*accept' "$report" 2>/dev/null || true); accept=${accept:-0}

            printf "<b>🔍 Knowledge Extractor: %s</b>\n\n" "$process"
            printf "📅 %s\n\n" "$DATE"
            printf "📊 Кандидатов: %s, Accept: %s\n\n" "$candidates" "$accept"

            if [ "$candidates" -gt 0 ]; then
                printf "Для применения: в Claude скажите «review extraction report»"
            else
                printf "Inbox пуст."
            fi
            ;;

        "audit")
            printf "<b>🔍 Knowledge Audit завершён</b>\n\n📅 %s\n\nПроверьте лог: ~/logs/extractor/%s.log" "$DATE" "$DATE"
            ;;

        "session-close-feed"|"git-diff-feed")
            # Feed scenarios append ###-blocks to the captures inbox (monthly
            # file under the WP-526 rotation, flat captures.md without it).
            # Count today's blocks by the feed marker so the pilot sees intake
            # volume, not just "the feed ran".
            local feed_marker="feed:${process%-feed}"
            local inbox_dir="${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox"
            local captures_target="$inbox_dir/captures/$(date +%Y-%m).md"
            [ -f "$captures_target" ] || captures_target="$inbox_dir/captures.md"
            local captured=0
            if [ -f "$captures_target" ]; then
                captured=$(grep -c "\[${feed_marker} ${DATE}\]" "$captures_target" 2>/dev/null || true)
                captured=${captured:-0}
            fi

            printf "<b>🔍 Knowledge Feeder: %s</b>\n\n" "$process"
            printf "📅 %s\n\n" "$DATE"
            if [ "$captured" -gt 0 ]; then
                printf "Захвачено кандидатов за сегодня: %s\n" "$captured"
                printf "Файл: <code>%s</code>" "${captures_target#"$inbox_dir/"}"
            else
                printf "Новых кандидатов нет."
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
