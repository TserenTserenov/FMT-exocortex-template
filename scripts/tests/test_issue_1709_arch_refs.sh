#!/usr/bin/env bash
# Regression for issue #1709: /archgate, /verify, the agent-inbox spec and the learning path referred to
# DP.ARCH.001 by its old section numbers (principles in §7, coverage in §7.1, domain checklists in
# §4.8-4.15, the Security characteristic in §4.7). In DP.ARCH.001 v2.0 §7 is "MCP"; the principles are in
# §15, the coverage table in §15.1, the domain characteristics in §12.8-12.15, Security in §12.7.
#
# A: the files changed by #1709 name the current sections together with their titles and no longer name the
#    old numbers. B: when DP.ARCH.001 is on this machine, every section number the references use exists in it
#    under the title the reference gives - a next renumbering makes this test fail instead of going unnoticed.
#
# Left out on purpose (separate owners): CLAUDE.md section 5 (author-sourced) and the AR.003 message in
# .claude/hooks/rule-engine.sh still say "DP.ARCH.001 §7".
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
PASSES=0
FAILS=0
ok()  { echo "  ✅ PASS: $*"; PASSES=$((PASSES + 1)); }
bad() { echo "  ❌ FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
has()   { grep -qF -- "$2" "$ROOT/$1" && ok "$1 names: $2" || bad "$1 does not name: $2"; }
lacks() { grep -qF -- "$2" "$ROOT/$1" && bad "$1 still has: $2" || ok "$1 has no: $2"; }

echo "--- #1709 A: references in the changed files ---"
has   .claude/skills/archgate/SKILL.md 'DP.ARCH.001 §15 «Архитектурные принципы (2-й уровень)»'
has   .claude/skills/archgate/SKILL.md 'DP.ARCH.001 §12.8–12.15'
has   .claude/skills/archgate/SKILL.md 'Экономичность — §12.15'
has   .claude/skills/archgate/SKILL.md 'DP.ARCH.001 §15.1 «Покрытие характеристик принципами»'
lacks .claude/skills/archgate/SKILL.md 'DP.ARCH.001 §7'
lacks .claude/skills/archgate/SKILL.md 'DP.ARCH.001 §4.'
has   .claude/skills/verify/SKILL.md 'DP.ARCH.001 §15 «Архитектурные принципы (2-й уровень)»'
lacks .claude/skills/verify/SKILL.md 'DP.ARCH.001 §7'
lacks .claude/skills/verify/SKILL.md '(21 принцип)'
has   extensions/agent-inbox/SPEC.md 'DP.ARCH.001 §15 «Архитектурные принципы (2-й уровень)»'
lacks extensions/agent-inbox/SPEC.md 'DP.ARCH.001 §7'
has   docs/LEARNING-PATH.md 'DP.ARCH.001 § 12.7]'
lacks docs/LEARNING-PATH.md 'DP.ARCH.001 § 4.7'

echo "--- #1709 B: the numbers exist in DP.ARCH.001 under these titles ---"
DOC="${DP_ARCH_001_FILE:-}"
if [ -z "$DOC" ]; then
  for base in "${IWE_WORKSPACE:-$HOME/IWE}" "$HOME/IWE"; do
    cand="$base/PACK-digital-platform/pack/digital-platform/02-domain-entities/DP.ARCH.001-platform-architecture.md"
    [ -f "$cand" ] && { DOC="$cand"; break; }
  done
fi
if [ -z "$DOC" ] || [ ! -f "$DOC" ]; then
  echo "  SKIP: DP.ARCH.001 is not on this machine (set DP_ARCH_001_FILE to check the section numbers)"
else
  heading() { grep -qE -- "$1" "$DOC" && ok "DP.ARCH.001 has: $2" || bad "DP.ARCH.001 has no heading: $2"; }
  heading '^## 15\. Архитектурные принципы \(2-й уровень\)' '§15 Архитектурные принципы (2-й уровень)'
  heading '^### 15\.1\. Покрытие характеристик принципами' '§15.1 Покрытие характеристик принципами'
  heading '^## 12\. Архитектурные характеристики' '§12 Архитектурные характеристики'
  heading '^### 12\.7\. Безопасность' '§12.7 Безопасность'
  heading '^### 12\.8\. ' '§12.8'
  heading '^### 12\.15\. Экономичность' '§12.15 Экономичность'
fi

echo
echo "issue #1709: $PASSES passed, $FAILS failed"
[ "$FAILS" -eq 0 ]
