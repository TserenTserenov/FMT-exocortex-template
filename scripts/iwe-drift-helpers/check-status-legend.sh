#!/usr/bin/env bash
# check-status-legend.sh — status legend drift detector WP and format compliance in REGISTRY
# Owner: WP-217 (sync mechanism sync). Activated WP-267 (child) after bug in linear-sync.sh 25 Apr.
# Principle: the detector reports, does not modify (see. iwe-drift.sh:11).
#
# What it checks (3 invariant'invariants):
#   I1. **Legend completeness:** all status-emoji, found in the table WP-REGISTRY.md,
#       are documented in the legend at the top of the file. A new emoji with no entry in the legend → DRIFT.
#   I2. **Format compliance — active id:** rows with plain id `| <num> |` have active status
#       (NOT from the terminal set {✅, 📦, ↗️, ❌}).
#   I3. **Format compliance — terminal id:** rows with crossed id `| ~~<num>~~ |` have
#       a terminal status from {✅, 📦, ↗️, ❌}.
#
# I2 + I3 — invariant id-format ↔ status (see. .claude/rules/formatting.md «Tables with WP»).
# Broken = mismatch row-format and status, which breaks the counters (linear-sync.sh, day-close.sh).
#
# Usage:
#   bash check-status-legend.sh                 # full report
#   bash check-status-legend.sh --critical-only # violations only
#   IWE_ROOT=/path bash check-status-legend.sh
#
# Does not depend on iwe-drift.sh — can be run independently. When iwe-drift.sh learns to
# dispatch `check: script:...` pairs, it will invoke this script automatically.

set -eu

# Load unified environment: WORKSPACE_DIR, IWE_ROOT, IWE_SCRIPTS, etc.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../.claude/lib/iwe-env-bootstrap.sh" || exit 1
REGISTRY="${REGISTRY:-$IWE_ROOT/${IWE_GOVERNANCE_REPO:-}/docs/WP-REGISTRY.md}"
MODE="${MODE:-all}"

# Terminal statuses — WP closure. Source: legend WP-REGISTRY.md.
# Changing this list = an architectural decision on the evolution of the lifecycle WP.
TERMINAL_STATUSES=("✅" "📦" "↗️" "❌")

while [ $# -gt 0 ]; do
    case "$1" in
        --critical-only) MODE="critical"; shift ;;
        --registry) REGISTRY="$2"; shift 2 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# //; s/^#//' | head -30
            exit 0
            ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

if [ ! -f "$REGISTRY" ]; then
    echo "REGISTRY not found: $REGISTRY" >&2
    exit 1
fi

# Extract the set of emoji from the legend.
# Both supported delivery forms are handled: Status and Description and: «Status | Description» and
# «Emoji | Status | What it means». The header identifies the column with emoji.
# Returns one emoji per line.
extract_legend_emojis() {
    awk '
        function trim(value) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            return value
        }
        /^\|/ {
            n = split($0, fields, "|")
            if (in_legend == 0) {
                for (i = 2; i < n; i++) {
                    header = trim(fields[i])
                    if (header == "Emoji") emoji_col = i
                    if (header == "Description") has_description = 1
                    if (header == "Status") status_col = i
                }
                if (emoji_col > 0 || (status_col > 0 && has_description)) {
                    if (emoji_col == 0) emoji_col = status_col
                    in_legend = 1
                    next
                }
            }
        }
        in_legend && /^\|---/ { next }
        in_legend && /^\|/ {
            n = split($0, fields, "|")
            if (n >= emoji_col) {
                emoji = trim(fields[emoji_col])
                if (emoji != "") print emoji
            }
            next
        }
        in_legend && /^[^|]/ { in_legend = 0 }
    ' "$REGISTRY"
}

# Extract the set of emoji from the column «St»/«Status» in the WP table WP.
# The column is identified by its header: column order is a configurable part: column order — configurable part
# of the registry, so a fixed index here produced false violations.
# Returns one emoji per line (with duplicates — whoever needs deduplication, filters with sort -u sort -u).
extract_table_emojis() {
    awk '
        function trim(value) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            return value
        }
        /^\|/ {
            n = split($0, fields, "|")
            if (trim(fields[2]) == "#") status_col = 0
            if (status_col == 0) {
                for (i = 2; i < n; i++) {
                    header = trim(fields[i])
                    if (header == "St" || header == "Status") {
                        status_col = i
                        next
                    }
                }
            }
        }
        /^\|[[:space:]]*(~~)?[0-9]+/ {
            n = split($0, fields, "|")
            if (status_col > 0 && n >= status_col) {
                status = trim(fields[status_col])
                gsub(/~~/, "", status)
                if (status != "") print status
            }
        }
    ' "$REGISTRY"
}

