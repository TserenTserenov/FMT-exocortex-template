#!/bin/bash
# routing: guard  deterministic=true
# dry-run-complete.sh <gate_id> <reason> [owner_session_id] <token>
# Атомарное завершение dry-run репетиции (issue #549 stage 2).
#
# Единственная штатная точка перехода active→completed: транзакционный замок,
# строгая schema-проверка state (валидный JSON v2, имя файла == .gate_id),
# монотонный tmp+mv, снятие sentinel ТОЛЬКО если его gate_id совпадает.
# Идемпотентно: повторное завершение — no-op, исходные metadata не перетираются.
#
# Авторизация (Codex review r1-r2: capability не декоративен и без флагов
# обхода): завершение ВСЕГДА требует token (4-й аргумент) — сверка sha256 с
# записанным в state (в state только хэш; preimage — у инициатора). Stop-хук
# рантайма этот helper НЕ вызывает — он выполняет переход сам (флага
# --trusted-stop не существует, попытка его передать — обычная ошибка
# capability). reason=manual-recovery без token — только с подтверждением с
# терминала пилота (/dev/tty); из скрипта/агента без tty — отказ.
set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

GATE_ID="${1:-}"
REASON="${2:-manual-recovery}"
OWNER_SID="${3:-}"
TOKEN="${4:-}"
if [ -z "$GATE_ID" ]; then
    echo "usage: dry-run-complete.sh <gate_id> [reason] [owner_session_id] <token>" >&2
    exit 1
fi
command -v jq >/dev/null 2>&1 || { echo "dry-run-complete: jq required" >&2; exit 2; }

SENTINEL="${IWE_DRY_RUN_SENTINEL:-/tmp/iwe-dry-run.flag}"
DRY_DIR="${IWE_DRY_RUN_DIR:-/tmp/iwe-dry-run-$(id -u)}"
# Единый резолвер путей (Codex r2): override действует только с маркером
# тест-режима — иначе все компоненты смотрели бы в разные места.
if [ -n "${IWE_DRY_RUN_DIR:-}" ] || [ -n "${IWE_DRY_RUN_SENTINEL:-}" ]; then
    [ -f "${IWE_DRY_RUN_DIR:-/nonexistent}/.iwe-dry-run-test-mode" ] || {
        DRY_DIR="/tmp/iwe-dry-run-$(id -u)"
        SENTINEL="/tmp/iwe-dry-run.flag"
    }
fi
LOCK_DIR="$DRY_DIR/transaction.lock"
SP="$DRY_DIR/gate-$GATE_ID.state"

fail() { echo "dry-run-complete: $*" >&2; exit 2; }

# Каталог: те же lstat-инварианты, что у гейта (Codex r1: helper обязан
# повторять их, не только комментировать).
[ -L "$DRY_DIR" ] && fail "dir $DRY_DIR is a symlink — refusing"
[ -d "$DRY_DIR" ] || fail "no dry-run dir $DRY_DIR (gate_id неизвестен)"
case "$(uname)" in
    Darwin) OWNER_UID=$(stat -f %u "$DRY_DIR" 2>/dev/null || true) ;;
    *)      OWNER_UID=$(stat -c %u "$DRY_DIR" 2>/dev/null || true) ;;
esac
[ "$OWNER_UID" = "$(id -u)" ] || fail "dir $DRY_DIR owned by uid $OWNER_UID"
case "$(uname)" in
    Darwin) PERMS=$(stat -f %Lp "$DRY_DIR" 2>/dev/null || true) ;;
    *)      PERMS=$(stat -c %a "$DRY_DIR" 2>/dev/null || true) ;;
