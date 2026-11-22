#!/usr/bin/env bash
# routing: helper  skill=week-close  called-by=sonnet  deterministic=true
# see DP.SC.159, DP.ROLE.059
# iwe-backup-check.sh — Backup system health check IWE
#
# WP-317 supplement, 2026-05-18.
#
# ═══════════════════════════════════════════════════════════════════════════════
# PROMISE
# ═══════════════════════════════════════════════════════════════════════════════
# In ≤3 seconds check 4 redundancy levels IWE and output markdown-report:
#   1. iCloud-backups (primary offline-channel)
#   2. Local copies .backups/ (legacy / fallback)
#   3. Git-hygiene (remote repos on GitHub as live backup-code)
#   4. Runtime-agent runtime directories outside ${HOME}/IWE (WP-7 Phase233a) — coverage
#      sources from iwe-backup-sources.yaml: what exists, what
#      skipped (with explicit reason), how large it is.
#
# Verdict: ✅ / ⚠️ / ❌ with a concrete action list.
# The script ONLY detects.. No auto-fixes, no write-operations in git.
#
# ═══════════════════════════════════════════════════════════════════════════════
# USAGE SCENARIOS
# ═══════════════════════════════════════════════════════════════════════════════
# 1. Manual verification before Week Close (step 7a in week-close protocol).
#    bash ~/IWE/scripts/iwe-backup-check.sh
#
# 2. Daily healthcheck via launchd / cron (macOS).
#    Add to crontab: 0 9 * * * bash $HOME/IWE/scripts/iwe-backup-check.sh
#
# 3. Integration into iwe-audit.sh (future): invoked as a subprocess for the Backup section Backup.
#
# 4. Pre-backup gate: run BEFORE backup-icloud.sh, to verify that
#    there are no dirty repos, that will not be included in the archive.
#
# ═══════════════════════════════════════════════════════════════════════════════
# DEPENDENCIES
# ═══════════════════════════════════════════════════════════════════════════════
#   bash, git, stat, date, find, du, wc, cut, sort (all POSIX / macOS-compatible)
#   Platform: macOS (requires iCloud Drive). On Linux — iCloud-section will be N/A.
#
# ═══════════════════════════════════════════════════════════════════════════════
# USAGE
# ═══════════════════════════════════════════════════════════════════════════════
#   bash iwe-backup-check.sh [OPTIONS]
#
# OPTIONS:
#   --root PATH         IWE root IWE (default: $HOME/IWE)
#   --warn-days N       Threshold "warning" for backup age in days (default: 7)
#   --critical-days N   Threshold "critical" for backup in days (default: 14)
#   --no-icloud         Skip check iCloud (Linux / headless)
#   --reset-baseline    Set baseline (number of files in the archive) for checking
#                       rotation integrity. Requires locally accessible (not
#                       iCloud-stub) archive. Commits + pushes baseline-file.
#   -h, --help          Show this help
#
# EXIT CODES:
#   0 — all OK (backup fresh, git clean)
#   1 — warnings (backup 7–14 days, or ≤2 dirty repos, or stale .backups/)
#   2 — critical (backup >14 days, or no iCloud, or >2 dirty repos)
#
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

# Load unified environment: IWE_OS, IWE_ROOT, IWE_ICLOUD_BACKUP_DIR, etc.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../.claude/lib/iwe-env-bootstrap.sh" || exit 1

# ---------- Configuration ----------
WARN_DAYS=7
CRITICAL_DAYS=14
MODE="check"
# Auto-disable iCloud check on non-macOS; can be overridden via --no-icloud
[ "$IWE_OS" = "macos" ] && CHECK_ICLOUD=1 || CHECK_ICLOUD=0

# ---------- Arguments ----------
while [ $# -gt 0 ]; do
    case "$1" in
        --root) IWE_ROOT="$2"; shift 2 ;;
        --warn-days) WARN_DAYS="$2"; shift 2 ;;
        --critical-days) CRITICAL_DAYS="$2"; shift 2 ;;
        --no-icloud) CHECK_ICLOUD=0; shift ;;
        --reset-baseline) MODE="reset-baseline"; shift ;;
        -h|--help) sed -n '/^# ═══/,/^[^#]/p' "$0" | sed -e '/^[^#]/d' -e 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

