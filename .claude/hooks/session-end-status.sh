#!/usr/bin/env bash
# SessionEnd — fail-safe agent-status write (issue #266, РП-395 Ф3 promise).
# agent-status-report.sh never fails the caller (always exit 0 itself); this
# hook mirrors that and never blocks session end.
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$(cd "${HOOK_DIR}/.." && pwd)"
# shellcheck source=../lib/iwe-env-bootstrap.sh
source "$CLAUDE_DIR/lib/iwe-env-bootstrap.sh" 2>/dev/null || { echo '{}'; exit 0; }

STATUS_SCRIPT="$IWE_SCRIPTS/agent-status-report.sh"
[ -x "$STATUS_SCRIPT" ] && bash "$STATUS_SCRIPT" claude-code idle 2>/dev/null

echo '{}'
exit 0