esac
[ -n "$PERMS" ] && [ $(( 8#$PERMS & 077 )) -eq 0 ] || fail "dir $DRY_DIR has group/other write permissions ($PERMS)"

tries=0
while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -gt 20 ]; then
        lock_pid=$(sed -n '1p' "$LOCK_DIR/pid" 2>/dev/null || true)
        lock_start=$(sed -n '3p' "$LOCK_DIR/pid" 2>/dev/null || true)
        cur_start=$(ps -o lstart= -p "$lock_pid" 2>/dev/null || true)
        if [ -n "$lock_pid" ] && { ! kill -0 "$lock_pid" 2>/dev/null || { [ -n "$lock_start" ] && [ -n "$cur_start" ] && [ "$lock_start" != "$cur_start" ]; }; }; then
            # ABA-защита: уносим устаревший замок уникальным именем, удаляем
            # именно его — не потенциально новый замок другого процесса.
            mv "$LOCK_DIR" "$DRY_DIR/.stale-lock-$$-$(date +%s)" 2>/dev/null || true
            rm -rf "$DRY_DIR"/.stale-lock-* 2>/dev/null || true
            mkdir "$LOCK_DIR" 2>/dev/null && break
        fi
        fail "transaction lock busy (gate_id=$GATE_ID)"
    fi
    sleep 0.1 2>/dev/null || sleep 1
done
NONCE=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
# Ошибка записи owner-файла = замок не захвачен (Codex r3: единый протокол
# замка во всех компонентах — pid + nonce + lstart).
if ! { echo "$$"; echo "$NONCE"; ps -o lstart= -p $$ 2>/dev/null || echo "unknown"; } > "$LOCK_DIR/pid" 2>/dev/null; then
    rm -rf "$LOCK_DIR" 2>/dev/null || true
    fail "cannot record lock owner"
fi
# Освобождение — только свой замок (сверка nonce).
trap 'if [ "$(sed -n "2p" "$LOCK_DIR/pid" 2>/dev/null)" = "$NONCE" ]; then rm -rf "$LOCK_DIR" 2>/dev/null; fi' EXIT

# Строгая schema-проверка state.
[ -f "$SP" ] || fail "state file not found: $SP"
jq -e . "$SP" >/dev/null 2>&1 || fail "state file corrupted (invalid JSON): $SP"
RECORDED_GID=$(jq -r '.gate_id // empty' "$SP" 2>/dev/null || true)
[ "$RECORDED_GID" = "$GATE_ID" ] || fail "state filename/gate_id mismatch: file=$SP, recorded=$RECORDED_GID"
[ "$(jq -r '.version // empty' "$SP")" = "2" ] || fail "unknown state version in $SP"

CURRENT=$(jq -r '.state // empty' "$SP" 2>/dev/null || true)
case "$CURRENT" in
    completed)
        echo "dry-run-complete: gate_id=$GATE_ID already completed (no-op)"
        ;;
    active)
        if [ -n "$OWNER_SID" ]; then
            recorded=$(jq -r '.owner_session_id // empty' "$SP" 2>/dev/null || true)
            [ "$recorded" = "$OWNER_SID" ] || fail "owner_session_id mismatch for gate_id=$GATE_ID (recorded=$recorded) — refusing to complete чужой gate"
        fi
        # Авторизация перехода: token всегда (исключение — manual-recovery
        # с живым подтверждением пилота с терминала).
        recorded_sha=$(jq -r '.owner_token_sha256 // empty' "$SP" 2>/dev/null || true)
        if [ -n "$TOKEN" ] && [ -n "$recorded_sha" ]; then
            given_sha=$(printf '%s' "$TOKEN" | shasum -a 256 | awk '{print $1}')
            [ "$given_sha" = "$recorded_sha" ] || fail "capability token mismatch for gate_id=$GATE_ID"
        elif [ "$REASON" = "manual-recovery" ] && [ -z "$TOKEN" ]; then
            { printf 'dry-run-complete: завершить gate_id=%s с reason=manual-recovery без capability token? [yes/N] ' "$GATE_ID"
              read -r answer; } < /dev/tty 2>/dev/null || fail "manual-recovery without token requires an interactive terminal (pilot only)"
            [ "$answer" = "yes" ] || fail "manual-recovery отклонён"
        else
            fail "capability token required (4-й аргумент) для завершения gate_id=$GATE_ID"
        fi
        TMP=$(mktemp "$DRY_DIR/.complete.XXXXXX") || fail "mktemp failed"
        jq --arg completed "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg reason "$REASON" \
            '.state="completed" | .completed_at=$completed | .completion_reason=$reason' \
            "$SP" > "$TMP" 2>/dev/null && mv -f "$TMP" "$SP" || { rm -f "$TMP"; fail "atomic transition failed"; }
        echo "dry-run-complete: gate_id=$GATE_ID → completed ($REASON)"
        ;;
    *)
        fail "state file corrupted (state='$CURRENT')"
        ;;
esac

# Sentinel снимается ТОЛЬКО после completed и ТОЛЬКО если он ссылается на
# этот же gate_id — и это обычный файл того же владельца (lstat, Codex r1).
if [ -f "$SENTINEL" ] && [ ! -L "$SENTINEL" ]; then
    case "$(uname)" in
    Darwin) S_UID=$(stat -f %u "$SENTINEL" 2>/dev/null || true) ;;
    *)      S_UID=$(stat -c %u "$SENTINEL" 2>/dev/null || true) ;;
esac
    [ "$S_UID" = "$(id -u)" ] || fail "sentinel $SENTINEL owned by uid $S_UID"
    S_GID=$(jq -r '.gate_id // empty' "$SENTINEL" 2>/dev/null || true)
    if [ "$S_GID" = "$GATE_ID" ]; then
        rm -f "$SENTINEL"
        echo "dry-run-complete: sentinel removed"
    fi
fi
exit 0
