#!/bin/bash
# build-runtime.sh — Generated runtime architecture (WP-273 Stage 2 Phase18)
#
# Idempotent rebuild $WORKSPACE_DIR/.iwe-runtime/ from IWE + .exocortex.env.
# Analogous to a Nix derivation Nix derivation: the same inputs → identical output.
#
# Source-of-truth: authoritative FMT (immutable, regenerable).
# Output: $WORKSPACE_DIR/.iwe-runtime/ (regenerable, not in git).
# Trigger: setup.sh, update.sh, manual run.
#
# Usage:
#   bash build-runtime.sh                   # rebuild + write
#   bash build-runtime.sh --dry-run         # show what would be created, without writing
#   bash build-runtime.sh --diff            # diff between the current runtime and what, would be created
#   bash build-runtime.sh --workspace PATH  # explicitly specify workspace (default: parent of FMT)
#   bash build-runtime.sh --env-file PATH   # explicitly specify .exocortex.env
#   bash build-runtime.sh --quiet           # minimal output (for setup/update.sh)
#
# Exit codes:
#   0 — success (or dry-run/diff without blockers)
#   1 — invalid arguments
#   2 — missing .exocortex.env
#   3 — overlay-registry not found
#   4 — missing source-source files from the registry
#   5 — drift detected (only in --diff mode when discrepancies are found)
#   7 — missing required value runtime-configuration
#
# WP-273 Stage 2 Phase18. ArchGate v2 → F (Generated runtime).

set -eu

# === Cross-platform sed -i ===
if sed --version >/dev/null 2>&1; then
    sed_inplace() { sed -i "$@"; }
else
    sed_inplace() { sed -i '' "$@"; }
fi

# === Cross-platform hash ===
hash_file() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    else
        sha256sum "$1" | cut -d' ' -f1
    fi
}

hash_dir() {
    local dir="$1"
    [ -d "$dir" ] || { echo "EMPTY"; return; }
    if command -v shasum >/dev/null 2>&1; then
        find "$dir" -type f -not -name '.build-hash' | sort | xargs shasum -a 256 2>/dev/null | shasum -a 256 | cut -d' ' -f1
    else
        find "$dir" -type f -not -name '.build-hash' | sort | xargs sha256sum 2>/dev/null | sha256sum | cut -d' ' -f1
    fi
}

# Copy of update.sh:is_protected_user_file() — build-runtime.sh runs as a separate
# subprocess (not sourced), so the two lists must be kept in sync manually (issue #327).
is_protected_user_file() {
    case "$1" in
        params.yaml|memory/MEMORY.md|.claude/settings.local.json|sessions/00-index.md) return 0 ;;
        *) return 1 ;;
    esac
}

# === Detect directories ===
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_DIR="$(dirname "$SCRIPT_DIR")"  # IWE/
DEFAULT_WORKSPACE="$(dirname "$TEMPLATE_DIR")"  # parent of FMT

WORKSPACE_DIR=""
ENV_FILE=""
DRY_RUN=false
DIFF_MODE=false
QUIET=false

# === Parse arguments ===
while [ $# -gt 0 ]; do
    case "$1" in
        --workspace)
            WORKSPACE_DIR="$2"
            shift 2
            ;;
        --env-file)
            ENV_FILE="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --diff)
            DIFF_MODE=true
            shift
            ;;
        --quiet|-q)
            QUIET=true
            shift
            ;;
        --help|-h)
            grep '^#' "$0" | head -28
            exit 0
            ;;
        *)
            echo "ERROR: Unknown argument: $1" >&2
            echo "Usage: bash build-runtime.sh [--dry-run|--diff] [--workspace PATH] [--env-file PATH] [--quiet]" >&2
            exit 1
            ;;
    esac
done

# === Resolve workspace + env-file ===
WORKSPACE_DIR="${WORKSPACE_DIR:-$DEFAULT_WORKSPACE}"
WORKSPACE_DIR="${WORKSPACE_DIR/#\~/$HOME}"

if [ -z "$ENV_FILE" ]; then
    # Searching for .exocortex.env: workspace → template (for migration from the old layout)
    if [ -f "$WORKSPACE_DIR/.exocortex.env" ]; then
        ENV_FILE="$WORKSPACE_DIR/.exocortex.env"
    elif [ -f "$TEMPLATE_DIR/.exocortex.env" ]; then
        ENV_FILE="$TEMPLATE_DIR/.exocortex.env"
        $QUIET || echo "  ⚠ .exocortex.env found in FMT (legacy location). Will be migrated to \$WORKSPACE_DIR/ on the next setup."
    fi
