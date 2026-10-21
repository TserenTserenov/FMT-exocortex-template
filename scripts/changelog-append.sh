#!/usr/bin/env bash
# routing: helper  skill=week-close,day-close  called-by=haiku
# see DP.SC.159, DP.ROLE.059
# changelog-append.sh — idempotent update of the section [Unreleased] in CHANGELOG.md
#
# Collects git-commits since the date of the last version → writes/replaces the block [Unreleased].
# Idempotent: can be called any number of times in a row — no duplicates will appear.
#
# Usage:
#   IWE_TEMPLATE=/path/to/FMT bash changelog-append.sh
#   bash changelog-append.sh --dry-run
#
# To freeze a version (Unreleased → X.Y.Z):
#   bash changelog-flush.sh --version 0.32.0

set -uo pipefail

dry_run=false

while [[ $# -gt 0 ]]; do
    case "$1" in --dry-run) dry_run=true ;; esac
    shift
done

# Write mode must never guess the target checkout. In author worktrees the
# historical fallback pointed at the canonical clone and silently modified it.
FMT_DIR="${IWE_TEMPLATE:-}"
if [[ -z "$FMT_DIR" ]]; then
    if ! $dry_run; then
        echo "❌ Write mode requires an explicit target: IWE_TEMPLATE=/path/to/FMT" >&2
        exit 2
    fi
    FMT_DIR="${IWE_WORKSPACE:-$HOME/IWE}/IWE"
    echo "⚠️  IWE_TEMPLATE is not set; dry-run reads fallback: $FMT_DIR" >&2
fi
CHANGELOG="$FMT_DIR/CHANGELOG.md"

if [[ ! -f "$CHANGELOG" ]]; then
    echo "❌ CHANGELOG.md not found: $CHANGELOG" >&2
    exit 1
fi

# Find the date of the last named version (skipping [Unreleased])
last_date=$(grep '## \[[0-9]' "$CHANGELOG" | head -1 | grep -o '[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}' || true)
if [[ -z "$last_date" ]]; then
    echo "⚠️  Could not find the date of the last version in CHANGELOG — collecting all commits." >&2
    last_date="1970-01-01"
fi

# B2: --after exclusive — subtract 1 day so as not to lose commits from the release day
# B4: git -C instead of cd, so as not to depend on cwd on error IWE_TEMPLATE
since_date=$(date -d "$last_date - 1 day" +%Y-%m-%d 2>/dev/null \
    || date -v-1d -j -f "%Y-%m-%d" "$last_date" +%Y-%m-%d 2>/dev/null \
    || echo "$last_date")
# WP-7 Phase62 item.4: %(trailers:key=Changelog-Tag) extracts the classification (security/
# migration/behavior/optional) in a single pass together with hash+subject — DRR
# decisions/2026-08/2026-08-10-wp-7-arhgeyt-changelog-klassifikaciya-bez-lts.md.
commits=$(git -C "$FMT_DIR" log --after="$since_date" \
    --format='%h%x09%s%x09%(trailers:key=Changelog-Tag,valueonly,separator=%x2c)' 2>/dev/null || true)

if [[ -z "$commits" ]]; then
    echo "ℹ️  No new commits since $last_date — [Unreleased] is not needed."
    exit 0
fi

# Grouping by type
added=""
fixed=""
changed=""

VALID_CHANGELOG_TAGS="security migration behavior optional"

is_valid_changelog_tag() {
    local candidate="$1"
    for valid in $VALID_CHANGELOG_TAGS; do
        [[ "$candidate" == "$valid" ]] && return 0
    done
    return 1
}

while IFS=$'\t' read -r hash msg rawtag; do
    [[ -z "$hash" ]] && continue

    # Take the first trailer value that is in the allowlist; ignore the rest. trailer'trailer, that is in the allowlist; ignore the rest.
    # No valid tag → render WITHOUT a badge, do not substitute "optional" silently
    # (DRR: "no label ≠ safe, simply not classified").
    tag=""
    if [[ -n "$rawtag" ]]; then
        IFS=',' read -ra tag_candidates <<< "$rawtag"
        for candidate in "${tag_candidates[@]}"; do
            # found in code review 13.08 code review 13.08: "security, migration" (space after
            # comma) produces the candidate " migration" — without trim it will not match
            # with allowlist and a valid tag will be silently lost if it appears second, if it is second in order.
            candidate="${candidate#"${candidate%%[![:space:]]*}"}"
            candidate="${candidate%"${candidate##*[![:space:]]}"}"
            if is_valid_changelog_tag "$candidate"; then
                tag="$candidate"
                break
            fi
        done
        # Diagnostics only on real ambiguity (multiple values)
        # or an invalid single value — do not emit noise on a valid single
        # case (peer-review with Codex, 2026-08-13).
        if [[ -n "$tag" && "${#tag_candidates[@]}" -gt 1 ]]; then
            # found verify-sub-agent 13.08: tag is actually found and
            # rendered — the message must not say "without label".
            echo "⚠️  Changelog-Tag is ambiguous in commit $hash: '$rawtag' — taking first valid '$tag'" >&2
        elif [[ -z "$tag" ]]; then
            echo "⚠️  Changelog-Tag is invalid in commit $hash: '$rawtag' — rendering without label" >&2
        fi
    fi

    prefix=""
    [[ -n "$tag" ]] && prefix="[$tag] "

    case "$msg" in
        feat*|feat\(*) added+="- ${prefix}\`$hash\` $msg"$'\n' ;;
        fix*|fix\(*)   fixed+="- ${prefix}\`$hash\` $msg"$'\n' ;;
        test*|docs*)   changed+="- ${prefix}\`$hash\` $msg"$'\n' ;;
        template-sync*) ;;  # auto-commits template-sync — skipping
        *)             changed+="- ${prefix}\`$hash\` $msg"$'\n' ;;
    esac
