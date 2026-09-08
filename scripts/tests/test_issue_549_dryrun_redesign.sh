#!/usr/bin/env bash
# test_issue_549_dryrun_redesign.sh — regression for issue #549 stage 2.
#
# Old design: sentinel removed + owner left -> eternal fail-closed, no in-band
# unlock. New design: canonical state per gate_id (exclusive, locked begin),
# atomic active->completed with capability token (sha256 in state, preimage
# only in the initiator's shell), provable orphan sweep, locked stale-sentinel
# self-heal, test-mode-only path overrides (unified resolver in all four
# components), Stop hook completing inline. Drives real hook/helper runs.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GATE="$ROOT/.claude/hooks/dry-run-gate.sh"
BEGIN="$ROOT/scripts/dry-run-begin.sh"
COMPLETE="$ROOT/scripts/dry-run-complete.sh"
TMP=$(mktemp -d)

export IWE_DRY_RUN_DIR="$TMP/dry"
export IWE_DRY_RUN_SENTINEL="$TMP/sentinel.flag"
mkdir -p "$IWE_DRY_RUN_DIR"; chmod 700 "$IWE_DRY_RUN_DIR"
# Гейт принимает оверрайды путей только с маркером тестового режима.
touch "$IWE_DRY_RUN_DIR/.iwe-dry-run-test-mode"

SLEEP_PID=""
cleanup() {
    [ -n "$SLEEP_PID" ] && kill "$SLEEP_PID" 2>/dev/null || true
    rm -rf "$TMP"
    rm -rf "$ROOT/.claude/logs" 2>/dev/null || true
    rm -f /tmp/iwe-dry-run-owner-legacytest.token 2>/dev/null || true
}
trap cleanup EXIT

fail=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

WRITE_JSON='{"tool_name":"Write","tool_input":{"file_path":"/tmp/x.md"}}'
gate_rc() { # <payload> → echoes rc
    printf '%s' "$1" | /bin/bash "$GATE" >/dev/null 2>&1; echo $?
}
expect_block() { # <desc> <payload>
    local rc
    rc=$(gate_rc "$2")
    [ "$rc" = "2" ] && ok "$1" || bad "$1 (ожидался rc=2, получен $rc)"
}
expect_allow() { # <desc> <payload>
    local rc
    rc=$(gate_rc "$2")
    [ "$rc" = "0" ] && ok "$1" || bad "$1 (ожидался rc=0, получен $rc)"
}
mkstate() { # <gate_id> <state> <pid> <pgid> <sid> [token]
    local tsha=""
    [ -n "${6:-}" ] && tsha=$(printf '%s' "$6" | shasum -a 256 | awk '{print $1}')
    jq -nc --arg gid "$1" --arg st "$2" --argjson pid "$3" --argjson pgid "$4" --arg sid "$5" --arg tsha "$tsha" \
      '{version:2,gate_id:$gid,owner_session_id:$sid,owner_pid:$pid,owner_pgid:$pgid,owner_pid_start:"unknown-start",owner_token_sha256:$tsha,state:$st,created_at:"2026-08-31T00:00:00Z",initiator:"test"}' \
      > "$IWE_DRY_RUN_DIR/gate-$1.state"
}
mksentinel() { # <gate_id>
    jq -nc --arg gid "$1" '{gate_id:$gid,created_at:"2026-08-31T00:00:00Z",session_id:"s",initiator:"test"}' \
      > "$IWE_DRY_RUN_SENTINEL"
}
clear_all() { rm -f "$IWE_DRY_RUN_DIR"/gate-*.state "$IWE_DRY_RUN_SENTINEL" 2>/dev/null || true; }

sleep 300 & SLEEP_PID=$!
SLEEP_PGID=$(ps -o pgid= -p "$SLEEP_PID" | tr -d ' ')
DEAD_PID=$(/bin/bash -c 'echo $$')

# --- 1. Чистая установка → allow ---
expect_allow "чистая установка: write разрешён" "$WRITE_JSON"

# --- 2. Активная репетиция: write блок (rc=2), read-only allow ---
mkstate "g-live" "active" "$SLEEP_PID" "$SLEEP_PGID" "sid-live" "tok-live"
mksentinel "g-live"
expect_block "активная репетиция: write заблокирован" "$WRITE_JSON"
expect_allow "активная репетиция: read-only разрешён" '{"tool_name":"Bash","tool_input":{"command":"git status"}}'

