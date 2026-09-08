#!/usr/bin/env bash
# WP-5 Ф43: launchd provides a minimal environment, so USER and LOGNAME must
# be rendered from explicit runtime configuration in every shipped job.
# Issue #527 additionally pins Synchronizer lifecycle and Strategist outcomes.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

WORKSPACE="$TMP/workspace"
ENV_FILE="$WORKSPACE/.exocortex.env"
mkdir -p "$WORKSPACE"
cat > "$ENV_FILE" <<EOF
GITHUB_USER="runtime-test"
WORKSPACE_DIR="$WORKSPACE"
CLAUDE_PATH="/usr/bin/claude"
CLAUDE_PROJECT_SLUG="runtime-test"
TIMEZONE_HOUR="4"
TIMEZONE_DESC="4:00 UTC"
HOME_DIR="$TMP/home"
USER_NAME="runtime-test-user"
GOVERNANCE_REPO="DS-strategy"
IWE_TEMPLATE="$ROOT"
IWE_RUNTIME="$WORKSPACE/.iwe-runtime"
EOF

bash "$ROOT/setup/build-runtime.sh" --quiet --workspace "$WORKSPACE" --env-file "$ENV_FILE"

assert_plist_identity() {
    local plist="$1"
    local key="$2"
    local value="$3"
    awk -v key="$key" -v value="$value" '
        $0 == "        <key>" key "</key>" {
            getline
            matched = $0 == "        <string>" value "</string>"
            exit
        }
        END { exit matched ? 0 : 1 }
    ' "$plist" || {
        echo "FAIL: $plist does not render $key=runtime-test-user" >&2
        exit 1
    }
}

PLISTS=(
    roles/strategist/scripts/launchd/com.strategist.morning.plist
    roles/strategist/scripts/launchd/com.strategist.weekreview.plist
    roles/synchronizer/scripts/launchd/com.exocortex.scheduler.plist
    roles/extractor/scripts/launchd/com.extractor.inbox-check.plist
)
for rel in "${PLISTS[@]}"; do
    plist="$WORKSPACE/.iwe-runtime/$rel"
    [ -f "$plist" ] || { echo "FAIL: missing rendered plist $rel" >&2; exit 1; }
    assert_plist_identity "$plist" USER runtime-test-user
    assert_plist_identity "$plist" LOGNAME runtime-test-user
    if [ "$rel" = "roles/extractor/scripts/launchd/com.extractor.inbox-check.plist" ]; then
        assert_plist_identity "$plist" IWE_GOVERNANCE_REPO DS-strategy
    fi
    if command -v plutil >/dev/null 2>&1 && ! plutil -lint "$plist" >/dev/null; then
        echo "FAIL: rendered plist is invalid: $rel" >&2
        exit 1
    fi
    if grep -q '{{USER_NAME}}' "$plist"; then
        echo "FAIL: $rel retains USER_NAME placeholder" >&2
        exit 1
    fi
done

MISSING_ENV="$TMP/missing-user.env"
grep -v '^USER_NAME=' "$ENV_FILE" > "$MISSING_ENV"
FALLBACK_USER=$(id -un)
bash "$ROOT/setup/build-runtime.sh" --quiet --workspace "$TMP/missing" --env-file "$MISSING_ENV"
for rel in "${PLISTS[@]}"; do
    plist="$TMP/missing/.iwe-runtime/$rel"
    assert_plist_identity "$plist" USER "$FALLBACK_USER"
    assert_plist_identity "$plist" LOGNAME "$FALLBACK_USER"
done

SCHEDULER="$ROOT/roles/synchronizer/scripts/scheduler.sh"
SCHEDULER_INSTALL="$ROOT/roles/synchronizer/install.sh"
OUTCOME_HELPER="$TMP/run-strategist-scenario.sh"
awk '
    /^run_strategist_scenario\(\) \{/{found=1}
    found{print}
    found && /^}/{exit}
' "$SCHEDULER" > "$OUTCOME_HELPER"
[ -s "$OUTCOME_HELPER" ] || {
    echo "FAIL: could not extract run_strategist_scenario from scheduler.sh" >&2
    exit 1
}

