#!/usr/bin/env bash
# test_issue_729_rhythm_config_resolve.sh — regression for issue #729.
#
# strategist.sh resolved RHYTHM_CONFIG (strategy_day source) by a literal
# "-Users-$(whoami)-IWE" path — broke silently (fallback to monday, no WARN)
# whenever the workspace wasn't literally ~/IWE (a symlink, WSL, a custom
# path). Fix: try the governance-repo copy first ($WORKSPACE/exocortex/...),
# then fall back to the auto-memory dir derived from the REAL workspace path
# (pwd -P + Claude Code's slugification: "/", "_" and "." all become "-").
# resolve_rhythm_config() in strategist.sh is extracted here (sed) rather
# than sourcing the whole script, which starts traps and sleep-inhibitor
# processes as soon as it's read.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
STRATEGIST_SH="$ROOT/roles/strategist/scripts/strategist.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0
check() { # <desc> <expected> <actual>
    if [ "$2" = "$3" ]; then
        echo "PASS: $1"
    else
        echo "FAIL: $1 — ожидалось [$2], получено [$3]"
        fail=$((fail + 1))
    fi
}

FUNC_SRC=$(sed -n '/^resolve_rhythm_config() {/,/^}/p' "$STRATEGIST_SH")
[ -n "$FUNC_SRC" ] || { echo "FAIL: resolve_rhythm_config() не найдена в $STRATEGIST_SH"; exit 1; }
eval "$FUNC_SRC"

# --- Случай 1: governance-репо копия найдена — используется она ---
mkdir -p "$TMP/case1/gov/exocortex"
touch "$TMP/case1/gov/exocortex/day-rhythm-config.yaml"
result=$(resolve_rhythm_config "$TMP/case1/gov" "$TMP/case1")
check "governance-копия найдена" "$TMP/case1/gov/exocortex/day-rhythm-config.yaml" "$result"

# --- Случай 2: governance-копии нет — fallback на auto-memory slug, путь
# с "." и "_" (issue #729 воспроизводится именно на таких путях) ---
WS2="$TMP/case2/home/a.b_c/IWE"
mkdir -p "$WS2"
result=$(HOME="$TMP" resolve_rhythm_config "$TMP/case2/nonexistent-gov" "$WS2")
expected_slug=$(printf '%s' "$WS2" | tr '/_.' '-')
check "fallback slug содержит и '.' и '_' корректно" \
    "$TMP/.claude/projects/${expected_slug}/memory/day-rhythm-config.yaml" "$result"

# --- Случай 3: fallback slug НЕ равен наивному sed 's#/#-#g' — фиксирует
# конкретный дефект, найденный cold-review этой же сессии (2026-09-09) ---
naive_slug=$(printf '%s' "$WS2" | sed 's#/#-#g')
if [ "$expected_slug" = "$naive_slug" ]; then
    echo "FAIL: тестовый путь не содержит '.'/'_' — regression case 3 не проверяет ничего"
    fail=$((fail + 1))
else
    echo "PASS: корректный slug отличается от наивного (regression на #729 cold-review)"
fi

if [ "$fail" -gt 0 ]; then
    echo "--- $fail провал(ов) ---"
    exit 1
fi
echo "--- все проверки пройдены ---"
