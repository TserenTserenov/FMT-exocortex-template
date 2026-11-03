#!/usr/bin/env bash
# author-source-gate.sh — a PR must not change a template file that has an author
# source without saying where the source change is (WP-529 Ф248, 03.11.2026).
#
# Why: the delivery pipeline runs author -> template. PR #1424 (WP-610 Ф9) translated the
# comments of 22 files directly in the template; the author sources stayed unchanged and
# template-sync.sh counted 23 files as "repair". No CI check knew those files had a source.
#
# The list of such files is .github/author-sourced-paths.txt (one path per line), rewritten
# by template-sync.sh on every real run, so it follows the sync manifest.
#
# Usage: author-source-gate.sh <base-ref> <head-ref>
#   env PR_BODY   pull request description (trailer may live there)
# Passes when:
#   - the list file is missing or empty (notice only), or
#   - no changed file is in the list, or
#   - every commit in <base>..<head> is a "template-sync: propagate" commit, or
#   - a line "Author-Source: <repo>#<n> | <sha> | pending #<n>" is in the PR body or in a commit message.
# Exit 1 otherwise, with the list of files.
set -euo pipefail

BASE="${1:?base ref}"
HEAD="${2:?head ref}"
LIST="${AUTHOR_SOURCED_LIST:-.github/author-sourced-paths.txt}"
TRAILER_RE='^Author-Source:[[:space:]]+([A-Za-z0-9_.-]+#[0-9]+|[0-9a-f]{7,40}|pending #[0-9]+)[[:space:]]*$'

if [ ! -s "$LIST" ]; then
    echo "::notice::author-source-gate: $LIST is missing or empty - gate skipped"
    exit 0
fi

changed=$(git diff --name-only "$BASE...$HEAD")
hits=$(printf '%s\n' "$changed" | grep -Fxf "$LIST" || true)
if [ -z "$hits" ]; then
    echo "author-source-gate: no changed file has an author source"
    exit 0
fi

subjects=$(git log --format=%s "$BASE..$HEAD")
if [ -n "$subjects" ] && ! printf '%s\n' "$subjects" | grep -qv '^template-sync: propagate'; then
    echo "author-source-gate: all commits are template-sync deliveries"
    exit 0
fi

if { printf '%s\n' "${PR_BODY:-}"; git log --format=%B "$BASE..$HEAD"; } | tr -d '\r' | grep -Eq "$TRAILER_RE"; then
    echo "author-source-gate: Author-Source trailer found"
    exit 0
fi

echo "::error::author-source-gate: the PR changes files that have an author source:"
printf '%s\n' "$hits" | sed 's/^/  - /'
echo "Change the source first (author repo) and add a line to the PR description:"
echo "  Author-Source: <repo>#<pr-number>   or   Author-Source: <commit-sha>   or   Author-Source: pending #<issue>"
echo "Mass edits of such files (translation, formatting, lint) belong in the source, not in the template."
exit 1
