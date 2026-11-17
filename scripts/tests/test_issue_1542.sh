#!/usr/bin/env bash
# Regression for issue #1542: the open/close protocols and two refusal hints called scripts by
# the workspace path (${IWE_WORKSPACE:-$HOME/IWE}/scripts/..., bare scripts/..., ~/IWE/scripts/...),
# while a release-channel install keeps scripts only in the template copy and points IWE_SCRIPTS
# there (.claude/lib/iwe-env-bootstrap.sh). The calls now go through ${IWE_SCRIPTS:-...}; three
# close-protocol steps whose scripts the template does not ship are skipped when absent.
set -uo pipefail
ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
PASSES=0
FAILS=0
ok()  { echo "  ✅ PASS: $*"; PASSES=$((PASSES + 1)); }
bad() { echo "  ❌ FAIL: $*" >&2; FAILS=$((FAILS + 1)); }

# A workspace-path script call NOT wrapped in ${IWE_SCRIPTS:-...}: the old prefix followed by
# "/scripts/" directly (the wrapped form has "/scripts}/").
OLD_CALL='\{IWE_WORKSPACE:-\$HOME/IWE\}/scripts/'
for f in memory/protocol-open.md memory/protocol-close.md; do
  hits=$(grep -nE "$OLD_CALL" "$ROOT/$f" || true)
  if [ -z "$hits" ]; then ok "$f: no workspace-path script calls"
  else bad "$f: workspace-path script calls left: $hits"; fi
done
if grep -q 'IWE_SCRIPTS:-${IWE_WORKSPACE:-$HOME/IWE}/scripts}/wp-inbox.sh' "$ROOT/memory/protocol-open.md"; then
  ok "protocol-open: wp-inbox.sh through IWE_SCRIPTS"
else
  bad "protocol-open: wp-inbox.sh is not called through IWE_SCRIPTS"
fi

close=$(cat "$ROOT/memory/protocol-close.md")
case "$close" in *"Скрипта нет по этому пути"*) ok "protocol-close: snapshot step is skipped when the script is absent" ;;
  *) bad "protocol-close: no skip rule for wp-phase-snapshot-write.py" ;; esac
case "$close" in *"**Скриптов нет**"*) ok "protocol-close: step 5c is skipped when the scripts are absent" ;;
  *) bad "protocol-close: no skip rule for step 5c" ;; esac

for f in .claude/hooks/session-open-gate.sh scripts/kimi-standalone-preflight.sh; do
  if grep -nE 'bash (scripts|~/IWE/scripts)/session-guard\.sh' "$ROOT/$f" >/dev/null; then
    bad "$f: refusal hint still points at a workspace-relative session-guard.sh"
  else
    ok "$f: refusal hint has no workspace-relative session-guard.sh"
  fi
done

# The hook hint must print the variable for the reader's shell, not an expanded empty value.
hint=$(AGENT=claude-code bash -c "$(awk '/^cat >&2 <<EOF$/ {f=1} f {print} f && /^EOF$/ {exit}' "$ROOT/.claude/hooks/session-open-gate.sh")" 2>&1)
case "$hint" in *'bash "${IWE_SCRIPTS:-$HOME/IWE/scripts}/session-guard.sh" open --wp WP-N'*) ok "hook hint renders the IWE_SCRIPTS form" ;;
  *) bad "hook hint does not render the IWE_SCRIPTS form: $hint" ;; esac

echo
echo "issue #1542: $PASSES passed, $FAILS failed"
[ "$FAILS" -eq 0 ]
