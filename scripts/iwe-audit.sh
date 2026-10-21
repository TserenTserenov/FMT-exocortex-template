#!/usr/bin/env bash
# routing: helper  skill=audit-installation  called-by=haiku  deterministic=true
# see DP.SC.159, DP.ROLE.059
# iwe-audit.sh — IWE installation audit orchestrator IWE
#
# WP-265 Phase2, 2026-04-26.
# Service Clause: PACK-verification/.../08-service-clauses/VR.SC.005-installation-audit.md
#
# ROLE: R8 Synchronizer — collects 3 deterministic sections
# (Inventory, L1 drift, DS-strategy) and produces markdown-report.
# Section 4 (MCP healthcheck) and verdict in the role of VR.R.002 Auditor —
# scope of the skill wrapper-wrapper `/audit-installation`, not this script.
#
# Principle «detector reports, operator acts» (see. iwe-drift.sh:7-11):
# the script ONLY detects and writes markdown. No auto-fixes.
#
# Usage:
#   bash iwe-audit.sh                  # full report
#   bash iwe-audit.sh --critical       # pass --critical to iwe-drift.sh
#   bash iwe-audit.sh --root PATH      # specify $IWE_ROOT (default: $HOME/IWE)
#   bash iwe-audit.sh -h | --help
#
# Exit code:
#   0 — all OK
#   1 — warnings (missing ≤2 optional files)
#   2 — critical gaps (≥1 required file is absent)
#
# Requirements: bash, git, stat, awk (POSIX). No external dependencies.
# macOS-compatible (stat -f vs stat -c — detected at runtime).

set -eu

# Load unified environment: WORKSPACE_DIR, IWE_ROOT, IWE_SCRIPTS, etc.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../.claude/lib/iwe-env-bootstrap.sh" || exit 1
DRIFT_CRITICAL=""

while [ $# -gt 0 ]; do
    case "$1" in
        --critical) DRIFT_CRITICAL="--critical"; shift ;;
        --root) IWE_ROOT="$2"; shift 2 ;;
        -h|--help)
            grep '^#' "$0" | head -28
            exit 0
            ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

if [ ! -d "$IWE_ROOT" ]; then
    echo "IWE_ROOT not found: $IWE_ROOT" >&2
    exit 2
fi

# ---------- Helpers ----------

# Check existence of file/directory/symlink with symlink resolution.
# Returns 0 if present (any type), 1 otherwise.
exists_any() {
    local p="$1"
    [ -e "$p" ] || [ -L "$p" ]
}

# Print a table row for inventory.
# Arguments: path (relative to IWE_ROOT), required (1/0), note
emit_inventory_row() {
    local rel="$1"
    local required="$2"
    local note="${3:-}"
    local abs="$IWE_ROOT/$rel"
    local status

    if exists_any "$abs"; then
        status="✅"
        if [ -L "$abs" ] && [ -z "$note" ]; then
            note="symlink"
        fi
        FOUND=$((FOUND + 1))
    else
        if [ "$required" = "1" ]; then
            status="❌"
            CRITICAL_MISSING=$((CRITICAL_MISSING + 1))
        else
            status="⚠️"
            OPTIONAL_MISSING=$((OPTIONAL_MISSING + 1))
        fi
    fi
    TOTAL=$((TOTAL + 1))
    printf "| \`%s\` | %s | %s |\n" "$rel" "$status" "$note"
}

# ---------- Header ----------

NOW=$(date '+%Y-%m-%d %H:%M')
echo "# IWE Installation Audit — $NOW"
echo ""
echo "_Root:_ \`$IWE_ROOT\`"
echo ""

# ---------- Section 1: Inventory ----------

echo "## 1. Inventory (file structure)"
echo ""
echo "| File | Status | Note |"
echo "|---|---|---|"

TOTAL=0
FOUND=0
CRITICAL_MISSING=0
OPTIONAL_MISSING=0

# CLAUDE.md — required
emit_inventory_row "CLAUDE.md" 1 ""

# MEMORY.md — required; can be a symlink to auto-memory
# In this installation MEMORY.md lives in memory/ — check both variants
if exists_any "$IWE_ROOT/MEMORY.md"; then
    emit_inventory_row "MEMORY.md" 1 ""
elif exists_any "$IWE_ROOT/memory/MEMORY.md"; then
    # MEMORY.md in memory/ — this is auto-memory layout
    TOTAL=$((TOTAL + 1))
    FOUND=$((FOUND + 1))
    printf "| \`%s\` | %s | %s |\n" "MEMORY.md" "✅" "in memory/MEMORY.md (auto-memory layout)"
else
    TOTAL=$((TOTAL + 1))
    CRITICAL_MISSING=$((CRITICAL_MISSING + 1))
    printf "| \`%s\` | %s | %s |\n" "MEMORY.md" "❌" "not found in the root, nor in memory/"
fi

# .claude/sync-manifest.yaml — required (source for iwe-drift)
emit_inventory_row ".claude/sync-manifest.yaml" 1 ""

# Rules
emit_inventory_row ".claude/rules/distinctions.md" 1 ""
emit_inventory_row ".claude/rules/formatting.md" 1 ""

# Skills (minimum day-open / day-close)
emit_inventory_row ".claude/skills/day-open/SKILL.md" 1 ""
emit_inventory_row ".claude/skills/day-close/SKILL.md" 1 ""

# Protocols
emit_inventory_row "memory/protocol-open.md" 1 ""
emit_inventory_row "memory/protocol-work.md" 1 ""
emit_inventory_row "memory/protocol-close.md" 1 ""

# Scripts
# update.sh LIVES ONLY in IWE/update.sh for all modes
# (it resolves on its own SCRIPT_DIR=FMT-template, WORKSPACE_DIR=parent). Never
# is propagated into workspace/scripts/. Similarly iwe-drift.sh: for user-mode
# lives only in FMT-template/scripts/, in author-mode is duplicated in workspace/scripts/.
AUTHOR_MODE=0
if [ -f "$IWE_ROOT/params.yaml" ] && grep -qE "^author_mode:[[:space:]]*true" "$IWE_ROOT/params.yaml"; then
    AUTHOR_MODE=1