done <<< "$commits"

# If all commits were skipped (template-sync) — do nothing
if [[ -z "$added" && -z "$fixed" && -z "$changed" ]]; then
    echo "ℹ️  Only auto-commits template-sync — [Unreleased] is not needed."
    exit 0
fi

# Build the block [Unreleased]
today=$(date +%Y-%m-%d)
new_block="## [Unreleased] — updated $today"$'\n'$'\n'
[[ -n "$added"   ]] && new_block+="### Added"$'\n'$'\n'"${added}"$'\n'
[[ -n "$changed" ]] && new_block+="### Changed"$'\n'$'\n'"${changed}"$'\n'
[[ -n "$fixed"   ]] && new_block+="### Fixed"$'\n'$'\n'"${fixed}"$'\n'

if $dry_run; then
    echo "--- dry-run: block [Unreleased] ---"
    printf '%s\n' "$new_block"
    echo "--- end ---"
    exit 0
fi

# Idempotency: remove the old [Unreleased] block if present
tmp=$(mktemp)
awk '
    /^## \[Unreleased\]/ { skip=1; next }
    skip && /^## \[/     { skip=0 }
    !skip                { print }
' "$CHANGELOG" > "$tmp"

# Prepend the new block after the header (before the first line ## [)
header_end=$(grep -n '^## \[' "$tmp" | head -1 | cut -d: -f1)
if [[ -z "$header_end" ]]; then
    # B1: CHANGELOG without named versions — correct write
    { cat "$tmp"; echo; printf '%s\n' "$new_block"; } > "$CHANGELOG"
else
    head_lines=$((header_end - 1))
    { head -n "$head_lines" "$tmp"; echo; printf '%s\n' "$new_block"; tail -n +"$header_end" "$tmp"; } > "$CHANGELOG"
fi

rm -f "$tmp"
echo "✅ [Unreleased] updated in CHANGELOG.md (commits since $last_date)"