if [ ! -d "$IWE_ROOT" ]; then
    echo "❌ IWE_ROOT not found: $IWE_ROOT" >&2
    exit 2
fi

# Baseline — local runtime-counter, not human-readable artifact and not in git
# (2026-07-20: current/ reserved for daily reading by the pilot). Path
# absolute, from IWE_ROOT (not from SCRIPT_DIR — that one is overwritten
# iwe-env-bootstrap.sh to its own location when source above; computed AFTER
# argument parsing, so that --root is taken into account).
REPO_DIR="${IWE_DS_MY_STRATEGY:-$IWE_ROOT/${IWE_GOVERNANCE_REPO:-DS-strategy}}"
BASELINE_FILE="$REPO_DIR/.state/backup-baseline.json"
BASELINE_THRESHOLD_PCT=80
ICLOUD_DIR="$IWE_ICLOUD_BACKUP_DIR"

# ---------- Helpers ----------
now_epoch=$(date +%s)
WARN_SEC=$((WARN_DAYS * 86400))
CRIT_SEC=$((CRITICAL_DAYS * 86400))

pass()  { printf "✅ %s\n" "$*"; }
warn()  { printf "⚠️  %s\n" "$*"; }
crit()  { printf "❌ %s\n" "$*"; }
info()  { printf "ℹ️  %s\n" "$*"; }

# GNU stat: -c %Y (mtime epoch) is tried FIRST: GNU `stat -f` means "file system status" and
# succeeds with several lines of output (#1010 F14). BSD/macOS stat rejects -c and falls to -f %m.
stat_mtime() {
    if stat -c %Y "$1" >/dev/null 2>&1; then
        stat -c %Y "$1"
    else
        stat -f %m "$1"
    fi
}

# Latest archive IWE-backup-*.tar.gz in iCloud (empty, if directory/no archives)
find_latest_icloud_archive() {
    [ -d "$ICLOUD_DIR" ] || return 0
    find "$ICLOUD_DIR" -maxdepth 1 -name 'IWE-backup-*.tar.gz' -type f 2>/dev/null | sort | tail -1
}

# du -k returns 0 for iCloud-stub (Optimize Mac Storage — file not
# downloaded locally). We distinguish "stub" from "actually empty/corrupted file".
archive_local_size_kb() {
    du -k "$1" 2>/dev/null | cut -f1
}

# Setting baseline: how many files "normally" the rotation archive contains.
# Requires a locally available (not a stub) archive. Idempotent — repeated
# call with no changes reports this and exits normally (step 20 BAK1).
reset_baseline() {
    local latest size_kb file_count existing_count

    latest=$(find_latest_icloud_archive)
    if [ -z "$latest" ]; then
        crit "No archive IWE-backup-*.tar.gz in $ICLOUD_DIR — nothing to use as baseline"
        return 2
    fi

    size_kb=$(archive_local_size_kb "$latest")
    if [ -z "$size_kb" ] || [ "$size_kb" -eq 0 ]; then
        crit "Archive $(basename "$latest") — iCloud-stub (0 KB locally). Force-download the file (open in Finder) and re-run --reset-baseline"
        return 2
    fi

    if ! tar -tzf "$latest" >/dev/null 2>&1; then
        crit "Archive $(basename "$latest") is corrupted — tar -tzf failed, baseline not set"
        return 2
    fi

    file_count=$(tar -tzf "$latest" 2>/dev/null | wc -l | tr -d '[:space:]')

    if [ -f "$BASELINE_FILE" ]; then
        existing_count=$(python3 -c "import json; print(json.load(open('$BASELINE_FILE'))['file_count'])" 2>/dev/null || echo "")
        if [ "$existing_count" = "$file_count" ]; then
            info "Baseline has not changed ($file_count files) — update is not required"
            return 0
        fi
    fi

    mkdir -p "$(dirname "$BASELINE_FILE")"
    if ! python3 -c "import json, datetime; json.dump({'file_count': $file_count, 'baseline_date': datetime.date.today().isoformat()}, open('$BASELINE_FILE', 'w'), indent=2)"; then
        crit "Failed to write baseline-file $BASELINE_FILE"
        return 1
    fi

    pass "Baseline set: $file_count files ($(basename "$latest")), written to $BASELINE_FILE"
    return 0
}