fi

# update.sh — always in FMT-template (for both modes)
TOTAL=$((TOTAL + 1))
if exists_any "$IWE_ROOT/IWE/update.sh"; then
    FOUND=$((FOUND + 1))
    printf "| \`%s\` | %s | %s |\n" "IWE/update.sh" "✅" "self-update self-update is launched from here"
else
    CRITICAL_MISSING=$((CRITICAL_MISSING + 1))
    printf "| \`%s\` | %s | %s |\n" "IWE/update.sh" "❌" "not found — updates are not possible"
fi

# iwe-drift.sh: check both possible locations (user-mode → only FMT-template, author-mode → both)
TOTAL=$((TOTAL + 1))
DRIFT_FMT="$IWE_ROOT/IWE/scripts/iwe-drift.sh"
DRIFT_WS="$IWE_ROOT/scripts/iwe-drift.sh"
if exists_any "$DRIFT_FMT"; then
    FOUND=$((FOUND + 1))
    if [ "$AUTHOR_MODE" = "1" ] && exists_any "$DRIFT_WS"; then
        printf "| \`%s\` | %s | %s |\n" "scripts/iwe-drift.sh" "✅" "author_mode: workspace + FMT (template-sync exports workspace → FMT)"
    else
        printf "| \`%s\` | %s | %s |\n" "scripts/iwe-drift.sh" "✅" "IWE/scripts/iwe-drift.sh (source-of-truth for user-mode)"
    fi
elif exists_any "$DRIFT_WS"; then
    FOUND=$((FOUND + 1))
    printf "| \`%s\` | %s | %s |\n" "scripts/iwe-drift.sh" "⚠️" "only in workspace/scripts/ (FMT-template absent)"
else
    CRITICAL_MISSING=$((CRITICAL_MISSING + 1))
    printf "| \`%s\` | %s | %s |\n" "scripts/iwe-drift.sh" "❌" "not found in either FMT-template, nor in workspace"
fi

# params.yaml — config
emit_inventory_row "params.yaml" 1 ""

# Governance-repo — directory with .git
GOV_REPO="${IWE_GOVERNANCE_REPO:-DS-strategy}"
DS_DIR="$IWE_ROOT/$GOV_REPO"
TOTAL=$((TOTAL + 1))
if [ -d "$DS_DIR" ]; then
    if [ -d "$DS_DIR/.git" ]; then
        FOUND=$((FOUND + 1))
        printf "| \`%s\` | %s | %s |\n" "$GOV_REPO/" "✅" "git-repo (is_git=true)"
    else
        OPTIONAL_MISSING=$((OPTIONAL_MISSING + 1))
        printf "| \`%s\` | %s | %s |\n" "$GOV_REPO/" "⚠️" "directory exists, but not a git-repo"
    fi
else
    CRITICAL_MISSING=$((CRITICAL_MISSING + 1))
    printf "| \`%s\` | %s | %s |\n" "$GOV_REPO/" "❌" "directory not found"
fi

echo ""
echo "**coverage:** $FOUND/$TOTAL (missing: critical=$CRITICAL_MISSING, optional=$OPTIONAL_MISSING)"
echo ""

# ---------- Section 2: L1 drift ----------

echo "## 2. L1 drift (platform vs FMT)"
echo ""

# Looking for iwe-drift.sh: prefer workspace (author-mode source-of-truth), fallback to FMT-template (user-mode).
DRIFT_SCRIPT="$IWE_ROOT/scripts/iwe-drift.sh"
if [ ! -f "$DRIFT_SCRIPT" ] && [ -f "$IWE_ROOT/IWE/scripts/iwe-drift.sh" ]; then
    DRIFT_SCRIPT="$IWE_ROOT/IWE/scripts/iwe-drift.sh"
fi
if [ -f "$DRIFT_SCRIPT" ]; then
    # Do not abort the whole script if iwe-drift fails — set -eu disable selectively
    set +e
    if [ -n "$DRIFT_CRITICAL" ]; then
        bash "$DRIFT_SCRIPT" --critical
        DRIFT_RC=$?
    else
        bash "$DRIFT_SCRIPT"
        DRIFT_RC=$?
    fi
    set -e
    if [ $DRIFT_RC -ne 0 ]; then
        echo ""
        echo "_iwe-drift.sh exit code: ${DRIFT_RC}_"
    fi
else
    echo "❌ \`scripts/iwe-drift.sh\` not found — drift-drift check skipped"
fi
echo ""

# ---------- Section 3: Governance repo ----------

echo "## 3. $GOV_REPO"
echo ""

if [ ! -d "$DS_DIR/.git" ]; then
    echo "❌ \`$GOV_REPO\` is not a git-repo (or directory is absent)"