# --- 3. Capability: без token / с неверным token — отказ; с верным — completed ---
/bin/bash "$COMPLETE" "g-live" "rehearsal-finished" "sid-live" >/dev/null 2>&1 \
    && bad "helper: завершение без token отклонено" || ok "helper: завершение без token отклонено"
/bin/bash "$COMPLETE" "g-live" "rehearsal-finished" "sid-live" "wrong-token" >/dev/null 2>&1 \
    && bad "helper: неверный token отклонён" || ok "helper: неверный token отклонён"
[ "$(jq -r .state "$IWE_DRY_RUN_DIR/gate-g-live.state")" = "active" ] \
    && ok "helper: после отказов state остался active" || bad "helper: после отказов state остался active"
/bin/bash "$COMPLETE" "g-live" "rehearsal-finished" "sid-live" "tok-live" >/dev/null 2>&1 \
    && ok "helper: завершение с верным token" || bad "helper: завершение с верным token"
[ ! -f "$IWE_DRY_RUN_SENTINEL" ] && ok "helper: sentinel снят после completed" || bad "helper: sentinel снят"
expect_allow "после completed: write разрешён" "$WRITE_JSON"
/bin/bash "$COMPLETE" "g-live" "another-reason" "sid-live" "tok-live" >/dev/null 2>&1
[ "$(jq -r .completion_reason "$IWE_DRY_RUN_DIR/gate-g-live.state")" = "rehearsal-finished" ] \
    && ok "helper: повторное завершение идемпотентно" || bad "helper: повторное завершение идемпотентно"
clear_all

# --- 4. sentinel+completed → самолечение под замком ---
mkstate "g-stale" "completed" "$SLEEP_PID" "$SLEEP_PGID" "sid-x"
mksentinel "g-stale"
expect_allow "sentinel+completed: самолечение, write разрешён" "$WRITE_JSON"
[ ! -f "$IWE_DRY_RUN_SENTINEL" ] && ok "sentinel+completed: stale sentinel снят" || bad "sentinel+completed: stale sentinel снят"
clear_all

# --- 5. Нет sentinel + active + владелец жив → блок с командой восстановления ---
mkstate "g-alive" "active" "$SLEEP_PID" "$SLEEP_PGID" "sid-alive"
OUT=$(printf '%s' "$WRITE_JSON" | /bin/bash "$GATE" 2>&1 >/dev/null) && RC=$? || RC=$?
[ "${RC:-0}" = "2" ] && ok "нет sentinel+active+живой владелец: блок" || bad "нет sentinel+active+живой владелец: блок"
printf '%s' "$OUT" | grep -q 'dry-run-complete.sh g-alive manual-recovery' \
    && ok "блок называет команду восстановления с gate_id" || bad "блок называет команду восстановления с gate_id"

# --- 6. Мёртвый pid + живой pgid (пережившие потомки) → блок ---
mkstate "g-tree" "active" "$DEAD_PID" "$SLEEP_PGID" "sid-tree"
expect_block "мёртвый pid + живой pgid: блок (дерево живо)" "$WRITE_JSON"
clear_all

# --- 7. Доказуемое сиротство → sweep + allow ---
mkstate "g-orphan" "active" "$DEAD_PID" "999999" "sid-orphan"
expect_allow "доказуемое сиротство: sweep, write разрешён" "$WRITE_JSON"
[ "$(jq -r .completion_reason "$IWE_DRY_RUN_DIR/gate-g-orphan.state")" = "orphan-sweep" ] \
    && ok "sweep записал reason=orphan-sweep" || bad "sweep записал reason=orphan-sweep"
clear_all

# --- 8. Legacy owner-token → вечная ветка ---
printf 'tok' > /tmp/iwe-dry-run-owner-legacytest.token
expect_block "legacy owner-token: вечный блок" "$WRITE_JSON"
rm -f /tmp/iwe-dry-run-owner-legacytest.token

# --- 9. Два active-state → corruption ---
mkstate "g-a1" "active" "$SLEEP_PID" "$SLEEP_PGID" "s1"
mkstate "g-a2" "active" "$SLEEP_PID" "$SLEEP_PGID" "s2"
expect_block "два active-state: corruption блок" "$WRITE_JSON"
clear_all

