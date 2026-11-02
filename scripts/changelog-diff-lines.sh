#!/usr/bin/env bash
# routing: helper  skill=notify-update,validate-template
# changelog-diff-lines.sh — extracts the added lines of CHANGELOG.md over
# a commit range, with an optional filter by the [security] tag.
#
# Single logic for .github/workflows/notify-security.yml (push) and
# validate-template.yml (push + pull_request) — WP-7 Phase 62 item 4. Extracted from
# three independent copies found by code review 13.08.2026 (DP.SC.172 P2:
# third repetition → function); a duplication bug was found there too — a bare
# `grep '\[security\]'` matched the substring anywhere in the commit text, not
# only the position of the prefix tag (false "🔒 urgent" alerts on commits like
# "fix: drop obsolete [security]-only migration shim").
#
# Usage:
#   bash changelog-diff-lines.sh <base-sha|""> [--security-only]
#
# base-sha empty or all zeros → no valid base (initial push/new
# branch): take the whole top block of CHANGELOG.md (up to the next "## [").

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
    # Anchor on the position of the prefix tag ("- [security] "), not a bare substring.
    if ! lines=$(printf '%s\n' "$lines" | awk '/^- \[security\] /'); then
        echo "ERROR: CHANGELOG security filter failed" >&2
        exit 1
    fi
fi

printf '%s\n' "$lines"