else
    set +e
    DS_STATUS=$(git -C "$DS_DIR" status --short 2>&1)
    DS_STATUS_RC=$?
    set -e

    if [ $DS_STATUS_RC -ne 0 ]; then
        echo "⚠️ \`git status\` failed (rc=$DS_STATUS_RC):"
        echo ""
        echo '```'
        echo "$DS_STATUS"
        echo '```'
    else
        if [ -z "$DS_STATUS" ]; then
            DS_CHANGES_COUNT=0
        else
            DS_CHANGES_COUNT=$(printf '%s\n' "$DS_STATUS" | wc -l | tr -d ' ')
        fi
        echo "**Uncommitted changes:** $DS_CHANGES_COUNT"
        if [ "$DS_CHANGES_COUNT" -gt 0 ]; then
            echo ""
            echo '```'
            # Show no more than 30 lines, to avoid bloating the report
            printf '%s\n' "$DS_STATUS" | head -30
            if [ "$DS_CHANGES_COUNT" -gt 30 ]; then
                echo "... (more $((DS_CHANGES_COUNT - 30)) lines)"
            fi
            echo '```'
        fi
    fi

    echo ""
    echo "### Git hooks (core.hooksPath)"
    echo ""
    # WP-484 Phase9 (2026-07-23/24): core.hooksPath drifting from .githooks/ once
    # silently disabled the pre-push force-push guard (WP-436) on a live host —
    # the "guard exists but isn't wired up" gap stayed invisible until an incident.
    HOOKS_PATH=$(git -C "$DS_DIR" config --get core.hooksPath 2>/dev/null || echo "")
    if [ "$HOOKS_PATH" != ".githooks" ]; then
        if [ -x "$DS_DIR/scripts/install-hooks.sh" ]; then
            echo "⚠️ \`core.hooksPath\` = \`${HOOKS_PATH:-<not set>}\`, expected \`.githooks\` — pre-push force-push guard (WP-436) may be disabled. Fix it: \`bash \"$DS_DIR/scripts/install-hooks.sh\"\`."
        else
            echo "⚠️ \`core.hooksPath\` = \`${HOOKS_PATH:-<not set>}\`, expected \`.githooks\` — pre-push force-push guard (WP-436) may be disabled. Fix it: \`git -C \"$DS_DIR\" config core.hooksPath .githooks\`."
        fi
    elif [ ! -x "$DS_DIR/.githooks/pre-push" ]; then
        echo "⚠️ \`core.hooksPath\` correct, but \`.githooks/pre-push\` is missing or not executable."
    else
        echo "✅ \`core.hooksPath=.githooks\`, \`pre-push\` guard enabled"
    fi

    echo ""
    echo "### Diff with FMT-strategy-template"
    echo ""

    # The template is looked up in two locations:
    # (1) {{WORKSPACE_DIR}}/FMT-strategy-template/ — standalone directory (authored)
    # (2) {{WORKSPACE_DIR}}/IWE/templates/strategy-skeleton/ — inside FMT (arrives via update.sh)
    FMT_DIR="$IWE_ROOT/FMT-strategy-template"
    if [ ! -d "$FMT_DIR" ] && [ -d "$IWE_ROOT/IWE/templates/strategy-skeleton" ]; then
        FMT_DIR="$IWE_ROOT/IWE/templates/strategy-skeleton"
    fi
    if [ ! -d "$FMT_DIR" ]; then
        echo "_N/A — template not found in either \`FMT-strategy-template/\`, nor in \`IWE/templates/strategy-skeleton/\`._"
    else
        echo "_Template source: \`${FMT_DIR#$IWE_ROOT/}\`_"
        echo ""
        set +e
        FMT_DIFF=$(diff -rq "$DS_DIR/" "$FMT_DIR/" 2>&1)
        FMT_DIFF_RC=$?
        set -e

        if [ -z "$FMT_DIFF" ]; then
            echo "_No file-level differences._"
        else
            FMT_DIFF_COUNT=$(printf '%s\n' "$FMT_DIFF" | wc -l | tr -d ' ')
            echo "**Differences (file level):** $FMT_DIFF_COUNT (top shown-30)"
            echo ""
            echo '```'
            printf '%s\n' "$FMT_DIFF" | head -30
            if [ "$FMT_DIFF_COUNT" -gt 30 ]; then
                echo "... (more $((FMT_DIFF_COUNT - 30)) lines)"
            fi
            echo '```'
        fi
    fi
fi

echo ""

# ---------- Section 3b: Promoted-copy drift (issue #347, layout — issue #582) ----------
#
# CI's check-seed-drift.sh holds scripts/ ↔ seed/strategy/scripts/ INSIDE the
# template, but the EXECUTED copy lives on the user machine where CI cannot see
# it. The audit runs exactly where both sides physically exist — compare here.
# Which copy counts as "installed" depends on the layout: Day Open skills invoke
# the pipeline through $IWE_SCRIPTS (iwe-env-bootstrap.sh default: template
# scripts/). Installations that promoted copies into the governance repo point
# IWE_SCRIPTS at $GOV_REPO/scripts instead. So the drift check compares seed
# against the copy that actually runs ($IWE_SCRIPTS) — requiring a governance
# copy on a template-layout install was a false "incomplete pipeline" (issue
# #582). All three files must be checked, absence included: a missing
# lib/common.sh breaks the scaffold just as silently as a stale one (the
# scaffold sources it with FATAL on absence).
# The seed copies carry a "# SNAPSHOT — …" marker line (see
# check-seed-drift.sh): byte-identity holds only after stripping that one
# line, so the comparison below strips it too — plain cmp would report the
# marker itself as drift on every healthy install.

echo "## 3b. Promoted copies Day Open (seed template ↔ executable copy)"
echo ""
SEED_SCRIPTS="$IWE_ROOT/IWE/seed/strategy/scripts"
SEED_SNAPSHOT_MARKER="# SNAPSHOT — synced manually via script-promote.sh from IWE/scripts/. Do not edit here directly."
# Physical paths (symlinks resolved), so that an alias of the same directory does not
# be read as «another copy».
EXEC_SCRIPTS="$(cd "${IWE_SCRIPTS:-/nonexistent}" 2>/dev/null && pwd -P || true)"
SEED_SCRIPTS_PHYSICAL="$(cd "$SEED_SCRIPTS" 2>/dev/null && pwd -P || true)"
IWE_SCRIPTS_DISPLAY="${IWE_SCRIPTS:-<not set>}"
if [ ! -d "$SEED_SCRIPTS" ]; then
    echo "_N/A — template with seed/strategy/scripts/ not found._"
elif [ -z "$EXEC_SCRIPTS" ]; then
    echo "- ❌ directory \`IWE_SCRIPTS=$IWE_SCRIPTS_DISPLAY\` does not exist — pipeline Day Open will not start"
    CRITICAL_MISSING=$((CRITICAL_MISSING + 1))
elif [ "$EXEC_SCRIPTS" = "$SEED_SCRIPTS_PHYSICAL" ]; then
    echo "_N/A — pipeline is running directly from seed (\`$IWE_SCRIPTS_DISPLAY\`), no separate copy exists._"
