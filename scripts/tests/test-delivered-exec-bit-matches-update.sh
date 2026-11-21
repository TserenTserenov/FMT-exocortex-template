#!/bin/bash
# test-delivered-exec-bit-matches-update.sh — 0.42 rc.9 red team, Н4: update.sh
# gives the exec bit to every delivered file its update_needs_exec_bit() rule
# marks as a program (*.sh, .githooks/*, .claude/bin/*, a payload starting with
# `#!`), while a clean install takes the mode git records. Files the rule marks
# but git keeps at 100644 ended up executable after an update and plain after a
# clean install. Every such delivered file must be 100755 in git.
#
# The rule is taken from update.sh itself, not copied, so the test follows it.
#
# Usage: bash scripts/tests/test-delivered-exec-bit-matches-update.sh

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MANIFEST="$ROOT/update-manifest.json"

RULE=$(awk '/^update_needs_exec_bit\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$ROOT/update.sh")
if [ -z "$RULE" ]; then
    echo "FAIL: update_needs_exec_bit() not found in update.sh"
    exit 1
fi
eval "$RULE"

modes=$(git -C "$ROOT" ls-files -s | awk '{print $1 "\t" $4}')
mismatch=()
checked=0
while IFS= read -r path; do
    [ -f "$ROOT/$path" ] || continue
    update_needs_exec_bit "$path" "$ROOT/$path" || continue
    checked=$((checked + 1))
    mode=$(printf '%s\n' "$modes" | awk -F'\t' -v p="$path" '$2 == p {print $1; exit}')
    [ "$mode" = "100755" ] || mismatch+=("$path (${mode:-untracked})")
done < <(python3 -c 'import json,sys; [print(e["path"]) for e in json.load(open(sys.argv[1]))["files"] if isinstance(e, dict)]' "$MANIFEST")

if [ "${#mismatch[@]}" -eq 0 ]; then
    echo "PASS: $checked delivered programs are 100755 in git, as update.sh delivers them"
    exit 0
fi
echo "FAIL: ${#mismatch[@]} delivered files get +x from update.sh but not from a clean install:"
printf '  %s\n' "${mismatch[@]}"
exit 1
