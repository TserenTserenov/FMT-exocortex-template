#!/bin/bash
# routing: migration  one-time=true
# see DP.SC.159, DP.ROLE.059
# migrate-to-runtime-target.sh — migration from dirty FMT (<=0.28.x) to Generated runtime (>=0.29.0).
#
# WP-273 Stage 2 Phase 21. ArchGate v2 -> F.
#
# What it does:
#   1. Detect: is FMT dirty (substituted values instead of placeholders)?
#   2. Extracts substituted values from FMT into .exocortex.env (if not already there)
#   3. Moves .exocortex.env from FMT to $WORKSPACE_DIR/ (if legacy location)
#   4. git restore in FMT (returns clean upstream)
#   5. Runs build-runtime.sh to generate .iwe-runtime/
#   6. Hint: reinstall the launchd agents (`bash roles/X/install.sh`)
#
# Safety:
#   - Idempotent: a rerun breaks nothing.
#   - Backup: saves the dirty FMT to .iwe-runtime-migration-backup/ before git restore.
#   - launchctl unload automatically before git restore (prevents running broken scripts).
#
# Usage:
#   bash scripts/migrate-to-runtime-target.sh [--dry-run] [--workspace PATH]
#
# Exit codes:
#   0 — success (or nothing to migrate, or dry-run)
#   1 — invalid arguments
#   2 — no git in FMT (cannot check dirty status)
#   3 — build-runtime.sh not found
#   4 — git restore failed (resolve conflicts manually)

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_DIR="$(dirname "$SCRIPT_DIR")"  # FMT-exocortex-template/
DEFAULT_WORKSPACE="$(dirname "$TEMPLATE_DIR")"

WORKSPACE_DIR="$DEFAULT_WORKSPACE"
DRY_RUN=false
BACKUP_DIR=""  # set in Step 5 on the clean->dirty branch; protects against unbound in the final hint under set -eu

while [ $# -gt 0 ]; do
    case "$1" in
        --workspace) WORKSPACE_DIR="$2"; shift 2 ;;
        --dry-run)   DRY_RUN=true; shift ;;
        --help|-h)
            grep '^#' "$0" | head -28
            exit 0
            ;;
        *)
            echo "ERROR: Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

WORKSPACE_DIR="${WORKSPACE_DIR/#\~/$HOME}"

echo "=========================================="
echo "  Migrate to Generated Runtime (WP-273)"
echo "=========================================="
echo "  Template: $TEMPLATE_DIR"
echo "  Workspace: $WORKSPACE_DIR"
[ "$DRY_RUN" = true ] && echo "  Mode: DRY-RUN (no writes)"
echo ""

# === Step 1: Verify git available ===
if ! git -C "$TEMPLATE_DIR" status >/dev/null 2>&1; then
    echo "ERROR: $TEMPLATE_DIR не git-репозиторий или git не установлен." >&2
    exit 2
fi

if ! [ -f "$TEMPLATE_DIR/setup/build-runtime.sh" ]; then
    echo "ERROR: $TEMPLATE_DIR/setup/build-runtime.sh не найден." >&2
    echo "  Возможно: clone до WP-273 Этап 2 (≤0.28.x). Сначала git pull origin main." >&2
    exit 3
fi

# === Step 2: Detect dirty FMT ===
DIRTY_FILES=$(git -C "$TEMPLATE_DIR" status --porcelain | grep -E '^[ M]M ' | awk '{print $2}' || true)
DIRTY_COUNT=$(echo "$DIRTY_FILES" | grep -c . || true)

if [ "$DIRTY_COUNT" -eq 0 ]; then
    echo "[1/6] FMT clean — миграция не требуется."
    # Continue to step 3 anyway: .exocortex.env in FMT may need to be migrated
else
    echo "[1/6] Detected dirty FMT: $DIRTY_COUNT файлов с изменениями."
    if [ "$DIRTY_COUNT" -le 10 ]; then
        echo "$DIRTY_FILES" | head -10 | sed 's/^/    /'
    else
        echo "$DIRTY_FILES" | head -10 | sed 's/^/    /'
        echo "    ... ($((DIRTY_COUNT - 10)) ещё)"
    fi
