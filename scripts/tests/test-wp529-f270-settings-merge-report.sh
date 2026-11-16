#!/usr/bin/env bash
# shellcheck disable=SC2034  # the subshells set variables that the function sourced from update.sh reads
# WP-529 Ф270, RT5-4 of the v0.42.0-rc.5 red team: after a rollback re-run the settings merge
# printed «обновлён слиянием» although the workspace settings.json stayed byte-identical (own hooks
# keep it different from the template, the merge adds nothing). Contract: the line names a change
# only when the file changed. Drives the real function extracted from update.sh with a stub merger.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
UPDATE_SH="${UPDATE_SH:-$ROOT/update.sh}"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/iwe-f270-settings-report.XXXXXX")
trap 'rm -rf "${TMP:?}"' EXIT

FAILS=0
ok()   { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS + 1)); }

FUNCS="$TMP/funcs.sh"
for fn in hash_file apply_settings_merge_if_requested explain_applied_settings_merge; do
  awk -v signature="$fn() {" '$0 == signature { found=1 } found { print } found && /^}$/ { exit }' \
    "$UPDATE_SH" >> "$FUNCS"
  grep -q "^$fn() {" "$FUNCS" || { echo "FATAL: $fn not found in update.sh" >&2; exit 2; }
done

TPL="$TMP/ws/FMT-exocortex-template"
mkdir -p "$TPL/.claude/scripts" "$TMP/ws/.claude"
echo '{"template": 1}' > "$TPL/.claude/settings.json"

# run_merge MERGER_BODY -> prints the function's output
run_merge() (
  printf '#!/bin/bash\n%s\n' "$1" > "$TPL/.claude/scripts/settings-merge-apply.sh"
  echo '{"template": 1, "own_hook": 1}' > "$TMP/ws/.claude/settings.json"
  # shellcheck disable=SC1090
  . "$FUNCS"
  APPLY_SETTINGS_MERGE=true SCRIPT_DIR="$TPL" WORKSPACE_DIR="$TMP/ws" PY_BIN=python3
  py_available() { return 0; }
  report_settings_merge_preview() { :; }
  apply_settings_merge_if_requested
)

echo "== merge adds nothing =="
out=$(run_merge 'cp "$2" "$2.bak"')
grep -q 'слияние ничего не изменило' <<<"$out" && ok "unchanged file reported as unchanged" || fail "output: $out"
grep -q 'обновлён слиянием' <<<"$out" && fail "unchanged file still reported as updated" || ok "no «обновлён» for an unchanged file"

echo "== merge changes the file =="
out=$(run_merge 'echo "{\"template\": 1, \"own_hook\": 1, \"new\": 1}" > "$2"')
grep -q 'обновлён слиянием' <<<"$out" && ok "changed file reported as updated" || fail "output: $out"

# WP-529 Ф270, finding 1 of the rc.14 red team: a withdrawn platform mode replaced by the merge is
# explained in plain words, even when the applier prints a line before its JSON report.
echo "== merge replaces the withdrawn acceptEdits mode =="
out=$(run_merge 'echo "note"; echo "{\"retired_defaults_replaced\": [\"permissions.defaultMode: acceptEdits -> default\"]}"; echo "{\"x\": 2}" > "$2"')
grep -q 'агент снова спрашивает подтверждение' <<<"$out" && ok "mode change explained" || fail "output: $out"
grep -q 'settings.local.json' <<<"$out" && ok "explanation names where to keep the mode" || fail "output: $out"
out=$(run_merge 'echo "{\"retired_defaults_replaced\": []}"; echo "{\"x\": 3}" > "$2"')
grep -q 'Режим правок агента' <<<"$out" && fail "mode line printed without a replacement" || ok "no mode line when nothing was replaced"

echo
if [ "$FAILS" -gt 0 ]; then
  echo "FAILED: $FAILS check(s)"
  exit 1
fi
echo "PASS"
