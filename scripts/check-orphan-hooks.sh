#!/usr/bin/env bash
# routing: utility  deterministic=true
# check-orphan-hooks.sh — every hook in .claude/hooks/ is actually invoked
#
# Defect class (issue #310, #323): guard script-guard resides in .claude/hooks/, declared in
# CLAUDE.md blocking, but is not registered in any event in settings.json and is not
# called from any other hook. It never fires — and nobody knows about it
# finds out, because «did not fire» looks exactly like «no violations were found».
# This is how IntegrationGate (rule-engine.sh) and ResidencyGate (residency-gate-*.sh) lived undetected. IntegrationGate (rule-engine.sh) and ResidencyGate (residency-gate-*.sh).
#
# Reachability is computed transitively: a hook from settings.json can invoke others
# (capture-bus.sh → detectors), such calls also count as being connected.
#
# Intentionally disconnected hooks are listed in .claude/hooks/.orphan-allowlist
# (one line = file name, `#` — comment with the reason). A file in the allowlist remains
# visible in the report, but does not fail the check: the purpose of the guard — so that «not connected»
# was an intentional decision, and not an accident.
#
# Reverse check (issue #360): every named [[gate:...]] from
# memory/protocol-*.md must be present in the enforcement-inventory.
# Usage: bash scripts/check-orphan-hooks.sh [FMT_DIR]

set -uo pipefail

FMT_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
HOOKS_DIR="$FMT_DIR/.claude/hooks"
SETTINGS="$FMT_DIR/.claude/settings.json"
ALLOWLIST="$HOOKS_DIR/.orphan-allowlist"
ENFORCEMENT_INVENTORY="$FMT_DIR/.claude/rules-lazy/blocking-rules-full.md"

if [ ! -d "$HOOKS_DIR" ]; then
    echo "SKIP: $HOOKS_DIR not found"
    exit 0
fi
if [ ! -f "$SETTINGS" ]; then
    echo "SKIP: $SETTINGS not found — cannot determine hook connectivity"
    exit 0
fi

# Seed set: everything, referenced by settings.json.
# Separator — space, not newline: membership is tested with the pattern
# `*" $name "*`, and on newlines it would not match anything (all hooks
# would be reported as disconnected on the very first run).
reachable=" $(grep -oE '[A-Za-z0-9_.-]+\.sh' "$SETTINGS" | sort -u | tr '\n' ' ')"

# Transitive closure: a hook, already deemed reachable, pulls in those, that it calls.
# The number of iterations equals the number of hooks, the number of hooks — the chain cannot be longer than that.
hook_count=$(find "$HOOKS_DIR" -maxdepth 1 -name '*.sh' | wc -l | tr -d ' ')
for _ in $(seq 1 "$hook_count"); do
    added=""
    for name in $reachable; do
        src="$HOOKS_DIR/$name"
        [ -f "$src" ] || continue
        while IFS= read -r ref; do
            case " $reachable $added " in
                *" $ref "*) ;;
                *) [ -f "$HOOKS_DIR/$ref" ] && added="$added $ref" ;;
            esac
        done < <(grep -oE '[A-Za-z0-9_.-]+\.sh' "$src" | sort -u)
    done
    [ -z "$added" ] && break
    reachable="$reachable $added"
done

# The reason lives on the same line after `#`, so the name is — the first field before the comment marker.
# `tr -d ' '` applied to the whole line would merge the name with the reason and the allowlist would not trigger allowlist would not trigger.
allow=" "
if [ -f "$ALLOWLIST" ]; then
    allow=" $(sed 's/#.*//' "$ALLOWLIST" | awk 'NF {print $1}' | tr '\n' ' ')"
fi

orphans=0
allowed=0
libraries=0
for path in "$HOOKS_DIR"/*.sh; do
    [ -f "$path" ] || continue
    name=$(basename "$path")
    case " $reachable " in *" $name "*) continue ;; esac
    # `claude-hook: false` in the header = library/CLI shipped alongside hooks,
    # not registerable in settings.json by contract (issues #310, #323).
    # Same marker setup/validate-template.sh honors — keep recognizers in sync.
    if head -3 "$path" | grep -q '^# claude-hook: false — '; then
        echo "LIBRARY: $name — not a hook by contract (claude-hook: false), registration in settings.json is not required"
        libraries=$((libraries + 1))
        continue
    fi
    case " $allow " in
        *" $name "*)
            echo "ALLOWED: $name — intentionally not connected (see. .claude/hooks/.orphan-allowlist)"
            allowed=$((allowed + 1))
            continue ;;
    esac
    echo "FAIL: $name resides in .claude/hooks/, but is not called from either settings.json, or from any other hook"
    echo "  Either register it under an event in settings.json, or delete it,"
    echo "  or add it to .claude/hooks/.orphan-allowlist with a reason."
    orphans=$((orphans + 1))
done

gate_gaps=0
declared_gate_tokens=$(grep -h -oE '\[\[gate:[A-Za-z0-9._-]+\]\]' "$FMT_DIR"/memory/protocol-*.md 2>/dev/null | grep -vF '[[gate:AR.NNN]]' | sort -u || true)
if [ -n "$declared_gate_tokens" ] && [ ! -f "$ENFORCEMENT_INVENTORY" ]; then
    echo "FAIL: protocol-gates are declared, but enforcement-inventory not found: $ENFORCEMENT_INVENTORY"
    gate_gaps=$((gate_gaps + 1))
elif [ -n "$declared_gate_tokens" ]; then
    while IFS= read -r gate_token; do
        [ -n "$gate_token" ] || continue
        if ! grep -qF "$gate_token" "$ENFORCEMENT_INVENTORY"; then
            echo "FAIL: $gate_token is declared in memory/protocol-*.md, but is missing from enforcement-inventory"
            gate_gaps=$((gate_gaps + 1))
        fi
    done <<< "$declared_gate_tokens"
fi

if [ "$orphans" -eq 0 ] && [ "$gate_gaps" -eq 0 ]; then
    echo "PASS: all hooks are connected and named protocol-gates are inventoried ($allowed intentionally not connected, $libraries libraries outside the hook contract)"
    exit 0
fi

echo ""
echo "Unconnected hooks: $orphans"
echo "Non-inventoried protocol-gates: $gate_gaps"
exit 1
