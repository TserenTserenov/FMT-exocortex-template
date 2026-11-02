#!/usr/bin/env bash
# routing: utility  deterministic=true
# see DP.SC.159, DP.ROLE.059
# iwe-backup-run.sh — regular scheduled encrypted backup of the sources
#
# WP-7 Phase 237в, 2026-10-16 (peer-session 2026-10-16-18-iwe-template-backup).
#
# PROMISE: take a snapshot of all sources from iwe-backup-sources.yaml (tier0 +
# tier1 always; tier2 — with --with-optional) into the same encrypted store
# used by iwe-backup-protect.sh (a shared repository = deduplication
# between regular and protective snapshots), then apply the retention policy
# (agreed by the peer session: 7 daily / 4 weekly / 6 monthly for the tag
# `scheduled`; the `protect` tag is not touched by this script at all).
#
# The schedule lives outside this script: the daily run is done by the Synchronizer
# role's scheduler (roles/synchronizer/scripts/scheduler.sh) via scripts/iwe-backup.sh,
# restic has no separate schedule file. Without the installed role — manual only.
# Engine choice (tar/restic) and the backup contract are in scripts/iwe-backup.sh.
#
# USAGE:
#   iwe-backup-run.sh [--with-optional]
#
# EXIT CODES:
#   0 — snapshot taken and confirmed (rotation may have partially failed — see stderr)
#   1 — snapshot failed/not confirmed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../.claude/lib/iwe-env-bootstrap.sh" || exit 1

usage() {
    cat >&2 <<'EOF'
iwe-backup-run.sh [--with-optional]

Снимает регулярный снимок источников tier0+tier1 (и tier2 при --with-optional)
в общее защитное хранилище, применяет политику хранения для тега `scheduled`.
EOF
}

WITH_OPTIONAL=0
while [ $# -gt 0 ]; do
    case "$1" in
        --with-optional) WITH_OPTIONAL=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "[backup-run] неизвестный аргумент: $1" >&2; usage; exit 2 ;;
    esac
done

if ! command -v restic >/dev/null 2>&1; then
    echo "❌ [backup-run] restic не установлен — снимок не снят" >&2
    exit 1
fi

SOURCES_FILE="$SCRIPT_DIR/iwe-backup-sources.yaml"
SOURCES_OVERRIDE="$HOME/.iwe-backup-sources.local.yaml"

if [ ! -f "$SOURCES_FILE" ]; then
    echo "❌ [backup-run] файл дефолтов не найден: $SOURCES_FILE" >&2
    exit 1
fi

# The same parsing as in iwe-backup-check.sh (section 4) — prints only
# existing paths, since restic backup refuses on a nonexistent path.
PATHS_TSV=$(HOME="$HOME" WORKSPACE_ROOT="$IWE_ROOT" SOURCES_FILE="$SOURCES_FILE" SOURCES_OVERRIDE="$SOURCES_OVERRIDE" WITH_OPTIONAL="$WITH_OPTIONAL" python3 <<'PYEOF'
import os
import yaml

home = os.environ["HOME"]
workspace = os.environ["WORKSPACE_ROOT"]
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

# Same merge as iwe-backup-check.sh: an override entry with the same path
# replaces the default one; `tierX:` with an empty value is an empty list.
sources = {}
for layer in (defaults, override):
    for tier in tiers:
        for entry in layer.get(tier) or []:
            raw_path = entry.get("path") or ""
            if not raw_path:
                continue
            path = raw_path.replace("${HOME}", home).replace("${WORKSPACE_DIR}", workspace)
            sources[os.path.realpath(path)] = path
for path in sources.values():
    if os.path.exists(path):
        print(path)
PYEOF
) || PATHS_TSV=""

if [ -z "$PATHS_TSV" ]; then
    echo "❌ [backup-run] не найдено ни одного существующего источника (или сбой разбора $SOURCES_FILE) — снимок не снят" >&2
    exit 1
fi

# bash 3.2 (macOS /bin/bash) has no mapfile
PATHS=()
while IFS= read -r source_path; do
    if [ -n "$source_path" ]; then
        PATHS+=("$source_path")
    fi
done <<< "$PATHS_TSV"

