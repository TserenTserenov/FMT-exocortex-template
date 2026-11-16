#!/usr/bin/env bash
# Every skill that runs a template script must find it without the caller's
# shell having sourced .iwe-paths. Skills run in shells that never read
# .bashrc/.zshenv (BASH_ENV is not set by every harness — issue #688 found the
# same class for Claude Code, the DeepSeek contour hit it on 11.11.2026: the
# agent's session had an empty $IWE_SCRIPTS and /wp-new could not reach
# create-wp.sh at all).
#
# Two sanctioned forms, both already used across the catalog:
#   1. the fallback:  "${IWE_SCRIPTS:-$HOME/IWE/scripts}/script.sh"
#   2. the bootstrap: the skill sources .iwe-paths first and then uses
#      $IWE_SCRIPTS (day-close, audit-installation do this).
# A bare $IWE_SCRIPTS/ in a skill with neither is the defect this test pins.
#
# Second half: a skill may only name a script that the template actually ships,
# so the promise of the fallback path stays true after the catalog changes.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKILLS="$ROOT/.claude/skills"
# Author-only script: lives in the author's workspace, deliberately not shipped
# (its absence from the template is recorded drift, not a catalog error here).
AUTHOR_ONLY="template-sync.sh"

PASS=0
FAIL=0
ok()  { echo "  ✅ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

[ -d "$SKILLS" ] || { echo "  ❌ нет каталога навыков $SKILLS"; exit 1; }

# --- 1. No bare $IWE_SCRIPTS/ without the .iwe-paths bootstrap -------------
scanned=0
violations=0
for f in "$SKILLS"/*/SKILL.md; do
    [ -f "$f" ] || continue
    scanned=$((scanned + 1))
    name=$(basename "$(dirname "$f")")
    grep -q 'iwe-paths' "$f" && continue
    if grep -q '\$IWE_SCRIPTS/' "$f"; then
        bad "$name: голый \$IWE_SCRIPTS/ без запасного пути и без подгрузки .iwe-paths"
        violations=$((violations + 1))
    fi
done
[ "$scanned" -gt 0 ] || { echo "  ❌ навыки не найдены в $SKILLS"; exit 1; }
[ "$violations" -eq 0 ] && ok "ни один навык не зовёт \$IWE_SCRIPTS/ без запасного пути ($scanned навыков)"

# --- 2. Every named script exists in the template ---------------------------
names=$(grep -h -o -E '\$\{IWE_SCRIPTS:-\$HOME/IWE/scripts\}/[A-Za-z0-9_.-]+/?|\$IWE_SCRIPTS/[A-Za-z0-9_.-]+/?' "$SKILLS"/*/SKILL.md \
    | sed -E 's#^\$\{IWE_SCRIPTS:-\$HOME/IWE/scripts\}/##; s#^\$IWE_SCRIPTS/##' \
    | grep -v '/$' | sort -u)
[ -n "$names" ] || { echo "  ❌ в навыках не нашлось ни одного вызова скрипта"; exit 1; }

checked=0
missing=0
for n in $names; do
    checked=$((checked + 1))
    [ -f "$ROOT/scripts/$n" ] && continue
    if [ "$n" = "$AUTHOR_ONLY" ]; then
        echo "  ℹ $n — авторский скрипт, в шаблоне не поставляется (осознанно пропущен)"
        continue
    fi
    bad "навык зовёт скрипт, которого нет в шаблоне: scripts/$n"
    missing=$((missing + 1))
done
[ "$missing" -eq 0 ] && ok "все упомянутые навыками скрипты есть в scripts/ ($checked имён)"

# --- 3. The regression that started this: wp-new must reach create-wp.sh ----
if grep -q '\${IWE_SCRIPTS:-\$HOME/IWE/scripts}/create-wp.sh' "$SKILLS/wp-new/SKILL.md"; then
    ok "wp-new зовёт create-wp.sh по запасному пути"
else
    bad "wp-new снова зовёт create-wp.sh без запасного пути"
fi

echo
if [ "$FAIL" -eq 0 ]; then
    echo "test_skills_script_paths: ALL PASS ($PASS)"
    exit 0
fi
echo "test_skills_script_paths: FAILED ($FAIL из $((PASS + FAIL)))"
exit 1
