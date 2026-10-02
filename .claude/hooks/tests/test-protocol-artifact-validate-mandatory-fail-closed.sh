#!/bin/bash
# test-protocol-artifact-validate-mandatory-fail-closed.sh — issue #764/#765.
#
# protocol-artifact-validate.sh resolved find-python3.sh via
# $WORKSPACE/scripts/lib/find-python3.sh — a path that never exists on any
# install (scripts/lib/ lives inside the template or as .claude/lib/, never
# copied to the workspace root). Resolver never found → python3 never runs →
# MANDATORY_WPS_CONFIGURED stays false, same as "mandatory not configured" —
# a broken environment was silently treated as a legitimate absence of the
# mandatory check.
#
# The hook is copied into an isolated fixture directory so that the sibling
# ../lib/find-python3.sh can genuinely be absent (in the real repo it always
# exists, which would mask the bug). Checks the hook now blocks the commit
# with a named reason, instead of silently approving it.

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_RESOLVER="$HOOK_DIR/../lib/find-python3.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# --- Fixture: isolated workspace + governance-репо ---
# day-rhythm-config.yaml lives at $WORKSPACE/memory/ (workspace root, a
# symlink to auto-memory on a real install) — NOT inside the governance-repo.
WS="$TMP/ws"
mkdir -p "$WS/DS-strategy/current" "$WS/memory"
git -C "$WS/DS-strategy" init -q
git -C "$WS/DS-strategy" config user.email test@test
git -C "$WS/DS-strategy" config user.name test

valid_dayplan() { # <path>
  cat > "$1" <<'EOF'
# DayPlan 2026-09-10
## План на сегодня
| Время | РП |
|-------|----|
| 10:00 | WP-7 |
## Календарь
| Время | Событие |
|-------|---------|
| 09:00 | тест |
## IWE за ночь
нет находок
## Разбор заметок
нет заметок
## Итоги вчера
готово
~1.0x мультипликатор
~2ч РП / ~1ч физ
EOF
}

printf 'mandatory_daily_wps: ["WP-7"]\n' > "$WS/memory/day-rhythm-config.yaml"
valid_dayplan "$WS/DS-strategy/current/DayPlan 2026-09-10.md"
git -C "$WS/DS-strategy" add "current/DayPlan 2026-09-10.md"

printf '%s' '{"session_id":"t","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cd \"'"$WS"'/DS-strategy\" && git add -A && git commit -m x"}}' \
  > "$TMP/envelope.json"

run_hook() { # <fixture-dir-with-hook-copy>
  # IWE_SCRIPTS explicitly cleared: the ambient dev shell has it exported to
  # the real template checkout (whose scripts/lib/find-python3.sh genuinely
  # exists) — inheriting it here would mask exactly the "resolver absent"
  # scenario this test exists to cover.
  env -u IWE_SCRIPTS IWE_WORKSPACE="$WS" IWE_ROOT="$WS" IWE_GOVERNANCE_REPO="DS-strategy" \
    bash "$1/protocol-artifact-validate.sh" < "$TMP/envelope.json"
}

# --- 1. Резолвер отсутствует целиком: копия хука без соседнего ../lib/ ---
NO_RESOLVER_DIR="$TMP/no-resolver/.claude/hooks"
mkdir -p "$NO_RESOLVER_DIR"
cp "$HOOK_DIR/protocol-artifact-validate.sh" "$NO_RESOLVER_DIR/"

OUT=$(run_hook "$NO_RESOLVER_DIR")
if echo "$OUT" | grep -q '"decision": *"block"'; then
  ok "резолвер отсутствует → хук блокирует коммит (fail-closed, не тихий пропуск)"
else
  bad "резолвер отсутствует → хук блокирует коммит (fail-closed, не тихий пропуск) (получено: $OUT)"
fi
echo "$OUT" | grep -qF 'python3 не резолвится' \
  && ok "причина блокировки названа явно" \
  || bad "причина блокировки названа явно (получено: $OUT)"

# --- 2. Тот же конфиг, резолвер присутствует рядом (self-relative ../lib/) ---
WITH_RESOLVER_DIR="$TMP/with-resolver/.claude/hooks"
mkdir -p "$WITH_RESOLVER_DIR" "$TMP/with-resolver/.claude/lib"
cp "$HOOK_DIR/protocol-artifact-validate.sh" "$WITH_RESOLVER_DIR/"
cp "$REAL_RESOLVER" "$TMP/with-resolver/.claude/lib/find-python3.sh"

OUT2=$(run_hook "$WITH_RESOLVER_DIR")
if echo "$OUT2" | grep -q '"decision": *"block"' && echo "$OUT2" | grep -qi "mandatory"; then
  ok "резолвер присутствует, mandatory сконфигурирован, DayPlan без упоминания mandatory → блок с содержательной причиной"
else
  bad "резолвер присутствует, mandatory сконфигурирован, DayPlan без упоминания mandatory → блок с содержательной причиной (получено: $OUT2)"
fi

git -C "$WS/DS-strategy" reset -q

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
