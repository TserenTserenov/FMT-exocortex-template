#!/bin/bash
# Dry-run Gate Hook (PreToolUse)
# Contract: memory/dry-run-contract.md
# WP-265 Phase 5.2 (ArchGate v3 — option F3 sentinel-only). v2: WP-7/BUGTRIAGE2 (issue #237).
#
# Purpose: block write-tools while a valid sentinel file is present.
# Sentinel: a single file /tmp/iwe-dry-run.flag (not session-bound).
# Reason for the single name: CLAUDE_SESSION_ID is not propagated into the
# subagent environment, so a session-bound name was unreliable on the most
# common smoke-test path — the main agent created the sentinel, the subagent Stop hook
# removed it under its own (empty) SID, the foreign sentinel stayed and got stuck for the whole TTL.
# A single file removes the create/cleanup mismatch in one move (issue #237 item 2).
# TTL: 2400 seconds (40 minutes) from mtime — a measured `close day` takes ~26
# minutes (issue #460), the margin keeps a legitimate rehearsal alive without a heartbeat.
#
# Principles:
# - jq missing / owner file orphaned without sentinel / TTL expired → fail-CLOSED,
#   not skip/allow (memory/dry-run-contract.md §Fail-safe; issue #460 paths 1-3:
#   a gate that can't see its own state has no basis to allow).
# - exit 0 = allow (no sentinel and no rehearsal declared)
# - exit 2 = block (with diagnostics in stderr; includes jq missing,
#   sentinel_missing-with-owner and TTL-expired)

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

SENTINEL="${IWE_DRY_RUN_SENTINEL:-/tmp/iwe-dry-run.flag}"
TTL_SECONDS=2400
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IWE_ROOT_GUESS="$(cd "$HOOK_DIR/../.." 2>/dev/null && pwd -P)"
GATE_LOG="$IWE_ROOT_GUESS/.claude/logs/gate_log.jsonl"

# issue #549 stage 2: canonical rehearsal state record (redesign).
# The sentinel remains the marker of the active mode (the whitelist
# machinery below depends on it), but the blocking decision is made from the state file.
# The directory is private (this uid only): symlink/foreign owner/group
# write = tampering attempt → fail-closed.
DRY_DIR="${IWE_DRY_RUN_DIR:-/tmp/iwe-dry-run-$(id -u)}"
# Env overrides of paths — explicit test mode only (Codex r1: ambient
# IWE_DRY_RUN_DIR/IWE_DRY_RUN_SENTINEL from the launch configuration must not
# disable production protection). The test creates the marker inside the override
# directory; without it the production paths apply.
if [ -n "${IWE_DRY_RUN_DIR:-}" ] || [ -n "${IWE_DRY_RUN_SENTINEL:-}" ]; then
    if [ ! -f "${IWE_DRY_RUN_DIR:-/nonexistent}/.iwe-dry-run-test-mode" ]; then
        DRY_DIR="/tmp/iwe-dry-run-$(id -u)"
        SENTINEL="/tmp/iwe-dry-run.flag"
    fi
fi
LOCK_DIR="$DRY_DIR/transaction.lock"

fail_closed() { # <message...> — single point of permanent blocking with diagnostics
    {
        echo "[dry-run-gate] BLOCKED: $*"
        echo "Reason: dry-run state machine fail-closed (см. memory/dry-run-contract.md)"
    } >&2
    exit 2
}

gate_log_event() { # <event> <detail>
    mkdir -p "$(dirname "$GATE_LOG")" 2>/dev/null || true
    printf '{"ts":"%s","gate":"dry-run-gate","event":"%s","detail":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >> "$GATE_LOG" 2>/dev/null || true
}

# lstat check of the private directory (Codex design review: /tmp without a protected
# directory allows substitution and symlink attacks). Called lazily — only when
# dry-run is actually in use, to avoid creating the directory on every tool call.
dry_dir_ensure() {
    if [ -L "$DRY_DIR" ]; then
        fail_closed "dry-run dir $DRY_DIR is a symlink — refusing (possible attack)"
    fi
    if [ ! -d "$DRY_DIR" ]; then
        mkdir -m 0700 "$DRY_DIR" 2>/dev/null || fail_closed "cannot create $DRY_DIR with 0700"
    fi
    local owner
    case "$(uname)" in
        Darwin) owner=$(stat -f %u "$DRY_DIR" 2>/dev/null) ;;
        *)      owner=$(stat -c %u "$DRY_DIR" 2>/dev/null) ;;
    esac
    [ "$owner" = "$(id -u)" ] || fail_closed "dry-run dir $DRY_DIR owned by uid $owner, expected $(id -u)"
    # group/other write forbidden (lstat form without following symlink — the directory is already checked above)
    local perms
    case "$(uname)" in
        Darwin) perms=$(stat -f %Lp "$DRY_DIR" 2>/dev/null) ;;
        *)      perms=$(stat -c %a "$DRY_DIR" 2>/dev/null) ;;
    esac
    [ -n "$perms" ] || fail_closed "cannot stat permissions of $DRY_DIR"
    # perms — a string of octal digits ("700"); interpret as octal.
    # bash 3.2: ${var:-default} inside $(( )) is not parsed — default is set separately above.
    [ $(( 8#$perms & 077 )) -eq 0 ] || fail_closed "dry-run dir $DRY_DIR has group/other write permissions ($perms)"
}

# Transactional lock via mkdir (portable; flock(1) is absent on macOS).
# The lock carries an owner (pid + lstart): a provably orphaned lock (owner
# dead) is removed; a live owner after attempts run out → fail-closed
# (Codex: a bare mkdir lock is eternal after a crash inside the transaction).
# ABA protection (Codex r1): a stale lock is carried off under a unique name and
# that very one is deleted, not a potentially new lock of another process;
# the lock carries an owner (pid + nonce); release — only by its own nonce.
LOCK_NONCE=""
lock_acquire() {
    local tries=0
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        tries=$((tries + 1))
        if [ "$tries" -gt 20 ]; then
            # Last chance: is the lock owner provably dead (pid not alive OR
            # its start does not match the recorded one — pid reuse)?
            local lock_pid lock_start cur_start
            lock_pid=$(sed -n '1p' "$LOCK_DIR/pid" 2>/dev/null || true)
            lock_start=$(sed -n '3p' "$LOCK_DIR/pid" 2>/dev/null || true)
            cur_start=$(ps -o lstart= -p "$lock_pid" 2>/dev/null || true)
            if [ -n "$lock_pid" ] && { ! kill -0 "$lock_pid" 2>/dev/null || { [ -n "$lock_start" ] && [ -n "$cur_start" ] && [ "$lock_start" != "$cur_start" ]; }; }; then
                mv "$LOCK_DIR" "$DRY_DIR/.stale-lock-$$-$(date +%s)" 2>/dev/null || true
                rm -rf "$DRY_DIR"/.stale-lock-* 2>/dev/null || true
                gate_log_event "lock_orphan_swept" "pid=$lock_pid"
                mkdir "$LOCK_DIR" 2>/dev/null && break
            fi
            return 1
        fi
        sleep 0.1 2>/dev/null || sleep 1
    done
    LOCK_NONCE=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
    # Owner: pid + nonce + lstart (stale detection by pid death OR start
    # mismatch — pid reuse). An owner-file write error = lock not acquired
    # (Codex r2: a suppressed write error made the lock eternal).
    if ! { echo "$$"; echo "$LOCK_NONCE"; ps -o lstart= -p $$ 2>/dev/null || echo "unknown"; } > "$LOCK_DIR/pid" 2>/dev/null; then
        rm -rf "$LOCK_DIR" 2>/dev/null || true
        return 1
    fi
    return 0
}
lock_release() {
    [ -n "$LOCK_NONCE" ] || return 0
    if [ "$(sed -n '2p' "$LOCK_DIR/pid" 2>/dev/null)" = "$LOCK_NONCE" ]; then
        rm -rf "$LOCK_DIR" 2>/dev/null || true
    fi
    LOCK_NONCE=""
}

state_path() { printf '%s/gate-%s.state' "$DRY_DIR" "$1"; }
state_field() { jq -r ".$2 // empty" "$1" 2>/dev/null || true; }

# Strict validation of the state file (Codex r1: broken JSON / foreign version /
# name vs .gate_id mismatch / unknown state — corruption, fail-closed,
# not "not active"). Prints the gate_id of a valid active file.
validate_state_file() { # <path> → rc 0 ok, 2 corruption; stdout: "state gate_id"
    local sf="$1" st gid ver
    jq -e . "$sf" >/dev/null 2>&1 || return 2
    ver=$(jq -r '.version // empty' "$sf" 2>/dev/null || true)
    [ "$ver" = "2" ] || return 2
    gid=$(jq -r '.gate_id // empty' "$sf" 2>/dev/null || true)
    [ -n "$gid" ] || return 2
    [ "gate-$gid.state" = "$(basename "$sf")" ] || return 2
    st=$(jq -r '.state // empty' "$sf" 2>/dev/null || true)
    case "$st" in
        active|completed) printf '%s %s\n' "$st" "$gid" ;;
        *) return 2 ;;
    esac
}

