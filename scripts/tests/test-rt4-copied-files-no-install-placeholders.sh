#!/usr/bin/env bash
# 0.42 red team, attack RT-4: after install, {{WORKSPACE_DIR}} and {{GOVERNANCE_REPO}}
# stayed literal in the agent's working files. setup.sh substitutes them only in
# CLAUDE.md/AGENTS.md (and update.sh also in .mcp.json); memory/** (setup step [3/6])
# and .claude/<subdir>/ (step [4b], `cp -r`) are copied as-is, and update.sh re-copies
# skills as-is too. A command such as `bash {{WORKSPACE_DIR}}/scripts/...` in a skill
# then fails. Files copied as-is must use the environment form instead:
# ${IWE_WORKSPACE:-$HOME/IWE} and ${IWE_GOVERNANCE_REPO:-DS-strategy}.
#
# The scope is taken from setup.sh itself (the [4b] subdir list), so a new copied
# subdirectory is covered without editing this test. The one exemption is the
# author-mode skill, which documents the {{KEY}} syntax used when promoting files.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

subdirs=$(sed -n 's/^[[:space:]]*for subdir in \(.*\); do$/\1/p' "$ROOT/setup.sh" | head -1)
[ -n "$subdirs" ] || fail "could not read the [4b] copied subdir list from setup.sh"
case " $subdirs " in *" skills "*) ;; *) fail "unexpected [4b] subdir list: $subdirs" ;; esac

targets=("$ROOT/memory" "$ROOT/extensions/protocol-close.after.session-record.md")
for d in $subdirs; do
  [ -d "$ROOT/.claude/$d" ] && targets+=("$ROOT/.claude/$d")
done

hits=$(grep -rnE '\{\{(WORKSPACE_DIR|GOVERNANCE_REPO)\}\}' "${targets[@]}" 2>/dev/null \
  | grep -v "^$ROOT/.claude/skills/author-mode/SKILL.md:" || true)
if [ -n "$hits" ]; then
  echo "$hits" | sed "s|^$ROOT/||" | head -30 >&2
  fail "files copied as-is at install still carry {{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}} ($(printf '%s\n' "$hits" | wc -l | tr -d ' ') lines)"
fi
echo "PASS: no {{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}} in memory/, .claude/{$subdirs} or the session-record extension"
