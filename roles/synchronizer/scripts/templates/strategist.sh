#!/bin/bash
# Notification template: Strategist (R1)
# Called from notify.sh via source

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

# HTML-escape for content from markdown-source (parse_mode=HTML).
# Apply to variables, that come from DayPlan/WeekPlan text, BEFORE substitution into printf.
# Do not apply to static <b>/<a> tags from printf — they must remain literal.
# Reason: phrases such as "<4/5", "a < b" in markdown break Telegram parser (Bad Request: Unsupported start tag).
escape_html() {
    python3 -c 'import sys, html; sys.stdout.write(html.escape(sys.stdin.read()))'
}

# Plan table -> Telegram list (#982). Columns are found by the header row, not by
# position: DayPlan is `🚦 | TWS | # | WP | h | Status`, WeekPlan is
# `🚦 | # | WP | h | Status | ...`, an older WeekPlan has no 🚦 at all. The icon is the
# done/in-progress marker from Status, else the traffic light from 🚦, else ⬜.
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
                    else if (h == "WP") ri = i
                    else if (h == "h" || h == "Budget") hi = i
                    else if (h == "Status") si = i
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
        printf '\n\n<a href="%s/blob/%s/current/%s">📄 Open in GitHub</a>' "$repo_url" "$branch" "$encoded_name"
    fi
}

# D16 (#983, #981): the morning Day Open built no plan and the strategist no longer replaces it with
# the free-form prompt. Static like week-review-failed: there is no file to look up. strategist.sh
# passes a reason code in DAY_OPEN_FAILED_REASON and the exit code in DAY_OPEN_FAILED_RC; only digits
# of the code reach the HTML message.
build_day_open_failed_message() {
    local rc="${DAY_OPEN_FAILED_RC:-}" reason
    local advice="Open the day in a Claude Code session with the command Claude Code with the command «open». Details - in the strategist log for today (logs/strategist/$DATE.log in the home directory)."
    case "$rc" in ''|*[!0-9]*) rc="" ;; esac
    case "${DAY_OPEN_FAILED_REASON:-}" in
        update-incomplete)
            reason="Template update not completed: marker left .update-incomplete. Automatic day opening is postponed${rc:+ (code $rc)}."
            advice="Complete or restore update.sh; after the marker is removed the scheduler will retry. If the plan is needed now, open the day in a Claude Code session Claude Code with the command «open»."
            ;;
        not-delivered)
            reason="Day opening pipeline (scripts/day-open-pipeline.sh) is not installed on this machine."
            advice="Run update.sh, to install it. Build the plan for today in a Claude Code session Claude Code with the command «open»."
            ;;
        scaffold-only-failed)
            reason="Model gateway is not configured, and the plan scaffold build without a model also did not complete${rc:+ (code $rc)}."
            ;;
        scaffold-incomplete)
            local draft_path="${IWE_WORKSPACE:-$HOME/IWE}/.tmp/day-open-scaffold/DayPlan $DATE.md"
            draft_path=$(printf '%s' "$draft_path" | escape_html)
            reason="Model gateway is not configured. Incomplete scaffold saved locally: <code>$draft_path</code>. Day was not opened${rc:+ (code $rc)}."
            advice="Edits in the draft are not carried over automatically to the full plan. Configure the model gateway or open the day in a Claude Code using the command «open»."
            ;;
        pipeline-failed)
            reason="Day Opening pipeline finished with an error${rc:+ (code $rc)}. If the Synchronizer scheduler is enabled, it will retry later; if the plan is needed now, do not wait."
            ;;
        attempts-exhausted)
            reason="All attempts to build a plan for today have been exhausted (error or timeout interruption-out${rc:+, last code $rc}), no more automatic retries will occur today."
            ;;
        *)
            reason="Day Opening pipeline did not build the plan${rc:+ (code $rc)}."
            ;;
    esac
    printf "<b>🔴 Daily plan was not built</b>\n\n%s\n\n%s" "$reason" "$advice"
}

build_message() {
    local scenario="$1"
    local file

    # WP-561 Phase25: a failed week-review must alarm even when no WeekPlan file is found or the
    # model wrote nothing, so this message is static and skips the file lookup below.
    if [ "$scenario" = "week-review-failed" ]; then
        printf "<b>🔴 Week-Review not delivered to the server</b>\n\nThe weekly report has not been confirmed in the shared version (the run did not start, the model failed to complete the task, or the completed report was not delivered to the server) - upcoming weekly scenarios may be left without results. The strategist log for today shows, at which exact step it failed."
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
            plan_items=$(table_to_list "$file" "Plan for today" | escape_html)

            printf "<b>📋 %s</b>\n\n" "$title"
            printf "<b>Plan:</b>\n%s" "$plan_items"
            ;;

        "session-prep")
            local title
            title=$(grep '^# ' "$file" | head -1 | sed 's/^# //' | escape_html)
            local plan_items
            plan_items=$(table_to_list "$file" "Work products" | escape_html)
            [ -z "$plan_items" ] && plan_items=$(table_to_list "$file" "Weekly plan" | escape_html)

            printf "<b>📅 %s</b>\n\n" "$title"
            printf "<b>Work products:</b>\n%s" "$plan_items"
            ;;

        "week-review")
            local title
            title=$(grep '^# ' "$file" | head -1 | sed 's/^# //' | escape_html)

            printf "<b>📊 Week-Review completed</b>\n\n%s" "$title"
            ;;

        "note-review")
            # The notifier cannot see what the model did, so the text claims nothing about written proposals
            printf "<b>📝 Note-Review completed</b>\n\nNotes remain in inbox, until you make a decision on them."
            ;;

        *)
            local title
            title=$(grep '^# ' "$file" | head -1 | sed 's/^# //' | escape_html)
            printf "<b>📋 %s</b>\n\nScenario <b>%s</b> completed." "$title" "$scenario"
            ;;
    esac

    get_github_link "$file"
}

build_buttons() {
    local scenario="$1"
    echo '[]'
}