if [ "$MODE" = "reset-baseline" ]; then
    reset_baseline
    exit $?
fi

# ---------- Status ----------
EXIT_CODE=0
WARNINGS=0
CRITICALS=0

# ---------- Section 1: iCloud-backups ----------

if [ "$CHECK_ICLOUD" -eq 1 ]; then
    echo "## 1. iCloud-backups"
    echo ""

    if [ ! -d "$ICLOUD_DIR" ]; then
        crit "Directory iCloud not found: $ICLOUD_DIR"
        CRITICALS=$((CRITICALS + 1))
    else
        # Latest archive
        LATEST=$(find_latest_icloud_archive)
        TOTAL_ARCHIVES=$(find "$ICLOUD_DIR" -maxdepth 1 -name 'IWE-backup-*.tar.gz' -type f 2>/dev/null | wc -l | tr -d ' ')

        if [ -z "$LATEST" ]; then
            crit "Archives IWE-backup-*.tar.gz not found in iCloud"
            CRITICALS=$((CRITICALS + 1))
        else
            LATEST_NAME=$(basename "$LATEST")
            LATEST_SIZE=$(du -sh "$LATEST" 2>/dev/null | cut -f1)
            LATEST_MTIME=$(stat_mtime "$LATEST")
            AGE_SEC=$((now_epoch - LATEST_MTIME))
            AGE_DAYS=$((AGE_SEC / 86400))

            echo "| Metric | Value |"
            echo "|---|---|"
            echo "| Latest archive | \`$LATEST_NAME\` |"
            echo "| Size | $LATEST_SIZE |"
            echo "| Age | ${AGE_DAYS}d |"
            echo "| Total archives | $TOTAL_ARCHIVES |"
            echo ""

            if [ "$AGE_SEC" -gt "$CRIT_SEC" ]; then
                crit "Latest backup is older than $CRITICAL_DAYS days (${AGE_DAYS}d)"
                CRITICALS=$((CRITICALS + 1))
            elif [ "$AGE_SEC" -gt "$WARN_SEC" ]; then
                warn "Latest backup is older than $WARN_DAYS days (${AGE_DAYS}d)"
                WARNINGS=$((WARNINGS + 1))
            else
                pass "Backup is fresh (${AGE_DAYS}d ≤ $WARN_DAYS d)"
            fi

            if [ "$TOTAL_ARCHIVES" -lt 2 ]; then
                warn "In iCloud only $TOTAL_ARCHIVES archive(s) — rotation may be broken"
                WARNINGS=$((WARNINGS + 1))
            else
                pass "Rotation: $TOTAL_ARCHIVES archive(s)"
            fi

            # du -k == 0 → iCloud-stub (Optimize Mac Storage, file not downloaded locally
            # locally). Integrity check and file count cannot be performed on a stub —
            # not an error, but N/A (run 22 BAK1: previously this produced a false "0 files").
            LATEST_SIZE_KB=$(archive_local_size_kb "$LATEST")
            if [ -z "$LATEST_SIZE_KB" ] || [ "$LATEST_SIZE_KB" -eq 0 ]; then
                info "Archive — iCloud-iCloud stub (not downloaded locally): smoke-test and comparison with baseline skipped"
            else
                if tar -tzf "$LATEST" >/dev/null 2>&1; then
                    pass "Smoke-archive integrity test (tar -tzf) — OK"
                else
                    crit "Archive is corrupted — tar -tzf failed"
                    CRITICALS=$((CRITICALS + 1))
                fi

                if [ ! -f "$BASELINE_FILE" ]; then
                    info "Baseline not set — run: $0 --reset-baseline"
                else
                    BASELINE_COUNT=$(python3 -c "import json; print(json.load(open('$BASELINE_FILE'))['file_count'])" 2>/dev/null || echo "")
                    BASELINE_DATE=$(python3 -c "import json; print(json.load(open('$BASELINE_FILE'))['baseline_date'])" 2>/dev/null || echo "")
                    if [ -z "$BASELINE_COUNT" ]; then
                        warn "Baseline-file is corrupted ($BASELINE_FILE) — run --reset-baseline"
                        WARNINGS=$((WARNINGS + 1))
                    else
                        CURRENT_COUNT=$(tar -tzf "$LATEST" 2>/dev/null | wc -l | tr -d '[:space:]')
                        THRESHOLD_COUNT=$(( BASELINE_COUNT * BASELINE_THRESHOLD_PCT / 100 ))
                        if [ "$CURRENT_COUNT" -lt "$THRESHOLD_COUNT" ]; then
                            crit "Archive contains $CURRENT_COUNT files — less than $BASELINE_THRESHOLD_PCT% of baseline ($BASELINE_COUNT, set on $BASELINE_DATE)"
                            CRITICALS=$((CRITICALS + 1))
                        else
                            pass "Archive: $CURRENT_COUNT files (≥$BASELINE_THRESHOLD_PCT% of baseline $BASELINE_COUNT, set on $BASELINE_DATE)"
                        fi
                    fi
                fi
            fi
        fi
    fi
    echo ""
