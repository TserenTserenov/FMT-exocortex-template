#!/usr/bin/env bash
# Regression for the library lookup of the #954 WP-number scripts (cold review of the series:
# M1, L3, L4a, L6). Five scripts start with the same block that finds scripts/lib/wp-num.sh:
# .claude/scripts/wp-sync-bundle.sh, .claude/scripts/wp-phase-digest.sh, scripts/close-wp.sh,
# scripts/archive-done-wp.sh, scripts/check-wp-transfer-completeness.sh.
#   * Not finding the library is an installation error, not "WP not found": exit 4 (memory/
#     protocol-open.md reads exit 1 as "РП не найден"), and the message names the searched
#     places, with the VALUE of IWE_TEMPLATE (or "не задана"), not the literal "${IWE_TEMPLATE}".
#   * The text between the "wp-num locate" markers is identical in all five files; the only
#     per-file difference, _WPN_ROOT_UP, sits above the block and must match the file's depth.
#   * A script started through a symlink (absolute, relative, chained) finds the library from
#     the real file's location.
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

echo "--- the lookup block is identical in the five scripts (the markers are the contract) ---"
ref=$(block_of "$ROOT/.claude/scripts/wp-sync-bundle.sh")
if [ -n "$ref" ]; then ok "the reference block exists in wp-sync-bundle.sh"; else bad "wp-sync-bundle.sh has no wp-num locate block"; fi
for f in $CONSUMERS; do
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

echo
if [ "$FAILS" -eq 0 ]; then
  echo "✅ test_issue_954_locate: $PASSES checks passed"
  exit 0
fi
echo "❌ test_issue_954_locate: $FAILS failed, $PASSES passed" >&2
exit 1
