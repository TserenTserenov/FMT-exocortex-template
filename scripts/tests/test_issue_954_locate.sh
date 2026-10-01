#!/usr/bin/env bash
# Regression for the library lookup of the #954 WP-number scripts (cold review of the series:
# M1, L3, L4a, L6). Five scripts start with the same block that finds scripts/lib/wp-num.sh:
# .claude/scripts/wp-sync-bundle.sh, .claude/scripts/wp-phase-digest.sh, scripts/close-wp.sh,
# scripts/archive-done-wp.sh, scripts/check-wp-transfer-completeness.sh.
#   * Not finding the library is an installation error, not "WP not found": exit 4 (memory/
#     protocol-open.md reads exit 1 as "РП не найден"), and the message names the searched
#     places, with the VALUE of IWE_TEMPLATE (or "не задана"), not the literal "${IWE_TEMPLATE}".
#   * The text between the "wp-num locate" markers is identical in all five files and in
#     scripts/session-guard.sh (which keeps working without the library: _WPN_OPTIONAL=1); the
#     per-file differences, _WPN_ROOT_UP and _WPN_OPTIONAL, sit above the block, and
#     _WPN_ROOT_UP must match the file's depth.
#   * A script started through a symlink (absolute, relative, chained) finds the library from
#     the real file's location.
#   * wp-sync-bundle.sh does not swallow the exit code of the wp-phase-digest.sh it calls: 4 (no
#     library) stays 4 with a message instead of turning into a bare exit 1 ("РП не найден" to
#     memory/protocol-open.md), and the helper is pointed at the library the bundle loaded.
# Synthetic fixtures under a temporary HOME/TMPDIR; every failure is collected and reported.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/locate-954.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/home" "$TMP/tmp"
export HOME="$TMP/home" TMPDIR="$TMP/tmp"
unset IWE_ROOT IWE_WORKSPACE IWE_GOVERNANCE_REPO IWE_TEMPLATE IWE_SCRIPTS STRATEGY_DIR

GOV=DS-strategy
LIB="$ROOT/scripts/lib/wp-num.sh"
CONSUMERS=".claude/scripts/wp-sync-bundle.sh .claude/scripts/wp-phase-digest.sh scripts/close-wp.sh scripts/archive-done-wp.sh scripts/check-wp-transfer-completeness.sh"
BLOCK_USERS="$CONSUMERS scripts/session-guard.sh"   # session-guard.sh has the same block, optional there
PASSES=0
FAILS=0
ok()  { echo "  ✅ PASS: $*"; PASSES=$((PASSES + 1)); }
bad() { echo "  ❌ FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
expect_eq() {  # <description> <expected> <got>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2], got [$3]"; fi
}
expect_has() {  # <description> <needle> <haystack>
  case "$3" in *"$2"*) ok "$1" ;; *) bad "$1: [$2] not found in: $3" ;; esac
}
expect_lacks() {  # <description> <needle> <haystack>
  case "$3" in *"$2"*) bad "$1: unexpected [$2] in: $3" ;; *) ok "$1" ;; esac
}

block_of() {  # <file>: the text between the markers, markers excluded
  awk '/^# >>> wp-num locate$/ { p = 1; next } /^# <<< wp-num locate$/ { p = 0 } p { print }' "$1"
}

new_fixture() {  # a workspace with a one-row registry and the card of WP-044; prints its path
  local d
  d=$(mktemp -d "$TMP/ws.XXXXXX")
  mkdir -p "$d/$GOV/docs" "$d/$GOV/inbox/WP-044" "$d/$GOV/archive/wp-contexts"
  printf '%s\n' '| # | Название | Статус |' '|---|----------|--------|' '| WP-044 | Demo | 🔄 |' > "$d/$GOV/docs/WP-REGISTRY.md"
  printf '%s\n' '---' 'wp: 44' 'status: in_progress' '---' '# card' > "$d/$GOV/inbox/WP-044/WP-044.md"
  printf '%s\n' "$d"
}

