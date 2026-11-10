#!/usr/bin/env bash
# Issue #1513 (class of closed #262): a skill calls <governance>/scripts/<name>,
# but the installation ships <name> only in the template's scripts/ — the user's
# governance repo never gets it, the call fails with "No such file or directory".
#
# Part 1 (guard over every skill): a path under the governance repo's scripts/
# must name a file the seed actually installs there (seed/strategy/scripts/), or
# one that is not a template-shipped script at all (generated data such as
# executor-catalog.yaml). A template-only script referenced that way is a defect.
# Part 2 (behaviour): apply-captures step 1 and step 6 blocks, executed as
# written, find ke-*.sh through IWE_SCRIPTS and, without it, through IWE_TEMPLATE.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# --- Part 1: guard ---------------------------------------------------------
cat > "$TMP/guard.py" <<'PY'
import json, pathlib, re, sys

root = pathlib.Path(sys.argv[1])
manifest = json.loads((root / "update-manifest.json").read_text(encoding="utf-8"))
shipped = {f["path"] for f in manifest.get("files", []) if isinstance(f, dict) and "path" in f}
seeded = {p.name for p in (root / "seed/strategy/scripts").iterdir()}

# Spellings skills use for the governance repo root.
gov = r'(?:\$\{?(?:GOV_DIR|GOV_WT|GOV_REPO_ROOT|GOVERNANCE_DIR|STRATEGY_DIR|STRATEGY)\}?' \
      r'|\$\{?IWE_GOVERNANCE_REPO(?::-[^}]*)?\}+' \
      r'|(?<![\w-])DS-strategy' \
      r'|\{\{GOVERNANCE_REPO\}\}|\{gov_repo\}|<governance[^>]*>)'
pattern = re.compile(gov + r'"?/scripts/([A-Za-z0-9_.-]+)')

out = []
for skill in sorted((root / ".claude/skills").rglob("*.md")):
    for n, line in enumerate(skill.read_text(encoding="utf-8").splitlines(), 1):
        for name in pattern.findall(line):
            if f"scripts/{name}" in shipped and name not in seeded:
                out.append(f"{skill.relative_to(root)}:{n}: {name}")
print("\n".join(out))
PY
violations=$(python3 "$TMP/guard.py" "$ROOT")
[ -z "$violations" ] || fail "skills call template-only scripts via the governance repo:
$violations"

# The guard must actually see the pre-fix spelling (otherwise it proves nothing).
fixture="$TMP/guard-fixture"
mkdir -p "$fixture/.claude/skills/x" "$fixture/seed/strategy/scripts"
cp "$ROOT/update-manifest.json" "$fixture/"
printf '%s\n' 'bash "$GOV_DIR/scripts/ke-queue-stats.sh" --list' \
    'bash "${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/claude-peer-adapter.sh"' \
    "adapter = os.path.expanduser(f'~/IWE/{gov_repo}/scripts/kimi-peer-adapter.sh')" \
    'bash "$IWE_ROOT/${IWE_GOVERNANCE_REPO:-${GOVERNANCE_REPO:-DS-strategy}}/scripts/codex-peer-adapter.sh"' \
    'bash ~/IWE/DS-strategy/scripts/grok-peer-adapter.sh' \
    > "$fixture/.claude/skills/x/SKILL.md"
hit=$(python3 "$TMP/guard.py" "$fixture")
for name in ke-queue-stats.sh claude-peer-adapter.sh kimi-peer-adapter.sh codex-peer-adapter.sh grok-peer-adapter.sh; do
    grep -q "$name" <<<"$hit" || fail "guard misses the pre-fix spelling of $name: '$hit'"
done

# --- Part 2: behaviour of apply-captures blocks ------------------------------
SKILL="$ROOT/.claude/skills/apply-captures/SKILL.md"
awk '/^### Шаг 1\. /{s=1} s&&/^```bash/{b=1;next} b&&/^```/{exit} b{print}' "$SKILL" > "$TMP/step1.sh"
awk 'BEGIN{b=0} /^```bash/{b=1;blk="";next} b&&/^```/{b=0; if (blk ~ /ke-report-reconcile/) {printf "%s", blk; exit}; next} b{blk=blk $0 "\n"}' "$SKILL" > "$TMP/step6.sh"
[ -s "$TMP/step1.sh" ] || fail "could not extract step 1 block"
[ -s "$TMP/step6.sh" ] || fail "could not extract the ke-report-reconcile block"

tpl="$TMP/IWE/FMT-exocortex-template"
mkdir -p "$tpl/scripts" "$TMP/IWE/DS-strategy/scripts" "$TMP/alt"
for s in ke-queue-stats.sh ke-report-reconcile.sh; do
    printf '#!/bin/bash\necho "STUB %s from $(basename "$(dirname "$(dirname "$0")")")"\n' "$s" > "$tpl/scripts/$s"
done
mkdir -p "$TMP/alt/scripts"
for s in ke-queue-stats.sh ke-report-reconcile.sh; do
    printf '#!/bin/bash\necho "STUB %s from alt"\n' "$s" > "$TMP/alt/scripts/$s"
done

run() { env -u IWE_SCRIPTS -u IWE_TEMPLATE -u IWE_ROOT -u IWE_GOVERNANCE_REPO \
        HOME="$TMP" IWE_WORKSPACE="$TMP/IWE" "$@" 2>&1; }

for step in step1 step6; do
    out=$(run IWE_TEMPLATE="$tpl" bash "$TMP/$step.sh")
    grep -q 'STUB ke-.* from FMT-exocortex-template' <<<"$out" \
        || fail "$step: not found through IWE_TEMPLATE: $out"
    out=$(run IWE_SCRIPTS="$TMP/alt/scripts" IWE_TEMPLATE="$tpl" bash "$TMP/$step.sh")
    grep -q 'STUB ke-.* from alt' <<<"$out" || fail "$step: IWE_SCRIPTS does not win: $out"
    out=$(run bash "$TMP/$step.sh")
    grep -q 'STUB ke-.* from FMT-exocortex-template' <<<"$out" \
        || fail "$step: default \$HOME/IWE/FMT-exocortex-template not used: $out"
done

echo "PASS: issue 1513 (guard + 6 behaviour checks)"
