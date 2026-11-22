#!/usr/bin/env bash
# check-arch-version.sh — mismatch detector ARCH-versions and downstream `derived_from:` anchors
# Owner: WP-217 (sync mechanism sync). Activated by WP-263 (child) after WP-253 Phase1 ArchGate.
# Principle: the detector reports, does not modify (see. iwe-drift.sh:11).
#
# What it does:
#   1. Scans PACK-*/pack/*/02-domain-entities/DP.ARCH.*.md → extracts (id, version) from frontmatter.
#   2. Scans PACK-*/**/*.md and $IWE_GOVERNANCE_REPO/inbox/*.md → looks for `derived_from:` anchors with DP.ARCH.NNN@vX.Y.
#   3. Compares: if downstream references a version, different from current → DRIFT.
#   4. Prints markdown-report.
#
# Usage:
#   bash check-arch-version.sh                    # full report
#   bash check-arch-version.sh --critical-only    # only drift (without OK)
#   IWE_ROOT=/path bash check-arch-version.sh     # alternative root
#
# Does not depend on iwe-drift.sh — can be run independently. When iwe-drift.sh learns to
# dispatch `check: script:...` pairs, it will invoke this script automatically.

set -eu

# Load unified environment: WORKSPACE_DIR, IWE_ROOT, IWE_SCRIPTS, etc.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../.claude/lib/iwe-env-bootstrap.sh" || exit 1
MODE="${MODE:-all}"

while [ $# -gt 0 ]; do
    case "$1" in
        --critical-only) MODE="critical"; shift ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# //; s/^#//' | head -25
            exit 0
            ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

# Extract version from frontmatter ARCH-document.
# Returns a normalized version (v1 → v1.0; v2.3 → v2.3) or "?" if not found.
extract_arch_version() {
    local file="$1"
    local v
    v=$(awk '
        /^---$/ { fm++; if (fm == 2) exit }
        fm == 1 && /^version:/ {
            sub(/^version:[[:space:]]*/, "")
            sub(/[[:space:]]+$/, "")
            print
            exit
        }
    ' "$file")
    if [ -z "$v" ]; then
        echo "?"
        return
    fi
    # Normalization: v1 → v1.0, keep v2.3 as is
    case "$v" in
        v[0-9]) echo "${v}.0" ;;
        *) echo "$v" ;;
    esac
}

# Extract id from frontmatter
extract_arch_id() {
    local file="$1"
    awk '
        /^---$/ { fm++; if (fm == 2) exit }
        fm == 1 && /^id:/ {
            sub(/^id:[[:space:]]*/, "")
            sub(/[[:space:]]+$/, "")
            print
            exit
        }
    ' "$file"
}

# Normalize version from downstream-anchor (@v1 → v1.0)
normalize_ver() {
    local v="$1"
    case "$v" in
        v[0-9]) echo "${v}.0" ;;
        *) echo "$v" ;;
    esac
}

# Step 1: build a current_version table from current_version from ARCH-documents
TMP_ARCH=$(mktemp)
TMP_DRIFT=$(mktemp)
TMP_OK=$(mktemp)
trap 'rm -f "$TMP_ARCH" "$TMP_DRIFT" "$TMP_OK"' EXIT

ARCH_GLOB="$IWE_ROOT/PACK-*/pack/*/02-domain-entities/DP.ARCH.*.md"
for f in $ARCH_GLOB; do
    [ -f "$f" ] || continue
    id=$(extract_arch_id "$f")
    ver=$(extract_arch_version "$f")
    # id can be "DP.ARCH.004" or "DP.ARCH.004-decisions" — both are valid
    [ -z "$id" ] && continue
    printf "%s\t%s\t%s\n" "$id" "$ver" "$f" >> "$TMP_ARCH"
done

# Step 2: scan downstream-documents and find anchors
# Globs: all PACK-* + governance inbox (env IWE_GOVERNANCE_REPO)
DOWNSTREAM_DIRS=()
for pack in "$IWE_ROOT"/PACK-*/; do
    [ -d "$pack" ] && DOWNSTREAM_DIRS+=("${pack%/}")
done
if [ -n "${IWE_GOVERNANCE_REPO:-}" ] && [ -d "$IWE_ROOT/$IWE_GOVERNANCE_REPO/inbox" ]; then
    DOWNSTREAM_DIRS+=("$IWE_ROOT/$IWE_GOVERNANCE_REPO/inbox")
fi

# No downstream-downstream directories — nothing to check (fresh user without PACK-repo)
if [ "${#DOWNSTREAM_DIRS[@]}" -eq 0 ]; then
    echo "[check-arch-version] no PACK-* repos and IWE_GOVERNANCE_REPO not set — skipping"
    exit 0