# --- 10. Битый state БЕЗ sentinel → corruption fail-closed (не «не active») ---
echo '{broken json' > "$IWE_DRY_RUN_DIR/gate-g-broken.state"
expect_block "битый state без sentinel: fail-closed" "$WRITE_JSON"
clear_all

# --- 11. Mismatch имени файла и .gate_id → corruption ---
mkstate "g-name" "active" "$SLEEP_PID" "$SLEEP_PGID" "s-n"
jq '.gate_id="g-other"' "$IWE_DRY_RUN_DIR/gate-g-name.state" > "$IWE_DRY_RUN_DIR/.t" && mv "$IWE_DRY_RUN_DIR/.t" "$IWE_DRY_RUN_DIR/gate-g-name.state"
expect_block "filename/gate_id mismatch: corruption блок" "$WRITE_JSON"
clear_all

# --- 12. Sentinel-симлинк → fail-closed ---
ln -s /etc/hostname "$IWE_DRY_RUN_SENTINEL"
expect_block "sentinel-симлинк: fail-closed" "$WRITE_JSON"
rm -f "$IWE_DRY_RUN_SENTINEL"

# --- 13. Stop-hook: свою репетицию завершает, чужую не трогает ---
mkstate "g-stop" "active" "$SLEEP_PID" "$SLEEP_PGID" "sid-stopper"
mkstate "g-foreign" "completed" "$SLEEP_PID" "$SLEEP_PGID" "sid-foreign"
printf '%s' '{"session_id":"sid-stopper","transcript_path":""}' | \
    IWE_DRY_RUN_DIR="$IWE_DRY_RUN_DIR" IWE_DRY_RUN_SENTINEL="$IWE_DRY_RUN_SENTINEL" \
    IWE_SCRIPTS="$ROOT/scripts" \
    /bin/bash "$ROOT/.claude/hooks/protocol-stop-gate.sh" >/dev/null 2>&1 || true
[ "$(jq -r .completion_reason "$IWE_DRY_RUN_DIR/gate-g-stop.state" 2>/dev/null)" = "stop-hook-fallback" ] \
    && ok "Stop-hook: fallback завершил свою репетицию" || bad "Stop-hook: fallback"
[ "$(jq -r .completion_reason "$IWE_DRY_RUN_DIR/gate-g-foreign.state" 2>/dev/null)" != "stop-hook-fallback" ] \
    && ok "Stop-hook: чужую репетицию не тронул" || bad "Stop-hook: чужую репетицию не тронул"
clear_all

# --- 14. Флаг --trusted-stop упразднён (Codex r2: обходился квотированием) —
# helper его не принимает: попытка — обычная ошибка capability, state активен ---
mkstate "g-ts" "active" "$SLEEP_PID" "$SLEEP_PGID" "sid-ts"
/bin/bash "$COMPLETE" "g-ts" "x" "sid-ts" "--trusted-stop" >/dev/null 2>&1 \
    && bad "helper: --trusted-stop отклонён" || ok "helper: --trusted-stop отклонён (флаг упразднён)"
[ "$(jq -r .state "$IWE_DRY_RUN_DIR/gate-g-ts.state")" = "active" ] \
    && ok "после --trusted-stop state остался active" || bad "после --trusted-stop state остался active"
clear_all

# --- 15. Env-оверрайд БЕЗ маркера тест-режима не отключает production-защиту ---
rm -f "$IWE_DRY_RUN_DIR/.iwe-dry-run-test-mode"
mkstate "g-prod" "active" "$SLEEP_PID" "$SLEEP_PGID" "sid-prod"
mksentinel "g-prod"
# Гейт смотрит production-пути (override проигнорирован): там ничего нет →
# allow (а не «активная репетиция» из override-каталога).
expect_allow "override без маркера: гейт на production-путях" "$WRITE_JSON"
# С маркером — снова видит override-каталог → блок.
touch "$IWE_DRY_RUN_DIR/.iwe-dry-run-test-mode"
expect_block "override с маркером: гейт видит тестовую репетицию" "$WRITE_JSON"
clear_all

# --- 16. Begin-helper: создание, эксклюзивность, token-поток end-to-end ---
OUT=$(/bin/bash "$BEGIN" test-init "sid-begin" 2>&1) \
    && ok "begin: репетиция создана" || bad "begin: репетиция создана ($OUT)"
