#!/bin/bash
# routing: guard  deterministic=true
# dry-run-begin.sh — exclusive creation dry-run rehearsal (issue #549 stage 2).
#
# The sole authorised creation point: transactional lock → failure, if
# an active rehearsal already exists (prints its gate_id) → strict validation
# existing state-files → atomic creation state(active) → sentinel
# referencing gate_id → unlock. Prints to stdout:
#   gate_id=<id>
#   owner_token=<token>          ← keep in shell initiator, NOT in state
#   owner_session_id=<sid>
# Token stored in state only as sha256 — rehearsal, reading state
# read-only command, does not receive preimage and cannot complete gate on its own
# (Codex review r1: decorative token + whitelisted helper = standard bypass).
set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

# --help/-h — before any side-effects (issue #757): bare exit 0 without this branch
# caused --help to actually arm the gate (INITIATOR="--help"), while HELP-smoke
# in validate-fmt-scripts.sh treated such exit 0 as proof of safety.
[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && {
    echo "dry-run-begin.sh — exclusive creation of a dry-run rehearsal (issue #549 stage 2)"
    echo "Usage: dry-run-begin.sh [initiator] [session_id]"
    exit 0
}

INITIATOR="${1:-audit-installation}"
SID="${2:-${CLAUDE_SESSION_ID:-dry-$(date +%s)-$$}}"
command -v jq >/dev/null 2>&1 || { echo "dry-run-begin: jq required" >&2; exit 2; }

SENTINEL="${IWE_DRY_RUN_SENTINEL:-/tmp/iwe-dry-run.flag}"
DRY_DIR="${IWE_DRY_RUN_DIR:-/tmp/iwe-dry-run-$(id -u)}"
# Unified path resolver (Codex r2): override override takes effect only with the marker
# test-mode — otherwise components look in different locations.
if [ -n "${IWE_DRY_RUN_DIR:-}" ] || [ -n "${IWE_DRY_RUN_SENTINEL:-}" ]; then
    [ -f "${IWE_DRY_RUN_DIR:-/nonexistent}/.iwe-dry-run-test-mode" ] || {
        DRY_DIR="/tmp/iwe-dry-run-$(id -u)"
        SENTINEL="/tmp/iwe-dry-run.flag"
    }
fi
LOCK_DIR="$DRY_DIR/transaction.lock"

fail() { echo "dry-run-begin: $*" >&2; exit 1; }

# Directory: lstat-lstat invariants of the gate.
[ -L "$DRY_DIR" ] && fail "dir $DRY_DIR is a symlink — refusing"
if [ ! -d "$DRY_DIR" ]; then
    mkdir -m 0700 "$DRY_DIR" 2>/dev/null || fail "cannot create $DRY_DIR with 0700"
fi
case "$(uname)" in
    Darwin) OWNER_UID=$(stat -f %u "$DRY_DIR" 2>/dev/null || true) ;;
    *)      OWNER_UID=$(stat -c %u "$DRY_DIR" 2>/dev/null || true) ;;
esac
[ "$OWNER_UID" = "$(id -u)" ] || fail "dir owned by uid $OWNER_UID"
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
            mv "$LOCK_DIR" "$DRY_DIR/.stale-lock-$$-$(date +%s)" 2>/dev/null || true
            rm -rf "$DRY_DIR"/.stale-lock-* 2>/dev/null || true
            mkdir "$LOCK_DIR" 2>/dev/null && break
        fi
        fail "transaction lock busy — another dry-run operation in progress"
    fi
    sleep 0.1 2>/dev/null || sleep 1
done
NONCE=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
# Write error for owner owner-file = lock not acquired (otherwise it becomes permanent).
if ! { echo "$$"; echo "$NONCE"; ps -o lstart= -p $$ 2>/dev/null || echo "unknown"; } > "$LOCK_DIR/pid" 2>/dev/null; then
    rm -rf "$LOCK_DIR" 2>/dev/null || true
    fail "cannot record lock owner"
