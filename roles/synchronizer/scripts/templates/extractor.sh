#!/bin/bash
# Notification template: Extractor (R2)
# Invoked from notify.sh via source

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
            candidates=$(grep -c '^## Candidate' "$report" 2>/dev/null || true); candidates=${candidates:-0}
            local accept
            accept=$(grep -c 'Verdict.*accept' "$report" 2>/dev/null || true); accept=${accept:-0}

            printf "<b>🔍 Knowledge Extractor: %s</b>\n\n" "$process"
            printf "📅 %s\n\n" "$DATE"
            printf "📊 Candidates: %s, Accept: %s\n\n" "$candidates" "$accept"

            if [ "$candidates" -gt 0 ]; then
                printf "To apply: in Claude say «review extraction report»"
            else
                printf "Inbox empty."
            fi
            ;;

        "audit")
            printf "<b>🔍 Knowledge Audit completed</b>\n\n📅 %s\n\nCheck the log: ~/logs/extractor/%s.log" "$DATE" "$DATE"
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

            # Previously: "No new candidates" was sent on every timer tick, even when
            # nothing had changed since the previous message -- live dump 09.10
            # caught a duplicate twice within 16 minutes with exactly this text. Branch
            # inbox-check already stays silent on an empty result (echo "" ->
            # notify.sh skips sending); this does the same for
            # consistency -- routine "nothing happened" goes into
            # silent counter (notify.sh's caller decides), not into chat on every tick.
            [ "$captured" -gt 0 ] || { echo ""; return; }
            printf "<b>🔍 Knowledge Feeder: %s</b>\n\n" "$process"
            printf "📅 %s\n\n" "$DATE"
            printf "Candidates captured today: %s\n" "$captured"
            printf "File: <code>%s</code>" "${captures_target#"$inbox_dir/"}"
            ;;

        *)
            echo ""
            ;;
    esac
}

build_buttons() {
    echo '[]'
}