else
    PROMOTED_DRIFT=0
    for rel in day-open-scaffold.sh day-open-pipeline.sh lib/common.sh; do
        seed_f="$SEED_SCRIPTS/$rel"
        inst_f="$EXEC_SCRIPTS/$rel"
        canon_f="$IWE_ROOT/IWE/scripts/$rel"
        # Three parties: canon (scripts/ template), snapshot (seed, with marker
        # SNAPSHOT — convention check-seed-drift.sh), installed copy
        # ($IWE_SCRIPTS). Each party is evaluated independently: absence of one does not
        # suppress diagnostics for the others (review #582, round 3). Classification
        # drift — against canon: comparing only seed↔installed copy incorrectly
        # declares the installed copy outdated, when in fact the snapshot has fallen behind,
        # and vice versa (round 2). `cp` from seed is forbidden as a recommended action: it would copy
        # the marker line into the installed copy, and the warning would reappear
        # on the next audit (round 1).
        present=0
        if [ ! -f "$seed_f" ]; then
            echo "- ⚠️ \`seed/strategy/scripts/$rel\` is not present in the template — seed delivery regression seed"
            PROMOTED_DRIFT=$((PROMOTED_DRIFT + 1))
        else
            present=$((present + 1))
        fi
        if [ ! -f "$inst_f" ]; then
            echo "- ⚠️ \`$rel\` is not present in the installed copy (\`$IWE_SCRIPTS_DISPLAY\`) — pipeline Day Open incomplete"
            PROMOTED_DRIFT=$((PROMOTED_DRIFT + 1))
        else
            present=$((present + 2))
        fi
        if [ -f "$canon_f" ]; then
            inst_ok=0; seed_ok=0
            [ $((present & 2)) -eq 2 ] && diff -q "$canon_f" "$inst_f" >/dev/null 2>&1 && inst_ok=1
            [ $((present & 1)) -eq 1 ] && diff -q <(grep -vF "$SEED_SNAPSHOT_MARKER" "$seed_f") "$canon_f" >/dev/null 2>&1 && seed_ok=1
            if [ $((present & 2)) -eq 2 ] && [ "$inst_ok" = 0 ]; then
                echo "- ⚠️ \`$rel\` in the installed copy has fallen behind the template canon — update: \`cp \"$canon_f\" \"$inst_f\"\` (save any local edits in the copy first)"
                PROMOTED_DRIFT=$((PROMOTED_DRIFT + 1))
            fi
            if [ $((present & 1)) -eq 1 ] && [ "$seed_ok" = 0 ]; then
                echo "- ⚠️ \`seed/strategy/scripts/$rel\` has fallen behind \`scripts/$rel\` — update snapshot: \`bash \"$IWE_ROOT/IWE/scripts/check-seed-drift.sh\" --fix\`"
                PROMOTED_DRIFT=$((PROMOTED_DRIFT + 1))
            fi
            if [ "$present" = 3 ] && [ "$inst_ok" = 1 ] && [ "$seed_ok" = 1 ]; then
                echo "- ✅ \`$rel\` matches the template canon (seed-snapshot is in sync)"
            fi
        else
            # Absence of the canon — is itself a template delivery regression,
            # even if the remaining copies match (review #582, round 4).
            echo "- ⚠️ canonical \`scripts/$rel\` is not present in the template — delivery regression"
            PROMOTED_DRIFT=$((PROMOTED_DRIFT + 1))
            if [ "$present" = 3 ]; then
                # The only remaining meaningful comparison: snapshot
                # (without marker) ↔ deployed copy.
                if diff -q <(grep -vF "$SEED_SNAPSHOT_MARKER" "$seed_f") "$inst_f" >/dev/null 2>&1; then
                    echo "- ✅ \`$rel\` matches seed (canonical scripts/ not available)"
                else
                    echo "- ⚠️ \`$rel\` in the deployed copy has diverged from seed of the template, canonical \`scripts/$rel\` not found — verify manually"
                    PROMOTED_DRIFT=$((PROMOTED_DRIFT + 1))
                fi
            fi
        fi
    done
    if [ "$PROMOTED_DRIFT" -gt 0 ]; then
        OPTIONAL_MISSING=$((OPTIONAL_MISSING + PROMOTED_DRIFT))
    fi
fi

echo ""

# ---------- Section 4: User customizations (L3) ----------
#
# L3 lives in 3-places: extensions/, params.yaml (differences from skeleton),
# AUTHOR-ONLY zones in extensions/*.md.
# Goal — show, that after restore personal customizations are in place.
# This is an **informational** section: absence of L3 ≠ failure (a new pilot has not yet
# configured anything). Verdict verdict is rendered by the Auditor substantively.

echo "## 4. User customizations (L3)"
echo ""

# 4a. extensions/
EXT_DIR="$IWE_ROOT/extensions"
echo "### Extensions"
echo ""
if [ ! -d "$EXT_DIR" ]; then
    echo "_extensions/ directory is absent — extensions are not configured_"
else
    set +e
    EXT_FILES=$(find -L "$EXT_DIR" -maxdepth 1 -type f -name "*.md" ! -name "README.md" 2>/dev/null | sort)
    set -e
    if [ -z "$EXT_FILES" ]; then
        echo "_In extensions/ only README — no user hooks present_"
    else
        EXT_COUNT=$(printf '%s\n' "$EXT_FILES" | wc -l | tr -d ' ')
        echo "**Hooks found:** $EXT_COUNT"
        echo ""
        echo "| Hook | Size | Source |"
        echo "|---|---|---|"
        printf '%s\n' "$EXT_FILES" | while read -r ext_file; do
            ext_name=$(basename "$ext_file")
            ext_size=$(wc -l < "$ext_file" | tr -d ' ')
            # issue #341 item.1: extensions are often kept in a governance-repo and linked
            # here — silently showing them as a regular file hides where, where the
            # customization actually lives (important when reviewing after restore/update).
            if [ -L "$ext_file" ]; then
                ext_target=$(readlink "$ext_file")
                printf "| \`%s\` | %s lines | symlink → \`%s\` |\n" "$ext_name" "$ext_size" "$ext_target"
            else
                printf "| \`%s\` | %s lines | file |\n" "$ext_name" "$ext_size"
            fi
        done
    fi
