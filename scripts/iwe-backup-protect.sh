#!/usr/bin/env bash
# routing: utility  deterministic=true
# see DP.SC.159, DP.ROLE.059
# iwe-backup-protect.sh — protection of sources before a destructive operation
#
# WP-7 Phase237b, 2026-10-16 (peer-session 2026-10-16-18-iwe-template-backup).
#
# PROMISE: create and VERIFY an encrypted snapshot of sources BEFORE launching
# the supplied command; if the snapshot failed or was not confirmed — command
# is NOT launched at all. Technical contract, not an instruction to the agent "first
# make a backup" (finding from the peer-session, Codex): a separate command "make
# a copy" does not guarantee cancellation of the next action on its failure, the wrapper —
# guarantees.
#
# KNOWN BOUNDARY: protects only operations, launched THROUGH this wrapper.
# Direct rm/rm/overwrite bypassing it is not intercepted — an honest boundary
# of the guarantee, not a hidden gap (recorded explicitly, not to be addressed later).
#
# USAGE:
#   iwe-backup-protect.sh <path...> [--reason TEXT] -- <command> [args...]
#
# EXIT CODES:
#   0 — snapshot confirmed, command launched (exit code — its own)
#   1 — snapshot failed/not confirmed, command NOT launched
#   2 — argument error (usage)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../.claude/lib/iwe-env-bootstrap.sh" || exit 1

usage() {
    cat >&2 <<'EOF'
iwe-backup-protect.sh <path...> [--reason TEXT] -- <command> [args...]

Creates and verifies an encrypted snapshot of the specified paths, then runs
the command. If the snapshot failed — the command is not run, exit 1.
EOF
}

SOURCES=()
REASON=""

while [ $# -gt 0 ]; do
    case "$1" in
        --) shift; break ;;
        --reason)
            if [ $# -lt 2 ]; then
                echo "[protect] --reason requires a value" >&2
                usage
                exit 2
            fi
            REASON="$2"
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        *) SOURCES+=("$1"); shift ;;
    esac
done

if [ "${#SOURCES[@]}" -eq 0 ] || [ $# -eq 0 ]; then
    echo "[protect] missing arguments: source paths are required-source paths and a command after --" >&2
    usage
    exit 2
fi

COMMAND=("$@")

if ! command -v restic >/dev/null 2>&1; then
    echo "❌ [protect] restic is not installed — operation was NOT performed" >&2
    exit 1
fi

PROTECT_DIR="$HOME/.iwe-backup"
REPO_DIR="$PROTECT_DIR/protect-repo"
KEY_FILE="$PROTECT_DIR/protect-repo.key"
LOG_FILE="$PROTECT_DIR/protect-log.jsonl"

mkdir -p "$PROTECT_DIR"
chmod 700 "$PROTECT_DIR"

if [ ! -s "$KEY_FILE" ]; then
    # Atomic write (temporary file + mv): two parallel first
    # initialization attempts cannot write a mixed or truncated key/truncated key
    # to the final path — exactly one mv wins `mv`, the second one overwrites
    # in the same way without corruption (the key is not used by a third
    # party in parallel). `-s` instead of `-f` also catches an empty
    # file, left over from an interrupted previous run.
    KEY_TMP="$(mktemp "$PROTECT_DIR/.protect-repo.key.XXXXXX")"
    ( umask 077 && head -c32 /dev/urandom | base64 > "$KEY_TMP" )
    mv "$KEY_TMP" "$KEY_FILE"
    echo "ℹ️  [protect] new encryption key created for the protect repository: $KEY_FILE" >&2
    echo "    Keep a separate backup of this file — losing it makes all future protect snapshots unreadable protect-snapshots unreadable." >&2
fi

export RESTIC_REPOSITORY="$REPO_DIR"
export RESTIC_PASSWORD_FILE="$KEY_FILE"

if [ ! -d "$REPO_DIR" ]; then
    echo "[protect] initializing the protect repository: $REPO_DIR" >&2
    if ! restic init >/dev/null 2>&1; then
        echo "❌ [protect] failed to initialize the restic repository restic — operation was NOT performed" >&2
        exit 1
    fi
fi

echo "[protect] creating pre-operation snapshot: ${SOURCES[*]}" >&2

BACKUP_OUTPUT=""
BACKUP_STATUS=0
BACKUP_OUTPUT=$(restic backup --json --tag protect "${SOURCES[@]}" 2>&1) || BACKUP_STATUS=$?

if [ "$BACKUP_STATUS" -ne 0 ]; then
    echo "❌ [protect] snapshot failed (restic exit $BACKUP_STATUS) — operation was NOT performed" >&2
    echo "$BACKUP_OUTPUT" >&2
    exit 1
fi

SNAPSHOT_ID=""
SNAPSHOT_ID=$(printf '%s\n' "$BACKUP_OUTPUT" | python3 -c '
import json
import sys

snapshot_id = ""
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except json.JSONDecodeError:
        continue
    if isinstance(obj, dict) and obj.get("message_type") == "summary":
        snapshot_id = obj.get("snapshot_id", "")
print(snapshot_id)
') || SNAPSHOT_ID=""

if [ -z "$SNAPSHOT_ID" ]; then
    echo "❌ [protect] snapshot created, but the identifier could not be extracted from the restic output restic — operation was NOT performed (integrity not confirmed)" >&2
    exit 1
fi

if ! restic snapshots "$SNAPSHOT_ID" >/dev/null 2>&1; then
    echo "❌ [protect] snapshot $SNAPSHOT_ID not confirmed by the repository — operation was NOT performed" >&2
    exit 1
fi

# Log — for audit convenience only, not part of the integrity guarantee:
# the snapshot has already been created and confirmed by the repository above. A log write failure
# MUST NOT cancel an already proven safe operation — therefore the entire
# block best-effort (warning to stderr, not exit).
if ! mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null; then
    echo "⚠️  [protect] failed to create log directory $(dirname "$LOG_FILE") — log entry skipped, snapshot is confirmed anyway" >&2
else
    TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    SOURCES_JOINED=$(printf '%s\x1e' "${SOURCES[@]}")
    COMMAND_JOINED=$(printf '%s ' "${COMMAND[@]}")
    if ! python3 -c '
import json
import sys

timestamp, snapshot_id, sources_joined, reason, command_joined, log_file = sys.argv[1:7]
entry = {
    "timestamp": timestamp,
    "snapshot_id": snapshot_id,
    "sources": [s for s in sources_joined.split("\x1e") if s],
    "reason": reason,
    "command": command_joined.strip(),
}
with open(log_file, "a") as f:
    f.write(json.dumps(entry, ensure_ascii=False) + "\n")
' "$TIMESTAMP" "$SNAPSHOT_ID" "$SOURCES_JOINED" "$REASON" "$COMMAND_JOINED" "$LOG_FILE"; then
        echo "⚠️  [protect] writing to log $LOG_FILE failed — snapshot is confirmed anyway" >&2
    fi
fi

echo "✅ [protect] snapshot $SNAPSHOT_ID confirmed — launching operation" >&2

# -u unsets RESTIC_REPOSITORY/RESTIC_PASSWORD_FILE before exec: otherwise they
# remain in the environment of the wrapped command (exec does not create a new process,
# only replaces the image) — if the command itself calls restic, it would otherwise
# unexpectedly see the path to this protect-repository.
exec env -u RESTIC_REPOSITORY -u RESTIC_PASSWORD_FILE "${COMMAND[@]}"
