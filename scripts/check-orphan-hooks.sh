#!/usr/bin/env bash
# routing: utility  deterministic=true
# check-orphan-hooks.sh — every hook in .claude/hooks/ is actually invoked
#
# Defect class (issue #310, #323): a guard script lies in .claude/hooks/, is declared
# blocking in CLAUDE.md, but is not registered in any settings.json event and is
# not called from any other hook. It never fires — and nobody finds out,
# because "did not fire" looks exactly like "there were no violations".
# That is how IntegrationGate (rule-engine.sh) and ResidencyGate (residency-gate-*.sh) lived.
#
# Reachability is computed transitively: a hook from settings.json may launch others
# (capture-bus.sh → detectors), such calls also count as wiring.
#
# Deliberately unwired hooks are listed in .claude/hooks/.orphan-allowlist
# (one line = file name, `#` — a comment with the reason). A file in the allowlist stays
# visible in the report but does not fail the check: the watchdog's goal is for "not wired"
# to be a decision, not an accident.
#
# Reverse check (issue #360): every named [[gate:...]] from
# memory/protocol-*.md must be present in the enforcement inventory.
# Usage: bash scripts/check-orphan-hooks.sh [FMT_DIR]

set -uo pipefail

FMT_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
HOOKS_DIR="$FMT_DIR/.claude/hooks"
SETTINGS="$FMT_DIR/.claude/settings.json"
ALLOWLIST="$HOOKS_DIR/.orphan-allowlist"
ENFORCEMENT_INVENTORY="$FMT_DIR/.claude/rules-lazy/blocking-rules-full.md"

if [ ! -d "$HOOKS_DIR" ]; then
    echo "SKIP: $HOOKS_DIR не найден"
    exit 0
fi
if [ ! -f "$SETTINGS" ]; then
    echo "SKIP: $SETTINGS не найден — определить подключение невозможно"
    exit 0
fi

# Starting set: everything referenced by settings.json.
# The separator is a space, not a newline: membership is checked by the pattern
# `*" $name "*`, and on newlines it would not match anything (all hooks
# reported as unwired on the very first run).
reachable=" $(grep -oE '[A-Za-z0-9_.-]+\.sh' "$SETTINGS" | sort -u | tr '\n' ' ')"

# Transitive closure: a hook already recognized as reachable pulls in those it invokes.
# Iterations exactly as many as there are hooks — the chain cannot be longer.
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

# The reason lives on the same line after `#`, so the name is the first field before the comment.
# `tr -d ' '` over the whole line would glue the name to the reason and the allowlist would not work.
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
        echo "LIBRARY: $name — не хук по контракту (claude-hook: false), подключение в settings.json не требуется"
        libraries=$((libraries + 1))
        continue
    fi
    case " $allow " in
        *" $name "*)
            echo "ALLOWED: $name — не подключён осознанно (см. .claude/hooks/.orphan-allowlist)"
            allowed=$((allowed + 1))
            continue ;;
    esac
    echo "FAIL: $name лежит в .claude/hooks/, но не вызывается ни из settings.json, ни из другого хука"
    echo "  Либо зарегистрируйте его в событии settings.json, либо удалите,"
    echo "  либо внесите в .claude/hooks/.orphan-allowlist с причиной."
    orphans=$((orphans + 1))
done

gate_gaps=0
declared_gate_tokens=$(grep -h -oE '\[\[gate:[A-Za-z0-9._-]+\]\]' "$FMT_DIR"/memory/protocol-*.md 2>/dev/null | grep -vF '[[gate:AR.NNN]]' | sort -u || true)
if [ -n "$declared_gate_tokens" ] && [ ! -f "$ENFORCEMENT_INVENTORY" ]; then
    echo "FAIL: protocol-gates объявлены, но enforcement-инвентарь не найден: $ENFORCEMENT_INVENTORY"
    gate_gaps=$((gate_gaps + 1))
elif [ -n "$declared_gate_tokens" ]; then
    while IFS= read -r gate_token; do
        [ -n "$gate_token" ] || continue
        if ! grep -qF "$gate_token" "$ENFORCEMENT_INVENTORY"; then
            echo "FAIL: $gate_token объявлен в memory/protocol-*.md, но отсутствует в enforcement-инвентаре"
            gate_gaps=$((gate_gaps + 1))
        fi
    done <<< "$declared_gate_tokens"
fi

if [ "$orphans" -eq 0 ] && [ "$gate_gaps" -eq 0 ]; then
    echo "PASS: все хуки подключены и именованные protocol-gates инвентаризированы ($allowed осознанно не подключены, $libraries библиотек вне контракта хуков)"
    exit 0
fi

echo ""
echo "Не подключено хуков: $orphans"
echo "Не инвентаризировано protocol-gates: $gate_gaps"
exit 1
