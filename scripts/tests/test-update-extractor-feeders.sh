#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals below are read by the function evaluated from update.sh.
# WP-5 F55: update.sh must schedule the Knowledge Extractor on already-configured
# machines, not only on a fresh setup.sh install (High finding of F54).
# Hyphenated filename on purpose: the secret guard reads test_<long-token> as a
# payment key and redacts it out of every log and CI file that names it.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# The defect was structural: the step existed in setup.sh and nowhere in the
# update path. Guard the wiring itself, not just the function body.
if ! awk '/^run_post_apply_backfills_or_die\(\)/,/^}/' "$ROOT/update.sh" \
    | grep -q 'backfill_extractor_feeders'; then
    echo 'post-apply backfill chain does not call backfill_extractor_feeders' >&2
    exit 1
fi

eval "$(awk '
  /^backfill_extractor_feeders\(\)/ { capture=1 }
  capture { print }
  capture && /^}/ { exit }
' "$ROOT/update.sh")"
declare -F backfill_extractor_feeders >/dev/null

SCRIPT_DIR="$TMP/template"
WORKSPACE_DIR="$TMP/workspace"
EFFECTIVE_GOVERNANCE_REPO="DS-my-strategy"
mkdir -p "$SCRIPT_DIR/scripts" "$WORKSPACE_DIR" "$TMP/bin"

FEEDERS="$SCRIPT_DIR/scripts/setup-extractor-feeders.sh"
write_feeders() {  # $1 = exit code the stub reports
    cat > "$FEEDERS" <<STUB
#!/usr/bin/env bash
printf '%s|%s|%s|%s\n' "\$1" "\$IWE_WORKSPACE" "\$IWE_GOVERNANCE_REPO" "\$IWE_RUNTIME" > "$TMP/feeders-call"
echo "  launchd plist установлен"
exit $1
STUB
    chmod +x "$FEEDERS"
}
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/claude"
chmod +x "$TMP/bin/claude"
PATH="$TMP/bin:$PATH"

# 1. Happy path: feeders installed with the workspace's own governance/runtime.
write_feeders 0
OUT=$(backfill_extractor_feeders)
EXPECTED="install|$WORKSPACE_DIR|DS-my-strategy|$WORKSPACE_DIR/.iwe-runtime"
if [ "$(cat "$TMP/feeders-call")" != "$EXPECTED" ]; then
    echo "feeders invoked with wrong mode or environment: $(cat "$TMP/feeders-call")" >&2
    exit 1
fi
if ! grep -Fq 'launchd plist установлен' <(printf '%s' "$OUT"); then
    echo 'feeders output was swallowed instead of shown to the pilot' >&2
    exit 1
fi

# 2. Opt-out: a pilot who removed the feeders keeps them removed across updates.
rm "$TMP/feeders-call"
OUT=$(IWE_SKIP_EXTRACTOR_FEEDERS=1 backfill_extractor_feeders)
if [ -e "$TMP/feeders-call" ]; then
    echo 'IWE_SKIP_EXTRACTOR_FEEDERS=1 still ran the feeders script' >&2
    exit 1
fi
if ! grep -Fq 'IWE_SKIP_EXTRACTOR_FEEDERS=1' <(printf '%s' "$OUT"); then
    echo 'opt-out was silent' >&2
    exit 1
fi

# 3. No claude CLI: not an update failure, but the pilot is told what to run.
OUT=$(PATH="/usr/bin:/bin" backfill_extractor_feeders)
if [ -e "$TMP/feeders-call" ]; then
    echo 'feeders ran without the claude CLI (it would exit 1 there)' >&2
    exit 1
fi
if ! grep -Fq "bash $FEEDERS" <(printf '%s' "$OUT"); then
    echo 'missing CLI case did not print the manual command' >&2
    exit 1
fi

# 4. Older template without the feeders script: skipped, not fatal.
mv "$FEEDERS" "$TMP/feeders-hidden"
OUT=$(backfill_extractor_feeders)
if ! grep -Fq 'backfill пропущен' <(printf '%s' "$OUT"); then
    echo 'missing feeders script was not reported as a skip' >&2
    exit 1
fi
mv "$TMP/feeders-hidden" "$FEEDERS"

# 5. Feeders failure surfaces, with the manual retry, and reports non-zero.
write_feeders 1
set +e
OUT=$(backfill_extractor_feeders 2>&1)
STATUS=$?
set -e
if [ "$STATUS" -eq 0 ]; then
    echo 'feeders failure was reported as success' >&2
    exit 1
fi
if ! grep -Fq 'повторите вручную' <(printf '%s' "$OUT"); then
    echo 'feeders failure did not print the manual retry' >&2
    exit 1
fi

echo 'PASS: update.sh backfills the Extractor feeders (install, opt-out, no-CLI, missing script, failure)'
