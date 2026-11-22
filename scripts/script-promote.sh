#!/usr/bin/env bash
# routing: utility  deterministic=true
# see DP.SC.159, DP.ROLE.059
# script-promote.sh — promotion of a personal script (or all shared scripts) into the platform template IWE
#
# Flow: personal folder/<script> → substitutions → FMT/scripts/<script>
# Personal constants are replaced with environment parameters (env vars).
#
# Usage:
#   bash script-promote.sh <path-to-script> [--dry-run] [--force]
#   bash script-promote.sh --all [--dry-run] [--force]
#
# Examples:
#   bash script-promote.sh ~/IWE/DS-strategy/scripts/my-tool.sh --dry-run
#   bash script-promote.sh ~/IWE/DS-strategy/scripts/my-tool.sh
#   bash script-promote.sh ~/IWE/DS-strategy/scripts/my-tool.sh --force
#   bash script-promote.sh --all
#
# --force: skip guard comparison with FMT HEAD (if FMT differs intentionally)
# --all: iterate over all scripts/*.sh|*.py, common to the personal copy and FMT — without --force
#        each diverged file IS SKIPPED (does not block the others), see. WP-485:
#        manual copying that bypassed this guard had already erased fixes made directly in FMT guard had already erased fixes, made directly in FMT
#        (issue #220/#259, commit 238a5c1) — --all exists, so that bulk
#        synchronization would from then on go through the same guard, as promotion of a single file.

set -uo pipefail

IWE="${IWE_WORKSPACE:-$HOME/IWE}"
FMT_DIR="${IWE_TEMPLATE:-$IWE/IWE}"
GOV_REPO_AUTHOR="${IWE_GOVERNANCE_REPO:-DS-strategy}"
GOV_REPO_TMPL="DS-strategy"
VALIDATOR="$FMT_DIR/scripts/validate-fmt-scripts.sh"

SRC=""
dry_run=false
force=false
batch_all=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) dry_run=true ;;
        --force)   force=true ;;
        --all)     batch_all=true ;;
        --*)       echo "Unknown flag: $arg" >&2; exit 1 ;;
        *)         if [[ -z "$SRC" ]]; then SRC="$arg"; else echo "Too many arguments" >&2; exit 1; fi ;;
    esac
done

if ! $batch_all && [[ -z "$SRC" || ! -f "$SRC" ]]; then
    echo "Usage: $0 <path-to-script> [--dry-run] [--force]" >&2
    echo "        or:   $0 --all [--dry-run] [--force]" >&2
    echo "Example: $0 ~/IWE/\$GOV_REPO/scripts/my-tool.sh" >&2
    exit 1
fi