fi
echo ""

# 4b. params.yaml — differences from skeleton
echo "### params.yaml — differences from template"
echo ""
PARAMS_USER="$IWE_ROOT/params.yaml"
# issue #348: reference moved to params.yaml.example — working params.yaml inside
# template is no longer tracked. Old name remains as fallback: on an installation,
# not fully updated, the previous file may be present alongside.
PARAMS_TEMPLATE="$IWE_ROOT/IWE/params.yaml.example"
[ -f "$PARAMS_TEMPLATE" ] || PARAMS_TEMPLATE="$IWE_ROOT/IWE/params.yaml"
if [ ! -f "$PARAMS_USER" ]; then
    echo "_params.yaml not found — configuration is not initialized_"
elif [ ! -f "$PARAMS_TEMPLATE" ]; then
    echo "_IWE/params.yaml.example not found — comparison is not possible_"
else
    set +e
    # Ignore comments and blank lines during comparison
    PARAMS_DIFF=$(diff <(grep -vE '^\s*(#|$)' "$PARAMS_TEMPLATE" | sort) \
                       <(grep -vE '^\s*(#|$)' "$PARAMS_USER" | sort) 2>&1)
    set -e
    if [ -z "$PARAMS_DIFF" ]; then
        echo "_Exact match with skeleton._"
    else
        PARAMS_DIFF_LINES=$(printf '%s\n' "$PARAMS_DIFF" | wc -l | tr -d ' ')
        echo "**Differences:** $PARAMS_DIFF_LINES lines (showing top-15)"
        echo ""
        echo '```diff'
        printf '%s\n' "$PARAMS_DIFF" | head -15
        echo '```'
    fi
fi
echo ""

# 4c. AUTHOR-ONLY zones in extensions/
echo "### AUTHOR-ONLY zones (extensions/)"
echo ""
EXTENSIONS_DIR="$IWE_ROOT/extensions"
if [ ! -d "$EXTENSIONS_DIR" ]; then
    echo "_extensions/ not found (normal for a new pilot)_"
