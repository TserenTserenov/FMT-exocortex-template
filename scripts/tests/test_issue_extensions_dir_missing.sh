#!/usr/bin/env bash
# WP-7 Ф133 (live user report, Ruslan, 2026-09-09): the canonical Day Open
# pipeline never completed on a fresh install — it always fell back to the
# free-form prompt. Root cause: setup.sh reads $WORKSPACE_DIR/extensions/
# (e.g. extensions/mcp-user.json) but never creates it, while
# day-open-hooks-runner.sh's step 0 treats a missing extensions/ as a hard
# abort by design (scripts/lib/day-open-hooks.sh: "every install ships
# extensions/, so this means a broken install, not 'no hooks'").
#
# This must exercise the REAL bug, not a synthetic stand-in: it runs an
# actual full-mode setup.sh (SETUP_CI=1, same invocation as
# setup/smoke-test-fresh-install.sh's E2E10) into a disposable workspace,
# then calls day-open-hooks-runner.sh directly against that workspace's
# extensions/ — no LLM, no network, no day-of-week branching (unlike
# strategist.sh, rejected as a regression target in peer-session
# 2026-09-09-10-wp7-f133-day-open-ext: too many unrelated side effects).
# setup/test-day-open-delivery-closure.sh's own hooks-runner test (5i)
# manually mkdir's extensions/ before running — it validates the runner's
# contract in isolation but can never catch this install-time gap. This
# test is red before the setup.sh/update.sh fix and green after.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

WORKSPACE="$TMP/workspace"
FAKE_HOME="$TMP/home"
mkdir -p "$WORKSPACE" "$FAKE_HOME"

# setup.sh's own exit code is not asserted here: past the point that creates
# extensions/ (step [4c]/[4d], well before [6/6] governance-repo git init),
# later steps can fail for reasons unrelated to this bug (e.g. a git wrapper
# hook rejecting the disposable repo's own init in some sandboxed dev
# environments) without that being evidence either way about extensions/.
# The assertion below is the actual regression target; setup.sh's output is
# kept only as debug context if that assertion fails.
SETUP_RC=0
SETUP_OUT=$(HOME="$FAKE_HOME" SETUP_CI=1 GITHUB_USER=issue-test WORKSPACE_DIR="$WORKSPACE" \
    GOVERNANCE_REPO="DS-strategy" \
    GIT_AUTHOR_NAME="issue-test" GIT_AUTHOR_EMAIL="issue-test@test.local" \
    GIT_COMMITTER_NAME="issue-test" GIT_COMMITTER_EMAIL="issue-test@test.local" \
    bash "$ROOT/setup.sh" 2>&1) || SETUP_RC=$?

RUNNER="$ROOT/scripts/day-open-hooks-runner.sh"
[ -f "$RUNNER" ] || { echo "FAIL: $RUNNER not found" >&2; exit 1; }

RUNNER_RC=0
RUNNER_OUT=$(IWE_ROOT="$WORKSPACE" HOME="$FAKE_HOME" bash "$RUNNER" before 2>&1) || RUNNER_RC=$?

if [ "$RUNNER_RC" -ne 0 ]; then
    echo "FAIL: day-open-hooks-runner.sh before exited $RUNNER_RC against a workspace" \
        "produced by a real setup.sh run — extensions/ dir contract violated" >&2
    echo "--- runner output ---" >&2
    echo "$RUNNER_OUT" >&2
    echo "--- setup.sh WORKSPACE_DIR (setup.sh exit=$SETUP_RC) ---" >&2
    ls -la "$WORKSPACE" >&2
    echo "--- setup.sh output (debug context, last 20 lines) ---" >&2
    echo "$SETUP_OUT" | tail -20 >&2
    exit 1
fi

echo "PASS: day-open-hooks-runner.sh before succeeds against a real setup.sh workspace"