BGID=$(printf '%s\n' "$OUT" | sed -n 's/^gate_id=//p')
BTOK=$(printf '%s\n' "$OUT" | sed -n 's/^owner_token=//p')
[ -n "$BGID" ] && [ -n "$BTOK" ] && ok "begin: gate_id и token выданы" || bad "begin: gate_id и token выданы"
# В state нет preimage token (только sha256).
jq -e '.owner_token == null' "$IWE_DRY_RUN_DIR/gate-$BGID.state" >/dev/null \
    && ok "begin: в state нет token-preimage" || bad "begin: в state нет token-preimage"
# Вторая репетиция — отказ с gate_id первой.
if /bin/bash "$BEGIN" test-init-2 "sid-2" >/dev/null 2>&1; then
    bad "begin: вторая активная репетиция отклонена"
else
    ok "begin: вторая активная репетиция отклонена"
fi
# Gate под репетицией блокирует write; complete с token завершает цикл.
expect_block "begin: write под репетицией заблокирован" "$WRITE_JSON"
/bin/bash "$COMPLETE" "$BGID" "rehearsal-finished" "sid-begin" "$BTOK" >/dev/null 2>&1 \
    && ok "end-to-end: завершение с token" || bad "end-to-end: завершение с token"
expect_allow "end-to-end: после цикла write разрешён" "$WRITE_JSON"
clear_all

# --- 17. Единый резолвер путей БЕЗ маркера: begin/gate/complete смотрят
# одинаково (production-пути). Codex r2: раньше begin писал в override, gate
# смотрел production — репетиция не защищала. NB: кейс осознанно использует
# production-пути и убирает за собой. ---
rm -f "$IWE_DRY_RUN_DIR/.iwe-dry-run-test-mode"
PROD_DIR="/tmp/iwe-dry-run-$(id -u)"
PROD_SENTINEL="/tmp/iwe-dry-run.flag"
[ ! -f "$PROD_SENTINEL" ] || { echo "SKIP 17: production sentinel занят"; }
if [ ! -f "$PROD_SENTINEL" ]; then
    OUT17=$(/bin/bash "$BEGIN" test-prod "sid-prod" 2>&1) \
        && ok "без маркера: begin на production-путях" || bad "без маркера: begin на production-путях ($OUT17)"
    PGID17=$(printf '%s\n' "$OUT17" | sed -n 's/^gate_id=//p')
    PTOK17=$(printf '%s\n' "$OUT17" | sed -n 's/^owner_token=//p')
    [ -f "$PROD_SENTINEL" ] && ok "без маркера: production sentinel создан" || bad "без маркера: production sentinel создан"
    expect_block "без маркера: gate видит репетицию (пути согласованы)" "$WRITE_JSON"
    /bin/bash "$COMPLETE" "$PGID17" "cleanup" "sid-prod" "$PTOK17" >/dev/null 2>&1 \
        && ok "без маркера: complete на production-путях" || bad "без маркера: complete на production-путях"
    [ ! -f "$PROD_SENTINEL" ] && ok "без маркера: production sentinel снят" || bad "без маркера: production sentinel снят"
    rm -f "$PROD_DIR/gate-$PGID17.state" 2>/dev/null || true
    expect_allow "без маркера: после цикла write разрешён" "$WRITE_JSON"
fi
touch "$IWE_DRY_RUN_DIR/.iwe-dry-run-test-mode"

# --- 18. Begin при уже существующем sentinel: отказ БЕЗ хвоста active-state ---
clear_all
mksentinel "g-pre"
if /bin/bash "$BEGIN" test-pre "sid-pre" >/dev/null 2>&1; then
    bad "begin: отказ при существующем sentinel"
else
    ok "begin: отказ при существующем sentinel"
fi
if ls "$IWE_DRY_RUN_DIR"/gate-*.state 2>/dev/null | grep -q .; then
    bad "begin: после отказа не осталось state-файлов"
else
    ok "begin: после отказа не осталось state-файлов"
fi
clear_all

if [ "$fail" -gt 0 ]; then
    echo "FAIL: $fail проверок упало"
    exit 1
fi
echo "PASS: dry-run state machine — locked exclusive begin, capability completion, provable orphan sweep, locked self-heal (issue #549 stage 2)"