else
    set +e
    AUTHOR_FILES=$(find "$EXTENSIONS_DIR" -name "*.md" -print0 2>/dev/null | xargs -0 grep -l "<!-- AUTHOR-ONLY" 2>/dev/null | wc -l | tr -d ' ')
    AUTHOR_BLOCKS=$(find "$EXTENSIONS_DIR" -name "*.md" -print0 2>/dev/null | xargs -0 grep -c "<!-- AUTHOR-ONLY" 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')
    set -e
    [ -z "$AUTHOR_FILES" ] && AUTHOR_FILES=0
    [ -z "$AUTHOR_BLOCKS" ] && AUTHOR_BLOCKS=0
    if [ "$AUTHOR_BLOCKS" -eq 0 ]; then
        echo "_AUTHOR-ONLY zones not found in extensions/ (normal for a new pilot)_"
    else
        echo "✅ Found AUTHOR-ONLY markers in AUTHOR-ONLY in extensions/:"
        echo "- files with markers: $AUTHOR_FILES"
        echo "- blocks \`<!-- AUTHOR-ONLY -->\`: $AUTHOR_BLOCKS"
    fi
fi
echo ""

# 4d. USER-SPACE zones in L1 FMT skills
echo "### USER-SPACE zones in L1-skills"
echo ""
FMT_SKILLS_DIR="$IWE_ROOT/IWE/.claude/skills"
if [ ! -d "$FMT_SKILLS_DIR" ]; then
    echo "_IWE/ not found — skipping_"
else
    total_l1=0
    with_markers=0
    without_markers=0
    while IFS= read -r -d '' md_file; do
        if grep -qE '^layer:[[:space:]]*L1' "$md_file" 2>/dev/null; then
            total_l1=$((total_l1 + 1))
            if grep -q '^<!-- USER-SPACE -->' "$md_file" 2>/dev/null; then
                with_markers=$((with_markers + 1))
            else
                without_markers=$((without_markers + 1))
            fi
        fi
    done < <(find "$FMT_SKILLS_DIR" -name "SKILL.md" -print0 2>/dev/null)
    if [ "$total_l1" -eq 0 ]; then
        echo "_L1-L1 skills not found_"
    elif [ "$without_markers" -eq 0 ]; then
        echo "✅ USER-SPACE markers: $with_markers/$total_l1 L1-L1 skills"
    else
        echo "⚠️ USER-SPACE markers are missing in $without_markers/$total_l1 L1-L1 skills"
        echo "  Run: bash \$IWE_ROOT/IWE/scripts/add-skill-markers.sh"
    fi
fi
echo ""

# ---------- Section 5: Update prerequisites ----------
#
# Check prerequisites for a successful run of update.sh, without running it itself.
# Goal — diagnose «why update will fail» BEFORE running (Q7 WP-265).
# Not a failure for the entire audit: missing prereq prereq → ⚠️ warning, pilot decides.

echo "## 5. Update prerequisites"
echo ""

UPD_WARN=0
UPD_FAIL=0

echo "### Binaries"
echo ""
echo "| Binary | Status | Path |"
echo "|---|---|---|"
for bin in git curl python3; do
    set +e
    BIN_PATH=$(command -v "$bin" 2>/dev/null)
    set -e
    if [ -n "$BIN_PATH" ]; then
        printf "| \`%s\` | ✅ | %s |\n" "$bin" "$BIN_PATH"
    else
        printf "| \`%s\` | ❌ | — |\n" "$bin"
        UPD_FAIL=$((UPD_FAIL + 1))
    fi
done
echo ""

echo "### Available memory"
echo ""
# issue #461 (WP-7 Phase76): PreToolUse hook timeouts were diagnosed on a live installation
# as "hook did not respond", although measurement (4 hooks on the Edit/Write path Edit/Write, total ~1,2s with
# timeout of tens of seconds) ruled out hooks as the cause — the real cause turned out to be
# memory starvation of the host-process. Proactive checking catches this BEFORE, as
# the failure manifests in the middle of the ritual, and not only after the fact in the error message.
# Capability-based: PSI (/proc/pressure/memory) — Linux cgroup v2 without a
# cross-platform equivalent (peer-session 2026-08-18-08-wp7-f75-f76-smoke-memory,
# consensus with Codex) — macOS obtains RAM/swap via vm_stat/sysctl without a PSI PSI-equivalent,
# not a pretend surrogate.
MEM_WARN_THRESHOLD_PCT=15  # free < 15% of total — warning, not a hard block
case "$(uname)" in
    Linux)
        if [ -r /proc/meminfo ]; then
            MEM_TOTAL_KB=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
            MEM_AVAIL_KB=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
            if [ -n "$MEM_TOTAL_KB" ] && [ -n "$MEM_AVAIL_KB" ] && [ "$MEM_TOTAL_KB" -gt 0 ]; then
                MEM_AVAIL_PCT=$((MEM_AVAIL_KB * 100 / MEM_TOTAL_KB))
                MEM_TOTAL_GIB=$(awk -v kb="$MEM_TOTAL_KB" 'BEGIN{printf "%.1f", kb/1024/1024}')
                MEM_AVAIL_GIB=$(awk -v kb="$MEM_AVAIL_KB" 'BEGIN{printf "%.1f", kb/1024/1024}')
                if [ "$MEM_AVAIL_PCT" -lt "$MEM_WARN_THRESHOLD_PCT" ]; then
                    echo "⚠️ Free ${MEM_AVAIL_GIB} GiB of ${MEM_TOTAL_GIB} GiB (${MEM_AVAIL_PCT}%) — below threshold ${MEM_WARN_THRESHOLD_PCT}%. Write/read tool failures with message/read failures with message \`PreToolUse hook did not respond\` at this memory level — known class (issue #461), not necessarily a hook problem."
                    UPD_WARN=$((UPD_WARN + 1))
                else
                    echo "✅ Free ${MEM_AVAIL_GIB} GiB of ${MEM_TOTAL_GIB} GiB (${MEM_AVAIL_PCT}%)"
                fi
            else
                echo "ℹ️ Failed to parse \`/proc/meminfo\` (MemTotal/MemAvailable)."
            fi
            if [ -r /proc/pressure/memory ]; then
                PSI_SOME=$(awk '/^some/{for(i=1;i<=NF;i++) if ($i ~ /^avg60=/) print $i}' /proc/pressure/memory | cut -d= -f2)
                if [ -n "$PSI_SOME" ]; then
                    echo "ℹ️ Memory pressure (PSI avg60, some): ${PSI_SOME}%"
                fi
            fi
        else
            echo "ℹ️ \`/proc/meminfo\` not available — memory check skipped."
        fi
        ;;
    Darwin)
        set +e
        MEM_TOTAL_BYTES=$(sysctl -n hw.memsize 2>/dev/null)
        VM_STAT_OUT=$(vm_stat 2>/dev/null)
        set -e
        if [ -n "$MEM_TOTAL_BYTES" ] && [ "$MEM_TOTAL_BYTES" -gt 0 ] && [ -n "$VM_STAT_OUT" ]; then
            PAGE_SIZE=$(echo "$VM_STAT_OUT" | head -1 | grep -oE '[0-9]+' | head -1)
            PAGE_SIZE=${PAGE_SIZE:-4096}
            PAGES_FREE=$(echo "$VM_STAT_OUT" | awk '/Pages free:/{gsub(/\./,"",$3); print $3}')
            PAGES_INACTIVE=$(echo "$VM_STAT_OUT" | awk '/Pages inactive:/{gsub(/\./,"",$3); print $3}')
            if [ -n "$PAGES_FREE" ] && [ -n "$PAGES_INACTIVE" ]; then
                MEM_AVAIL_BYTES=$(( (PAGES_FREE + PAGES_INACTIVE) * PAGE_SIZE ))
                MEM_AVAIL_PCT=$((MEM_AVAIL_BYTES * 100 / MEM_TOTAL_BYTES))
                MEM_TOTAL_GIB=$(awk -v b="$MEM_TOTAL_BYTES" 'BEGIN{printf "%.1f", b/1024/1024/1024}')
                MEM_AVAIL_GIB=$(awk -v b="$MEM_AVAIL_BYTES" 'BEGIN{printf "%.1f", b/1024/1024/1024}')
                if [ "$MEM_AVAIL_PCT" -lt "$MEM_WARN_THRESHOLD_PCT" ]; then
                    echo "⚠️ Free+inactive ${MEM_AVAIL_GIB} GiB of ${MEM_TOTAL_GIB} GiB (${MEM_AVAIL_PCT}%) — below threshold ${MEM_WARN_THRESHOLD_PCT}%. Write/read tool failures with message/read with message \`PreToolUse hook did not respond\` at this memory level — known class (issue #461), not necessarily a hook problem."
                    UPD_WARN=$((UPD_WARN + 1))
                else
                    echo "✅ Free+inactive ${MEM_AVAIL_GIB} GiB of ${MEM_TOTAL_GIB} GiB (${MEM_AVAIL_PCT}%)"
                fi
            else
                echo "ℹ️ Could not parse output \`vm_stat\` (Pages free/inactive)."
            fi
        else
            echo "ℹ️ \`sysctl hw.memsize\`/\`vm_stat\` unavailable — memory check skipped."
        fi
        set +e
        SWAP_USED=$(sysctl -n vm.swapusage 2>/dev/null | grep -oE 'used = [0-9.]+[MG]' | grep -oE '[0-9.]+[MG]')
        set -e
        if [ -n "$SWAP_USED" ]; then
            echo "ℹ️ Swap used: ${SWAP_USED}"
        fi
        ;;
    *)
        echo "ℹ️ Memory check is not implemented for platform $(uname)."
        ;;
esac
echo ""

echo "### Configuration (.exocortex.env)"
echo ""
# WP-273: setup.sh ≥0.7.0 saves .exocortex.env in $IWE_ROOT/, not in $HOME/
if [ -f "$IWE_ROOT/.exocortex.env" ]; then
    ENV_FILE="$IWE_ROOT/.exocortex.env"
