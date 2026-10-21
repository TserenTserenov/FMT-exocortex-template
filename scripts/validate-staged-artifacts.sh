#!/usr/bin/env bash
# routing: guard  deterministic=true
# validate-staged-artifacts.sh — correctness boundary pre-commit for
# protocol artifacts governance-repo (issue #544).
#
# PreToolUse-hook protocol-artifact-validate.sh — early layer of fast feedback
# feedback, but it reads the index BEFORE the command is executed, so with the combined form
# `git add … && git commit` stays silent. This script is called by the REAL git-hook
# pre-commit — it sees the index after any form of add (globs, -A/-u, combined
# commands) and reads staged blob (`git show :path`), not the working tree:
# with partial staging the exact content that will go into the, that will go into the
# commit. ALL staged staged-artifacts of each type, not just one
# lexicographically last.
#
# Usage: from .githooks/pre-commit governance-repo (cwd = repo root).
# All output — to stderr: stdout git-hook stdout is not guaranteed to be visible to the user.
# Exit 0 — commit is allowed; exit 1 — block with a human-readable breakdown.
set -uo pipefail

TMPDIR_OWN=$(mktemp -d "${TMPDIR:-/tmp}/staged-artifacts.XXXXXX")
trap 'rm -rf "$TMPDIR_OWN"' EXIT HUP INT TERM

WORKSPACE="${IWE_WORKSPACE:-${IWE_ROOT:-$(cd "$(git rev-parse --show-toplevel)/.." 2>/dev/null && pwd || true)}}"
GOV_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

ERRORS=()

# find-python3.sh resolver (issue #764): $WORKSPACE/scripts/lib/find-python3.sh
# never existed on any install — scripts/lib/ lives inside the template, not
# in the workspace root. Resolve via $IWE_SCRIPTS first (setup.sh's own var),
# then self-relative to this script's own governance-repo scripts/lib/.
resolve_find_python3() {
    local candidate
    if [ -n "${IWE_SCRIPTS:-}" ] && [ -f "$IWE_SCRIPTS/lib/find-python3.sh" ]; then
        printf '%s\n' "$IWE_SCRIPTS/lib/find-python3.sh"
        return 0
    fi
    candidate="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)/lib/find-python3.sh"
    if [ -f "$candidate" ]; then
        printf '%s\n' "$candidate"
        return 0
    fi
    return 1
}

err() { ERRORS+=("$1"); }

# staged_to_tmp <path> — staged blob to a temporary file; prints the path.
staged_to_tmp() {
    local p="$1" tmp
    tmp=$(mktemp "$TMPDIR_OWN/blob.XXXXXX")
    if git show ":$p" > "$tmp" 2>/dev/null; then
        printf '%s\n' "$tmp"
    else
        rm -f "$tmp"
        return 1
    fi
}

validate_dayplan() { # <staged-path> <tmpfile>
    local rel="$1" f="$2"
    local section
    local SECTIONS=(
      "Plan for Today|Plan for Today|Today.s Plan"
      "Calendar|Calendar"
      "IWE Overnight|IWE Overnight"
      "Notes Review|Notes Review"
      "Yesterday|Yesterday"
    )
    for section in "${SECTIONS[@]}"; do
        grep -qE "$section" "$f" || err "DayPlan $rel: missing section «${section}»"
    done

    local headings
    headings=$(grep -cE '^## |^[[:space:]]*<summary>' "$f" 2>/dev/null || true)
    if [ "${headings:-0}" -lt 3 ]; then
        err "DayPlan $rel: sections (## or <summary>) fewer than 3 (found: ${headings:-0})"
    fi

    local calendar_lines
    calendar_lines=$(awk 'f && /^## /{exit} /Calendar|Calendar/{f=1} f' "$f" 2>/dev/null | wc -l | tr -d ' ')
    if [ "${calendar_lines:-0}" -lt 3 ]; then
        err "DayPlan $rel: section «Calendar» empty or too short (${calendar_lines:-0} lines)"
    fi

    if grep -q "Scout Findings Scout" "$f" 2>/dev/null; then
        if ! awk 'f && /^## /{exit} /Scout Findings Scout/{f=1} f' "$f" 2>/dev/null | grep -iqE 'found|capture|status|none|find|disabled|not configured'; then
            err "DayPlan $rel: section «Scout Findings Scout» empty (accepted markers are 'no findings', 'disabled', 'not configured')"
        fi
    fi

    if ! grep -qE "~[0-9]+[.,]?[0-9]*x" "$f" && ! grep -qiE "multiplier.*(not counting|not set)" "$f"; then
        err "DayPlan $rel: multiplier not found — required '~N.Nx' in the budget line or an explicit note «multiplier not counted»"
    fi

    # Mandatory check — only if configured. Config exists, but
    # is not readable (broken YAML) OR python3 cannot be resolved — both equally
    # fail-closed (issue #765): a mandatory gate must not silently
    # skip the check due to-an infrastructure error, resolver python3
    # no more reliable, than the YAML.
    local config="$WORKSPACE/memory/day-rhythm-config.yaml"
    # issue #773 — I proposed my own resolver, but while this session was in progress,
    # the same bug was independently fixed by a parallel session as issue #764/#765
    # (PR #769): resolve_find_python3() below — already merged version,
    # additionally performs mandatory-check fail-closed (not WARN-skip,
    # as I had proposed). Taking their version, not keeping a duplicate implementation
    # of the same fact (OwnerIntegrity) — see. issue-comment #773.
    local py="" py_resolver=""
    py_resolver=$(resolve_find_python3) || py_resolver=""
    if [ -n "$py_resolver" ]; then
        py=$("$py_resolver" 2>/dev/null) || py=""
    fi
    if [ -f "$config" ]; then
        if [ -z "$py" ]; then
            err "DayPlan $rel: day-rhythm-config.yaml exists, but python3 cannot be resolved (find-python3.sh not found or did not return an interpreter) — mandatory-check is not possible, fail-closed"
        else
            # Codes: 0 = mandatory is configured; 1 = valid config (map)
            # without mandatory; 2 = any error (missing PyYAML, malformed YAML, root
            # not map, including empty file/null) — fail-closed (review #544).
            local py_rc=0
            "$py" -c "
import sys
try:
    import yaml
    d = yaml.safe_load(open(sys.argv[1]))
except Exception:
    sys.exit(2)
if not isinstance(d, dict):
    sys.exit(2)
sys.exit(0 if d.get('mandatory_daily_wps') else 1)
" "$config" 2>/dev/null || py_rc=$?
            case "$py_rc" in
                0)
                    grep -qi "mandatory" "$f" || err "DayPlan $rel: mandatory check not found (mandatory_daily_wps is configured)"
                    ;;
                1)
                    : # valid config without mandatory — check is not required
                    ;;
                *)
                    # 2 — read errors/schema; other exit codes (126/127/signal) —
                    # also fail-closed: unknown check outcome ≠ «not
                    # configured».
                    err "DayPlan $rel: day-rhythm-config.yaml exists, but cannot be read (missing PyYAML / malformed or empty YAML / root is not map / interpreter exited with rc=$py_rc) — mandatory-check is not possible, fail-closed"
                    ;;
            esac
        fi
    fi

    if ! grep -qE "~[0-9]+[.,]?[0-9]* ?[hh] WP" "$f"; then
        err "DayPlan $rel: day budget is not in the format '~Xh WP / ~Yh phys'"
    fi

    # Carry-over: previous DayPlan is looked up on disk (other files — not part of
    # the index, that is fine), the artifact itself is validated from staged blob above.
    local prev
    prev=$(ls "$GOV_ROOT"/current/DayPlan\ *.md 2>/dev/null | sort | tail -2 | head -1)
    if [ -n "$prev" ] && [ "$prev" != "$GOV_ROOT/$rel" ]; then
        grep -qiE 'carry.over|carry_over' "$f" || \
            err "DayPlan $rel: carry-over from the previous Day Close is missing (previous: $(basename "$prev"))"
    fi
}