# Atomic active→completed transition (tmp+mv in the same directory, monotonic,
# idempotent: repeated completion does not overwrite the original metadata).
complete_gate() { # <gate_id> <reason>
    local gate_id="$1" reason="$2" sp tmp
    sp=$(state_path "$gate_id")
    [ -f "$sp" ] || return 1
    [ "$(state_field "$sp" state)" = "active" ] || return 0
    tmp=$(mktemp "$DRY_DIR/.complete.XXXXXX") || return 1
    jq --arg completed "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg reason "$reason" \
        '.state="completed" | .completed_at=$completed | .completion_reason=$reason' \
        "$sp" > "$tmp" 2>/dev/null && mv -f "$tmp" "$sp" || { rm -f "$tmp"; return 1; }
    gate_log_event "gate_completed" "gate_id=$gate_id reason=$reason"
    return 0
}

# Scan of all state files with strict validation. stdout: "state gate_id" pairs.
# Any corruption → rc 2 (NOT "silently skip the file"); the caller must
# check the code — with process substitution the subshell rc is lost (Codex r1:
# fail_closed inside <( ) terminates only the subprocess, the gate continued and
# allowed the operation).
scan_states() {
    local sf entry
    shopt -s nullglob
    for sf in "$DRY_DIR"/gate-*.state; do
        entry=$(validate_state_file "$sf") || return 2
        printf '%s\n' "$entry"
    done
    shopt -u nullglob
}

# Provable orphanhood (both conditions, fail-closed on any ambiguity):
# 1. owner_pid is dead OR its lstart does not match the recorded one (pid reuse);
# 2. no live process with owner_pgid (the whole rehearsal tree is gone).
# Numeric validation of arguments (Codex r1: pgid=0/foo — not proven).
# ps error / empty output / non-numeric fields → return 2 (not proven ≠ orphaned).
# Known remainder (documented in the contract): if the runtime puts the gate
# itself into the owner's process group, the pgid scan always sees "alive" → eternal
# fail-closed (the safe direction), the sweep will not fire.
orphan_proven() { # <pid> <pid_start> <pgid>
    local pid="$1" pid_start="$2" pgid="$3" cur_start snapshot
    case "$pid" in ''|*[!0-9]*|0) return 2 ;; esac
    case "$pgid" in ''|*[!0-9]*|0) return 2 ;; esac
    if kill -0 "$pid" 2>/dev/null; then
        cur_start=$(ps -o lstart= -p "$pid" 2>/dev/null) || return 2
        [ -n "$cur_start" ] || return 2
        # Alive and start matches — the owner is alive, no orphanhood.
        [ "$cur_start" = "$pid_start" ] && return 1
        # Alive but a different start — pid reuse: the original owner is dead.
    fi
    snapshot=$(ps -eo pid=,pgid= 2>/dev/null) || return 2
    [ -n "$snapshot" ] || return 2
    if printf '%s\n' "$snapshot" | awk -v pg="$pgid" '$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $2 == pg {f=1} END{exit f?0:1}'; then
        return 1  # the rehearsal tree is still alive — not an orphan
    fi
    return 0
}

# jq is needed to parse the payload. Per contract (memory/dry-run-contract.md
# §Fail-safe): a broken gate must fail-CLOSED, not open — a gate that can't
# see its own state has no basis to allow (issue #460 path 1; this used to
# exit 0, contradicting the fail-CLOSED example already documented in the
# contract).
if ! command -v jq >/dev/null 2>&1; then
    echo "[dry-run-gate] FAIL-CLOSED: jq missing, blocking by default (install jq to restore normal operation)" >&2
    exit 2
fi

# A sentinel symlink is a tampering attempt, not a state (lstat check,
# Codex design review: a dangling symlink would give a false "sentinel missing").
if [ -L "$SENTINEL" ]; then
    fail_closed "sentinel $SENTINEL is a symlink — refusing"
fi