PROTECT_DIR="$HOME/.iwe-backup"
REPO_DIR="$PROTECT_DIR/protect-repo"
KEY_FILE="$PROTECT_DIR/protect-repo.key"

mkdir -p "$PROTECT_DIR"
chmod 700 "$PROTECT_DIR"

if [ ! -s "$KEY_FILE" ]; then
    KEY_TMP="$(mktemp "$PROTECT_DIR/.protect-repo.key.XXXXXX")"
    ( umask 077 && head -c32 /dev/urandom | base64 > "$KEY_TMP" )
    mv "$KEY_TMP" "$KEY_FILE"
    echo "ℹ️  [backup-run] создан новый ключ шифрования защитного хранилища: $KEY_FILE" >&2
    echo "    Сохраните резервную копию этого файла отдельно — его потеря делает все будущие снимки нечитаемыми." >&2
fi

# A key readable by other users, owned by someone else or replaced by a symlink makes
# the encrypted store only as safe as that file. Stop BEFORE restic touches it; the
# content of the key is never printed.
key_file_unsafe() {  # prints the reason and returns 0 when the key file must not be used
    local f="$1" mode owner
    if [ -L "$f" ]; then
        echo "файл ключа - символьная ссылка"
        return 0
    fi
    if [ "$(uname -s)" = Darwin ]; then
        read -r mode owner < <(stat -f '%Lp %u' "$f")
    else
        read -r mode owner < <(stat -c '%a %u' "$f")
    fi
    if [ "$owner" != "$(id -u)" ]; then
        echo "владелец файла ключа - другой пользователь"
        return 0
    fi
    if [ "${mode: -2}" != "00" ]; then
        echo "файл ключа доступен другим пользователям (права $mode)"
        return 0
    fi
    return 1
}

if KEY_PROBLEM="$(key_file_unsafe "$KEY_FILE")"; then
    echo "❌ [backup-run] небезопасный файл ключа: $KEY_PROBLEM — снимок не снят." >&2
    echo "    Исправить: chmod 600 \"$KEY_FILE\" (владелец - вы, не ссылка). Содержимое ключа не показывается." >&2
    exit 1
fi

export RESTIC_REPOSITORY="$REPO_DIR"
export RESTIC_PASSWORD_FILE="$KEY_FILE"

if [ ! -d "$REPO_DIR" ]; then
    echo "[backup-run] инициализирую защитное хранилище: $REPO_DIR" >&2
    if ! restic init >/dev/null 2>&1; then
        echo "❌ [backup-run] не удалось инициализировать репозиторий restic — снимок не снят" >&2
        exit 1
    fi
fi

echo "[backup-run] создаю регулярный снимок (${#PATHS[@]} источник(ов))" >&2

BACKUP_OUTPUT=""
BACKUP_STATUS=0
BACKUP_OUTPUT=$(restic backup --json --tag scheduled "${PATHS[@]}" 2>&1) || BACKUP_STATUS=$?

if [ "$BACKUP_STATUS" -ne 0 ]; then
    echo "❌ [backup-run] снимок не удался (restic exit $BACKUP_STATUS) — см. вывод ниже" >&2
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
    echo "❌ [backup-run] снимок создан, но не подтверждён репозиторием" >&2
    exit 1
fi

echo "✅ [backup-run] снимок $SNAPSHOT_ID подтверждён" >&2

# Rotation — only by the `scheduled` tag: protect snapshots (the `protect` tag)
# are not affected by this call (a different retention policy, Phase 237б).
# A rotation failure does not cancel an already successful snapshot — report and exit 0:
# the retention policy is storage hygiene, not a data-safety guarantee.
FORGET_LOG="$(mktemp)" || FORGET_LOG="/dev/null"
if ! restic forget --tag scheduled --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune >"$FORGET_LOG" 2>&1; then
    echo "⚠️  [backup-run] ротация (forget --prune) не удалась — снимок всё равно подтверждён, место не освобождено" >&2
    cat "$FORGET_LOG" >&2
fi
[ "$FORGET_LOG" = "/dev/null" ] || rm -f "$FORGET_LOG"

echo "$SNAPSHOT_ID"