fi
echo ""

# === Step 3: Migrate .exocortex.env from FMT to workspace (if needed) ===
echo "[2/6] .exocortex.env location..."
if [ -f "$TEMPLATE_DIR/.exocortex.env" ] && [ ! -f "$WORKSPACE_DIR/.exocortex.env" ]; then
    if $DRY_RUN; then
        echo "  [DRY RUN] Would copy: $TEMPLATE_DIR/.exocortex.env → $WORKSPACE_DIR/.exocortex.env"
    else
        cp "$TEMPLATE_DIR/.exocortex.env" "$WORKSPACE_DIR/.exocortex.env"
        chmod 600 "$WORKSPACE_DIR/.exocortex.env"
        echo "  ✓ Copied to $WORKSPACE_DIR/.exocortex.env (chmod 600)"
    fi
elif [ -f "$WORKSPACE_DIR/.exocortex.env" ]; then
    echo "  ✓ $WORKSPACE_DIR/.exocortex.env уже существует"
else
    echo "  ⚠ .exocortex.env не найден ни в FMT, ни в workspace."
    echo "    Запустите: bash $TEMPLATE_DIR/setup.sh"
    exit 0
fi
echo ""

# === Determine effective ENV_FILE (resilient to dry-run, where copy was not performed) ===
# Real-run: workspace/.exocortex.env was already created or existed -> use it.
# Dry-run without a workspace file: legacy FMT/.exocortex.env as the source for build-runtime --dry-run.
# Without this, dry-run fails with exit 2 "not found" right after the "Would copy" hint.
if [ -f "$WORKSPACE_DIR/.exocortex.env" ]; then
    ENV_FILE="$WORKSPACE_DIR/.exocortex.env"
elif [ -f "$TEMPLATE_DIR/.exocortex.env" ]; then
    ENV_FILE="$TEMPLATE_DIR/.exocortex.env"
else
    echo "  ⚠ .exocortex.env не найден ни в workspace, ни в FMT. Прерываюсь." >&2
    exit 0
fi

# === Step 4: Add IWE_RUNTIME to .exocortex.env (if missing) ===
echo "[3/6] IWE_RUNTIME placeholder..."
if grep -q '^IWE_RUNTIME=' "$ENV_FILE" 2>/dev/null; then
    echo "  ✓ IWE_RUNTIME уже в .exocortex.env"
else
    if $DRY_RUN; then
        echo "  [DRY RUN] Would add: IWE_RUNTIME=$WORKSPACE_DIR/.iwe-runtime"
    else
        echo "IWE_RUNTIME=$WORKSPACE_DIR/.iwe-runtime" >> "$ENV_FILE"
        echo "  ✓ Добавлено: IWE_RUNTIME=$WORKSPACE_DIR/.iwe-runtime"
    fi
fi
echo ""

# === Step 5: Backup + git restore + build runtime ===
if [ "$DIRTY_COUNT" -gt 0 ]; then
    BACKUP_DIR="$WORKSPACE_DIR/.iwe-runtime-migration-backup"

    echo "[4/6] Backup dirty FMT + git restore..."
    if $DRY_RUN; then
        echo "  [DRY RUN] Would backup dirty files to $BACKUP_DIR/"
        echo "  [DRY RUN] Would: launchctl unload IWE plists (com.strategist.*, com.extractor.*, com.exocortex.*)"
        echo "  [DRY RUN] Would: git restore (revert FMT to clean upstream)"
    else
        # Backup dirty files
        mkdir -p "$BACKUP_DIR"
        echo "$DIRTY_FILES" | while IFS= read -r f; do
            [ -z "$f" ] && continue
            mkdir -p "$BACKUP_DIR/$(dirname "$f")"
            cp "$TEMPLATE_DIR/$f" "$BACKUP_DIR/$f" 2>/dev/null || true
        done
        echo "  ✓ Dirty files backed up to $BACKUP_DIR/"

        # Unload launchd agents (prevents running broken substituted scripts)
        if command -v launchctl >/dev/null 2>&1; then
            for plist in com.strategist.morning com.strategist.weekreview com.extractor.inbox-check com.extractor.git-diff-feed com.exocortex.scheduler; do
                launchctl unload "$HOME/Library/LaunchAgents/${plist}.plist" 2>/dev/null || true
            done
            echo "  ✓ launchd: IWE-агенты выгружены"
        fi

        # git restore
        if ! git -C "$TEMPLATE_DIR" restore .; then
            echo "ERROR: git restore failed. Разрешите конфликты вручную и запустите снова." >&2
            exit 4
        fi
        echo "  ✓ FMT restored to clean upstream (HEAD: $(git -C "$TEMPLATE_DIR" rev-parse --short HEAD))"
    fi
    echo ""