# Sentinel missing — dry-run is inactive. If the owner's capability file
# remained, protection vanished unexpectedly or was removed explicitly before Stop: earlier
# this was only logged and still allowed (#369) — the same fail-open
# class as path 1 above (issue #460 path 2). The owner file is direct
# evidence that a rehearsal is still declared active; we block instead of
# silently letting a write pass around the lost protection.
if [ ! -f "$SENTINEL" ]; then
    # issue #549 stage 2: canonical state files first (see header).
    # Provable orphanhood lifts the eternal block; unproven does not.
    if [ -d "$DRY_DIR" ] && [ ! -L "$DRY_DIR" ]; then
        dry_dir_ensure
        # Strict scan under the transactional lock (Codex r1: without the lock —
        # TOCTOU with creation of a new rehearsal; a broken/foreign state is corruption,
        # not "not active").
        if ! lock_acquire; then
            fail_closed "transaction lock held by a live process — dry-run state busy, retry later"
        fi
        ACTIVE_GIDS=()
        STATES_OUT=""
        if ! STATES_OUT=$(scan_states); then
            lock_release
            fail_closed "corrupted dry-run state file in $DRY_DIR"
        fi
        while IFS= read -r entry; do
            [ -n "$entry" ] || continue
            case "${entry%% *}" in
                active) ACTIVE_GIDS+=("${entry#* }") ;;
            esac
        done <<< "$STATES_OUT"
        if [ "${#ACTIVE_GIDS[@]}" -gt 1 ]; then
            lock_release
            fail_closed "multiple active dry-run states — corruption (exclusivity invariant broken): ${ACTIVE_GIDS[*]}"
        fi
        if [ "${#ACTIVE_GIDS[@]}" -eq 1 ]; then
            gate_id="${ACTIVE_GIDS[0]}"
            sf=$(state_path "$gate_id")
            owner_pid=$(state_field "$sf" owner_pid)
            owner_start=$(state_field "$sf" owner_pid_start)
            owner_pgid=$(state_field "$sf" owner_pgid)
            if orphan_proven "$owner_pid" "$owner_start" "$owner_pgid"; then
                # A transition error ≠ permission (Codex r1): complete_gate
                # failed — fail-closed, state stays active.
                if ! complete_gate "$gate_id" "orphan-sweep"; then
                    lock_release
                    fail_closed "orphan proven for gate_id=$gate_id but atomic completion failed — refusing to open"
                fi
                lock_release
                exit 0
            fi
            lock_release
            {
                echo "[dry-run-gate] BLOCKED: dry-run sentinel missing while state gate_id=$gate_id is still active"
                echo "Reason: owner alive or orphanhood not proven — fail-closed per contract"
                printf 'Recovery (pilot terminal only, after confirming no dry-run is actually active):\n  bash %q %s manual-recovery\n' \
                    "$IWE_ROOT_GUESS/FMT-exocortex-template/scripts/dry-run-complete.sh" "$gate_id"
            } >&2
            exit 2
        fi
        lock_release
    fi
    # Legacy branch of the old format (owner-*.token without a state file) — unchanged:
    # eternal fail-closed with the exact recovery command.
    OWNER_FILE=$(find -L /tmp -maxdepth 1 -name 'iwe-dry-run-owner-*.token' -type f -print -quit 2>/dev/null || true)
    if [ -n "$OWNER_FILE" ]; then
        gate_log_event "sentinel_missing" "owner_file=$(basename "$OWNER_FILE")"
        {
            echo "[dry-run-gate] BLOCKED: dry-run sentinel missing while owner file $(basename "$OWNER_FILE") still present"
            echo "Reason: protection lost mid-rehearsal (TTL/crash/race) — fail-closed per contract"
            # issue #549 stage 1: this branch is fail-closed FOREVER by design
            # (no TTL — elapsed time proves nothing about completion), and the
            # gate blocks the agent's own rm before the whitelist is reached,
            # so recovery is only possible from the pilot's own terminal.
            # Name the exact command instead of leaving the user to guess.
            printf 'Recovery (pilot terminal only, after confirming no dry-run is actually active):\n  rm -f %q\n' "$OWNER_FILE"
        } >&2
        exit 2
    fi
    exit 0
fi

# issue #549 stage 2: a sentinel with gate_id — decision by the canonical state,
# not only by the TTL below. A sentinel of the old format (no gate_id) follows the
# previous TTL+whitelist path unchanged.
# lstat invariants of the sentinel (Codex r1): a regular file of the same owner.
case "$(uname)" in
    Darwin) S_UID=$(stat -f %u "$SENTINEL" 2>/dev/null || true) ;;
    *)      S_UID=$(stat -c %u "$SENTINEL" 2>/dev/null || true) ;;
esac
[ -n "$S_UID" ] && [ "$S_UID" = "$(id -u)" ] || fail_closed "sentinel $SENTINEL owned by uid ${S_UID:-unknown}, expected $(id -u)"
SENTINEL_GID=$(jq -r '.gate_id // empty' "$SENTINEL" 2>/dev/null || true)
if [ -n "$SENTINEL_GID" ]; then
    dry_dir_ensure
    SP=$(state_path "$SENTINEL_GID")
    [ -f "$SP" ] || fail_closed "sentinel references unknown gate_id=$SENTINEL_GID — corruption or manual edit"
    # Validation of the state file the sentinel refers to (the same strict
    # contract as the scanner: name/.gate_id mismatch — corruption).
    validate_state_file "$SP" >/dev/null || fail_closed "state for gate_id=$SENTINEL_GID failed validation — corruption"
    ST=$(state_field "$SP" state)
    case "$ST" in
        completed)
            # Self-healing UNDER THE LOCK (Codex r1: without the lock a race — between read
            # and rm a new rehearsal may write a new sentinel and we would delete
            # someone else's). Re-read the sentinel under the lock: delete only
            # if it is still about the COMPLETED gate_id and there is no new active one.
            if ! lock_acquire; then
                fail_closed "transaction lock busy during stale-sentinel sweep (gate_id=$SENTINEL_GID)"
            fi
            CUR_GID=$(jq -r '.gate_id // empty' "$SENTINEL" 2>/dev/null || true)
            NEW_ACTIVE=0
            STATES_OUT=""
            if ! STATES_OUT=$(scan_states); then
                lock_release
                fail_closed "corrupted dry-run state file in $DRY_DIR"
            fi
            while IFS= read -r entry; do
                [ -n "$entry" ] || continue
                [ "${entry%% *}" = "active" ] && NEW_ACTIVE=1
            done <<< "$STATES_OUT"
            if [ "$CUR_GID" = "$SENTINEL_GID" ] && [ "$NEW_ACTIVE" = "0" ]; then
                rm -f "$SENTINEL"
                gate_log_event "stale_sentinel_swept" "gate_id=$SENTINEL_GID"
                lock_release
                exit 0
            fi
            lock_release
            # The sentinel changed under the lock (new rehearsal / foreign write) —
            # do not touch someone else's and do not open: fail-closed with diagnostics.
            fail_closed "sentinel changed during stale sweep (was gate_id=$SENTINEL_GID, now '${CUR_GID:-none}', active_present=$NEW_ACTIVE) — refusing to remove чужой sentinel"
            ;;
        active)
            ;; # normal dry-run mode — then TTL + whitelist
        *)
            fail_closed "gate state for gate_id=$SENTINEL_GID is '$ST' — corruption"
            ;;
    esac
fi

case "$(uname)" in
    Darwin) MTIME=$(stat -f %m "$SENTINEL" 2>/dev/null) ;;
    *)      MTIME=$(stat -c %Y "$SENTINEL" 2>/dev/null) ;;
esac

if [ -z "$MTIME" ]; then
    # File vanished between test and stat (race with parallel cleanup) — allow.
    exit 0