install_code() {  # <root> [with-lib: yes|no]: the five consumers at their repository paths
  local root="$1" f
  for f in $CONSUMERS; do
    mkdir -p "$root/$(dirname "$f")"
    cp "$ROOT/$f" "$root/$f"
  done
  if [ "${2:-yes}" = yes ]; then
    mkdir -p "$root/scripts/lib"
    cp "$LIB" "$root/scripts/lib/wp-num.sh"
  fi
}

run_env() {  # <extra env assignments...> -- <command...>: the command in a clean environment
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  env -i PATH="$PATH" HOME="$HOME" TMPDIR="$TMPDIR" ${envs[@]+"${envs[@]}"} "$@"
}

echo "--- the lookup block is identical in the five scripts and in session-guard.sh (the markers are the contract) ---"
ref=$(block_of "$ROOT/.claude/scripts/wp-sync-bundle.sh")
if [ -n "$ref" ]; then ok "the reference block exists in wp-sync-bundle.sh"; else bad "wp-sync-bundle.sh has no wp-num locate block"; fi
for f in $BLOCK_USERS; do
  begins=$(grep -c '^# >>> wp-num locate$' "$ROOT/$f")
  ends=$(grep -c '^# <<< wp-num locate$' "$ROOT/$f")
  expect_eq "$f: exactly one begin and one end marker" "1/1" "$begins/$ends"
  other=$(block_of "$ROOT/$f")
  if [ -n "$other" ] && [ "$other" = "$ref" ]; then ok "$f: the block is identical to the reference"; else bad "$f: the lookup block differs from the reference or is missing"; fi
  case "$f" in .claude/scripts/*) want='../..' ;; *) want='..' ;; esac
  got=$(sed -n 's/^_WPN_ROOT_UP="\(.*\)"$/\1/p' "$ROOT/$f")
  expect_eq "$f: _WPN_ROOT_UP (the one per-file difference, set above the block) matches the file's depth" "$want" "$got"
  up_line=$(grep -n '^_WPN_ROOT_UP=' "$ROOT/$f" | head -1 | cut -d: -f1)
  begin_line=$(grep -n '^# >>> wp-num locate$' "$ROOT/$f" | head -1 | cut -d: -f1)
  if [ -n "$up_line" ] && [ -n "$begin_line" ] && [ "$up_line" -lt "$begin_line" ]; then ok "$f: _WPN_ROOT_UP is set before the block"; else bad "$f: _WPN_ROOT_UP must be set above the begin marker"; fi
  # the library is mandatory (exit 4 when missing) everywhere but in session-guard.sh
  case "$f" in scripts/session-guard.sh) want='1' ;; *) want='""' ;; esac
  got=$(sed -n 's/^_WPN_OPTIONAL=\(.*\)$/\1/p' "$ROOT/$f")
  expect_eq "$f: _WPN_OPTIONAL is declared ($want: optional only where the gate degrades instead of failing)" "$want" "$got"
  opt_line=$(grep -n '^_WPN_OPTIONAL=' "$ROOT/$f" | head -1 | cut -d: -f1)
  if [ -n "$opt_line" ] && [ -n "$begin_line" ] && [ "$opt_line" -lt "$begin_line" ]; then ok "$f: _WPN_OPTIONAL is set before the block"; else bad "$f: _WPN_OPTIONAL must be set above the begin marker"; fi
done

echo "--- no library: exit 4 (an installation error, not 'WP not found') and a message that names the places ---"
NOLIB="$TMP/nolib"
install_code "$NOLIB" no
EMPTY_TEMPLATE="$TMP/empty-template"
mkdir -p "$EMPTY_TEMPLATE"
for f in $CONSUMERS; do
  out=$(cd "$TMP" && run_env IWE_TEMPLATE="$EMPTY_TEMPLATE" -- bash "$NOLIB/$f" 2>&1); rc=$?
  expect_eq "$f without the library exits 4" 4 "$rc"
  expect_has "$f: the message names wp-num.sh" "wp-num.sh" "$out"
  expect_has "$f: the message prints the VALUE of IWE_TEMPLATE" "IWE_TEMPLATE=$EMPTY_TEMPLATE" "$out"
  expect_lacks "$f: no literal \${IWE_TEMPLATE} in the message" "\${IWE_TEMPLATE}" "$out"
  out=$(cd "$TMP" && run_env -- bash "$NOLIB/$f" 2>&1); rc=$?
  expect_eq "$f without the library and without IWE_TEMPLATE exits 4" 4 "$rc"
  expect_has "$f: an unset IWE_TEMPLATE is said so" "не задана" "$out"
done

echo "--- the exit-code contract is written down ---"
header=$(sed -n '1,12p' "$ROOT/.claude/scripts/wp-sync-bundle.sh")
expect_has "the bundle header lists exit 4" "exit 0/1/2/3/4" "$header"
expect_has "the bundle header says what exit 4 means" "wp-num.sh" "$header"
contract=$(cat "$ROOT/memory/protocol-open.md")
expect_has "protocol-open.md says exit 4 is an installation error, not 'WP not found'" "Exit 4 → не найдена библиотека wp-num.sh: ошибка установки, не «РП не найден»" "$contract"

echo "--- a script started through a symlink finds the library from the real file's location ---"
LAYOUT="$TMP/layout"
install_code "$LAYOUT" yes
WS=$(new_fixture)
mkdir -p "$TMP/lnk-abs" "$TMP/lnk-rel"
ln -s "$LAYOUT/.claude/scripts/wp-sync-bundle.sh" "$TMP/lnk-abs/wp-sync-bundle.sh"
ln -s "$LAYOUT/.claude/scripts/wp-phase-digest.sh" "$TMP/lnk-abs/wp-phase-digest.sh"
ln -s "$LAYOUT/scripts/check-wp-transfer-completeness.sh" "$TMP/lnk-abs/check-wp-transfer-completeness.sh"
ln -s ../layout/.claude/scripts/wp-sync-bundle.sh "$TMP/lnk-rel/step1.sh"   # relative link ...
ln -s step1.sh "$TMP/lnk-rel/step2.sh"                                       # ... behind a second link

out=$(cd "$TMP" && run_env IWE_WORKSPACE="$WS" IWE_GOVERNANCE_REPO="$GOV" -- bash "$TMP/lnk-abs/wp-sync-bundle.sh" --self-test 2>&1); rc=$?
expect_eq "bundle through an absolute symlink: exit code" 0 "$rc"
expect_has "bundle through an absolute symlink reaches the card" "lookup: OK" "$out"
out=$(cd "$TMP" && run_env IWE_WORKSPACE="$WS" IWE_GOVERNANCE_REPO="$GOV" -- bash "$TMP/lnk-rel/step2.sh" --self-test 2>&1); rc=$?
expect_eq "bundle through a chain of relative symlinks: exit code" 0 "$rc"
expect_has "bundle through a chain of relative symlinks reaches the card" "lookup: OK" "$out"
out=$(cd "$TMP" && run_env IWE_WORKSPACE="$WS" IWE_GOVERNANCE_REPO="$GOV" -- bash "$TMP/lnk-abs/wp-phase-digest.sh" 44 2>&1); rc=$?
expect_eq "digest through a symlink: exit code" 0 "$rc"
expect_has "digest through a symlink reads the card" "status=in_progress" "$out"
out=$(cd "$TMP" && run_env IWE_GOVERNANCE_REPO="$GOV" -- bash "$TMP/lnk-abs/check-wp-transfer-completeness.sh" 44 --dry-run "$WS" 2>&1); rc=$?
expect_eq "transfer check (scripts/ layout) through a symlink: exit code" 0 "$rc"
expect_lacks "transfer check through a symlink finds the padded card" "не найден" "$out"

# ---------------------------------------------------------------------------
# The bundle compares the snapshot of its dependencies (handoff_snapshot) with what
# wp-phase-digest.sh says now. The helper's exit code used to be dropped (`|| true`, stderr to
# /dev/null) and the grep on its empty output ended the bundle with a bare exit 1.
new_handoff_fixture() {  # a workspace where WP-044 relates to WP-045 and holds a snapshot of it; prints its path
  local d
  d=$(mktemp -d "$TMP/hws.XXXXXX")
  mkdir -p "$d/$GOV/docs" "$d/$GOV/inbox/WP-044" "$d/$GOV/inbox/WP-045"
  printf '%s\n' '| # | Название | Статус |' '|---|----------|--------|' '| 44 | Demo | 🔄 |' '| 45 | Other | 🔄 |' > "$d/$GOV/docs/WP-REGISTRY.md"
  printf '%s\n' '---' 'wp: 44' 'status: in_progress' 'updated: 2026-09-30' 'related:' '  - WP-45' \
    'handoff_snapshot:' '  - ref: WP-45' '    observed_status: in_progress' '    observed_phase_digest: 0123456789ab' \
    '---' '# WP-044' '' '- [ ] phase one' > "$d/$GOV/inbox/WP-044/WP-044.md"
  printf '%s\n' '---' 'wp: 45' 'status: in_progress' '---' '# WP-045' '' '- [ ] x' > "$d/$GOV/inbox/WP-045/WP-045.md"
  printf '%s\n' "$d"
}

stub_digest() {  # <tree> <exit code> <stdout text or ""> <stderr text>: the helper next to the bundle becomes a stub
  local f="$1/.claude/scripts/wp-phase-digest.sh"
  rm -f "$f"
  {
    printf '#!/usr/bin/env bash\n'
    [ -z "$3" ] || printf 'printf "%%s\\n" "%s"\n' "$3"
    printf 'echo "%s" >&2\nexit %s\n' "$4" "$2"
  } > "$f"
  chmod +x "$f"
}

run_bundle() {  # <tree> <workspace> <wp>: stdout+stderr, then the exit code is the function's
  (cd "$TMP" && run_env IWE_WORKSPACE="$2" IWE_GOVERNANCE_REPO="$GOV" -- bash "$1/.claude/scripts/wp-sync-bundle.sh" "$3" 2>&1)
}

echo "--- the helper fails with 4 (no library): the bundle exits 4 with the helper's message, not a bare 1 ---"
STUBT="$TMP/stub-tree"
install_code "$STUBT" yes
HWS=$(new_handoff_fixture)
stub_digest "$STUBT" 4 "" "stub: wp-num.sh не найден"
out=$(run_bundle "$STUBT" "$HWS" 44); rc=$?
expect_eq "digest exit 4 -> bundle exit 4" 4 "$rc"
expect_has "the helper's own message reaches the user" "stub: wp-num.sh не найден" "$out"
expect_has "the bundle says it is an installation error" "ошибка установки" "$out"
expect_has "the bundle names the helper and the WP it was asked about" "wp-phase-digest.sh (WP-45)" "$out"

echo "--- any other failure of the helper still ends the bundle with exit 1, as before, but says what failed ---"
stub_digest "$STUBT" 1 "" "stub: WP-45 не найден"
out=$(run_bundle "$STUBT" "$HWS" 44); rc=$?
expect_eq "digest exit 1 -> bundle exit 1" 1 "$rc"
expect_has "the helper's own message reaches the user" "stub: WP-45 не найден" "$out"
expect_has "the bundle says which exit code the helper gave" "завершился с кодом 1" "$out"
stub_digest "$STUBT" 7 "" "stub: unexpected"
out=$(run_bundle "$STUBT" "$HWS" 44); rc=$?
expect_eq "digest exit 7 -> bundle exit 1" 1 "$rc"
expect_has "the bundle says which exit code the helper gave" "завершился с кодом 7" "$out"

echo "--- the helper's contract: exit 0 means a status= AND a phase_digest= line; an answer without them is a broken helper, not 'no drift' ---"
# What the helper prints on exit 0 is compared with the snapshot (status in_progress, digest 0123456789ab).
stub_digest "$STUBT" 0 "" ""
out=$(run_bundle "$STUBT" "$HWS" 44); rc=$?
expect_eq "digest exit 0 with no output -> bundle exit 1 (nothing was compared)" 1 "$rc"
expect_has "the message names the broken contract and both missing lines" "завершился с кодом 0, но не выдал status=, phase_digest=" "$out"
expect_has "the message says it is a helper contract violation" "нарушен контракт helper" "$out"
expect_lacks "no 'no drift' is reported for a comparison that did not happen" "Drift-сигналы" "$out"
stub_digest "$STUBT" 0 "status=done" "stub: noise on stderr is not output"
out=$(run_bundle "$STUBT" "$HWS" 44); rc=$?
expect_eq "digest exit 0 with only a status line -> bundle exit 1" 1 "$rc"
expect_has "the message names the missing phase_digest line" "не выдал phase_digest=:" "$out"
expect_has "the helper's own stderr reaches the user" "stub: noise on stderr is not output" "$out"
stub_digest "$STUBT" 0 "phase_digest=deadbeef0000" ""
out=$(run_bundle "$STUBT" "$HWS" 44); rc=$?
expect_eq "digest exit 0 with only a phase_digest line -> bundle exit 1" 1 "$rc"
expect_has "the message names the missing status line" "не выдал status=:" "$out"
stub_digest "$STUBT" 0 $'status=\nphase_digest=0123456789ab' ""
out=$(run_bundle "$STUBT" "$HWS" 44); rc=$?
expect_eq "digest exit 0 with an empty status= value -> bundle exit 1" 1 "$rc"
echo "--- a complete answer drives the comparison ---"
stub_digest "$STUBT" 0 $'status=in_progress\nphase_digest=0123456789ab\nphase_count=1' "stub: noise on stderr is not output"
out=$(run_bundle "$STUBT" "$HWS" 44); rc=$?
expect_eq "digest = the snapshot -> bundle exit 0" 0 "$rc"
expect_lacks "digest = the snapshot -> no drift" "stale_handoff" "$out"
stub_digest "$STUBT" 0 $'status=done\nphase_digest=0123456789ab\nphase_count=1' ""
out=$(run_bundle "$STUBT" "$HWS" 44); rc=$?
expect_eq "another status than the snapshot -> bundle exit 0" 0 "$rc"
expect_has "another status than the snapshot -> the drift is reported" "DRIFT: stale_handoff" "$out"
install_code "$STUBT" yes   # the real helper again
out=$(run_bundle "$STUBT" "$HWS" 44); rc=$?
expect_eq "the real helper: bundle exit 0" 0 "$rc"
expect_has "the real helper's digest differs from the snapshot -> the drift is reported" "DRIFT: stale_handoff" "$out"

echo "--- the helper is pointed at the library the bundle loaded (what update.sh passes for the canary) ---"
# The helper next to the bundle is a link into a tree with no library: left alone it exits 4.
LINKT="$TMP/link-tree"
install_code "$LINKT" yes
rm -f "$LINKT/.claude/scripts/wp-phase-digest.sh"
ln -s "$NOLIB/.claude/scripts/wp-phase-digest.sh" "$LINKT/.claude/scripts/wp-phase-digest.sh"
out=$(cd "$TMP" && run_env IWE_WORKSPACE="$HWS" IWE_GOVERNANCE_REPO="$GOV" -- bash "$NOLIB/.claude/scripts/wp-phase-digest.sh" 45 2>&1); rc=$?
expect_eq "the helper alone, from the tree with no library, exits 4 (the premise of this check)" 4 "$rc"
out=$(run_bundle "$LINKT" "$HWS" 44); rc=$?
expect_eq "bundle with a linked helper and no IWE_TEMPLATE in the environment: exit 0" 0 "$rc"
expect_has "the helper found the library through the path the bundle handed over: the drift is reported" "DRIFT: stale_handoff" "$out"

echo
if [ "$FAILS" -eq 0 ]; then
  echo "✅ test_issue_954_locate: $PASSES checks passed"
  exit 0
fi
echo "❌ test_issue_954_locate: $FAILS failed, $PASSES passed" >&2
exit 1