# promote_one SRC — promotes a single file. Return: 0 promoted/equivalent,
# 2 skipped guard'by the (FMT has moved ahead), 1 other error (validation/smoke-test).
promote_one() {
    local src="$1" fname dest result head_version tmp_dir tmp_file smoke_result
    fname=$(basename "$src")
    dest="$FMT_DIR/scripts/$fname"

    echo "🔄 Promoting: $fname"
    echo "   From: $src"
    echo "   To:   $dest"
    echo ""

    # Substitutions: personal constants → environment parameters
    # Order matters: longer path first ($HOME/IWE), then the shorter one ($HOME)
    result=$(sed \
        -e "s|$HOME/IWE|\${IWE:-\$HOME/IWE}|g" \
        -e "s|$HOME|\$HOME|g" \
        -e "s|$GOV_REPO_AUTHOR|\${IWE_GOVERNANCE_REPO:-$GOV_REPO_TMPL}|g" \
        "$src")

    # Guard: FMT HEAD contains a newer version? Also checked in --dry-run —
    # otherwise `--all --dry-run` reports «everything will be promoted», although some files
    # have diverged and a real run will skip them (WP-485).
    # We compare $result (after substitutions) against HEAD:scripts/$fname — not against working tree.
    # Goal: catch the case where runtime-copy stale and overwrites fixes, already merged into FMT.
    # New file (not in HEAD) → guard is silent. FMT not a git-repo → guard is silent.
    if ! $force && git -C "$FMT_DIR" rev-parse HEAD >/dev/null 2>&1; then
        head_version=$(git -C "$FMT_DIR" show "HEAD:scripts/$fname" 2>/dev/null || true)
        if [[ -n "$head_version" ]]; then
            if ! diff -q <(printf '%s\n' "$result") <(printf '%s\n' "$head_version") >/dev/null 2>&1; then
                echo "⚠️  SKIPPED: FMT HEAD contains a different version of $fname" >&2
                echo "   Probably, FMT already contains fixes FMT already contains fixes, that are not present in your copy." >&2
                echo "   Promotion will overwrite these changes." >&2
                echo "" >&2
                echo "   Current version in FMT HEAD:" >&2
                echo "     git -C \"$FMT_DIR\" show HEAD:scripts/$fname" >&2
                echo "   What will be promoted (after substitutions):" >&2
                echo "     bash \"$0\" \"$src\" --dry-run" >&2
                echo "" >&2
                echo "   Continue (if the difference is intentional):" >&2
                echo "     $0 \"$src\" --force" >&2
                return 2
            fi
        fi
    fi

    if $dry_run; then
        echo "--- dry-run: result after substitutions (guard passed) ---"
        printf '%s\n' "$result"
        echo "--- end ---"
        return 0
    fi

    # Validation of the result via a temporary file
    tmp_dir=$(mktemp -d)
    tmp_file="$tmp_dir/$fname"
    printf '%s\n' "$result" > "$tmp_file"
    chmod +x "$tmp_file"

    if [[ -f "$VALIDATOR" ]]; then
        if ! bash "$VALIDATOR" "$tmp_dir" 2>&1; then
            rm -rf "$tmp_dir"
            echo "" >&2
            echo "❌ Personal hardcoded values remain after substitutions." >&2
            echo "   Use --dry-run to preview and fix manually." >&2
            return 1
        fi
    fi

    # Smoke-test: run in an isolated env with template variables
    # Goal: verify that the script does not exit with exit 1 in a foreign environment
    # We use --help or an empty invocation — we expect exit 0 or exit 1 only from validation
    # 5s alarm (perl, portable — the same technique, as in kimi-peer-adapter.sh): daemon-scripts
    # (while true; do ...; done without handling --help) otherwise they hang here indefinitely —
    # found on kimi-session-watchdog.sh, script-promote.sh hung on smoke-test.
    echo "   smoke-test with template environment..."
    smoke_result=0
    # PATH inherited from the caller's own environment, not a hardcoded macOS list
    # (WP-484, 2026-07-28): the previous "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
    # has no `date`, `git`, or `which` on NixOS (a pilot's remote server) — any promotion run from
    # that host hit exit 127 here regardless of the script being promoted, live-
    # reproduced blocking a WP-484 fix. env -i still clears everything else, so
    # the smoke test's own environment isolation is unchanged, only PATH now comes
    # from wherever script-promote.sh itself is actually running.
    env -i \
        HOME="/tmp/iwe-smoke-user" \
        IWE="/tmp/iwe-smoke-user/IWE" \
        IWE_GOVERNANCE_REPO="DS-strategy" \
        PATH="$PATH" \
        perl -e 'alarm 5; exec @ARGV' -- bash "$tmp_file" --help > /dev/null 2>&1 || smoke_result=$?

    # exit 0 = OK, exit 1 = validation error (acceptable — script run without arguments)
    # exit 127 = command not found (dependency is broken) — blocker
    # exit 142 = SIGALRM (perl alarm) — script did not finish within 5s, looks like a daemon
    # with a loop while true; this is not a dependency bug, just skip and continue.
    if [[ $smoke_result -eq 127 ]]; then
        rm -rf "$tmp_dir"
        echo "❌ Smoke-test: exit 127 — the script cannot start in a foreign environment." >&2
        echo "   Check dependencies (python3, jq, etc..) and absolute paths." >&2
        return 1
    fi
    if [[ $smoke_result -eq 142 ]]; then
        echo "   smoke-test: timeout 5s (looks like a daemon with an infinite loop, not a blocker)"
    else
        echo "   smoke-test: OK (exit $smoke_result)"
    fi

    # Copy to FMT
    cp "$tmp_file" "$dest"
    chmod +x "$dest"
    rm -rf "$tmp_dir"

    echo ""
    echo "✅ Promoted: FMT/scripts/$fname"
    return 0
}

finalize() {
    local changelog_script="$FMT_DIR/scripts/changelog-append.sh"
    [[ -f "$changelog_script" ]] && IWE_TEMPLATE="$FMT_DIR" bash "$changelog_script"

    local manifest_script="$FMT_DIR/generate-manifest.sh"
    if [[ -f "$manifest_script" ]]; then
        echo "🔄 Rebuilding update-manifest.json..."
        bash "$manifest_script" 2>&1
    else
        echo "⚠️  generate-manifest.sh not found — update update-manifest.json manually"
    fi
}

if $batch_all; then
    total=0 synced=0 skipped=0 failed=0
    for f in "$IWE"/scripts/*.sh "$IWE"/scripts/*.py; do
        [[ -f "$f" ]] || continue
        fname=$(basename "$f")
        [[ -f "$FMT_DIR/scripts/$fname" ]] || continue  # shared files only — new files are not added here automatically
        total=$((total + 1))
        promote_one "$f"; rc=$?
        case "$rc" in
            0) synced=$((synced + 1)) ;;
            2) skipped=$((skipped + 1)) ;;
            *) failed=$((failed + 1)) ;;
        esac
        echo ""
    done

    echo "Summary --all: $total shared files · $synced promoted · $skipped skipped (diverged — manual review required + --force) · $failed errors"

    if $dry_run; then
        exit 0
    fi
    if [[ $synced -gt 0 ]]; then
        finalize
        echo "Next step:"
        echo "  cd $FMT_DIR && git status && git add scripts/ CHANGELOG.md update-manifest.json && git commit -m 'feat: promote scripts to platform (--all)'"
    fi
    [[ $skipped -eq 0 && $failed -eq 0 ]]
    exit $?
fi

promote_one "$SRC"
rc=$?
if [[ $rc -eq 0 ]] && ! $dry_run; then
    finalize
    echo "Next step:"
    echo "  cd $FMT_DIR && git add scripts/$(basename "$SRC") CHANGELOG.md update-manifest.json && git commit -m 'feat: promote $(basename "$SRC") to platform'"
fi
exit $rc