else
    echo "[4/6] FMT уже clean — skip backup/restore"
    echo ""
fi

# === Step 6: Build runtime ===
echo "[5/6] build-runtime.sh..."
if $DRY_RUN; then
    bash "$TEMPLATE_DIR/setup/build-runtime.sh" \
        --dry-run --workspace "$WORKSPACE_DIR" --env-file "$ENV_FILE" 2>&1 | sed 's/^/  /'
else
    bash "$TEMPLATE_DIR/setup/build-runtime.sh" \
        --workspace "$WORKSPACE_DIR" --env-file "$ENV_FILE" 2>&1 | sed 's/^/  /'
fi
echo ""

# === Step 7: Refresh ~/.iwe-paths (R5.3 of Evgeny, 27 Apr) ===
# The 0.28.x clone did not know about IWE_RUNTIME — after migration ~/.iwe-paths stays without
# export IWE_RUNTIME, and the launchd install.sh / scheduler see an incomplete env.
# Source-of-truth: setup/install-iwe-paths.sh (also called from setup.sh [4d]).
echo "[6/6] Refreshing ~/.iwe-paths..."
GOVERNANCE_REPO_VAL=$(grep '^GOVERNANCE_REPO=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d'=' -f2-)
GOVERNANCE_REPO_VAL="${GOVERNANCE_REPO_VAL:-DS-strategy}"
if $DRY_RUN; then
    bash "$TEMPLATE_DIR/setup/install-iwe-paths.sh" \
        --workspace "$WORKSPACE_DIR" --governance "$GOVERNANCE_REPO_VAL" --dry-run 2>&1 | sed 's/^/  /'
else
    bash "$TEMPLATE_DIR/setup/install-iwe-paths.sh" \
        --workspace "$WORKSPACE_DIR" --governance "$GOVERNANCE_REPO_VAL" 2>&1 | sed 's/^/  /'
fi
echo ""

# === Done ===
echo "=========================================="
if $DRY_RUN; then
    echo "  [DRY RUN] Миграция завершена бы успешно."
    echo "=========================================="
    echo ""
    echo "Запустите без --dry-run для применения:"
    echo "  bash $TEMPLATE_DIR/scripts/migrate-to-runtime-target.sh"
else
    echo "  Миграция завершена."
    echo "=========================================="
    echo ""
    echo "Дальше (порядок важен — install.sh требует IWE_RUNTIME в env):"
    echo "  1. Перезагрузите env-переменные shell:"
    echo "     source ~/.zshenv  # либо открыть новый терминал"
    echo ""
    echo "  2. Проверьте что IWE_RUNTIME экспортирована и .iwe-runtime создан:"
    echo "     echo \$IWE_RUNTIME && ls \"\$IWE_RUNTIME/roles/\""
    echo ""
    echo "  3. Переустановите launchd-агенты тех ролей, которыми пользуетесь:"
    echo "     bash $TEMPLATE_DIR/roles/strategist/install.sh"
    echo "     bash $TEMPLATE_DIR/roles/extractor/install.sh    # опционально"
    echo "     bash $TEMPLATE_DIR/roles/synchronizer/install.sh # опционально (заменяет отдельных strategist-агентов)"
    echo ""
    echo "  Если install.sh отказывается с 'plist содержит {{IWE_RUNTIME}}' —"
    echo "  значит шаг 1 (source) пропущен. Не скопировался env."
    [ -n "$BACKUP_DIR" ] && echo "" && echo "  Backup dirty FMT: $BACKUP_DIR/"
fi