else
    ENV_FILE="$HOME/.exocortex.env"  # legacy: installs before setup.sh ≥0.7.0
fi
if [ ! -f "$ENV_FILE" ]; then
    if [ "$AUTHOR_MODE" = "1" ]; then
        echo "ℹ️ \`.exocortex.env\` not needed in author_mode (placeholders are substituted by template-sync.sh, not update.sh)."
    else
        echo "❌ File \`.exocortex.env\` is missing — update.sh will not be able to substitute placeholders. Fix: run \`bash $IWE_ROOT/setup.sh\`."
        UPD_FAIL=$((UPD_FAIL + 1))
    fi
else
    set +e
    GH_USER=$(grep -E "^GITHUB_USER=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'")
    set -e
    if [ -z "$GH_USER" ] || [ "$GH_USER" = "{{GITHUB_USER}}" ]; then
        echo "⚠️ \`GITHUB_USER\` is empty or = placeholder. Fix: edit \`~/.exocortex.env\`, set the login."
        UPD_WARN=$((UPD_WARN + 1))
    else
        echo "✅ \`GITHUB_USER=$GH_USER\` is set"
    fi
fi
echo ""

echo "### Status IWE"
echo ""
FMT_TPL="$IWE_ROOT/IWE"
if [ ! -d "$FMT_TPL" ]; then
    echo "⚠️ \`IWE/\` is missing — update.sh update.sh will clone it on first run. If update has already been run and did not succeed, check network connectivity to GitHub."
    UPD_WARN=$((UPD_WARN + 1))
elif [ ! -d "$FMT_TPL/.git" ]; then
    echo "❌ \`IWE/\` exists, but is not a git-repo — update.sh will not be able to fetch/pull. Fix: re-clone."
    UPD_FAIL=$((UPD_FAIL + 1))
