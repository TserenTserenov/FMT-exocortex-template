#!/usr/bin/env bash
# routing: utility  deterministic=true
# see DP.SC.159, DP.ROLE.059
# iwe-backup-run.sh — scheduled encrypted backup of sources
#
# WP-7 Phase237v, 2026-10-16 (peer-session 2026-10-16-18-iwe-template-backup).
#
# PROMISE: take a snapshot of all sources from iwe-backup-sources.yaml (tier0 +
# tier1 always; tier2 — when --with-optional) into the same encrypted repository,
# that is used by iwe-backup-protect.sh (shared repository = deduplication
# between scheduled and protect snapshots), then apply the retention policy
# (agreed upon in peer-session: 7 daily / 4 weekly / 6 monthly for tag
# `scheduled`; tag `protect` is not touched by this script at all).
#
# Schedule — outside this script (launchd plist, see. templates/iwe-backup-run.plist).
#
# USAGE:
#   iwe-backup-run.sh [--with-optional]
#
# EXIT CODES:
#   0 — snapshot taken and confirmed (rotation may have partially failed — see. stderr)
#   1 — snapshot failed/not confirmed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../.claude/lib/iwe-env-bootstrap.sh" || exit 1

usage() {
    cat >&2 <<'EOF'
iwe-backup-run.sh [--with-optional]

Takes a scheduled snapshot of sources tier0+tier1 (and tier2 with --with-optional)
into the shared protective repository, applies the retention policy for tag `scheduled`.
EOF
}

WITH_OPTIONAL=0
while [ $# -gt 0 ]; do
    case "$1" in
        --with-optional) WITH_OPTIONAL=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "[backup-run] unknown argument: $1" >&2; usage; exit 2 ;;
    esac
done

if ! command -v restic >/dev/null 2>&1; then
    echo "❌ [backup-run] restic is not installed — snapshot was not taken" >&2
    exit 1
fi

SOURCES_FILE="$SCRIPT_DIR/iwe-backup-sources.yaml"
SOURCES_OVERRIDE="$HOME/.iwe-backup-sources.local.yaml"

if [ ! -f "$SOURCES_FILE" ]; then
    echo "❌ [backup-run] defaults file not found: $SOURCES_FILE" >&2
    exit 1
fi

# Same parsing logic, as in iwe-backup-check.sh (section 4) — prints only
# existing paths, i.e. restic backup fails on a non-existent path.
PATHS_TSV=$(HOME="$HOME" SOURCES_FILE="$SOURCES_FILE" SOURCES_OVERRIDE="$SOURCES_OVERRIDE" WITH_OPTIONAL="$WITH_OPTIONAL" python3 <<'PYEOF'
import os
import yaml

home = os.environ["HOME"]
with_optional = os.environ["WITH_OPTIONAL"] == "1"


def load(path):
    if not os.path.isfile(path):
        return {}
    with open(path) as f:
        return yaml.safe_load(f) or {}


defaults = load(os.environ["SOURCES_FILE"])
override = load(os.environ["SOURCES_OVERRIDE"])

if defaults.get("schema_version") != 1:
    import sys
    print(f"unsupported schema_version: {defaults.get('schema_version')!r}", file=sys.stderr)
    sys.exit(1)

tiers = ["tier0_unique", "tier1_scheduled"]
if with_optional:
    tiers.append("tier2_optional")

for tier in tiers:
    entries = list(defaults.get(tier, [])) + list(override.get(tier, []))
    for entry in entries:
        path = entry.get("path", "").replace("${HOME}", home)
        if os.path.exists(path):
            print(path)
PYEOF
) || PATHS_TSV=""

if [ -z "$PATHS_TSV" ]; then
    echo "❌ [backup-run] no existing source found (or parse failure of $SOURCES_FILE) — snapshot was not taken" >&2
    exit 1
fi

mapfile -t PATHS <<< "$PATHS_TSV"

PROTECT_DIR="$HOME/.iwe-backup"
REPO_DIR="$PROTECT_DIR/protect-repo"
KEY_FILE="$PROTECT_DIR/protect-repo.key"

mkdir -p "$PROTECT_DIR"
chmod 700 "$PROTECT_DIR"

if [ ! -s "$KEY_FILE" ]; then
    KEY_TMP="$(mktemp "$PROTECT_DIR/.protect-repo.key.XXXXXX")"
    ( umask 077 && head -c32 /dev/urandom | base64 > "$KEY_TMP" )
    mv "$KEY_TMP" "$KEY_FILE"
    echo "ℹ️  [backup-run] new encryption key created for the protective repository: $KEY_FILE" >&2
    echo "    Keep a separate backup copy of this file — losing it makes all future snapshots unreadable." >&2
fi

export RESTIC_REPOSITORY="$REPO_DIR"
export RESTIC_PASSWORD_FILE="$KEY_FILE"

if [ ! -d "$REPO_DIR" ]; then
    echo "[backup-run] initializing protective repository: $REPO_DIR" >&2
    if ! restic init >/dev/null 2>&1; then
        echo "❌ [backup-run] failed to initialize restic repository restic — snapshot was not taken" >&2
        exit 1
    fi
fi

echo "[backup-run] creating scheduled snapshot (${#PATHS[@]} source(s))" >&2

BACKUP_OUTPUT=""
BACKUP_STATUS=0
BACKUP_OUTPUT=$(restic backup --json --tag scheduled "${PATHS[@]}" 2>&1) || BACKUP_STATUS=$?

if [ "$BACKUP_STATUS" -ne 0 ]; then
    echo "❌ [backup-run] snapshot failed (restic exit $BACKUP_STATUS) — see. output below" >&2
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

if [ -z "$SNAPSHOT_ID" ] || ! restic snapshots "$SNAPSHOT_ID" >/dev/null 2>&1; then
    echo "❌ [backup-run] snapshot created, but not confirmed by the repository" >&2
    exit 1
fi

echo "✅ [backup-run] snapshot $SNAPSHOT_ID confirmed" >&2

# Rotation — by tag only `scheduled`: snapshots protect (tag `protect`)
# are not affected by this invocation (different retention policy, Phase237b).
# A rotation failure does not cancel an already successful snapshot — report and exit 0:
# retention policy is space hygiene, not a guarantee of data safety.
FORGET_LOG="$(mktemp)" || FORGET_LOG="/dev/null"
if ! restic forget --tag scheduled --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune >"$FORGET_LOG" 2>&1; then
    echo "⚠️  [backup-run] rotation (forget --prune) failed — snapshot is confirmed anyway, space not freed" >&2
    cat "$FORGET_LOG" >&2
fi
[ "$FORGET_LOG" = "/dev/null" ] || rm -f "$FORGET_LOG"

echo "$SNAPSHOT_ID"