assert_scheduler_outcome() {
    local stub_rc="$1"
    local expected_log="$2"
    local unexpected_log="$3"
    local marker="$TMP/outcome-$stub_rc.marker"
    local output

    output=$(STUB_RC="$stub_rc" MARKER="$marker" bash -c '
        set -uo pipefail
        TASK_TIMEOUT_LONG=10
        STRATEGIST_SH=/fixture/strategist.sh
        LOG_FILE="$MARKER.log"
        timeout() { return "$STUB_RC"; }
        log() { printf "%s\n" "$1"; }
        source "$1"
        rc=0
        run_strategist_scenario morning || rc=$?
        [ "$rc" -eq 0 ] && : > "$MARKER"
        printf "RESULT_RC=%s\n" "$rc"
    ' _ "$OUTCOME_HELPER")

    printf '%s' "$output" | grep -Fq "RESULT_RC=$stub_rc" || {
        echo "FAIL: strategist outcome $stub_rc was not preserved: $output" >&2
        exit 1
    }
    if [ "$stub_rc" -eq 0 ]; then
        [ -f "$marker" ] || {
            echo "FAIL: successful strategist run did not create its completion marker" >&2
            exit 1
        }
    elif [ -e "$marker" ]; then
        echo "FAIL: strategist outcome $stub_rc incorrectly created a completion marker" >&2
        exit 1
    fi
    if [ -n "$expected_log" ]; then
        printf '%s' "$output" | grep -Fq "$expected_log" || {
            echo "FAIL: strategist outcome $stub_rc missed '$expected_log': $output" >&2
            exit 1
        }
    fi
    if [ -n "$unexpected_log" ] && printf '%s' "$output" | grep -Fq "$unexpected_log"; then
        echo "FAIL: strategist outcome $stub_rc emitted '$unexpected_log': $output" >&2
        exit 1
    fi
}

assert_scheduler_outcome 0 "" "WARN:"
assert_scheduler_outcome 2 "SKIP:" "WARN:"
assert_scheduler_outcome 1 "WARN:" "SKIP:"
assert_scheduler_outcome 124 "WARN:" "SKIP:"

python3 - "$SCHEDULER" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")
assert text.count('if run_strategist_scenario "') == 4
assert text.count('timeout "$TASK_TIMEOUT_LONG" "$STRATEGIST_SH"') == 1
PY

HEADER=$(head -15 "$SCHEDULER")
if printf '%s' "$HEADER" | grep -Eq 'LEGACY|отключён|автоматически не запускается'; then
    echo "FAIL: scheduler header still declares the installed dispatcher disabled" >&2
    exit 1
fi
printf '%s' "$HEADER" | grep -Fq 'roles/synchronizer/install.sh' || {
    echo "FAIL: scheduler header no longer states its installer lifecycle" >&2
    exit 1
}
grep -Fq 'systemctl --user enable --now iwe-exocortex-scheduler.timer' "$SCHEDULER_INSTALL" || {
    echo "FAIL: Linux installer no longer activates the central scheduler" >&2
    exit 1
}
grep -Fq 'iwe_install_cron_fallback "synchronizer"' "$SCHEDULER_INSTALL" || {
    echo "FAIL: Linux installer no longer provides the central scheduler cron fallback" >&2
    exit 1
}
LAUNCHCTL_TOOL='launchctl'
grep -Fq "$LAUNCHCTL_TOOL load \"\$PLIST_DST\"" "$SCHEDULER_INSTALL" || {
    echo "FAIL: macOS installer no longer activates the central scheduler" >&2
    exit 1
}

for scaffold in scripts/day-open-scaffold.sh seed/strategy/scripts/day-open-scaffold.sh; do
    grep -Fq 'scheduler.sh dispatch' "$ROOT/$scaffold" || {
        echo "FAIL: $scaffold no longer gives the valid manual dispatch command" >&2
        exit 1
    }
    if grep -F 'scheduler.sh --dry-run' "$ROOT/$scaffold" | grep -Fq 'legacy-скрипт'; then
        echo "FAIL: $scaffold still labels the installed dispatcher legacy" >&2
        exit 1
    fi
done

echo "PASS: launchd identity, scheduler outcomes and active lifecycle contracts hold"