else
    set +e
    FMT_DIRTY=$(git -C "$FMT_TPL" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    FMT_BRANCH=$(git -C "$FMT_TPL" branch --show-current 2>/dev/null)
    set -e
    if [ "$FMT_DIRTY" -gt 0 ]; then
        echo "⚠️ \`IWE/\` has $FMT_DIRTY uncommitted changes (branch \`$FMT_BRANCH\`) — update may conflict. Fix: \`git -C IWE stash\` or commit."
        UPD_WARN=$((UPD_WARN + 1))
    else
        echo "✅ \`IWE/\` clean (branch \`$FMT_BRANCH\`)"
    fi
fi
echo ""

# WP-5 F57: the author's usage instruction (FPF/USING-FPF.md) reaches an
# installation only through its FPF copy, which update.sh fast-forwards. A copy
# that is missing, older than the instruction, or behind the server means agents
# quote FPF from memory. Warning only: the copy is optional infrastructure.
# Commit age alone proves neither staleness (the author may simply not have
# published) nor freshness (a copy can be days behind a recent tip), so age is
# reported as a hint and lag is measured against the last known server state.
report_fpf_copy_state() {
    local fpf="$IWE_ROOT/FPF" commit_ts now_ts age_days behind

    echo "### Copy status FPF"
    echo ""
    # .git is a file, not a directory, in a linked worktree or a submodule.
    if [ ! -e "$fpf/.git" ]; then
        echo "⚠️ Copy \`FPF/\` not found — skill \`/fpf\` will not be able to read the full text. Fix: \`bash update.sh\` or clone ailev/FPF into \`FPF/\`."
        UPD_WARN=$((UPD_WARN + 1))
        echo ""
        return 0
    fi
    if [ -f "$fpf/USING-FPF.md" ]; then
        echo "✅ \`FPF/USING-FPF.md\` (authors instructions) is present"
    else
        echo "⚠️ The FPF copy does not have FPF does not have \`USING-FPF.md\` — the copy is older than the authors instructions. Fix: \`bash update.sh\` (will update the copy) or \`git -C FPF pull --ff-only\`, if the copy has no local changes."
        UPD_WARN=$((UPD_WARN + 1))
    fi
    behind=$(git -C "$fpf" rev-list --count 'HEAD..@{u}' 2>/dev/null || echo "")
    if [ -n "$behind" ] && [ "$behind" -gt 0 ]; then
        echo "⚠️ Copy FPF is behind the last known server state by $behind commit(s) (based on the last fetch). Fix: \`bash update.sh\`."
        UPD_WARN=$((UPD_WARN + 1))
    fi
    commit_ts=$(git -C "$fpf" log -1 --format=%ct 2>/dev/null || echo 0)
    now_ts=$(date +%s)
    if [ "${commit_ts:-0}" -le 0 ]; then
        echo "⚠️ Could not read the date of the last commit of the FPF copy FPF."
        UPD_WARN=$((UPD_WARN + 1))
    else
        age_days=$(( (now_ts - commit_ts) / 86400 ))
        [ "$age_days" -lt 0 ] && age_days=0
        if [ "$age_days" -gt 30 ]; then
            echo "⚠️ The last commit of the FPF copy is FPF older than 30 days ($age_days d.) — possibly, the copy is outdated (or the author has not published anything for a long time). Fix: \`bash update.sh\`."
            UPD_WARN=$((UPD_WARN + 1))
        elif [ -z "$behind" ] || [ "$behind" -eq 0 ]; then
            echo "✅ Copy FPF is up to date (last commit $age_days d. ago)"
        fi
    fi
    echo ""
}

report_fpf_copy_state

if [ $UPD_FAIL -gt 0 ]; then
    echo "**Section verdict:** ❌ $UPD_FAIL critical preconditions are not met — \`update.sh\` will fail without them."
elif [ $UPD_WARN -gt 0 ]; then
    echo "**Section verdict:** ⚠️ $UPD_WARN warnings — \`update.sh\` may partially succeed, but check the recommendations above."
else
    echo "**Section verdict:** ✅ ready for \`update.sh\`."
fi
echo ""

# Accounting in the final exit code: critical-fail in update prereq raises CRITICAL_MISSING
if [ $UPD_FAIL -gt 0 ]; then
    CRITICAL_MISSING=$((CRITICAL_MISSING + UPD_FAIL))
fi
if [ $UPD_WARN -gt 0 ]; then
    OPTIONAL_MISSING=$((OPTIONAL_MISSING + UPD_WARN))
fi

# ---------- Section 6: Cross-platform path leaks (WP-5/WP-7 Stability-4) ----------
#
# Detector: on Linux-server must not contain macOS-paths `/Users/...` or
# slug `{{CLAUDE_PROJECT_SLUG}}` in systemd-units, configs, env-files.
# Source: 12 May 2026, MEMORY_SRC in template-sync.sh pointed to macOS slug
# on Linux-server → silent WARN: Source not found every night.
#
# Runs ONLY on Linux. On macOS — skipped (paths are normal).

echo "## 6. Cross-platform path leaks"
echo ""

OS_NAME="$(uname -s)"
if [ "$OS_NAME" != "Linux" ]; then
    echo "_Skipped (this host — $OS_NAME, check is relevant only for Linux-servers)._"
    echo ""
else
    LEAK_COUNT=0
    LEAK_LOCATIONS=""

    # Search locations (common configuration entry points). Leak patterns — in grep below.
    LEAK_TARGETS="
/etc/systemd/system
/etc/iwe
$HOME/.config
$HOME/.iwe-runtime
$IWE_ROOT/.iwe-runtime
$IWE_ROOT/.claude
"

    echo "| Location | Leaks | Example |"
    echo "|---|---|---|"
    for target in $LEAK_TARGETS; do
        [ -e "$target" ] || continue
        set +e
        HITS=$(grep -rIl --include='*.sh' --include='*.env' --include='*.service' \
            --include='*.timer' --include='*.json' --include='*.yaml' --include='*.yml' \
            -e "{{HOME_DIR}}" -e "{{CLAUDE_PROJECT_SLUG}}" \
            "$target" 2>/dev/null | head -5)
        set -e
        if [ -n "$HITS" ]; then
            HITS_COUNT=$(echo "$HITS" | wc -l | tr -d ' ')
            LEAK_COUNT=$((LEAK_COUNT + HITS_COUNT))
            FIRST=$(echo "$HITS" | head -1)
            printf "| \`%s\` | %s | \`%s\` |\n" "$target" "$HITS_COUNT" "$FIRST"
            LEAK_LOCATIONS="$LEAK_LOCATIONS\n$HITS"
        else
            printf "| \`%s\` | 0 | — |\n" "$target"
        fi
    done
    echo ""

    if [ $LEAK_COUNT -gt 0 ]; then
        echo "**Found $LEAK_COUNT files with macOS-paths.** Fix: replace with \`\$HOME\`, \`{{HOME_DIR}}\` or \`\$IWE_ROOT\`. Possible silent failures in scripts."
        OPTIONAL_MISSING=$((OPTIONAL_MISSING + 1))
    else
        echo "✅ macOS-paths not found — configuration is correct for Linux."
    fi
fi
echo ""

# ---------- Section 7: Repo permissions integrity (WP-5/WP-7 Stability-4b) ----------
#
# Detector: files in .git/objects/ must be owned by the user, who runs
# pull/commit. If as a result of ssh-as-root operations (or sudo without -u) appeared
# root-owned objects — subsequent pull under a regular user fails with
# "insufficient permission for adding an object to repository database".
#
# Source: 11→12 May 2026, dirty pull-repos warnings on the remote pilot server — the root cause turned out to be
# in root-owned .git/objects after ssh-as-root commands from mac.
#
# Relevant for Linux (where ssh may connect as different user). On macOS usually
# everything under one user — skipping.

echo "## 7. Repo permissions integrity"
echo ""

if [ "$OS_NAME" != "Linux" ]; then
    echo "_Skipped (this host — $OS_NAME, check is relevant for multi-user Linux-servers)._"
    echo ""
else
    EXPECTED_USER="${IWE_AUDIT_USER:-$(whoami)}"
    PERM_VIOLATIONS=0
    echo "Expected owner: \`$EXPECTED_USER\` (override: IWE_AUDIT_USER=...)"
    echo ""

    echo "| Repo | Foreign files in .git | Example |"
    echo "|---|---|---|"
    for repo_git in $(find -L "$IWE_ROOT" -maxdepth 3 -type d -name '.git' 2>/dev/null); do
        repo="${repo_git%/.git}"
        repo_name="${repo#$IWE_ROOT/}"
        set +e
        # find -not -user may not work on NixOS if whoami not in /etc/passwd
        FOREIGN=$(find "$repo_git" -not -user "$EXPECTED_USER" 2>/dev/null | head -5)
        set -e
        if [ -n "$FOREIGN" ]; then
            FOREIGN_COUNT=$(echo "$FOREIGN" | wc -l | tr -d ' ')
            PERM_VIOLATIONS=$((PERM_VIOLATIONS + 1))
            FIRST=$(echo "$FOREIGN" | head -1)
            printf "| \`%s\` | %s | \`%s\` |\n" "$repo_name" "$FOREIGN_COUNT" "$FIRST"
        fi
    done
    echo ""

    if [ $PERM_VIOLATIONS -gt 0 ]; then
        echo "**Found $PERM_VIOLATIONS repos with foreign files in .git/.** Fix: \`sudo chown -R $EXPECTED_USER:$EXPECTED_USER <repo>/.git\`. Prevention: ssh not as root, or explicit \`sudo -u $EXPECTED_USER git ...\`."
        OPTIONAL_MISSING=$((OPTIONAL_MISSING + 1))
    else
        echo "✅ All repos have the correct owner of .git/. .git/."
    fi
fi
echo ""

# ---------- Exit code ----------

# 2 = critical gaps; 1 = warnings; 0 = OK
if [ $CRITICAL_MISSING -ge 1 ]; then
    exit 2
fi
if [ $OPTIONAL_MISSING -gt 0 ]; then
    exit 1
fi
exit 0
