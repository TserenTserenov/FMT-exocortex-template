#!/bin/bash
# video-scan.sh — video recording scan and linking to WP
#
# Traverses video recording directories (Zoom, Telemost and others.), finds
# new/unprocessed files, links to WP by name or date.
#
# Usage:
#   video-scan.sh                # full scan
#   video-scan.sh --new          # new only (since last scan)
#   video-scan.sh --stale        # stale only (> stale_days)
#   video-scan.sh --dry-run      # show what it will find, do not write
#
# Trigger: Day Open (step 5b), Strategy Session (video-review)
# Config: memory/day-rhythm-config.yaml → section video

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)/memory"
# WP-273 0.29.4 R6.1 fix (issue #271): runtime-resolve instead of build-time {{WORKSPACE_DIR}} — as in strategist.sh.
WORKSPACE="${IWE_WORKSPACE:-$HOME/IWE}"
LOG_DIR="$HOME/logs/synchronizer"
DATE=$(date +%Y-%m-%d)
LOG_FILE="$LOG_DIR/video-scan-$DATE.log"
STATE_FILE="$LOG_DIR/.video-scan-last"

# === Arguments ===

MODE="full"
DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --new)     MODE="new" ;;
        --stale)   MODE="stale" ;;
        --dry-run) DRY_RUN=true ;;
    esac
done

mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [video-scan] $1" | tee -a "$LOG_FILE"
}

# === Reading config (YAML → variables) ===
# Simple parser — no dependencies (yq/jq not required)

parse_config() {
    local config="$CONFIG_DIR/day-rhythm-config.yaml"
    if [ ! -f "$config" ]; then
        log "ERROR: config not found: $config"
        exit 1
    fi

    VIDEO_ENABLED=$(awk '/^video:/{found=1} found && /enabled:/{print $2; exit}' "$config")
    STALE_DAYS=$(awk '/^video:/{found=1} found && /stale_days:/{print $2; exit}' "$config")
    TRANSCRIPTS_DIR=$(awk '/^video:/{found=1} found && /transcripts_dir:/{print $2; exit}' "$config")

    # Directories: parse YAML list (lines with "- ")
    VIDEO_DIRS=()
    local in_dirs=false
    while IFS= read -r line; do
        # Start of section directories:
        if [[ "$line" =~ ^[[:space:]]+directories: ]]; then
            in_dirs=true
            continue
        fi
        # Inside directories — lines with "- "
        if [ "$in_dirs" = true ]; then
            if [[ "$line" =~ ^[[:space:]]+-[[:space:]]+(.*) ]]; then
                local dir="${BASH_REMATCH[1]}"
                # Strip quotes
                dir="${dir#\"}"
                dir="${dir%\"}"
                dir="${dir#\'}"
                dir="${dir%\'}"
                # Expand ~
                dir="${dir/#\~/$HOME}"
                VIDEO_DIRS+=("$dir")
            elif [[ "$line" =~ ^[[:space:]]+[a-z] ]]; then
                # Next key — exit from directories
                in_dirs=false
            fi
        fi
    done < "$config"

    # Extensions: parse array [mp4, mov, ...]
    EXTENSIONS=$(awk '/^video:/{found=1} found && /extensions:/{gsub(/[\[\]]/, ""); n=split($0, a, ":"); val=a[2]; gsub(/[ ]/, "", val); split(val, b, ","); for(i in b) print b[i]; exit}' "$config")

    VIDEO_ENABLED="${VIDEO_ENABLED:-false}"
    STALE_DAYS="${STALE_DAYS:-3}"
    TRANSCRIPTS_DIR="${TRANSCRIPTS_DIR:-transcripts/}"
}

# === Search for video files across all directories ===

find_videos() {
    for video_dir in "${VIDEO_DIRS[@]}"; do
        [ -d "$video_dir" ] || continue

        local find_args=()
        find_args+=("$video_dir" "-maxdepth" "3" "-type" "f" "(")

        local first=true
        for ext in $EXTENSIONS; do
            if [ "$first" = true ]; then
                first=false
            else
                find_args+=("-o")
            fi
            find_args+=("-name" "*.$ext")
        done
        find_args+=(")")

        # Filter by mode
        case "$MODE" in
            new)
                if [ -f "$STATE_FILE" ]; then
                    find_args+=("-newer" "$STATE_FILE")
                fi
                ;;
            stale)
                find_args+=("-mtime" "+${STALE_DAYS}")
                ;;
        esac

        # macOS-macOS-compatible output (without GNU -printf) (without GNU -printf)
        while IFS= read -r -d '' file; do
            local mtime
            mtime=$(stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null || echo 0)
            echo "$mtime $file"
        done < <(find "${find_args[@]}" -print0 2>/dev/null)
    done | sort -rn | cut -d' ' -f2-
}

