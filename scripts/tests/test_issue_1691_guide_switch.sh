#!/usr/bin/env bash
# Regression for issue #1691: Day Open starts scripts/update-derived-snapshot.py in the background; it opens a
# headless Claude Code session and spends tokens, and the user had no supported way to switch it off. The script
# now reads `personal_guide_enabled` from the workspace params.yaml: only the literal `false` skips the whole
# refresh - before any subprocess, also with --dry-run and with Day Open's --if-stale-days - and logs why. A
# missing key, a missing params.yaml or any other value keep the previous behaviour.
#
# A stub `claude` on PATH records every call; the real script runs in two layouts: from the template
# (workspace from IWE_ROOT) and as the copy installed in the governance repo (workspace = its parent).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/guide-1691.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home"
CALLS="$TMP/claude-calls.log"
export CLAUDE_CALLS_LOG="$CALLS"
unset IWE_WORKSPACE IWE_TEMPLATE

PASSES=0
FAILS=0
ok()  { echo "  ✅ PASS: $*"; PASSES=$((PASSES + 1)); }
bad() { echo "  ❌ FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
expect_has()   { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1: [$2] not found in: $3" ;; esac; }
expect_lacks() { case "$3" in *"$2"*) bad "$1: [$2] must not be in: $3" ;; *) ok "$1" ;; esac; }
expect_eq()    { [ "$2" = "$3" ] && ok "$1" || bad "$1: expected [$2], got [$3]"; }

# The stub answers like `claude -p ... dt_read_digital_twin`: a valid 3_4_qualification reply.
cat > "$TMP/bin/claude" <<'STUB'
#!/bin/sh
echo called >> "$CLAUDE_CALLS_LOG"
echo '{"3_4_qualification": {"stage_id": "STG.Student.Practicing", "rcs_indices": {"W": {"idx": 2}, "M1": {"idx": 3}, "M2": {"idx": 3}, "M4": {"idx": 4}}}}'
STUB
chmod +x "$TMP/bin/claude"

calls() { if [ -f "$CALLS" ]; then wc -l < "$CALLS" | tr -d ' '; else echo 0; fi; }
reset_calls() { rm -f -- "$CALLS"; }

# Layout 1: the script from the template, workspace from IWE_ROOT.
new_template_ws() {  # <params.yaml text or empty for none> -> prints the workspace
  local ws; ws=$(mktemp -d "$TMP/ws.XXXXXX")
  [ -z "$1" ] || printf '%s\n' "$1" > "$ws/params.yaml"
  printf '%s\n' "$ws"
}
run_template() {  # <workspace> [args] -> stdout+stderr; exit code in $RC
  local ws="$1"; shift
  OUT=$(PATH="$TMP/bin:$PATH" HOME="$TMP/home" IWE_ROOT="$ws" IWE_GOVERNANCE_REPO=DS-strategy \
        python3 "$ROOT/scripts/update-derived-snapshot.py" "$@" 2>&1)
  RC=$?
}
template_snapshot() { printf '%s\n' "$1/DS-strategy/.cache/derived_snapshot.json"; }

# Layout 2: the copy installed in the governance repo (what Day Open really runs).
new_installed_ws() {  # <params.yaml text or empty> -> prints the workspace
  local ws; ws=$(mktemp -d "$TMP/iws.XXXXXX")
  mkdir -p "$ws/DS-strategy/scripts"
  printf '# Тип репозитория\n\n**Тип**: `DS/governance`\n' > "$ws/DS-strategy/REPO-TYPE.md"
  cp "$ROOT/seed/strategy/scripts/update-derived-snapshot.py" "$ws/DS-strategy/scripts/"
  [ -z "$1" ] || printf '%s\n' "$1" > "$ws/params.yaml"
  printf '%s\n' "$ws"
}
run_installed() {  # <workspace> [args]
  local ws="$1"; shift
  OUT=$(PATH="$TMP/bin:$PATH" HOME="$TMP/home" env -u IWE_ROOT \
        python3 "$ws/DS-strategy/scripts/update-derived-snapshot.py" "$@" 2>&1)
  RC=$?
}

echo "--- #1691 A: personal_guide_enabled: false -> no claude call, a logged skip ---"
reset_calls; WS=$(new_template_ws 'personal_guide_enabled: false')
run_template "$WS" --if-stale-days 10
expect_eq "A: exit code 0 (a skip is not a failure)" 0 "$RC"
expect_eq "A: headless claude was not called" 0 "$(calls)"
expect_has "A: the log names the reason" "SKIPPED: personal_guide_enabled is false" "$OUT"
expect_has "A: the log names the params file" "$(basename "$WS")/params.yaml" "$OUT"
[ ! -e "$(template_snapshot "$WS")" ] && ok "A: no snapshot is written" || bad "A: a snapshot appeared although the refresh is off"