fi

if [ -z "$ENV_FILE" ] || [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: .exocortex.env not found. Searched in:" >&2
    echo "  - $WORKSPACE_DIR/.exocortex.env" >&2
    echo "  - $TEMPLATE_DIR/.exocortex.env" >&2
    echo "Run setup.sh for initial configuration." >&2
    exit 2
fi

OVERLAY_FILE="$TEMPLATE_DIR/.claude/runtime-overlay.yaml"
if [ ! -f "$OVERLAY_FILE" ]; then
    echo "ERROR: Overlay-registry not found: $OVERLAY_FILE" >&2
    exit 3
fi

RUNTIME_DIR="$WORKSPACE_DIR/.iwe-runtime"

if ! $QUIET; then
    echo "=== build-runtime ==="
    echo "  Template: $TEMPLATE_DIR"
    echo "  Workspace: $WORKSPACE_DIR"
    echo "  Env file: $ENV_FILE"
    echo "  Runtime: $RUNTIME_DIR"
    [ "$DRY_RUN" = true ] && echo "  Mode: DRY-RUN (no writes)"
    [ "$DIFF_MODE" = true ] && echo "  Mode: DIFF (compare existing vs new)"
    echo ""
fi

# === Load .exocortex.env ===
# Safe parse: only KEY=VALUE, no eval/source.
# Bash 3.2-compatible: we use the function env_get instead of associative array.
# issue #319: values in .exocortex.env conventionally quoted
# (WORKSPACE_DIR="/home/iwe/IWE") — without strip quotes were included literally in
# every substituted-substitution. Strip only PAIRED outer quotes
# (the same character at the start and at the end), inner ones are left untouched.
env_get() {
    local raw
    raw=$(grep "^$1=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d'=' -f2-)
    # launchd does not pass USER/LOGNAME in job, but build runs in
    # an interactive system, where Unix login reliably available. An explicit value
    # from env-file takes priority for non-standard installations.
    if [ -z "$raw" ] && [ "$1" = "USER_NAME" ]; then
        raw=$(id -un 2>/dev/null || true)
    fi
    case "$raw" in
        \"*\") [ ${#raw} -ge 2 ] && raw="${raw#\"}" && raw="${raw%\"}" ;;
        \'*\') [ ${#raw} -ge 2 ] && raw="${raw#\'}" && raw="${raw%\'}" ;;
    esac
    printf '%s' "$raw"
}

# === Parse overlay-registry ===
# Minimal YAML-parser: reads the lists substituted/copied_to_workspace.
# Expected format: key at the start of the line + colon, then `  - path` for each file.
parse_list() {
    local section="$1"
    awk -v sect="$section" '
        $0 ~ "^"sect":" { in_section=1; next }
        in_section && /^[a-z_]+:/ { in_section=0 }
        in_section && /^[[:space:]]+-[[:space:]]/ {
            sub(/^[[:space:]]+-[[:space:]]+/, "")
            sub(/[[:space:]]*#.*/, "")
            sub(/[[:space:]]+$/, "")
            if (length($0) > 0) print
        }
    ' "$OVERLAY_FILE"
}

# Bash 3.2-compatible array population (mapfile = bash 4+).
SUBSTITUTED_FILES=()
while IFS= read -r line; do SUBSTITUTED_FILES+=("$line"); done < <(parse_list "substituted")
COPIED_FILES=()
while IFS= read -r line; do COPIED_FILES+=("$line"); done < <(parse_list "copied_to_workspace")
PLACEHOLDERS=()
while IFS= read -r line; do PLACEHOLDERS+=("$line"); done < <(parse_list "placeholders")

if [ "${#SUBSTITUTED_FILES[@]}" -eq 0 ] && [ "${#COPIED_FILES[@]}" -eq 0 ]; then
    echo "ERROR: Overlay-registry is empty or corrupt: $OVERLAY_FILE" >&2
    exit 3
fi

# USER/LOGNAME are absent from launchd's minimal environment. They are rendered
# during the build from explicit configuration or the current Unix login.
if [ -z "$(env_get USER_NAME)" ]; then
    echo "ERROR: cannot determine USER_NAME to render launchd jobs." >&2
    echo "Set USER_NAME in .exocortex.env or run the build as a Unix user." >&2
    exit 7
fi

# === Verify source files exist in FMT ===
MISSING=()
for f in "${SUBSTITUTED_FILES[@]}" "${COPIED_FILES[@]}"; do
    # issue #348: a user-owned workspace file ships as <name>.example (see
    # copy_to_workspace_file below) — accept either name here, or this pre-flight
    # rejects the very layout the fix introduces.
    [ -f "$TEMPLATE_DIR/$f" ] || [ -f "$TEMPLATE_DIR/$f.example" ] || MISSING+=("$f")
done

if [ "${#MISSING[@]}" -gt 0 ]; then
    echo "ERROR: Files from overlay-registry are missing from FMT: FMT:" >&2
    printf '  - %s\n' "${MISSING[@]}" >&2
    echo "Possible cause:: outdated runtime-overlay.yaml or incomplete clone." >&2
    exit 4
fi

# === Build runtime in temp directory (atomic swap on success) ===
if BUILD_DIR=$(mktemp -d 2>/dev/null); then
    :
else
    BUILD_DIR="/tmp/iwe-build-$$"
    mkdir -p "$BUILD_DIR"
fi
trap "rm -rf '$BUILD_DIR'" EXIT

# Hash inputs (FMT files + .exocortex.env) for build-stamp
resolve_overlay_source() {
    local rel="$1"
    local src="$TEMPLATE_DIR/$rel"
    [ -f "$src" ] || src="$TEMPLATE_DIR/$rel.example"
    [ -f "$src" ] || { echo "ERROR: overlay source missing for $rel" >&2; return 1; }
    printf '%s\n' "$src"
}

INPUT_HASH=$(
    {
        for f in "${SUBSTITUTED_FILES[@]}" "${COPIED_FILES[@]}"; do
            hash_file "$(resolve_overlay_source "$f")"
            echo "$f"
        done
        hash_file "$ENV_FILE"
        hash_file "$OVERLAY_FILE"
    } | hash_file /dev/stdin 2>/dev/null || \
    {
        for f in "${SUBSTITUTED_FILES[@]}" "${COPIED_FILES[@]}"; do
            hash_file "$(resolve_overlay_source "$f")"
            echo "$f"
        done
        hash_file "$ENV_FILE"
        hash_file "$OVERLAY_FILE"
    } | (command -v shasum >/dev/null && shasum -a 256 || sha256sum) | cut -d' ' -f1
)

FMT_VERSION=$(grep '^## \[' "$TEMPLATE_DIR/CHANGELOG.md" | grep -v '^## \[Unreleased\]' | head -1 | sed 's/.*\[\(.*\)\].*/\1/')

# === Apply substitutions ===
build_substituted_file() {
    local rel="$1"
    local src
    src=$(resolve_overlay_source "$rel") || return 1
    local dst="$BUILD_DIR/runtime/$rel"
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"

    # Build sed script from placeholders + .exocortex.env (env_get).
    local sed_args=()
    local ph val
    for ph in "${PLACEHOLDERS[@]}"; do
        val=$(env_get "$ph")
        sed_args+=(-e "s|{{$ph}}|$val|g")
    done

    if [ ${#sed_args[@]} -gt 0 ]; then
        sed_inplace "${sed_args[@]}" "$dst"
    fi

    # Preserve executable bit (.sh files always get +x — git may track 100644 after updates)
    if [ -x "$src" ] || [[ "$rel" == *.sh ]]; then
        chmod +x "$dst"
    fi

    # Verify no unsubstituted placeholders remain
    if grep -qE '\{\{[A-Z_]+\}\}' "$dst" 2>/dev/null; then
        echo "  ⚠ $rel: unreplaced placeholders remain:" >&2
        grep -oE '\{\{[A-Z_]+\}\}' "$dst" | sort -u | sed 's/^/      /' >&2
    fi
}

copy_to_workspace_file() {
    local rel="$1"
    local src
    src=$(resolve_overlay_source "$rel") || return 1
    local dst="$BUILD_DIR/workspace/$rel"
    # issue #348: a workspace file that belongs to the user (params.yaml) ships as
    # <name>.example and is git-ignored under its working name — otherwise the
    # template repo owns a file it has declared to be the user's, and a fork's pull
    # puts the upstream defaults back over the user's edits. Destination name is
    # unchanged; only the source in the template carries the .example suffix.
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    case "$dst" in *.sh) chmod +x "$dst" ;; esac
}

# Process substituted
for f in "${SUBSTITUTED_FILES[@]}"; do
    build_substituted_file "$f"
done

# Process copied_to_workspace
for f in "${COPIED_FILES[@]}"; do
    copy_to_workspace_file "$f"
done

# === Stamp build hash + version ===
{
    echo "$INPUT_HASH"
    echo ""
    echo "FMT version: $FMT_VERSION"
    echo "Overlay version: $(grep -m1 '^version:' "$OVERLAY_FILE" | sed 's/version:[[:space:]]*//')"
    echo "Built: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$BUILD_DIR/runtime/.build-hash"

# === Diff mode ===
if $DIFF_MODE; then
    if [ ! -d "$RUNTIME_DIR" ]; then
        echo "[diff] $RUNTIME_DIR does not exist — will be created from scratch."
        echo "  Substituted: ${#SUBSTITUTED_FILES[@]} files"
        echo "  Copied to workspace: ${#COPIED_FILES[@]} files"
        exit 0
    fi

    DRIFT_COUNT=0
    for f in "${SUBSTITUTED_FILES[@]}"; do
        existing="$RUNTIME_DIR/$f"
        new="$BUILD_DIR/runtime/$f"
        if [ ! -f "$existing" ]; then
            echo "[diff] NEW: $f"
            DRIFT_COUNT=$((DRIFT_COUNT + 1))
        elif ! cmp -s "$existing" "$new"; then
            echo "[diff] CHANGED: $f"
            diff -u "$existing" "$new" 2>/dev/null | head -20 | sed 's/^/  /'
            DRIFT_COUNT=$((DRIFT_COUNT + 1))
        fi
    done

    if [ "$DRIFT_COUNT" -eq 0 ]; then
        echo "[diff] runtime in sync (0 changes)"
        exit 0
    else
        echo ""
        echo "[diff] $DRIFT_COUNT files would have changed. Run without --diff to apply changes."
        exit 5
    fi
fi

# === Dry-run mode ===
if $DRY_RUN; then
    echo "[dry-run] Will be created in $RUNTIME_DIR/:"
    for f in "${SUBSTITUTED_FILES[@]}"; do
        echo "  ~ $f (substituted)"
    done
    echo ""
    echo "[dry-run] Will be copied to $WORKSPACE_DIR/:"
    for f in "${COPIED_FILES[@]}"; do
        echo "  + $f"
    done
    echo ""
    echo "[dry-run] Build hash (for drift detection): ${INPUT_HASH:0:16}..."
    echo "[dry-run] No changes on disk."
    exit 0
fi

# === Atomic swap: replace runtime + copy workspace files ===
# WP-273 0.29.4 R6.3 fix: flock on $WORKSPACE_DIR/.iwe-runtime.lock — prevents
# race window between two concurrent build-runtime OR build-runtime + scheduler.
# scheduler.sh also acquires shared lock on this file before reading runner-paths.
mkdir -p "$WORKSPACE_DIR"
LOCK_FILE="${WORKSPACE_DIR}/.iwe-runtime.lock"

# Using flock if available (Linux always; macOS — via util-linux brew, optional)
if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK_FILE"
    if ! flock -x -w 30 9; then
        echo "ERROR: build-runtime: failed to acquire exclusive lock on $LOCK_FILE within 30 sec" >&2
        exit 6
    fi
fi

# 1. Replace .iwe-runtime/ atomically (under lock'while holding the — no one is reading at this moment)
RUNTIME_OLD="${RUNTIME_DIR}.old.$$"
if [ -d "$RUNTIME_DIR" ]; then
    mv "$RUNTIME_DIR" "$RUNTIME_OLD"
fi

mv "$BUILD_DIR/runtime" "$RUNTIME_DIR"

# bug-2026-09-02-build-runtime-wipes-live-session-state: .iwe-runtime/ is
# documented above as build-only (.build-hash, .build-version, roles/), but
# session-guard.sh and friends also keep LIVE, non-regenerable state directly
# under it (sessions/, isolate-push-attempts/, close-obligation/ — observed
# live, not an exhaustive list). A plain "swap + rm -rf the old tree" silently
# destroyed other agents' open-session markers on 2026-09-02. Carry forward
# any top-level entry the fresh build did not itself produce, instead of
# assuming the whole old tree is disposable.
#
# bug-2026-09-17-tsekh1-recovery-backups-abort: under `set -eu`, a single
# failed `mv` (e.g. permission denied on a root-owned entry inherited from an
# earlier root-privileged operation) used to abort this whole script — losing
# any not-yet-processed live entries and skipping the `rm -rf` below entirely,
# leaving `$RUNTIME_OLD` orphaned on disk indefinitely (live incident: a
# month-old root:root `recovery-backups/` blocked the carry-forward, and
# `.iwe-runtime.old.<pid>` from that run is still there). Failing one entry
# must not cost the rest.
CARRY_FORWARD_FAILURES=0
if [ -d "$RUNTIME_OLD" ]; then
    while IFS= read -r entry; do
        [ -e "$RUNTIME_DIR/$entry" ] && continue
        if ! mv "$RUNTIME_OLD/$entry" "$RUNTIME_DIR/$entry" 2>/dev/null; then
            echo "  ⚠ failed to move $RUNTIME_OLD/$entry to $RUNTIME_DIR/ (owner/permissions?) — left in place, move manually (for example via sudo)" >&2
            CARRY_FORWARD_FAILURES=$((CARRY_FORWARD_FAILURES + 1))
        fi
    done < <(find "$RUNTIME_OLD" -mindepth 1 -maxdepth 1 -exec basename {} \;)
    if [ "$CARRY_FORWARD_FAILURES" -eq 0 ]; then
        rm -rf "$RUNTIME_OLD"
    else
        echo "  ⚠ $RUNTIME_OLD left on disk — $CARRY_FORWARD_FAILURES record(s/s) were not moved, live data inside may be incomplete" >&2
    fi
fi

# bug-2026-09-17-tsekh1-recovery-backups-abort (continuation): leftovers from
# a PAST crashed run (different pid, e.g. `.iwe-runtime.old.4079200` sitting
# next to `.iwe-runtime.old.$$` right now) are not this run's responsibility
# to delete blindly — a directory named "recovery-backups" is presumably
# there on purpose, and deleting other processes' state without knowing
# whether they're mid-flight is its own risk. Surface them instead of hiding
# the debt again: this is the "no owner ever notices" gap the same incident
# found, closed by visibility rather than by silent auto-delete.
STALE_OLD_DIRS=""
for candidate in "${RUNTIME_DIR}".old.*; do
    [ -d "$candidate" ] || continue
    [ "$candidate" = "$RUNTIME_OLD" ] && continue
    STALE_OLD_DIRS="${STALE_OLD_DIRS}${STALE_OLD_DIRS:+, }$candidate"
done
# Do NOT gate on $QUIET (unlike the regular info-messages in this script):
# update.sh — the sole regular call path for build-runtime.sh — calls
# it explicitly with --quiet (issue found by cold-review of the same session), and this
# the warning exists precisely so as not to be silently lost in this, so that it does not drown silently in this
# very invocation.
if [ -n "$STALE_OLD_DIRS" ]; then
    echo "  ⚠ stale directories from previous interrupted rebuilds were found: $STALE_OLD_DIRS"
    echo "    inspect the contents and remove manually (may be required sudo), if it is no longer needed"
fi

# Lock is released automatically on exit (FD 9 is closed)

# 2. Copy workspace files (NOT atomic — this is not critical, files are independent)
COPIED_COUNT=0
for f in "${COPIED_FILES[@]}"; do
    src="$BUILD_DIR/workspace/$f"
    dst="$WORKSPACE_DIR/$f"
    mkdir -p "$(dirname "$dst")"
    if [ -f "$dst" ] && is_protected_user_file "$f"; then
        : # skip — protected file already exists, seed-on-first-install only (issue #327)
    elif [ -f "$dst" ] && cmp -s "$src" "$dst"; then
        : # skip — identical
    else
        # issue #348: seeding a protected user file used to be silent, so a workspace
        # that had lost its params.yaml (layout migration, interrupted setup) got the
        # template default back with no trace — indistinguishable from "update.sh
        # overwrote my settings". Say it out loud when it happens.
        if is_protected_user_file "$f" && [ ! -f "$dst" ]; then
            $QUIET || echo "  ⚠ $f was absent from $WORKSPACE_DIR — seeded with template values. Your previous settings in it have NOT been restored."
        fi
        cp "$src" "$dst"
        COPIED_COUNT=$((COPIED_COUNT + 1))
    fi
done

if ! $QUIET; then
    echo "✓ runtime: ${#SUBSTITUTED_FILES[@]} files in $RUNTIME_DIR/"
    echo "✓ workspace: $COPIED_COUNT files updated / ${#COPIED_FILES[@]} checked"
    echo "  Build hash: ${INPUT_HASH:0:16}..."
    echo "  FMT version: $FMT_VERSION"
fi

exit 0