# === Binding to WP by file name ===

match_wp() {
    local filename="$1"
    local base
    base=$(basename "$filename")

    # Pattern 1: WP-{N} in the file name
    if [[ "$base" =~ WP-([0-9]+) ]]; then
        echo "WP-${BASH_REMATCH[1]}"
        return 0
    fi

    # Pattern 2: Date in the file name (YYYY-MM-DD)
    if [[ "$base" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}) ]]; then
        echo "date:${BASH_REMATCH[1]}"
        return 0
    fi

    echo "unmatched"
    return 1
}

# === Transcript check ===

has_transcript() {
    local video_path="$1"
    local base
    base=$(basename "$video_path" | sed 's/\.[^.]*$//')

    # Check transcripts/ next to the video and in the first directory
    local video_parent
    video_parent=$(dirname "$video_path")

    [ -f "$video_parent/$TRANSCRIPTS_DIR/${base}.txt" ] || \
    [ -f "$video_parent/$TRANSCRIPTS_DIR/${base}.md" ] || \
    [ -f "${VIDEO_DIRS[0]}/$TRANSCRIPTS_DIR/${base}.txt" ] 2>/dev/null || \
    [ -f "${VIDEO_DIRS[0]}/$TRANSCRIPTS_DIR/${base}.md" ] 2>/dev/null
}

# === Video duration (ffprobe) ===

get_duration() {
    local video_path="$1"
    if command -v ffprobe &>/dev/null; then
        ffprobe -v quiet -show_entries format=duration -of csv=p=0 "$video_path" 2>/dev/null | awk '{printf "%.0f", $1/60}'
    else
        echo "?"
    fi
}

# === Source (which folder) ===

get_source() {
    local video_path="$1"
    local dir
    dir=$(dirname "$video_path")
    # Show the name of the top-level parent folder
    for vd in "${VIDEO_DIRS[@]}"; do
        if [[ "$video_path" == "$vd"* ]]; then
            basename "$vd"
            return
        fi
    done
    basename "$dir"
}

# === Main scan ===

scan() {
    parse_config

    if [ "$VIDEO_ENABLED" = "false" ]; then
        log "SKIP: video.enabled=false in the config"
        exit 0
    fi

    if [ "${#VIDEO_DIRS[@]}" -eq 0 ]; then
        log "WARN: video.directories is empty — nothing to scan"
        exit 0
    fi

    log "=== Video Scan Started (mode=$MODE) ==="
    log "Directories: ${VIDEO_DIRS[*]}"

    local total=0
    local matched=0
    local unmatched=0
    local stale=0
    local no_transcript=0

    # Output in format for Day Open
    echo ""
    echo "## Video recordings ($MODE)"
    echo ""
    echo "| File | Source | Dur. | WP | Transcript | Age |"
    echo "|------|----------|-------|----|------------|---------|"

    while IFS= read -r video_path; do
        [ -z "$video_path" ] && continue
        total=$((total + 1))

        local fname
        fname=$(basename "$video_path")
        local source
        source=$(get_source "$video_path")
        local duration
        duration=$(get_duration "$video_path")
        local wp_match
        wp_match=$(match_wp "$video_path" || true)
        local has_tr="no"
        has_transcript "$video_path" && has_tr="yes"
        local age_days
        age_days=$(( ($(date +%s) - $(stat -c %Y "$video_path" 2>/dev/null || stat -f %m "$video_path" 2>/dev/null || echo 0)) / 86400 ))

        # Count
        if [ "$wp_match" = "unmatched" ]; then
            unmatched=$((unmatched + 1))
            wp_match="—"
        else
            matched=$((matched + 1))
        fi
        [ "$has_tr" = "no" ] && no_transcript=$((no_transcript + 1))
        [ "$age_days" -gt "$STALE_DAYS" ] && stale=$((stale + 1))

        # Overdue marker
        local age_str="${age_days}d"
        [ "$age_days" -gt "$STALE_DAYS" ] && age_str="⚠️ ${age_str}"

        echo "| $fname | $source | ${duration}min | $wp_match | $has_tr | $age_str |"

    done < <(find_videos)

    echo ""
    echo "**Total:** $total videos ($matched linked, $unmatched without WP, $stale stale, $no_transcript without transcript)"

    log "Total: $total videos, $matched linked, $unmatched without WP, $stale stale"

    # Update timestamp of the last scan
    if [ "$DRY_RUN" = false ]; then
        touch "$STATE_FILE"
    fi

    log "=== Video Scan Completed ==="
}

scan