# Extract pairs (id_format, status) for format compliance check.
# id_format: "active" if plain `| 263 |`, "terminal" if crossed `| ~~263~~ |`.
extract_id_status_pairs() {
    awk '
        function trim(value) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            return value
        }
        /^\|/ {
            n = split($0, fields, "|")
            if (trim(fields[2]) == "#") status_col = 0
            if (status_col == 0) {
                for (i = 2; i < n; i++) {
                    header = trim(fields[i])
                    if (header == "St" || header == "Status") {
                        status_col = i
                        next
                    }
                }
            }
        }
        /^\|[[:space:]]*(~~)?[0-9]+/ {
            n = split($0, fields, "|")
            if (status_col == 0 || n < status_col) next
            id_field = fields[2]
            status_field = fields[status_col]
            id_field = trim(id_field)
            status_field = trim(status_field)
            gsub(/~~/, "", status_field)

            if (match(id_field, /^~~[0-9]+~~$/)) {
                id_format = "terminal"
                gsub(/~~/, "", id_field)
            } else if (match(id_field, /^[0-9]+$/)) {
                id_format = "active"
            } else {
                next  # invalid format, skip
            }

            print id_field "\t" id_format "\t" status_field
        }
    ' "$REGISTRY"
}

# Set of terminal statuses as regex
is_terminal_status() {
    local s="$1"
    for t in "${TERMINAL_STATUSES[@]}"; do
        if [ "$s" = "$t" ]; then
            return 0
        fi
    done
    return 1
}

# Step 1: Legend completeness (I1)
TMP_LEGEND=$(mktemp)
TMP_TABLE=$(mktemp)
TMP_VIOLATIONS=$(mktemp)
trap 'rm -f "$TMP_LEGEND" "$TMP_TABLE" "$TMP_VIOLATIONS"' EXIT

extract_legend_emojis > "$TMP_LEGEND"
extract_table_emojis | sort -u > "$TMP_TABLE"

undocumented_count=0
while IFS= read -r emoji; do
    [ -z "$emoji" ] && continue
    if ! grep -qxF "$emoji" "$TMP_LEGEND"; then
        printf "| I1 | undocumented-status | %s | Emoji appears in the table, but is absent from the legend |\n" "$emoji" >> "$TMP_VIOLATIONS"
        undocumented_count=$((undocumented_count + 1))
    fi
done < "$TMP_TABLE"

# Step 2 & 3: Format compliance (I2, I3)
mismatch_count=0
ok_count=0
while IFS=$'\t' read -r wp_id id_format status; do
    [ -z "$wp_id" ] && continue
    if [ "$id_format" = "active" ]; then
        # active id → status must NOT be terminal
        if is_terminal_status "$status"; then
            printf "| I2 | active-id-with-terminal-status | WP-%s | id=plain but status=%s (terminal). Should be ~~%s~~ |\n" "$wp_id" "$status" "$wp_id" >> "$TMP_VIOLATIONS"
            mismatch_count=$((mismatch_count + 1))
        else
            ok_count=$((ok_count + 1))
        fi
    elif [ "$id_format" = "terminal" ]; then
        # terminal id → status MUST be terminal
        if ! is_terminal_status "$status"; then
            printf "| I3 | terminal-id-with-active-status | WP-%s | id=~~%s~~ but status=%s (active). Remove strikethrough or change the status |\n" "$wp_id" "$wp_id" "$status" >> "$TMP_VIOLATIONS"
            mismatch_count=$((mismatch_count + 1))
        else
            ok_count=$((ok_count + 1))
        fi
    fi
done < <(extract_id_status_pairs)

# Step 4: output
echo "## WP-status legend drift report ($(date +%Y-%m-%d))"
echo ""
echo "Source: WP-267 child WP-217. Manifest pair: \`wp-status-legend-drift\`."
echo "REGISTRY: $REGISTRY"
echo ""

if [ "$MODE" != "critical" ]; then
    echo "### Legend (source of truth)"
    echo ""
    echo '```'
    cat "$TMP_LEGEND"
    echo '```'
    echo ""
    echo "Terminal statuses (hardcoded in the script): ${TERMINAL_STATUSES[*]}"
    echo "Active = everything else from the legend. Any new status is active by default active."
    echo ""
fi

if [ -s "$TMP_VIOLATIONS" ]; then
    echo "### Violations"
    echo ""
    echo "| invariant | type | object | details |"
    echo "|---|---|---|---|"
    cat "$TMP_VIOLATIONS"
    echo ""
fi

# Summary
echo "### Summary"
echo ""
echo "- ✅ format-compliance OK: $ok_count"
echo "- ⚠️ undocumented status emoji (I1): $undocumented_count"
echo "- ⚠️ format-compliance violations (I2+I3): $mismatch_count"

if [ "$undocumented_count" -gt 0 ] || [ "$mismatch_count" -gt 0 ]; then
    exit 2
fi
