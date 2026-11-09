#!/usr/bin/env bash
# light-onboarding-state.sh — single source of the "new person" predicate for the
# light onboarding (WP-406 Ф40, light-onboarding v1.0.2). Both the UserPromptSubmit
# hook wp-gate-reminder.sh and the /onboarding skill call this script, so the rule
# lives in one place.
#
# Light onboarding is ACTIVE when:
#   .claude/state/light-onboarding-force exists
#   OR ( .claude/state/light-onboarding-done is absent
#        AND .claude/state/wp-numbers is absent
#        AND the governance repo has no work: no WP row in docs/WP-REGISTRY.md,
#            no inbox/WP-* card, no current/DayPlan* )
# On a fresh install no working-state signal exists (observed 09.11 on a clean
# setup.sh --core install), so a new person gets the onboarding; anyone who already
# works in the environment never gets it back after an update or a repeated setup.sh.
#
# Usage:
#   light-onboarding-state.sh status [--quiet]  prints active|inactive; exit 0 = active, 1 = inactive
#   light-onboarding-state.sh done              onboarding passed: create done, remove force
#   light-onboarding-state.sh reset             explicit reset: create force (work state is untouched)
#
# Workspace: $IWE_WORKSPACE, else $CLAUDE_PROJECT_DIR, else the current directory.
# setup.sh and update.sh never create or delete the done/force files.

set -uo pipefail

WS="${IWE_WORKSPACE:-${CLAUDE_PROJECT_DIR:-$PWD}}"
STATE_DIR="$WS/.claude/state"
DONE_FILE="$STATE_DIR/light-onboarding-done"
FORCE_FILE="$STATE_DIR/light-onboarding-force"

# A registry row is "| 12 |", "| ~~12~~ |", "| **12** |" or legacy "| WP-12 |" —
# the same pattern create-wp.sh uses for numbering. The seed row "| — |" does not match.
ROW_RE='^\|[[:space:]]*[*~]*(WP-)?[0-9]+[*~]*[[:space:]]*\|'

# Governance repo name, resolved like setup.sh does: $IWE_GOVERNANCE_REPO, else the
# GOVERNANCE_REPO= line of $WS/.exocortex.env (read with grep, never sourced).
# Empty result = unknown name; callers then scan every repo of the workspace.
governance_repo() {
    local name="${IWE_GOVERNANCE_REPO:-}"
    if [ -z "$name" ] && [ -f "$WS/.exocortex.env" ]; then
        name=$(grep '^GOVERNANCE_REPO=' "$WS/.exocortex.env" 2>/dev/null | head -1 | cut -d= -f2-)
        name="${name#\"}"; name="${name%\"}"
    fi
    printf '%s' "$name"
}

# Working state of one governance repo: a WP row in the registry, a WP card in
# inbox/, or a DayPlan in current/. A fresh install has none of them (seed: an
# empty registry, inbox/fleeting-notes.md, current/WeekPlan W1.md).
repo_has_work() {
    local gov="$1" path
    [ -f "$gov/docs/WP-REGISTRY.md" ] && grep -qE "$ROW_RE" "$gov/docs/WP-REGISTRY.md" && return 0
    for path in "$gov"/inbox/WP-* "$gov"/current/DayPlan*; do
        [ -e "$path" ] && return 0
    done
    return 1
}

workspace_has_work() {
    local name gov
    [ -e "$STATE_DIR/wp-numbers" ] && return 0
    name=$(governance_repo)
    if [ -n "$name" ]; then
        repo_has_work "$WS/$name"
        return
    fi
    for gov in "$WS"/*/; do
        repo_has_work "${gov%/}" && return 0
    done
    return 1
}

is_active() {
    [ -e "$FORCE_FILE" ] && return 0
    [ -e "$DONE_FILE" ] && return 1
    workspace_has_work && return 1
    return 0
}

case "${1:-}" in
    status)
        if is_active; then
            [ "${2:-}" = "--quiet" ] || echo active
            exit 0
        fi
        [ "${2:-}" = "--quiet" ] || echo inactive
        exit 1
        ;;
    done)
        mkdir -p "$STATE_DIR" || exit 2
        date -u +%Y-%m-%dT%H:%M:%SZ > "$DONE_FILE" || exit 2
        rm -f "$FORCE_FILE"
        echo "light onboarding: marked as passed"
        ;;
    reset)
        mkdir -p "$STATE_DIR" || exit 2
        date -u +%Y-%m-%dT%H:%M:%SZ > "$FORCE_FILE" || exit 2
        echo "light onboarding: will run again on the next message"
        ;;
    *)
        echo "usage: light-onboarding-state.sh status [--quiet] | done | reset" >&2
        exit 2
        ;;
esac