validate_weekplan() { # <staged-path> <tmpfile>
    local rel="$1" f="$2"
    local lines headings
    lines=$(wc -l < "$f" | tr -d ' ')
    headings=$(grep -cE '^## |^[[:space:]]*<summary>' "$f" 2>/dev/null || true)
    if [ "${lines:-0}" -gt 80 ] && [ "${headings:-0}" -lt 3 ]; then
        err "WeekPlan $rel: more than 80 lines ($lines), but sections (## or <summary>) fewer than 3 (${headings:-0}) — structure it using ## or <details><summary>"
    fi
}

validate_weekreport() { # <staged-path> <tmpfile>
    local rel="$1" f="$2"
    grep -q "Results" "$f" || err "WeekReport $rel: missing section «Results»"
}

# Iterate over ALL staged-artifacts of each type (not just one sort|tail -1):
# a commit with two WeekPlan must not hide an invalid one behind a valid one.
# -z + --diff-filter=ACMRT: names with spaces/unicode does not break parsing;
# deleted files are not checked (nothing to check), type-change (file became
# a symlink) — is checked. Index enumeration — fail-closed: could not
# read the index → block, not a silent skip (review #544, round 2).
STAGED_FILE="$TMPDIR_OWN/staged.list"
if ! git diff --cached --name-only -z --diff-filter=ACMRT > "$STAGED_FILE" 2>"$TMPDIR_OWN/staged.err"; then
    echo "⛔ Failed to enumerate the index (git diff --cached) — commit is blocked (fail-closed):" >&2
    sed 's/^/  /' "$TMPDIR_OWN/staged.err" >&2
    exit 1
fi
while IFS= read -r -d '' rel; do
    case "$rel" in
        current/DayPlan*.md)    kind=dayplan ;;
        current/WeekPlan*.md)   kind=weekplan ;;
        current/WeekReport*.md) kind=weekreport ;;
        *) continue ;;
    esac
    tmp=$(staged_to_tmp "$rel") || {
        echo "⛔ Failed to read staged blob $rel — commit is blocked (fail-closed)." >&2
        exit 1
    }
    case "$kind" in
        dayplan)    validate_dayplan "$rel" "$tmp" ;;
        weekplan)   validate_weekplan "$rel" "$tmp" ;;
        weekreport) validate_weekreport "$rel" "$tmp" ;;
    esac
    rm -f "$tmp"
done < "$STAGED_FILE"

if [ ${#ERRORS[@]} -gt 0 ]; then
    echo "⛔ PROTOCOL ARTIFACT VALIDATION FAILED (pre-commit, staged blob):" >&2
    printf '  - %s\n' "${ERRORS[@]}" >&2
    echo "Validating the contents of the INDEX (git show :path), not the working tree (git show :path), not the working tree —" >&2
    echo "after editing the file run git add again git add." >&2
    exit 1
fi
exit 0
