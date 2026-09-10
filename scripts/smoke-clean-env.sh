#!/bin/bash
set -euo pipefail

# Smoke-test для новых scripts/*.sh в FMT. see WP-347 PD-1.

if [ $# -lt 1 ]; then
    echo "Usage: $0 <path-to-script>"
    exit 1
fi

file="$1"
FAIL=0

# 1. Syntax
if ! bash -n "$file" >/dev/null 2>&1; then
    echo "SYNTAX: FAIL"
    FAIL=1
else
    echo "SYNTAX: PASS"
fi

# 2. Safe-mode (warning only)
if ! grep -q '^set -euo pipefail' "$file" >/dev/null 2>&1; then
    echo "SAFE-MODE: missing"
else
    echo "SAFE-MODE: PASS"
fi

# 3. Shebang
if ! head -1 "$file" | grep -q '^#!/' >/dev/null 2>&1; then
    echo "SHEBANG: missing"
    FAIL=1
else
    echo "SHEBANG: PASS"
fi

# 4. Optional --help in env -i with timeout 5s
TIMEOUT_CMD=""
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_CMD="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_CMD="gtimeout"
fi

if [ -n "$TIMEOUT_CMD" ]; then
    # issue #757: exit 0 alone doesn't prove --help was side-effect-free —
    # dry-run-begin.sh exited 0 under --help while still arming the dry-run
    # gate. Snapshot the known gate-state artifacts before/after and fail
    # the smoke test if --help changed them, instead of trusting the exit
    # code as the only signal.
    #
    # Cold-review finding: diffing the SHARED global path
    # (/tmp/iwe-dry-run-<uid>/) races against any concurrent, unrelated
    # dry-run-begin.sh/dry-run-complete.sh call on the same machine (this
    # repo runs several agents in parallel) — a false positive. Fix: route
    # through dry-run-begin.sh's own test-mode override
    # (IWE_DRY_RUN_DIR + .iwe-dry-run-test-mode marker, already implemented
    # there for exactly this purpose) into a private temp dir, so the diff
    # only ever sees state this smoke-test run itself could have created.
    # Harmless for scripts under test that don't know these two env vars.
    dry_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/smoke-clean-env-dryrun.XXXXXX")
    trap 'rm -rf "$dry_test_dir"' EXIT
    touch "$dry_test_dir/.iwe-dry-run-test-mode"
    dry_sentinel="$dry_test_dir/iwe-dry-run.flag"
    dry_dir="$dry_test_dir"
    gate_before=$(ls "$dry_dir"/gate-*.state 2>/dev/null | sort || true)
    sentinel_before=0
    if [ -e "$dry_sentinel" ]; then sentinel_before=1; fi

    help_exit=0
    env -i HOME="$HOME" PATH="$PATH" \
        IWE_DRY_RUN_DIR="$dry_test_dir" IWE_DRY_RUN_SENTINEL="$dry_sentinel" \
        "$TIMEOUT_CMD" 5 bash "$file" --help >/dev/null 2>&1 || help_exit=$?

    gate_after=$(ls "$dry_dir"/gate-*.state 2>/dev/null | sort || true)
    sentinel_after=0
    if [ -e "$dry_sentinel" ]; then sentinel_after=1; fi
    rm -rf "$dry_test_dir"
    trap - EXIT

    if [ "$gate_before" != "$gate_after" ] || [ "$sentinel_before" != "$sentinel_after" ]; then
        echo "HELP: side effects detected (dry-run gate state changed)"
        FAIL=1
    elif [ "$help_exit" -eq 124 ] || [ "$help_exit" -eq 137 ]; then
        echo "HELP: timed out"
    elif [ "$help_exit" -ne 0 ] && [ "$help_exit" -ne 1 ] && [ "$help_exit" -ne 2 ]; then
        echo "HELP: unexpected exit $help_exit"
    else
        echo "HELP: PASS"
    fi
else
    echo "HELP: timeout utility not available, skipped"
fi

if [ "$FAIL" -eq 0 ]; then
    echo "smoke-clean-env: PASS $file"
    exit 0
else
    exit 1
fi
