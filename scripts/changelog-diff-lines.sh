#!/usr/bin/env bash
# routing: helper  skill=notify-update,validate-template
# changelog-diff-lines.sh — extracts added lines CHANGELOG.md over
# commit range, with an optional filter by tag [security].
#
# Shared logic for .github/workflows/notify-security.yml (push) and
# validate-template.yml (push + pull_request) — WP-7 Phase62 item.4. Extracted from
# three independent copies found by code review 13.08.2026 (DP.SC.172 P2:, found code review 13.08.2026 (DP.SC.172 P2:
# third repetition → function); a duplication bug was also found there — bare
# `grep '\[security\]'` matched the substring anywhere in the commit message, not
# only the position of the tag-prefix (false "🔒 urgent"-alerts on commits of the form
# "fix: drop obsolete [security]-only migration shim").
#
# Usage:
#   bash changelog-diff-lines.sh <base-sha|""> [--security-only]
#
# base-sha base-sha is empty or all zeros meaning no valid base exists (initial push or new → no valid base (initial push/new
# branch): take the entire top block CHANGELOG.md (up to the next "## [").

set -uo pipefail

FMT_DIR="${IWE_TEMPLATE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CHANGELOG="$FMT_DIR/CHANGELOG.md"
base="${1:-}"
security_only=false
[[ "${2:-}" == "--security-only" ]] && security_only=true

if [[ ! -f "$CHANGELOG" ]]; then
    echo "ERROR: CHANGELOG.md is missing: $CHANGELOG" >&2
    exit 1
fi

if [[ -z "$base" || "$base" == "0000000000000000000000000000000000000000" ]]; then
    if ! lines=$(awk '/^## \[/{n++} n==1' "$CHANGELOG"); then
        echo "ERROR: CHANGELOG.md extraction failed" >&2
        exit 1
    fi
else
    if ! diff_output=$(git -C "$FMT_DIR" diff --unified=0 "$base"..HEAD -- CHANGELOG.md 2>&1); then
        echo "ERROR: git diff failed (base=$base): $diff_output" >&2
        exit 1
    fi
    if ! lines=$(printf '%s\n' "$diff_output" | awk '
        substr($0, 1, 1) == "+" && substr($0, 1, 3) != "+++" { print substr($0, 2) }
    '); then
        echo "ERROR: CHANGELOG diff parsing failed" >&2
        exit 1
    fi
fi

if $security_only; then
    # Anchor to the position of the tag-prefix ("- [security] "), not a bare substring.
    if ! lines=$(printf '%s\n' "$lines" | awk '/^- \[security\] /'); then
        echo "ERROR: CHANGELOG security filter failed" >&2
        exit 1
    fi
fi

printf '%s\n' "$lines"
