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
# Exit 1 otherwise, with the list of files. Exit 2 when git or grep fails.
#
# Every git call is read into a variable and checked on its own; grep then searches that
# text through a here-string. A pipeline would hide failures: grep -q exits on the first
# match and the writer dies of SIGPIPE (false refusal, or a false pass under "!"), and
# pipefail reports the last failing member, so a git error looked like "no trailer".
set -euo pipefail

BASE="${1:?base ref}"
HEAD="${2:?head ref}"
LIST="${AUTHOR_SOURCED_LIST:-.github/author-sourced-paths.txt}"
TRAILER_RE='^Author-Source:[[:space:]]+([A-Za-z0-9_.-]+#[0-9]+|[0-9a-f]{7,40}|pending #[0-9]+)[[:space:]]*$'

# check_grep <what> <rc>: grep's 0 (match) and 1 (no match) pass; anything else stops the gate.
check_grep() {
    [ "$2" -le 1 ] || { echo "::error::author-source-gate: grep over $1 failed (rc=$2)"; exit 2; }
}

if [ ! -s "$LIST" ]; then
    echo "::notice::author-source-gate: $LIST is missing or empty - gate skipped"
    exit 0
fi

changed=$(git diff --name-only "$BASE...$HEAD") \
    || { echo "::error::author-source-gate: git diff $BASE...$HEAD failed"; exit 2; }
rc=0
hits=$(grep -Fxf "$LIST" <<<"$changed") || rc=$?
check_grep "changed files" "$rc"
if [ -z "$hits" ]; then
    echo "author-source-gate: no changed file has an author source"
    exit 0
fi

subjects=$(git log --format=%s "$BASE..$HEAD") \
    || { echo "::error::author-source-gate: git log $BASE..$HEAD failed"; exit 2; }
if [ -n "$subjects" ]; then
    rc=0
    grep -qv '^template-sync: propagate' <<<"$subjects" || rc=$?
    check_grep "commit subjects" "$rc"
    if [ "$rc" -eq 1 ]; then
        echo "author-source-gate: all commits are template-sync deliveries"
        exit 0
    fi
fi

messages=$(git log --format=%B "$BASE..$HEAD") \
    || { echo "::error::author-source-gate: git log $BASE..$HEAD failed"; exit 2; }
text="${PR_BODY:-}"$'\n'"$messages"
rc=0
grep -Eq "$TRAILER_RE" <<<"${text//$'\r'/}" || rc=$?
check_grep "PR body and commit messages" "$rc"
if [ "$rc" -eq 0 ]; then
    echo "author-source-gate: Author-Source trailer found"
    exit 0
fi

echo "::error::author-source-gate: the PR changes files that have an author source:"
printf '%s\n' "$hits" | sed 's/^/  - /'
echo "Change the source first (author repo) and add a line to the PR description:"
echo "  Author-Source: <repo>#<pr-number>   or   Author-Source: <commit-sha>   or   Author-Source: pending #<issue>"
echo "Mass edits of such files (translation, formatting, lint) belong in the source, not in the template."
exit 1
