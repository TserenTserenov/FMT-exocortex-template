#!/bin/bash
# Notification template: Synchronizer (R8)
# Called from notify.sh via source

LOG_DIR="$HOME/logs/synchronizer"
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

            # Was: was sending "Repos with commits: 0" on every run, even when not a single
            # repository had changed -- the same smell, as in Knowledge
            # Feeder (found in the same session 09.10). A run, where some-thing was actually
            # found (found>0), remains realtime -- this is not the same fix
            # (converting routine found>0 into a digest -- a separate architectural
            # change, do not touch here).
            [ "$found" -gt 0 ] || { echo ""; return; }

            printf "<b>🔄 Code Scan</b>\n\n"
            printf "📅 %s\n\n" "$DATE"
            printf "Repos with commits: %s\n" "$found"
            printf "No changes: %s\n\n" "$skipped"

            if [ "$found" -gt 0 ]; then
                printf "<b>Repos:</b>\n%s" "$repo_list"
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