fi
trap 'if [ "$(sed -n "2p" "$LOCK_DIR/pid" 2>/dev/null)" = "$NONCE" ]; then rm -rf "$LOCK_DIR" 2>/dev/null; fi' EXIT

# Exclusivity + strict validation of existing state under the lock.
shopt -s nullglob
for sf in "$DRY_DIR"/gate-*.state; do
    jq -e . "$sf" >/dev/null 2>&1 || fail "corrupted state file: $sf"
    [ "$(jq -r '.version // empty' "$sf" 2>/dev/null)" = "2" ] || fail "state file $sf has unknown version"
    sf_gid=$(jq -r '.gate_id // empty' "$sf" 2>/dev/null || true)
    [ "gate-$sf_gid.state" = "$(basename "$sf")" ] || fail "state filename/gate_id mismatch: $sf"
    sf_state=$(jq -r '.state // empty' "$sf" 2>/dev/null || true)
    case "$sf_state" in
        active) fail "active dry-run dry-run rehearsal already exists (gate_id=$sf_gid) — complete it first: dry-run-complete.sh $sf_gid <reason> <sid> <token>" ;;
        completed) ;;
        *) fail "state file $sf has unknown state '$sf_state'" ;;
    esac
done

GID="dry-$(date +%s)-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
TOKEN=$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')
TOKEN_SHA=$(printf '%s' "$TOKEN" | shasum -a 256 | awk '{print $1}')
OWNER_PID=$PPID
OWNER_PID_START=$(ps -o lstart= -p "$OWNER_PID" 2>/dev/null || true)
OWNER_PGID=$(ps -o pgid= -p "$OWNER_PID" 2>/dev/null | tr -d ' ')
case "$OWNER_PID" in ''|*[!0-9]*) fail "cannot determine owner pid" ;; esac
case "$OWNER_PGID" in ''|*[!0-9]*|0) fail "cannot determine owner pgid (got '$OWNER_PGID')" ;; esac
[ -n "$OWNER_PID_START" ] || fail "cannot determine owner pid start"

# Sentinel is checked BEFORE creating state (Codex r4: otherwise when already
# existing sentinel an active-state remains active-state without an issued token).
[ ! -e "$SENTINEL" ] && [ ! -L "$SENTINEL" ] || fail "sentinel $SENTINEL already exists — refusing"

umask 077
TMP=$(mktemp "$DRY_DIR/.begin.XXXXXX") || fail "mktemp failed"
jq -nc --arg gid "$GID" --arg sid "$SID" --arg tsha "$TOKEN_SHA" \
  --argjson pid "$OWNER_PID" --arg pstart "$OWNER_PID_START" --argjson pgid "$OWNER_PGID" \
  --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg init "$INITIATOR" \
  '{version:2,gate_id:$gid,owner_session_id:$sid,owner_pid:$pid,owner_pgid:$pgid,owner_pid_start:$pstart,owner_token_sha256:$tsha,state:"active",created_at:$created,initiator:$init}' \
  > "$TMP" && mv -f "$TMP" "$DRY_DIR/gate-$GID.state" || { rm -f "$TMP"; fail "atomic state create failed"; }

# Sentinel — exclusive creation, only after state. On a race condition (some-one
# created it after our check) — rollback of our own state.
if ! ( set -C; jq -nc --arg gid "$GID" --arg sid "$SID" --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{gate_id:$gid,created_at:$created,session_id:$sid,initiator:"audit-installation"}' \
    > "$SENTINEL" ) 2>/dev/null; then
    rm -f "$DRY_DIR/gate-$GID.state" 2>/dev/null || true
    fail "sentinel $SENTINEL already exists — refusing to overwrite (state rolled back)"
fi

printf 'gate_id=%s\nowner_token=%s\nowner_session_id=%s\n' "$GID" "$TOKEN" "$SID"