fi

NOW=$(date +%s)
if [ $((NOW - MTIME)) -gt $TTL_SECONDS ]; then
    # issue #460 path 3: used to `rm -f` and allow — a gate deleting its own
    # protection then trusting the write is the same fail-open shape as
    # paths 1-2. A stale sentinel means the owner crashed or forgot cleanup,
    # not that the rehearsal ended safely; block and require an explicit
    # `rm -f "$SENTINEL"` once that's confirmed.
    {
        echo "[dry-run-gate] BLOCKED: sentinel stale (older than ${TTL_SECONDS}s, mtime $MTIME)"
        echo "Reason: TTL expired without cleanup — owner likely crashed, protection kept fail-closed"
        echo "If the rehearsal really ended: rm -f $SENTINEL"
    } >&2
    exit 2
fi

# Read tool_name and tool_input from stdin
INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""')
[ -z "$TOOL_NAME" ] && exit 0

# Sentinel metadata (for diagnostics)
SENTINEL_META=$(cat "$SENTINEL" 2>/dev/null || echo '{}')
SENTINEL_INITIATOR=$(echo "$SENTINEL_META" | jq -r '.initiator // "unknown"' 2>/dev/null || echo "unknown")
SENTINEL_CREATED=$(echo "$SENTINEL_META" | jq -r '.created_at // "unknown"' 2>/dev/null || echo "unknown")

block() {
    local target="$1"
    {
        echo "[dry-run-gate] BLOCKED: $TOOL_NAME on $target"
        echo "Reason: dry-run mode active (sentinel created at $SENTINEL_CREATED, by $SENTINEL_INITIATOR)"
        echo "Expected: tool blocked by contract, this is rehearsal failure point"
    } >&2
    exit 2
}

# === Direct write-tools: Write, Edit, MultiEdit, NotebookEdit ===
case "$TOOL_NAME" in
    Write|Edit|MultiEdit|NotebookEdit)
        FP=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // ""')
        block "${FP:-<no path>}"
        ;;
esac

# === IWE knowledge-namespace MCP gate (match by action, not by namespace
# prefix — issue #219, VxxxlBxxxxv) ===
#
# Was: an exact list `mcp__claude_ai_IWE__<write-action>` below (carried over from
# git blame of this file). The current knowledge MCP server is called `iwe-knowledge`
# (see mcp__iwe-knowledge__* in the live tool list), and none of the
# write tools under that name matched any line of the list —
# the gate was fail-open for the whole namespace it was created for
# (personal_write, dt_write_digital_twin, personal_delete, send_telegram_message
# etc. passed the rehearsal unvalidated).
#
# Now: deny-by-default for any MCP tool_name whose server name contains
# "iwe" or "knowledge" (survives a future server rename better than
# an exact name list) — a reading action passes by the name pattern
# (search/get_*/list_*/read_*/describe_*/*_status/*_stats/*_traverse/*_expand/
# *_search_by_name/backlinks/whoami/get_instructions), everything else is blocked.
# If a new read-only tool does not fall under the pattern — a false BLOCK
# (the safe direction of error), not a false ALLOW.
case "$TOOL_NAME" in
    mcp__*iwe*__*|mcp__*knowledge*__*|mcp__*IWE*__*)
        ACTION="${TOOL_NAME##*__}"
        # Substring patterns (`*get_*`, not just `get_*`): for half of the
        # read tools the action does not start with a verb but contains it
        # in the middle after a domain prefix (`knowledge_list_documents`,
        # `user_profile_get_tier`, `dt_read_digital_twin`). Anchored-only
        # `get_*`/`list_*`/`read_*`/`describe_*` falsely blocked all of those —
        # found by a live run of the regression test on the full tool list
        # of the server, not by assumption.
        case "$ACTION" in
            search|whoami|get_instructions|backlinks|\
            *get_*|*list_*|*read_*|*describe_*|\
            *_status|*_stats|*_traverse|*_expand|*_search_by_name|*_search|*_list)
                : # read-only action — not blocked here, falls to the whitelist below/allow
                ;;
            *)
                block "$TOOL_NAME"
                ;;
        esac
        ;;
esac

# === MCP-write whitelist (exact tool_name matches, other servers) ===
case "$TOOL_NAME" in
    mcp__claude_ai_Gmail__create_draft|\
    mcp__claude_ai_Gmail__create_label|\
    mcp__claude_ai_Gmail__label_message|\
    mcp__claude_ai_Gmail__label_thread|\
    mcp__claude_ai_Gmail__unlabel_message|\
    mcp__claude_ai_Gmail__unlabel_thread|\
    mcp__claude_ai_Google_Calendar__create_event|\
    mcp__claude_ai_Google_Calendar__delete_event|\
    mcp__claude_ai_Google_Calendar__update_event|\
    mcp__claude_ai_Google_Calendar__respond_to_event|\
    mcp__claude_ai_Google_Drive__create_file|\
    mcp__ext-google-calendar__create-event|\
    mcp__ext-google-calendar__create-events|\
    mcp__ext-google-calendar__delete-event|\
    mcp__ext-google-calendar__update-event|\
    mcp__ext-google-calendar__respond-to-event|\
    mcp__ext-google-drive__copy_file|\
    mcp__ext-google-drive__create_file|\
    mcp__ext-google-drive__create_folder|\
    mcp__ext-google-drive__delete_file|\
    mcp__ext-google-drive__move_file|\
    mcp__ext-google-drive__update_file|\
    mcp__ext-google-drive__share_file|\
    mcp__ext-linear__create_issue|\
    mcp__ext-linear__update_issue|\
    mcp__ext-railway__create-environment|\
    mcp__ext-railway__create-project-and-link|\
    mcp__ext-railway__deploy|\
    mcp__ext-railway__deploy-template|\
    mcp__ext-railway__generate-domain|\
    mcp__ext-railway__link-environment|\
    mcp__ext-railway__link-service|\
    mcp__ext-railway__set-variables)
        block "$TOOL_NAME"
        ;;
esac