fi

drift_count=0
ok_count=0
unknown_count=0
missing_arch_version=0

for dir in "${DOWNSTREAM_DIRS[@]}"; do
    [ -d "$dir" ] || continue
    # All .md with derived_from in frontmatter
    while IFS= read -r downstream_file; do
        # Extract all DP.ARCH.NNN@vX.Y anchors from frontmatter (first 30 lines of the file are sufficient)
        # Support for a single reference and a list [DP.ARCH.004@v2.3, DP.ARCH.005@v1]
        anchors=$(awk '
            /^---$/ { fm++; if (fm == 2) exit }
            fm == 1 && /derived_from:/ { capture = 1 }
            capture && /DP\.ARCH\./ {
                # extract all DP.ARCH.NNN[-suffix]@vX(.Y) matches from the string
                while (match($0, /DP\.ARCH\.[0-9]+(-[a-z0-9-]+)?@v[0-9]+(\.[0-9]+)?/)) {
                    print substr($0, RSTART, RLENGTH)
                    $0 = substr($0, RSTART + RLENGTH)
                }
            }
            capture && /^[a-z_]+:/ && !/derived_from:/ { capture = 0 }
        ' "$downstream_file")

        [ -z "$anchors" ] && continue

        while IFS= read -r anchor; do
            [ -z "$anchor" ] && continue
            arch_id="${anchor%@*}"
            arch_ver_raw="${anchor#*@}"
            arch_ver=$(normalize_ver "$arch_ver_raw")

            # Find current version for arch_id
            current=$(awk -F'\t' -v id="$arch_id" '$1 == id { print $2; exit }' "$TMP_ARCH")

            relpath="${downstream_file#$IWE_ROOT/}"

            if [ -z "$current" ]; then
                printf "| %s | %s | unknown | UNKNOWN | ARCH-document %s not found |\n" \
                    "$relpath" "$arch_id@$arch_ver_raw" "$arch_id" >> "$TMP_DRIFT"
                unknown_count=$((unknown_count + 1))
            elif [ "$current" = "?" ]; then
                printf "| %s | %s | %s | NO-VERSION | ARCH without explicit `version:` |\n" \
                    "$relpath" "$arch_id@$arch_ver_raw" "$current" >> "$TMP_DRIFT"
                missing_arch_version=$((missing_arch_version + 1))
            elif [ "$arch_ver" = "$current" ]; then
                printf "| %s | %s | %s | OK | — |\n" \
                    "$relpath" "$arch_id@$arch_ver_raw" "$current" >> "$TMP_OK"
                ok_count=$((ok_count + 1))
            else
                printf "| %s | %s | %s | DRIFT | downstream is behind |\n" \
                    "$relpath" "$arch_id@$arch_ver_raw" "$current" >> "$TMP_DRIFT"
                drift_count=$((drift_count + 1))
            fi
        done <<< "$anchors"
    done < <(grep -rl "^derived_from:" "$dir" 2>/dev/null | grep '\.md$' || true)
done

# Step 3: output
echo "## ARCH-version drift report ($(date +%Y-%m-%d))"
echo ""
echo "Source: WP-263 child WP-217. Manifest pair: \`arch-version-drift\`."
echo ""

# Registry of found ARCH
echo "### ARCH-documents (current versions)"
echo ""
echo "| ID | version | file |"
echo "|---|---|---|"
while IFS=$'\t' read -r id ver file; do
    relpath="${file#$IWE_ROOT/}"
    printf "| %s | %s | %s |\n" "$id" "$ver" "$relpath"
done < "$TMP_ARCH"
echo ""

# Drift / unknown / missing-version
if [ -s "$TMP_DRIFT" ]; then
    echo "### Drift (requires sync)"
    echo ""
    echo "| downstream | anchor | current | status | comment |"
    echo "|---|---|---|---|---|"
    cat "$TMP_DRIFT"
    echo ""
fi

# OK — in full mode only
if [ "$MODE" != "critical" ] && [ -s "$TMP_OK" ]; then
    echo "### OK (synchronized)"
    echo ""
    echo "| downstream | anchor | current | status | comment |"
    echo "|---|---|---|---|---|"
    cat "$TMP_OK"
    echo ""
fi

# Summary
echo "### Summary"
echo ""
echo "- ✅ OK: $ok_count"
echo "- ⚠️ DRIFT: $drift_count"
echo "- ❓ UNKNOWN (ARCH not found): $unknown_count"
echo "- ⚠️ NO-VERSION (ARCH without \`version:\`): $missing_arch_version"

if [ "$drift_count" -gt 0 ] || [ "$missing_arch_version" -gt 0 ]; then
    exit 2
fi
