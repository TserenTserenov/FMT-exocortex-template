#!/bin/bash
# routing: guard  deterministic=true
# dry-run-complete.sh <gate_id> <reason> [owner_session_id] <token>
# Atomic completion of a dry-run rehearsal (issue #549 stage 2).
#
# The only regular active→completed transition point: a transactional lock,
# strict schema check of state (valid JSON v2, file name == .gate_id),
# monotonic tmp+mv, removal of the sentinel ONLY if its gate_id matches.
# Idempotent: repeated completion is a no-op, the original metadata is not overwritten.
#
# Authorization (Codex review r1-r2: the capability is not decorative and has no
# bypass flags): completion ALWAYS requires a token (4th argument) — checked by sha256 against
# the one recorded in state (state holds only the hash; the preimage is with the initiator). The runtime
# Stop hook does NOT call this helper — it performs the transition itself (the
# --trusted-stop flag does not exist, trying to pass it is an ordinary capability
# error). reason=manual-recovery without a token — only with confirmation from
# the pilot's terminal (/dev/tty); from a script/agent without a tty — refusal.
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

fail() { echo "dry-run-complete: $*" >&2; exit 2; }

# Path and privacy check come from the one shared library (also used by the
# gate, the Stop hook and dry-run-begin.sh — issue #1447), so all components
# look in the same place and apply the same criterion.
# The gate's own copy (<ws>/.claude/lib in a workspace) first, so completion
# applies the gate's criteria; the template copy is only a fallback for the
# template checkout itself and for a workspace whose library went missing in
# a partial update — completing the rehearsal is what lets the gate open again.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN_LIB="$SCRIPT_DIR/../../.claude/lib/dry-run-dir.sh"
[ -f "$SCRIPT_DIR/../../.claude/hooks/dry-run-gate.sh" ] && [ -r "$DRY_RUN_LIB" ] \
    || DRY_RUN_LIB="$SCRIPT_DIR/../.claude/lib/dry-run-dir.sh"
# shellcheck source=../.claude/lib/dry-run-dir.sh
{ [ -r "$DRY_RUN_LIB" ] && . "$DRY_RUN_LIB"; } || fail "$DRY_RUN_LIB missing — cannot locate dry-run state"
dry_run_resolve_paths || fail "$DRY_RUN_ERR"
DRY_DIR="$DRY_RUN_DIR"
SENTINEL="$DRY_RUN_SENTINEL"
LOCK_DIR="$DRY_DIR/transaction.lock"
SP="$DRY_DIR/gate-$GATE_ID.state"
[ -d "$DRY_DIR" ] || [ -L "$DRY_DIR" ] || fail "no dry-run dir $DRY_DIR (gate_id неизвестен)"
dry_run_dir_check existing || fail "$DRY_RUN_ERR"

tries=0
while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -gt 20 ]; then
        lock_pid=$(sed -n '1p' "$LOCK_DIR/pid" 2>/dev/null || true)
        lock_start=$(sed -n '3p' "$LOCK_DIR/pid" 2>/dev/null || true)
        cur_start=$(ps -o lstart= -p "$lock_pid" 2>/dev/null || true)
        if [ -n "$lock_pid" ] && { ! kill -0 "$lock_pid" 2>/dev/null || { [ -n "$lock_start" ] && [ -n "$cur_start" ] && [ "$lock_start" != "$cur_start" ]; }; }; then
            # ABA protection: we move the stale lock away under a unique name and delete
            # exactly that one — not a potentially new lock of another process.
            mv "$LOCK_DIR" "$DRY_DIR/.stale-lock-$$-$(date +%s)" 2>/dev/null || true
            rm -rf "$DRY_DIR"/.stale-lock-* 2>/dev/null || true
            mkdir "$LOCK_DIR" 2>/dev/null && break
        fi
        fail "transaction lock busy (gate_id=$GATE_ID)"
    fi
    sleep 0.1 2>/dev/null || sleep 1
done
NONCE=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
# An owner-file write error = the lock is not acquired (Codex r3: a single lock
# protocol across all components — pid + nonce + lstart).
if ! { echo "$$"; echo "$NONCE"; ps -o lstart= -p $$ 2>/dev/null || echo "unknown"; } > "$LOCK_DIR/pid" 2>/dev/null; then
    rm -rf "$LOCK_DIR" 2>/dev/null || true
    fail "cannot record lock owner"
fi
# Release — only our own lock (nonce check).
trap 'if [ "$(sed -n "2p" "$LOCK_DIR/pid" 2>/dev/null)" = "$NONCE" ]; then rm -rf "$LOCK_DIR" 2>/dev/null; fi' EXIT

# Strict schema check of state.
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
        # Transition authorization: a token always (the exception is manual-recovery
        # with live confirmation from the pilot's terminal).
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

# The sentinel is removed ONLY after completed and ONLY if it refers to
# this same gate_id — and it is a regular file of the same owner (lstat, Codex r1).
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
