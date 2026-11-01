#!/bin/bash
# Шаблон уведомлений: Экстрактор (R2)
# Вызывается из notify.sh через source

REPORTS_DIR="${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/extraction-reports"
DATE=$(date +%Y-%m-%d)

# Repeat suppression (WP-568 F11). The scheduler runs inbox-check 4-5 times a
# day and the feeds up to 4 times; each run used to resend the same text
# ("за сегодня: N" with N unchanged, the same X/Y for inbox-check). A message
# is dropped when it is byte-identical to the last one built for the same
# scenario. Every message carries $DATE, so the first message of a new day
# always goes out, and a feed message only changes when N grows.
#
# The record is written when the message is built, not when Telegram confirms
# delivery: notify.sh on author hosts can lag behind this template, so a
# post-send hook there would silently never fire. Cost of that choice: if a
# send fails, the same text is not retried; the next change still goes out.
NOTIFY_REPEAT_STATE_DIR="${IWE_NOTIFY_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/iwe/notify}"

# Prints <message> unless it repeats the last one recorded for <scenario>.
emit_unless_repeat() {  # <scenario> <message>
    local scenario="$1" message="$2"
    local state="$NOTIFY_REPEAT_STATE_DIR/extractor-$scenario.last"
    [ -n "$message" ] || return 0
    if [ -f "$state" ] && [ "$(cat "$state")" = "$message" ]; then
        echo "extractor/$scenario: same text as the last message, not resent" >&2
        return 0
    fi
    # tmp + mv: a concurrent tick never reads a truncated record.
    if ! { mkdir -p "$NOTIFY_REPEAT_STATE_DIR" && printf '%s' "$message" > "$state.$$" && mv -f "$state.$$" "$state"; }; then
        rm -f "$state.$$" 2>/dev/null
        echo "WARN: extractor/$scenario: cannot record $state, repeats will not be suppressed" >&2
    fi
    printf '%s' "$message"
}

build_message() {
    local process="$1"
    case "$process" in
        "inbox-check"|"session-close-feed"|"git-diff-feed")
            emit_unless_repeat "$process" "$(compose_message "$process")"
            ;;
        *)
            compose_message "$process"
            ;;
    esac
}

compose_message() {
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

            # Было: "Новых кандидатов нет" слала каждый тик таймера, даже когда
            # ничего не изменилось с прошлого сообщения -- живой дамп 09.10
            # поймал дубль дважды за 16 минут ровно с этим текстом. Ветка
            # inbox-check выше уже молчит при пустом результате (echo "" ->
            # notify.sh пропускает отправку); это делает то же самое для
            # согласованности -- рутинное "ничего не произошло" идёт в
            # тихий счётчик (notify.sh's caller decides), не в чат на каждый тик.
            [ "$captured" -gt 0 ] || { echo ""; return; }
            printf "<b>🔍 Knowledge Feeder: %s</b>\n\n" "$process"
            printf "📅 %s\n\n" "$DATE"
            printf "Захвачено кандидатов за сегодня: %s\n" "$captured"
            printf "Файл: <code>%s</code>" "${captures_target#"$inbox_dir/"}"
            ;;

        *)
            echo ""
            ;;
    esac
}

build_buttons() {
    echo '[]'
}