else
    echo "## 1. iCloud-backups"
    echo ""
    info "N/A (platform: $IWE_OS — iCloud available only on macOS)"
    echo ""
fi

# ---------- Section 2: Local .backups/ ----------

LOCAL_BACKUP_DIR="$IWE_ROOT/.backups"

echo "## 2. Local .backups/"
echo ""

if [ ! -d "$LOCAL_BACKUP_DIR" ]; then
    info "Directory .backups/ is absent — legacy-channel is not used"
else
    BACKUP_FOLDERS=$(find "$LOCAL_BACKUP_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)
    if [ -z "$BACKUP_FOLDERS" ]; then
        info ".backups/ exists, but is empty — OK"
    else
        FOLDER_COUNT=$(echo "$BACKUP_FOLDERS" | wc -l | tr -d ' ')
        echo "| Folder | Date | Size |"
        echo "|---|---|---|"
        while IFS= read -r folder; do
            name=$(basename "$folder")
            mtime=$(stat_mtime "$folder")
            age_days=$(((now_epoch - mtime) / 86400))
            size=$(du -sh "$folder" 2>/dev/null | cut -f1)
            printf "| \`%s\` | %sd | %s |\n" "$name" "$age_days" "$size"
        done <<< "$BACKUP_FOLDERS"
        echo ""

        # Check whether there are very old, whether there are very old entries (>30 days)
        STALE=0
        while IFS= read -r folder; do
            mtime=$(stat_mtime "$folder")
            age_days=$(((now_epoch - mtime) / 86400))
            if [ "$age_days" -gt 30 ]; then
                STALE=$((STALE + 1))
            fi
        done <<< "$BACKUP_FOLDERS"

        if [ "$STALE" -gt 0 ]; then
            warn "$STALE folders older than 30 days — cleanup is recommended"
            WARNINGS=$((WARNINGS + 1))
        else
            pass "All local copies are ≤30 days"
        fi
    fi
fi
echo ""

# ---------- Section 3: Git-hygiene ----------

echo "## 3. Git-hygiene (24 repos)"
echo ""

DIRTY_COUNT=0
UNPUSHED_COUNT=0
echo "| Repo | Uncommitted | Unpushed |"
echo "|---|---|---|"

for gitdir in $(find "$IWE_ROOT" -maxdepth 2 -name ".git" -type d 2>/dev/null); do
    repo_dir=$(dirname "$gitdir")
    repo_name=$(basename "$repo_dir")

    # Skip node_modules / .venv nested .git
    if echo "$repo_dir" | grep -qE '(node_modules|\.venv)'; then
        continue
    fi

    uncommitted="0"
    unpushed="0"

    if [ -n "$(git -C "$repo_dir" status --short 2>/dev/null)" ]; then
        uncommitted="$(git -C "$repo_dir" status --short 2>/dev/null | wc -l | tr -d ' ')"
        DIRTY_COUNT=$((DIRTY_COUNT + 1))
    fi

    ahead=$(git -C "$repo_dir" rev-list --count HEAD@{upstream}..HEAD 2>/dev/null || echo 0)
    if [ "$ahead" -gt 0 ]; then
        unpushed="$ahead"
        UNPUSHED_COUNT=$((UNPUSHED_COUNT + 1))
    fi

    if [ "$uncommitted" != "0" ] || [ "$unpushed" != "0" ]; then
        printf "| \`%s\` | %s | %s |\n" "$repo_name" "$uncommitted" "$unpushed"
    fi
done
echo ""

if [ "$DIRTY_COUNT" -eq 0 ] && [ "$UNPUSHED_COUNT" -eq 0 ]; then
    pass "All repos are clean (0 uncommitted, 0 unpushed)"
else
    if [ "$DIRTY_COUNT" -gt 0 ]; then
        warn "$DIRTY_COUNT repos with uncommitted changes"
        WARNINGS=$((WARNINGS + 1))
    fi
    if [ "$UNPUSHED_COUNT" -gt 0 ]; then
        warn "$UNPUSHED_COUNT repos with unpushed commits"
        WARNINGS=$((WARNINGS + 1))
    fi
    if [ "$DIRTY_COUNT" -gt 2 ]; then
        crit "Too many dirty repos ($DIRTY_COUNT > 2)"
        CRITICALS=$((CRITICALS + 1))
    fi
fi
echo ""

# ---------- Section 4: Runtime-agent directories (WP-7 Phase233a) ----------

echo "## 4. Runtime-agent directories outside \`\$HOME/IWE\`"
echo ""

SOURCES_FILE="$SCRIPT_DIR/iwe-backup-sources.yaml"
SOURCES_OVERRIDE="$HOME/.iwe-backup-sources.local.yaml"

if [ ! -f "$SOURCES_FILE" ]; then
    info "Defaults file not found ($SOURCES_FILE) — section skipped"
    echo ""
else
    # python3 outputs one TSV-TSV row per source: tier, path, exists(0/1), note.
    # YAML parsing YAML — here, not in bash: avoid manual parsing
    # structured format (P9) and write one row per entry. Size is NOT computed
    # here: `du -sh` on large sources (for example ~/IWE entirely, hundreds
    # GB) takes minutes and breaks the stated 3 seconds limit of this script «≤3 seconds» of this script
    # (found by live run during implementation, WP-7 Phase233a) — for status
    # coverage size is not needed, only the presence fact.
    SOURCES_TSV=$(HOME="$HOME" SOURCES_FILE="$SOURCES_FILE" SOURCES_OVERRIDE="$SOURCES_OVERRIDE" python3 <<'PYEOF'
import os
import yaml

home = os.environ["HOME"]


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

tiers = ["tier0_unique", "tier1_scheduled", "tier2_optional"]
for tier in tiers:
    entries = list(defaults.get(tier, [])) + list(override.get(tier, []))
    for entry in entries:
        raw_path = entry.get("path", "")
        path = raw_path.replace("${HOME}", home)
        note = entry.get("note", "")
        exists = os.path.exists(path)
        print(f"{tier}\t{path}\t{int(exists)}\t{note}")
PYEOF
) || SOURCES_TSV=""

    if [ -z "$SOURCES_TSV" ]; then
        warn "Failed to parse $SOURCES_FILE (empty output or error python3) — check PyYAML (python3 -c 'import yaml')"
        WARNINGS=$((WARNINGS + 1))
    else
        MISSING_TIER0=0
        echo "| Tier | Path | Status | Note |"
        echo "|---|---|---|---|"
        while IFS=$'\t' read -r tier path exists note; do
            [ -z "$tier" ] && continue
            if [ "$exists" = "1" ]; then
                printf "| %s | \`%s\` | present | %s |\n" "$tier" "$path" "${note:--}"
            else
                printf "| %s | \`%s\` | skipped (does not exist) | %s |\n" "$tier" "$path" "${note:--}"
                if [ "$tier" = "tier0_unique" ]; then
                    MISSING_TIER0=$((MISSING_TIER0 + 1))
                fi
            fi
        done <<< "$SOURCES_TSV"
        echo ""

        if [ "$MISSING_TIER0" -gt 0 ]; then
            crit "$MISSING_TIER0 source(s) of level tier0 (unrecoverable data) not found — check the path or override"
            CRITICALS=$((CRITICALS + 1))
        else
            pass "All tier0-sources (unrecoverable data) are present on disk"
        fi
    fi
    echo ""
fi

# ---------- Section 5: Freshness of the regular backup (WP-7 Phase237v) ----------

echo "## 5. Regular encrypted backup (restic)"
echo ""

PROTECT_REPO_DIR="$HOME/.iwe-backup/protect-repo"
PROTECT_KEY_FILE="$HOME/.iwe-backup/protect-repo.key"
FRESHNESS_CRIT_HOURS=48

if ! command -v restic >/dev/null 2>&1; then
    info "restic is not installed — regular backup (iwe-backup-run.sh) is not configured"
elif [ ! -d "$PROTECT_REPO_DIR" ]; then
    info "Repository $PROTECT_REPO_DIR has not been created yet — run scripts/iwe-backup-run.sh at least once"
else
    # Age is calculated in python3: restic returns ISO8601 with a real offset
    # (for example +03:00) — bash/date-parsing without accounting for offset (found by live run
    # run: naive "take the part before the dot" produced a negative age,
    # i.e. local time was interpreted as UTC).
    #
    # stderr restic (not python3) do NOT suppress: broken/missing key,
    # stale lock or a corrupt repository produce a non-zero exit code restic with
    # empty stdout — then python branch "snapshots=[]" falsely reports
    # «backup has never been run» instead of the real cause (a different fix is needed
    # fix: key/repository, not just re-running the backup) — discovered during cold review
    # review. We capture the restic output separately and display it when restic separately and show it on empty
    # result, if it is non-empty.
    RESTIC_SNAPSHOTS_ERR="$(mktemp)"
    SNAPSHOTS_JSON=$(RESTIC_REPOSITORY="$PROTECT_REPO_DIR" RESTIC_PASSWORD_FILE="$PROTECT_KEY_FILE" \
        restic snapshots --tag scheduled --json 2>"$RESTIC_SNAPSHOTS_ERR") || true
    AGE_HOURS=$(printf '%s' "$SNAPSHOTS_JSON" | python3 -c '
import datetime
import json
import sys

try:
    snapshots = json.load(sys.stdin)
except json.JSONDecodeError:
    snapshots = []
if not snapshots:
    sys.exit(1)
latest = max(datetime.datetime.fromisoformat(s["time"]) for s in snapshots)
age = datetime.datetime.now(datetime.timezone.utc) - latest
print(int(age.total_seconds() // 3600))
' 2>/dev/null) || AGE_HOURS=""

    if [ -z "$AGE_HOURS" ]; then
        if [ -s "$RESTIC_SNAPSHOTS_ERR" ]; then
            crit "restic snapshots failed with an error — storage/key require inspection, not simply «run the backup»"
            cat "$RESTIC_SNAPSHOTS_ERR" >&2
            CRITICALS=$((CRITICALS + 1))
        else
            warn "No snapshot with tag scheduled not found — scheduled backup has never been run"
            WARNINGS=$((WARNINGS + 1))
        fi
    elif [ "$AGE_HOURS" -gt "$FRESHNESS_CRIT_HOURS" ]; then
        crit "The latest scheduled snapshot is older than ${FRESHNESS_CRIT_HOURS}h (${AGE_HOURS}h ago) — schedule is not running"
        CRITICALS=$((CRITICALS + 1))
    else
        pass "Latest scheduled snapshot ${AGE_HOURS}h ago (≤ ${FRESHNESS_CRIT_HOURS}h)"
    fi
    rm -f "$RESTIC_SNAPSHOTS_ERR"
fi
echo ""

# ---------- Summary ----------

echo "---"
echo ""
echo "## Verdict"
echo ""

if [ "$CRITICALS" -gt 0 ]; then
    echo "❌ **Critical:** $CRITICALS  |  ⚠️ **Warnings:** $WARNINGS"
    echo ""
    echo "**Actions:**"
    echo "1. Run \`bash $IWE_ROOT/scripts/backup-icloud.sh\` if the backup is outdated"
    echo "2. Commit / push changes in dirty repos"
    echo "3. Check iCloud Drive in System Settings if the directory is not found"
    EXIT_CODE=2
elif [ "$WARNINGS" -gt 0 ]; then
    echo "⚠️ **Warnings:** $WARNINGS  |  Critical: 0"
    echo ""
    echo "**Recommendations:**"
    echo "- At the next Week Close run \`check-dirty-repos\` + \`backup-icloud.sh\`"
    echo "- Clean up \`.backups/\` if there are stale-folders"
    EXIT_CODE=1
else
    echo "✅ **All OK.** Backup fresh, git clean, rotation is working."
    EXIT_CODE=0
fi

exit "$EXIT_CODE"