echo "--- #1691 B: false with a trailing comment, and with --dry-run / without flags ---"
reset_calls; WS=$(new_template_ws 'personal_guide_enabled: false   # no tokens, please')
run_template "$WS"
expect_eq "B: commented false: no claude call" 0 "$(calls)"
expect_has "B: commented false: skip logged" "SKIPPED" "$OUT"
run_template "$WS" --dry-run
expect_eq "B: --dry-run with false: no claude call" 0 "$(calls)"
expect_lacks "B: --dry-run with false prints no snapshot" '"stage_raw"' "$OUT"

echo "--- #1691 C: true, key missing, params.yaml missing -> the refresh runs as before ---"
reset_calls; WS=$(new_template_ws 'personal_guide_enabled: true')
run_template "$WS" --if-stale-days 10
expect_eq "C: true: exit code 0" 0 "$RC"
expect_eq "C: true: claude called once" 1 "$(calls)"
SNAP=$(template_snapshot "$WS")
if [ -f "$SNAP" ] && grep -q '"source": "mcp-fetched"' "$SNAP" && grep -q '"stage_raw": 2' "$SNAP"; then
  ok "C: true: the snapshot is written from the stub reply"
else
  bad "C: true: snapshot missing or wrong: $(cat "$SNAP" 2>/dev/null)"
fi
expect_lacks "C: true: no skip message" "SKIPPED" "$OUT"
reset_calls; WS=$(new_template_ws 'region: ru')
run_template "$WS" --if-stale-days 10
expect_eq "C: key missing: claude called once" 1 "$(calls)"
reset_calls; WS=$(new_template_ws '')
run_template "$WS" --if-stale-days 10
expect_eq "C: no params.yaml: claude called once" 1 "$(calls)"

echo "--- #1691 D: only the literal false counts (the convention of wp_new_add_to_weekplan, #1503) ---"
for v in '"false"' 'False' 'no' 'off'; do
  reset_calls; WS=$(new_template_ws "personal_guide_enabled: $v")
  run_template "$WS" --if-stale-days 10
  expect_eq "D: [$v] does not switch the refresh off" 1 "$(calls)"
done
reset_calls; WS=$(new_template_ws '  personal_guide_enabled: false')
run_template "$WS" --if-stale-days 10
expect_eq "D: an indented line is not a top-level key: the refresh runs" 1 "$(calls)"

echo "--- #1691 E: the installed copy in the governance repo reads the workspace params.yaml ---"
reset_calls; WS=$(new_installed_ws 'personal_guide_enabled: false')
run_installed "$WS" --if-stale-days 10
expect_eq "E: installed copy, false: exit code 0" 0 "$RC"
expect_eq "E: installed copy, false: no claude call" 0 "$(calls)"
expect_has "E: installed copy: the skip names the workspace params.yaml" "$(basename "$WS")/params.yaml" "$OUT"
[ ! -e "$WS/DS-strategy/.cache/derived_snapshot.json" ] && ok "E: installed copy: no snapshot written" || bad "E: installed copy wrote a snapshot"
reset_calls; WS=$(new_installed_ws 'personal_guide_enabled: true')
run_installed "$WS" --if-stale-days 10
expect_eq "E: installed copy, true: claude called once" 1 "$(calls)"
[ -f "$WS/DS-strategy/.cache/derived_snapshot.json" ] && ok "E: installed copy, true: snapshot written" || bad "E: installed copy, true: no snapshot"

echo "--- #1691 F: the shipped params example documents the key with the default true ---"
if grep -qE '^personal_guide_enabled: true' "$ROOT/params.yaml.example"; then ok "F: params.yaml.example has personal_guide_enabled: true"; else bad "F: params.yaml.example does not document personal_guide_enabled"; fi
if cmp -s <(grep -vF '# SNAPSHOT' "$ROOT/seed/strategy/scripts/update-derived-snapshot.py") "$ROOT/scripts/update-derived-snapshot.py"; then ok "F: the seed copy matches scripts/"; else bad "F: the seed copy differs from scripts/"; fi

echo
echo "issue #1691: $PASSES passed, $FAILS failed"
[ "$FAILS" -eq 0 ]