# === Bash matchers ===
#
# v2 (issue #237): instead of grep over the whole command string — three passes:
#  1) strip quoted spans (text inside '...'/"..." cannot pose as a
#     command — earlier `echo "see: git commit"` falsely matched, issue #237 item 4);
#  2) split the normalized string into simple commands by the separators
#     ; & | && || ( ) { } $( ` — earlier `(git commit -am x)` in parentheses
#     slipped through unnoticed, issue #237 item 1;
#  3) classify each fragment by its first word (after skipping
#     VAR=val/command/env/nohup/time/sudo), not by searching for a substring anywhere.
#
# The only exception to step 1 is psql: SQL lives inside quotes, so
# SQL-write is matched against the UNnormalized command, but only when the first
# word of the fragment is psql (otherwise `grep "psql -c INSERT" file` would again falsely hit).
if [ "$TOOL_NAME" = "Bash" ]; then
    CMD=$(echo "$INPUT" | jq -r '.tool_input.command // ""')
    [ -z "$CMD" ] && exit 0

    # Step 1: remove quoted spans and harmless redirects to null.
    # issue #315-fix2: the only real (documented in day-close/SKILL.md,
    # day-close-details.md) form of invoking day-close-prepare.sh is a quoted var-expansion
    # bash "$IWE_SCRIPTS/day-close-prepare.sh". This is a LITERAL string (the variable
    # is not yet expanded at PreToolUse time — expansion is done by bash during real
    # execution, after the gate), but it falls under the general s/"[^"]*"/ QSTR /g
    # below and turns into a token QSTR indistinguishable from any other string —
    # the whitelist case below never matches this form (verified by a live
    # reproduction of the command from day-close-details.md:32). A targeted replacement
    # BEFORE the general quote collapse preserves the recognizability of exactly this
    # hardwired pattern without opening a general quote bypass for the rest.
    # issue #460 path 5: day-close/SKILL.md steps 1/2 call two read-only
    # diagnostic python scripts via `${IWE_TEMPLATE:-<HOME_DIR>/IWE/...}/...`
    # — unquoted brace-expansion. The same class of problem as day-close-prepare.sh
    # above: `{`/`}` inside `${...}` fall under the general split-into-simple-commands
    # (step 2, the characters `(){}&;` are separators) and break the path into pieces before
    # the whitelist case for python|python3 gets to see it whole. A targeted
    # replacement BEFORE the split preserves the recognizability of exactly these two hardwired calls
    # (confirmed by code review: without it the path 5 fix blocks day-close at the
    # very first step — read-only scripts, not a place of a real write).
    #
    # The exact path in the pattern, NOT a wildcard: `[^}]*` instead of a specific
    # default value would allow `${IWE_TEMPLATE:-$(cmd)}/...` — command
    # substitution inside the default would be swallowed by the marker BEFORE
    # step 2 gets to segment and recognize it (round-2 review, live
    # reproduction: `${IWE_TEMPLATE:-$(touch /tmp/PWNED)}/...` passed as
    # allow). The same lesson already applied to `WL_ABS`/`WL_ABS2` below (review-01
    # High/review-02 H1) — whitelist only by the exact string, not by glob.
    # issue #694: the anchor is $IWE_ROOT_GUESS (the path of the hook itself, computed at line
    # ~27 from BASH_SOURCE), not $HOME/IWE — the same technique already used
    # for GATE_LOG above. Not an env variable (IWE_WORKSPACE/IWE_TEMPLATE
    # are injectable by the caller's environment — the very bypass that
    # review-01/review-02 closed by dropping the env default in this whitelist).
    WL_TEMPLATE_ABS="$IWE_ROOT_GUESS/FMT-exocortex-template"
    # Cold-review finding (Codex, 2026-09-14): a STATIC marker string in a
    # NORM whitelist is spoofable — an attacker can type the marker text
    # literally as the command's own bare argument and bypass the gate by
    # planting a same-named file, since NORM only ever ADDS the marker, it
    # never proves the marker came from OUR substitution rather than from
    # the attacker's own input. GATE_NONCE makes the NEW .iwe-paths marker
    # below unpredictable per invocation (this hook is a fresh process per
    # PreToolUse call, so the attacker's $CMD is fixed before this nonce
    # even exists) — scoped ONLY to issue #784/#785's whitelist, not to the
    # pre-existing static markers (__WL_DAY_CLOSE_PREPARE__ etc. below),
    # which are a separate, already-shipped finding outside this fix's scope.
    #
    # issue #1238: #1233's new .iwe-paths resolver (day-close/SKILL.md,
    # dry-run-contract.md) is a compound statement ("IWE_PATHS=...; if ...;
    # then for _c in ...; do ...; done; fi; [ -n ... ] && . \"$IWE_PATHS\""),
    # not a single quoted argument like the two __WL_IWE_PATHS_* patterns
    # above -- its final dot-source targets the *variable* $IWE_PATHS, whose
    # value the per-segment classifier below can't see (each segment is
    # classified independently; it has no memory of what an earlier segment
    # assigned). Splitting the chain and whitelisting only the trailing
    # `. "$IWE_PATHS"` segment would need taint-tracking PWD/IWE_WORKSPACE
    # reassignment too -- and IWE_PATHS itself is legitimately assigned
    # *twice* inside this very chain, so a blanket "IWE_PATHS= anywhere ->
    # tampered" rule (the HOME_OR_IWE_PATHS_TAMPERED technique) would flag
    # our own whitelisted text and never fire. The chain is whitelisted as
    # ONE exact, pre-approved block instead: this pattern matches character-
    # for-character only the known-safe text (verified both ends -- see
    # scripts/tests/ test for this hook, which asserts the exact byte match,
    # not just a smoke pass/fail), so there is no sub-pattern an attacker
    # could reuse out of context. A single added/removed space anywhere in
    # the chain fails the match and the whole command falls through to
    # "indirect execution under dry-run" (fail-closed), same as any other
    # unrecognized source|. target.
    #
    # Must run FIRST in this -e pipeline, before the standalone
    # "$HOME/.iwe-paths" marker below: the chain's own last fallback
    # candidate is that exact literal, so if the standalone marker ran
    # first it would eat that substring out of the chain and the whole-
    # block pattern below would never match the (now-mutated) text. Found
    # live while adding this fix -- the two earlier tests in
    # TestIwePathsChainWhitelist failed with the block pattern listed last.
    GATE_NONCE=$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
    [ -n "$GATE_NONCE" ] || GATE_NONCE="$$-$(date +%s%N 2>/dev/null || date +%s)"
    NORM=$(printf '%s' "$CMD" | sed -E \
        -e "s@IWE_PATHS=\"\\\$\\{IWE_PATHS_FILE:-\\}\"; if \\[ -z \"\\\$IWE_PATHS\" \\]; then for _c in \"\\\$PWD/\\.iwe-paths\" \"\\\$\\{IWE_WORKSPACE:-\\\$HOME/IWE\\}/\\.iwe-paths\" \"\\\$HOME/\\.iwe-paths\"; do \\[ -r \"\\\$_c\" \\] && \\{ IWE_PATHS=\"\\\$_c\"; break; \\}; done; fi; \\[ -n \"\\\$IWE_PATHS\" \\] && \\. \"\\\$IWE_PATHS\"@ __WL_IWE_PATHS_CHAIN_${GATE_NONCE}__ @g" \
        -e 's@"\$IWE_SCRIPTS/day-close-prepare\.sh"@ __WL_DAY_CLOSE_PREPARE__ @g' \
        -e 's@"\$IWE_SCRIPTS/dry-run-complete\.sh"@ __WL_DRY_RUN_COMPLETE__ @g' \
        -e "s@\\\$\\{IWE_TEMPLATE:-${WL_TEMPLATE_ABS//\//\\/}\\}/\\.claude/scripts/memory-drift-scan\\.py@ __WL_PY_MDS__ @g" \
        -e "s@\\\$\\{IWE_TEMPLATE:-${WL_TEMPLATE_ABS//\//\\/}\\}/\\.claude/scripts/check-index-health\\.py@ __WL_PY_CIH__ @g" \
        -e "s@\"\\\$HOME/\\.iwe-paths\"@ __WL_IWE_PATHS_${GATE_NONCE}__ @g" \
        -e "s@\"\\\$\\{IWE_PATHS_FILE:-\\\$HOME/\\.iwe-paths\\}\"@ __WL_IWE_PATHS_${GATE_NONCE}__ @g" \
        -e "s/'[^']*'/ QSTR /g" \
        -e 's/"[^"]*"/ QSTR /g' \
        -e 's@[0-9]?>[[:space:]]*/dev/null@ @g' \
        -e 's@2>&1@ @g')
    NORM_RC=$?
    # Codex review (2026-09-14): a broken -e expression makes the WHOLE sed
    # invocation fail with EMPTY stdout (verified live: any invalid -e in
    # this pipeline → exit 1, zero bytes out — sed validates the full -e
    # script upfront, before touching input). $(...) alone doesn't stop the
    # script (no `set -e` here, only pipefail) — without this check, NORM
    # would silently become "", SPLIT/the whole Bash-matcher loop below would
    # never iterate, and every single Bash command would fall through to
    # "read-only: allow" at the bottom of the file, regardless of content.
    # Found live while adding the #784/#785 whitelist to this same pipeline.
    if [ "$NORM_RC" -ne 0 ]; then
        fail_closed "NORM sed pipeline failed (exit $NORM_RC) — cannot classify command, refusing to allow"
    fi

    # Redirect into a real file — check against the whole normalized string
    # (position-independent relative to the segmentation below, as before).
    if echo "$NORM" | grep -qE '[[:space:]]>>?[[:space:]]'; then
        block "$CMD (redirect to file)"
    fi

    # Step 2: split into simple commands.
    SPLIT=$(printf '%s\n' "$NORM" | sed -E 's/\$\(|`|[(){}&;]|\|\|?|&&/\n/g')

    # issue #1258: same split, but from $CMD (before $NORM collapses every
    # quoted span to the literal text "QSTR") -- a quoted/escaped command
    # name like "cd" or \cd needs its quoting intact to tell it apart from
    # QSTR by the time the cd/pushd check below runs.
    SPLIT_RAW=$(printf '%s\n' "$CMD" | sed -E 's/\$\(|`|[(){}&;]|\|\|?|&&/\n/g')

    # Live-review finding (Fable, 2026-09-14): the .iwe-paths whitelist matches the
    # LITERAL TEXT "$HOME/.iwe-paths"/"${IWE_PATHS_FILE:-...}", not the
    # resolved value — the loop below classifies each segment INDEPENDENTLY
    # and does not remember assignments from previous segments. A live run confirmed
    # the bypass: `HOME=/tmp/evil; . "$HOME/.iwe-paths"` on REAL execution
    # sources /tmp/evil/.iwe-paths (bash substitutes the variable at execution
    # time, after this gate), but the classifier sees the second segment
    # in isolation and does not know about the override in the first. Discovered after
    # deployment — we scan the WHOLE SPLIT in advance for an override of HOME/
    # IWE_PATHS_FILE anywhere in the command and revoke the whitelist for the whole command
    # if one is present. A round-2 cold review (Codex, 2026-09-14) found that the first
    # version of the regex (anchored to segment start, export only) missed:
    # (a) a prefix assignment NOT as the first word of a segment (`x=1 HOME=evil cmd`),
    # (b) readonly/declare/typeset/local/builtin export/command export,
    # (c) printf -v HOME / read HOME (assignment via builtin, not `VAR=`).
    # The regex below covers all three classes; quoted spans are already collapsed into QSTR
    # at this step (see sed above), so "HOME=" inside a user
    # string (e.g. python -c "...HOME=...") does not leak here.
    #
    # issue #1238: IWE_WORKSPACE and PWD were added to the same regex — they now
    # also control which file is actually sourced (the #1233 fallback chain
    # tries "$PWD/.iwe-paths" and "${IWE_WORKSPACE:-$HOME/IWE}/.iwe-paths"),
    # the same attack as HOME/IWE_PATHS_FILE originally. Verified live
    # (not only by text): `PWD=/tmp/evil; echo "$PWD/.iwe-paths"` really
    # prints `/tmp/evil/.iwe-paths` in bash — a plain assignment overrides the
    # substitution.
    #
    # Cold-review finding (Agent tool, 2026-10-15): `cd` — the ordinary, most frequent
    # way to actually change `$PWD` in a running shell — was NOT caught by the assignment-
    # oriented regex above (`cd` does not match `VAR=`). A live PoC confirmed a
    # full bypass: `cd /tmp/evil-poc; <chain>` passed the gate (exit 0) and really
    # sourced the forged `/tmp/evil-poc/.iwe-paths` on actual execution.
    # `pushd` gives the same effect; `popd`/a jump through a function with another name —
    # not covered, a documented residual boundary (memory/dry-run-contract.md).
    HOME_OR_IWE_PATHS_TAMPERED=0
    if printf '%s\n' "$SPLIT" | grep -qE \
        '(^|[[:space:]])(builtin[[:space:]]+|command[[:space:]]+)?(export|readonly|declare|typeset|local)([[:space:]]+-[A-Za-z]+)*[[:space:]]+(HOME|IWE_PATHS_FILE|IWE_WORKSPACE|PWD)=|(^|[[:space:]])(HOME|IWE_PATHS_FILE|IWE_WORKSPACE|PWD)=|(^|[[:space:]])printf([[:space:]]+[^[:space:]]*)*[[:space:]]+-v[[:space:]]+(HOME|IWE_PATHS_FILE|IWE_WORKSPACE|PWD)([[:space:]]|$)|(^|[[:space:]])read([[:space:]]+-[A-Za-z]+)*[[:space:]]+(HOME|IWE_PATHS_FILE|IWE_WORKSPACE|PWD)([[:space:]]|$)' \
    ; then
        HOME_OR_IWE_PATHS_TAMPERED=1
    fi

    # issue #1258 (independent red-team audit, 2026-10-17): the `cd|pushd`
    # alternative the regex above used to carry only matched the literal
    # bytes "cd"/"pushd" with real whitespace around them — exactly the PoC
    # #1238 itself used, nothing else. `\cd`, `"cd"`, `'cd'` and `$'cd'` all
    # strip down to the plain word "cd" once bash parses them and invoke the
    # identical builtin (confirmed live: `bash -c '\cd /tmp/x && pwd'` really
    # changes directory) — the same attack #1238 closed, just not written in
    # the one byte-exact shape the regex looked for. A fifth regex
    # alternative for "\cd" would only buy one more round of the same trap
    # (quoted-cd, ansi-c $'cd', ...), so this reuses the word tokenizer
    # destructive-guard.sh already has for its own `rm` detection — it strips
    # quotes/backslash/ANSI-C escapes the way bash's own parser does, so a
    # command name survives disguising by construction, not by one more
    # enumerated case.
    CD_PUSHD_TOKEN_DETECTED=0
    if printf '%s\n' "$SPLIT_RAW" | perl -e '
        sub words {
          my ($text) = @_;
          my (@out, $word, $quote) = ();
          for (my $i = 0; $i < length($text); $i++) {
            my $char = substr($text, $i, 1);
            if (defined $quote) {
              if ($char eq "\\" && $quote eq "ansi" && $i + 1 < length($text)) {
                my $esc = substr($text, $i + 1, 1);
                my $tail = substr($text, $i + 1);
                my %simple = (a => "\a", b => "\b", e => chr(27), E => chr(27), f => "\f", n => "\n", r => "\r", t => "\t", v => chr(11));
                if ($esc eq "x" && $tail =~ /^x([0-9A-Fa-f]{1,2})/) {
                  $word .= chr(hex $1);
                  $i += length($1) + 1;
                } elsif ($tail =~ /^([0-7]{1,3})/) {
                  $word .= chr(oct($1) & 255);
                  $i += length($1);
                } elsif (($esc eq "u" && $tail =~ /^u([0-9A-Fa-f]{1,4})/) || ($esc eq "U" && $tail =~ /^U([0-9A-Fa-f]{1,8})/)) {
                  $word .= chr(hex $1);
                  $i += length($1) + 1;
                } elsif (exists $simple{$esc}) {
                  $word .= $simple{$esc};
                  $i++;
                } elsif ($esc eq "c" && $i + 2 < length($text)) {
                  $word .= chr(ord(substr($text, $i + 2, 1)) & 31);
                  $i += 2;
                } elsif ($esc eq chr(92) || $esc eq chr(39) || $esc eq q{"} || $esc eq q{?}) {
                  $word .= $esc;
                  $i++;
                } else {
                  $word .= $char;
                }
              } elsif ($char eq "\\" && $quote eq q{"} && $i + 1 < length($text) && substr($text, $i + 1, 1) =~ /[\$`"\\\n]/) {
                $word .= substr($text, ++$i, 1);
              } elsif ($char eq ($quote eq "ansi" ? chr(39) : $quote)) {
                undef $quote;
              } else {
                $word .= $char;
              }
            } elsif ($char eq q{$} && $i + 1 < length($text) && substr($text, $i + 1, 1) eq chr(39)) {
              $quote = "ansi";
              $i++;
            } elsif ($char eq q{$} && $i + 1 < length($text) && substr($text, $i + 1, 1) eq q{"}) {
              next;
            } elsif ($char eq q{"} || $char eq chr(39)) {
              $quote = $char;
            } elsif ($char eq "\\" && $i + 1 < length($text)) {
              $word .= substr($text, ++$i, 1);
            } elsif ($char =~ /\s/) {
              push @out, $word if length $word;
              $word = q{};
            } else {
              $word .= $char;
            }
          }
          push @out, $word if length $word;
          return @out;
        }
        while (my $seg = <STDIN>) {
          chomp $seg;
          my @w = words($seg);
          next unless @w;
          my $i = 0;
          $i++ if $i < @w && ($w[$i] eq "builtin" || $w[$i] eq "command");
          exit 0 if $i < @w && ($w[$i] eq "cd" || $w[$i] eq "pushd");
        }
        exit 1;
    '; then
        CD_PUSHD_TOKEN_DETECTED=1
    fi
    [ "$CD_PUSHD_TOKEN_DETECTED" = "1" ] && HOME_OR_IWE_PATHS_TAMPERED=1

    while IFS= read -r SEG; do
        [ -z "$SEG" ] && continue
        # shellcheck disable=SC2086
        set -- $SEG
        # Skip VAR=val / command / env / nohup / time / sudo / nice — move
        # to the real command. issue #825, two holes (both confirmed live by
        # cold review): (1) `nice` was missing from the wrapper list — `nice rm -f
        # ...` passed unchecked; (2) comparison by the literal word did not
        # match `/usr/bin/nice ...`/an absolute path to any wrapper —
        # basename (`${1##*/}`) closes this without touching the file system
        # (not readlink/stat — a pure string operation, it does not open the same
        # bypass class that was closed for WL_ABS/WL_ABS2/WL_ABS3 review-01/02:
        # those compare the SECOND token — the path to the script argument — for ALLOW,
        # and stay literal; here only the BLOCKING arm that
        # the command falls into changes).
        while [ $# -gt 0 ]; do
            case "$1" in
                *=*) shift ;;
                *)
                    case "${1##*/}" in
                        command|env|nohup|time|sudo) shift ;;
                        nice)
                            shift
                            # nice itself accepts an optional priority
                            # argument — `nice -n 19 cmd`/`nice -n19 cmd`
                            # (the most frequent form of a real call) without this
                            # block matched neither VAR= nor the wrapper list and
                            # stopped the loop at W0=-n, again passing
                            # unchecked (cold review found it live).
                            case "${1:-}" in
                                -n) [ $# -ge 2 ] && shift 2 || shift ;;
                                -n*|--adjustment=*) shift ;;
                                -[0-9]*) shift ;;
                            esac
                            ;;
                        *) break ;;
                    esac
                    ;;
            esac
        done
        [ $# -eq 0 ] && continue
        W0="${1##*/}"

        case "$W0" in
            git)
                shift
                # Skip global opts: -C dir, --git-dir=X, --work-tree=X, -c key=val
                while [ $# -gt 0 ]; do
                    case "$1" in
                        -C|--git-dir|--work-tree) shift 2 ;;
                        --git-dir=*|--work-tree=*) shift ;;
                        -c) shift 2 ;;
                        -c*) shift ;;
                        *) break ;;
                    esac
                done
                case "${1:-}" in
                    add|commit|push|pull|reset|merge|rebase|mv|rm) block "$CMD (git write)" ;;
                    checkout) case "${2:-}" in -*) block "$CMD (git checkout -)" ;; esac ;;
                esac
                ;;
            rm|mv)
                shift
                ARGS=""
                for a in "$@"; do
                    case "$a" in
                        -*) ;;
                        *) ARGS="$ARGS $a" ;;
                    esac
                done
                # Cleanup exception: the dry-run sentinel itself — the only allow.
                [ "$ARGS" = " $SENTINEL" ] && continue
                block "$CMD (filesystem mutation)"
                ;;
            tee)
                case "${2:-}" in
                    /dev/null) ;;
                    *) block "$CMD (tee write)" ;;
                esac
                ;;
            sed)
                echo "$SEG" | grep -qE '(^|[[:space:]])-[a-zA-Z]*i' && block "$CMD (sed in-place)"
                ;;
            curl)
                echo "$SEG" | grep -qE '(-X[[:space:]]*)?(POST|PUT|DELETE|PATCH)|--data|(^|[[:space:]])-d([[:space:]]|$)' \
                    && block "$CMD (HTTP write)"
                ;;
            psql)
                # The SQL lives in the quotes of the original command — check the original $CMD,
                # but only because the first word of the fragment is already confirmed as psql.
                echo "$CMD" | grep -qiE '(INSERT|UPDATE|DELETE|TRUNCATE|DROP|ALTER)[[:space:]]' \
                    && block "$CMD (SQL write)"
                ;;
            bash|sh|zsh)
                # Whitelist of read-only helpers (issue #264): explicitly listed
                # read-only enumerator scripts are allowed under dry-run — their
                # payload is inspected by the script code (no write paths).
                # The list is synchronized with memory/dry-run-contract.md §Bash matchers;
                # adding = editing the contract + this case + code review.
                # The absolute path is hardcoded by the exact string, not by glob
                # (review-01 High, review-02 H1): glob */.claude/... let through a
                # /tmp forgery, and ${IWE_ROOT:-...}/${IWE_WORKSPACE:-...} opened
                # the same bypass via env injection (the calling environment may
                # substitute an arbitrary env before the Bash call). The anchor is
                # $IWE_ROOT_GUESS (issue #694): the hook's own path via
                # BASH_SOURCE (line ~27), a non-standard WORKSPACE_DIR
                # resolves itself, injection via env is impossible.
                shift
                WL_ABS="$IWE_ROOT_GUESS/.claude/scripts/load-extensions.sh"
                # The real deployed path is a nested clone, not the workspace root
                # (scripts/ is not copied into $WORKSPACE_DIR, unlike .claude/;
                # see the IWE_SCRIPTS default in .claude/lib/iwe-env-bootstrap.sh:86).
                WL_ABS2="$IWE_ROOT_GUESS/FMT-exocortex-template/scripts/day-close-prepare.sh"
                # issue #549 stage 2: normal completion of a rehearsal — the transition
                # active→completed via the helper (the rm of the sentinel inside it goes
                # after completed, so it is safe itself under the gate;
                # its internal `rm -f "$SENTINEL"` is covered by the cleanup exception
                # of the rm branch above).
                WL_ABS3="$IWE_ROOT_GUESS/FMT-exocortex-template/scripts/dry-run-complete.sh"
                case "${1:-}" in
                    .claude/scripts/load-extensions.sh|"$WL_ABS") ;;
                    scripts/day-close-prepare.sh|"$WL_ABS2"|__WL_DAY_CLOSE_PREPARE__) ;;
                    scripts/dry-run-complete.sh|"$WL_ABS3"|__WL_DRY_RUN_COMPLETE__) ;;
                    *) block "$CMD (indirect execution under dry-run)" ;;
                esac
                ;;
            "__WL_IWE_PATHS_CHAIN_${GATE_NONCE}__")
                # issue #1238: whole-block marker from NORM above (see the
                # comment on that sed -e line for why the #1233 fallback
                # chain is whitelisted as ONE exact unit instead of per-
                # segment). The marker IS the whole segment here -- no
                # command word precedes it, unlike the source|. arm below,
                # so this arm matches on W0 directly.
                if [ "$HOME_OR_IWE_PATHS_TAMPERED" = "1" ]; then
                    block "$CMD (HOME/IWE_PATHS_FILE/IWE_WORKSPACE/PWD reassigned earlier in the same command)"
                fi
                shift
                # Same concatenation guard as the source|. arm's round-2
                # cold-review fix below: NORM's replacement text has spaces
                # on both sides of the marker, but sed's match itself has no
                # end-of-string anchor -- text glued directly onto the
                # matched literal with no separator (e.g. `...&& . "$IWE_PATHS"rm
                # -rf /`) stays attached to the marker as extra tokens in
                # this same segment. Any leftover token after the marker
                # means the original text wasn't actually just our chain.
                [ $# -gt 0 ] && block "$CMD (unexpected token after .iwe-paths chain whitelist marker)"
                ;;
            source|.)
                # issue #784/#785: sourcing .iwe-paths (a flat KEY=VALUE
                # file without side effects — shell state between calls
                # does not live across the agent's Bash calls, so it has to be
                # sourced in the same command) was blocked unconditionally.
                # Whitelist — by the GATE_NONCE nonce marker (see NORM above),
                # not by static text: cold review (Codex) found that a
                # static marker is spoofed by the attacker's literal input
                # (`source __WL_СТАТИКА__` + a same-named file on disk =
                # gate bypass). eval/xargs are intentionally NOT included here: general
                # indirect vectors with no known safe case in the contract.
                # Live-review finding (Fable): HOME_OR_IWE_PATHS_TAMPERED
                # (computed before this loop) revokes the whitelist if HOME/
                # IWE_PATHS_FILE is overridden somewhere in the same command.
                if [ "$HOME_OR_IWE_PATHS_TAMPERED" = "1" ]; then
                    block "$CMD (HOME/IWE_PATHS_FILE reassigned earlier in the same command)"
                fi
                shift
                case "${1:-}" in
                    "__WL_IWE_PATHS_${GATE_NONCE}__")
                        shift
                        # round-2 cold review (Codex): NORM inserts spaces
                        # around the marker on replacement — without this check
                        # `. "$HOME/.iwe-paths"suffix` (concatenation without
                        # a space in the original command) would resolve to W0=.
                        # $1=marker $2=suffix and pass as allow, although it
                        # actually sources a different file.
                        [ $# -gt 0 ] && block "$CMD (unexpected token after .iwe-paths whitelist marker)"
                        ;;
                    *) block "$CMD (indirect execution under dry-run)" ;;
                esac
                ;;
            eval|xargs)
                block "$CMD (indirect execution under dry-run)"
                ;;
            python|python3)
                # issue #460 path 5: real write path (extensions/day-close.before.garmin-verify.md
                # runs `python3 garmin-collect.py`, network + file writes) had no matcher branch
                # at all — passed through as read-only.
                shift
                case "${1:-}" in
                    # `-c "..."` inline snippets (e.g. day-close-details.md STRATEGY_DAY_NAME
                    # guard) — already outside this contract's threat model per
                    # memory/dry-run-contract.md §"Out of contract" (a malicious
                    # `python -c 'open(...,"w")'` was always an accepted gap); exempting
                    # read-only inline snippets doesn't remove protection that existed.
                    -c) ;;
                    __WL_PY_MDS__|__WL_PY_CIH__) ;;
                    *) block "$CMD (indirect execution under dry-run)" ;;
                esac
                ;;
            uv|uvx)
                # issue #821: `uv run <script>` had no matcher branch at all — same
                # gap as python/python3 (#460 path 5). `uvx` is a distinct binary
                # (alias for `uv tool run`), same threat, needs its own case arm.
                shift
                case "${1:-}" in
                    --version|-V|--help|help) ;;
                    *) block "$CMD (indirect execution under dry-run)" ;;
                esac
                ;;
        esac
    done <<< "$SPLIT"
fi

# Read-only: allow
exit 0
