#!/usr/bin/env bash
# Regression for issue #954: the WP number is read differently by different scripts.
#
# create-wp.sh writes the card folder zero-padded (inbox/WP-044/WP-044.md) but the registry
# cell and the frontmatter as the bare number; registries are also kept by hand ("WP-044",
# "~~WP-044~~"). Readers that rebuilt the number their own way disagreed:
#   A. registry_status() did not find a "| WP-044 |" row   -> update.sh --check canary FAILED
#   B. find_wp_file() looked for WP-44/ and fell back to the FIRST file with `wp: 44`
#      (a note, not the card) while reporting OK
#   C. close-wp.sh matched the registry row only by the bare number -> row not struck, "closed"
#   D. archive-done-wp.sh built WP-44/ (false "flat" mode), ignored the exit code of mv and
#      printed a success line on failure; wp-phase-digest.sh and check-wp-transfer-completeness.sh
#      repeated the same lookup
# The fix is one shared reader, scripts/lib/wp-num.sh, located from each script's OWN
# file location (never from the data root, which fixtures substitute).
#
# Every check runs on synthetic fixtures under a temporary HOME/TMPDIR. All failures are
# collected and reported together; exit 1 when any check failed.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/wp-num-954.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/home" "$TMP/tmp"
export HOME="$TMP/home" TMPDIR="$TMP/tmp"
unset IWE_ROOT IWE_WORKSPACE IWE_GOVERNANCE_REPO IWE_TEMPLATE IWE_SCRIPTS STRATEGY_DIR

GOV=DS-strategy
LIB="$ROOT/scripts/lib/wp-num.sh"
BUNDLE="$ROOT/.claude/scripts/wp-sync-bundle.sh"
DIGEST="$ROOT/.claude/scripts/wp-phase-digest.sh"
CLOSE="$ROOT/scripts/close-wp.sh"
ARCHIVE="$ROOT/scripts/archive-done-wp.sh"
TRANSFER="$ROOT/scripts/check-wp-transfer-completeness.sh"
WPLIST="$ROOT/scripts/wp-list.py"

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

new_ws() {  # a fresh workspace with an empty governance skeleton; prints its path
  local d
  d=$(mktemp -d "$TMP/ws.XXXXXX")
  mkdir -p "$d/$GOV/docs" "$d/$GOV/inbox" "$d/$GOV/archive/wp-contexts"
  printf '%s\n' "$d"
}

issue_registry() {  # <file> <first-cell>: the one-row registry from the issue text
  cat > "$1" <<EOF
| # | Приоритет | Название | Статус | Репо | Бюджет | Неделя |
|---|-----------|---------|--------|------|--------|--------|
| $2 | P2 | **Demo WP** | 🔄 in_progress | DS-strategy | 3h | W38 |
EOF
}

card() {  # <path> <wp-field or ""> <status>
  mkdir -p "$(dirname "$1")"
  {
    printf -- '---\n'
    [ -z "$2" ] || printf 'wp: %s\n' "$2"
    printf 'status: %s\ncreated: 2026-09-30\n---\n# card\n' "$3"
  } > "$1"
}

if [ -r "$LIB" ]; then
  # shellcheck source=/dev/null
  . "$LIB"
  have_lib=1
else
  have_lib=0
  bad "library is missing: $LIB"
fi

# ---------------------------------------------------------------------------
echo "--- library: normalisation, spellings, registry cell regex ---"
if [ "$have_lib" = 1 ]; then
  for pair in "44:44" "044:44" "WP-44:44" "WP-044:44" "wp-044:44" "~~WP-044~~:44" "**WP-044**:44" " 044 :44" "0:0" "000:0"; do
    got=$(wp_num_normalize "${pair%%:*}") || got="<rc=$?>"
    expect_eq "normalize [${pair%%:*}]" "${pair#*:}" "$got"
  done
  for raw in "" "abc" "WP-" "13*" "WP-44-slug" "-5" "1.5" "4 4" "1234567890"; do
    got=$(wp_num_normalize "$raw"); rc=$?
    if [ "$rc" -ne 0 ] && [ -z "$got" ]; then ok "normalize rejects [$raw] without output"; else bad "normalize [$raw]: expected rc!=0 and no output, got rc=$rc out=[$got]"; fi
  done
  expect_eq "padded 44" "044" "$(wp_num_padded 44)"
  expect_eq "padded WP-7" "007" "$(wp_num_padded WP-7)"
  expect_eq "padded 1234 (four digits stay as they are)" "1234" "$(wp_num_padded 1234)"

  re=$(wp_num_registry_cell_regex 44)
  for cell in "44" "044" "WP-44" "WP-044" "wp-044" "~~WP-044~~" "**WP-044**" "44★"; do
    if grep -Eq -- "^\\|[[:space:]]*${re}[[:space:]]*\\|" <<<"| $cell | x |"; then
      ok "cell regex (ERE) matches [$cell] for 44"
    else
      bad "cell regex (ERE) must match [$cell] for 44"
    fi
  done
  for cell in "440" "0440" "4" "144" "WP-0440" "~~440~~"; do
    if grep -Eq -- "^\\|[[:space:]]*${re}[[:space:]]*\\|" <<<"| $cell | x |"; then
      bad "cell regex (ERE) must NOT match [$cell] for 44"
    else
      ok "cell regex (ERE) rejects [$cell] for 44"
    fi
  done
  py_out=$(python3 - "$re" <<'PY'
import re, sys
cell_re = sys.argv[1]
yes = ["44", "044", "WP-44", "WP-044", "wp-044", "~~WP-044~~", "**WP-044**", "44★"]
no = ["440", "0440", "4", "144", "WP-0440", "~~440~~"]
bad = [c for c in yes if not re.match(r"^\|\s*" + cell_re + r"\s*\|", "| %s | x |" % c)]
bad += [c for c in no if re.match(r"^\|\s*" + cell_re + r"\s*\|", "| %s | x |" % c)]
print("ok" if not bad else "mismatch: " + ", ".join(bad))
PY
)
  expect_eq "the same regex means the same in Python re" "ok" "$py_out"

  # Sourcing must be free of side effects: no output, no shell options changed.
  src_out=$(bash -c '. "$1"' _ "$LIB" 2>&1)
  before=$(set +o)
  # shellcheck source=/dev/null
  . "$LIB"
  after=$(set +o)
  expect_eq "sourcing prints nothing" "" "$src_out"
  expect_eq "sourcing leaves shell options alone" "$before" "$after"
  if [ -x /bin/bash ]; then
    b32=$(/bin/bash -c '. "$1"; wp_num_normalize WP-044; wp_num_padded 5; wp_num_registry_cell_regex 44' _ "$LIB" 2>&1)
    expect_eq "library runs under /bin/bash" "44
005
(~~)?(\\*\\*)?(WP-|wp-)?0*44(\\*\\*)?(~~)?[^0-9|]*" "$b32"
  fi
fi

# ---------------------------------------------------------------------------
echo "--- #954 A: registry_status finds '| WP-044 |' (functions taken from the bundle) ---"
REGISTRY_FILE="$TMP/registry-forms.md"
cat > "$REGISTRY_FILE" <<'EOF'
| # | Название | Статус | Приоритет |
|---|----------|--------|-----------|
| WP-044 | Префикс и нули | 🔄 | P1 |
| 045 | Только нули | ⏳ | P1 |
| 46 | Канон: голое число | 🔄 | P1 |
| ~~WP-047~~ | ~~Зачёркнутый, префикс и нули~~ | ✅ | P2 |
| **WP-048** | Жирный префикс | ⏳ | P2 |
| 440 | Соседний номер | 📦 | P3 |
| 0450 | Соседний номер с нулём | ⏸ | P3 |
EOF
eval "$(awk '/^registry_status_column\(\)/ { c=1 } c { print } c && /^}/ { print ""; c=0 }' "$BUNDLE")"
eval "$(awk '/^registry_status\(\)/ { c=1 } c { print } c && /^}/ { exit }' "$BUNDLE")"
if declare -F registry_status >/dev/null; then
  for q in 44 044 WP-044 wp-44; do
    expect_eq "registry_status $q finds '| WP-044 |'" "🔄 in_progress" "$(registry_status "$q" 2>/dev/null)"
  done
  expect_eq "registry_status 45 finds '| 045 |', not '| 0450 |'" "⏳ pending" "$(registry_status 45 2>/dev/null)"
  expect_eq "registry_status 46 (canonical bare number) still resolves" "🔄 in_progress" "$(registry_status 46 2>/dev/null)"
  expect_eq "registry_status 47 finds '| ~~WP-047~~ |'" "✅ done" "$(registry_status 47 2>/dev/null)"
  expect_eq "registry_status 48 finds '| **WP-048** |'" "⏳ pending" "$(registry_status 48 2>/dev/null)"
  expect_eq "registry_status 440 keeps its own row" "📦 archived" "$(registry_status 440 2>/dev/null)"
  expect_eq "registry_status 450 finds '| 0450 |'" "⏸ paused" "$(registry_status 450 2>/dev/null)"
  expect_eq "registry_status 4 does not match 44/440" "_не в реестре_" "$(registry_status 4 2>/dev/null)"
else
  bad "registry_status could not be loaded from $BUNDLE"
fi

# ---------------------------------------------------------------------------
echo "--- #954 B: find_wp_file returns the card, not the first file that says 'wp: N' ---"
WS=$(new_ws)
IN="$WS/$GOV/inbox"
AR="$WS/$GOV/archive/wp-contexts"
card "$IN/WP-044/WP-044.md" 44 in_progress
card "$IN/a-notes.md" 44 notes
card "$IN/WP-046/WP-046.md" "" in_progress           # a card without the `wp:` field
card "$IN/b-notes.md" 46 notes
card "$IN/WP-45/WP-45.md" 45 in_progress             # older, unpadded folder
card "$IN/WP-070-flat-slug.md" 70 in_progress
card "$AR/WP-050/WP-050.md" 50 "done"
card "$AR/WP-060-closed-slug.md" 60 "done"           # what close-wp.sh writes
card "$AR/WP-469-unrelated.md" 469 "done"
# shellcheck disable=SC2034  # read by the find_wp_file() taken from the bundle below
INBOX_DIR="$IN"
# shellcheck disable=SC2034  # same
ARCHIVE_DIR="$AR"
eval "$(awk '/^find_wp_file\(\)/ { c=1 } c { print } c && /^}/ { exit }' "$BUNDLE")"
if declare -F find_wp_file >/dev/null; then
  for q in 44 044 WP-044; do
    expect_eq "find_wp_file $q -> the padded folder card" "$IN/WP-044/WP-044.md" "$(find_wp_file "$q")"
  done
  expect_eq "find_wp_file 46 -> the card even though a note carries 'wp: 46'" "$IN/WP-046/WP-046.md" "$(find_wp_file 46)"
  for q in 45 045; do
    expect_eq "find_wp_file $q -> the real unpadded folder card" "$IN/WP-45/WP-45.md" "$(find_wp_file "$q")"
  done
  expect_eq "find_wp_file 70 -> flat slug card" "$IN/WP-070-flat-slug.md" "$(find_wp_file 70)"
  for q in 50 050; do
    expect_eq "find_wp_file $q -> archive folder card" "$AR/WP-050/WP-050.md" "$(find_wp_file "$q")"
  done
  expect_eq "find_wp_file 60 -> flat archive context (padded name)" "$AR/WP-060-closed-slug.md" "$(find_wp_file 60)"
  expect_eq "find_wp_file 469 -> its own archive file" "$AR/WP-469-unrelated.md" "$(find_wp_file 469)"
  expect_eq "find_wp_file 47 -> nothing (46/469 prefixes are not IDs)" "" "$(find_wp_file 47)"
  expect_eq "find_wp_file 440 -> nothing" "" "$(find_wp_file 440)"
else
  bad "find_wp_file could not be loaded from $BUNDLE"
fi

# ---------------------------------------------------------------------------
echo "--- #954 A+B end to end: wp-sync-bundle.sh on the stand from the issue ---"
WS=$(new_ws)
issue_registry "$WS/$GOV/docs/WP-REGISTRY.md" "WP-044"
card "$WS/$GOV/inbox/WP-044/WP-044.md" 44 in_progress
card "$WS/$GOV/inbox/a-notes.md" 44 notes
out=$(IWE_WORKSPACE="$WS" IWE_GOVERNANCE_REPO="$GOV" bash "$BUNDLE" --self-test 2>&1); rc=$?
expect_eq "A: --self-test exits 0 (Canary resolves the '| WP-044 |' row)" 0 "$rc"
expect_has "A: the row's status is resolved" "registry_status: 🔄 in_progress" "$out"
expect_lacks "A: no 'not in registry'" "не в реестре" "$out"

issue_registry "$WS/$GOV/docs/WP-REGISTRY.md" "44"
for q in 44 044; do
  out=$(IWE_WORKSPACE="$WS" IWE_GOVERNANCE_REPO="$GOV" bash "$BUNDLE" --self-test "$q" 2>&1); rc=$?
  expect_eq "B: --self-test $q exits 0" 0 "$rc"
  expect_has "B: --self-test $q names the card, not the notes" "lookup: OK ($WS/$GOV/inbox/WP-044/WP-044.md)" "$out"
done

WS=$(new_ws)
issue_registry "$WS/$GOV/docs/WP-REGISTRY.md" "WP-046"
card "$WS/$GOV/inbox/WP-046/WP-046.md" "" in_progress
card "$WS/$GOV/inbox/b-notes.md" 46 notes
for q in 46 046 WP-046; do
  out=$(IWE_WORKSPACE="$WS" IWE_GOVERNANCE_REPO="$GOV" bash "$BUNDLE" "$q" 2>&1); rc=$?
  expect_eq "bundle $q exits 0" 0 "$rc"
  expect_has "bundle $q reads the padded card" "Файл: \`inbox/WP-046/WP-046.md\`" "$out"
done

# ---------------------------------------------------------------------------
echo "--- #954 C: close-wp.sh strikes the row whatever the cell looks like ---"
for arg in 44 WP-044 wp-044; do
  WS=$(new_ws)
  cat > "$WS/$GOV/docs/WP-REGISTRY.md" <<'EOF'
| # | Приоритет | Название | Статус | Репо | Бюджет | Неделя |
|---|-----------|---------|--------|------|--------|--------|
| 440 | P2 | **Neighbour** | 🔄 in_progress | DS-strategy | 3h | W38 |
| WP-044 | P2 | **Demo WP** | 🔄 in_progress | DS-strategy | 3h | W38 |
EOF
  card "$WS/$GOV/inbox/WP-044/WP-044.md" 44 in_progress
  out=$(IWE_ROOT="$WS" IWE_GOVERNANCE_REPO="$GOV" bash "$CLOSE" --wp "$arg" --summary "closed by the test" 2>&1); rc=$?
  expect_eq "close-wp --wp $arg exits 0" 0 "$rc"
  expect_has "close-wp --wp $arg: the '| WP-044 |' row is struck" "| ~~WP-044~~ |" "$(sed -n '4p' "$WS/$GOV/docs/WP-REGISTRY.md")"
  expect_has "close-wp --wp $arg: the neighbour row 440 is untouched" "| 440 | P2 | **Neighbour** |" "$(sed -n '3p' "$WS/$GOV/docs/WP-REGISTRY.md")"
  expect_lacks "close-wp --wp $arg: no 'row not found' warning" "не найдена" "$out"
  if [ -f "$WS/$GOV/archive/wp-contexts/WP-044-demo-wp.md" ]; then
    ok "close-wp --wp $arg: the context file takes its slug from the struck row"
  else
    bad "close-wp --wp $arg: expected archive/wp-contexts/WP-044-demo-wp.md, got: $(ls "$WS/$GOV/archive/wp-contexts")"
  fi
  expect_has "close-wp --wp $arg: card status is done" "status: done" "$(cat "$WS/$GOV/inbox/WP-044/WP-044.md")"
done
WS=$(new_ws)
cat > "$WS/$GOV/docs/WP-REGISTRY.md" <<'EOF'
| # | Приоритет | Название | Статус | Репо | Бюджет | Неделя |
|---|-----------|---------|--------|------|--------|--------|
| 44 | P2 | **Demo WP** | 🔄 in_progress | DS-strategy | 3h | W38 |
EOF
card "$WS/$GOV/inbox/WP-044/WP-044.md" 44 in_progress
IWE_ROOT="$WS" IWE_GOVERNANCE_REPO="$GOV" bash "$CLOSE" --wp 44 --summary "closed by the test" >/dev/null 2>&1
expect_has "close-wp: the canonical bare-number row is still struck" "| ~~44~~ |" "$(sed -n '3p' "$WS/$GOV/docs/WP-REGISTRY.md")"

# ---------------------------------------------------------------------------
echo "--- #954 D: archive-done-wp.sh moves the padded folder and reports failures honestly ---"
for arg in 44 044 WP-044; do
  WS=$(new_ws)
  card "$WS/$GOV/inbox/WP-044/WP-044.md" 44 in_progress
  mkdir -p "$WS/$GOV/inbox/WP-044/data"
  printf 'payload\n' > "$WS/$GOV/inbox/WP-044/data/x.txt"
  out=$(cd "$TMP" && IWE_GOVERNANCE_REPO="$GOV" bash "$ARCHIVE" "$arg" "$WS" 2>&1); rc=$?
  expect_eq "archive-done-wp $arg exits 0" 0 "$rc"
  expect_lacks "archive-done-wp $arg: not mistaken for a flat file" "плоский" "$out"
  if [ -f "$WS/$GOV/archive/wp-contexts/WP-044/WP-044.md" ] && [ -f "$WS/$GOV/archive/wp-contexts/WP-044/data/x.txt" ] && [ ! -e "$WS/$GOV/inbox/WP-044" ]; then
    ok "archive-done-wp $arg: the whole folder moved to archive/wp-contexts/WP-044"
  else
    bad "archive-done-wp $arg: folder not moved. inbox=[$(ls "$WS/$GOV/inbox")] archive=[$(ls "$WS/$GOV/archive/wp-contexts")] out: $out"
  fi
  expect_has "archive-done-wp $arg: card status is done" "status: done" "$(cat "$WS/$GOV/archive/wp-contexts/WP-044/WP-044.md" 2>/dev/null)"
done

WS=$(new_ws)
card "$WS/$GOV/inbox/WP-45/WP-45.md" 45 in_progress   # older unpadded folder keeps its own name
out=$(cd "$TMP" && IWE_GOVERNANCE_REPO="$GOV" bash "$ARCHIVE" 45 "$WS" 2>&1); rc=$?
expect_eq "archive-done-wp 45 (unpadded legacy folder) exits 0" 0 "$rc"
if [ -f "$WS/$GOV/archive/wp-contexts/WP-45/WP-45.md" ] && [ ! -e "$WS/$GOV/inbox/WP-45" ]; then
  ok "archive-done-wp 45: the real folder name is kept"
else
  bad "archive-done-wp 45: folder not moved. out: $out"
fi

WS=$(new_ws)
card "$WS/$GOV/inbox/WP-044/WP-044.md" 44 in_progress
git -C "$WS/$GOV" init -q
git -C "$WS/$GOV" add -A
git -C "$WS/$GOV" -c user.name=test -c user.email=test@example.invalid commit -q -m "stand"
out=$(cd "$TMP" && IWE_GOVERNANCE_REPO="$GOV" bash "$ARCHIVE" 44 "$WS" 2>&1); rc=$?
expect_eq "archive-done-wp 44 in a git repository exits 0" 0 "$rc"
expect_lacks "archive-done-wp 44 in a git repository: plain git mv worked" "git mv -f не удался" "$out"
if [ -f "$WS/$GOV/archive/wp-contexts/WP-044/WP-044.md" ] && [ ! -e "$WS/$GOV/inbox/WP-044" ]; then
  ok "archive-done-wp 44 in a git repository: folder moved"
else
  bad "archive-done-wp 44 in a git repository: folder not moved. out: $out"
fi

# A failed move must be reported as a failure: no success line, non-zero exit, card left in place.
WS=$(new_ws)
card "$WS/$GOV/inbox/WP-044/WP-044.md" 44 in_progress
rmdir "$WS/$GOV/archive/wp-contexts"
: > "$WS/$GOV/archive/wp-contexts"                      # the destination directory cannot be created
out=$(cd "$TMP" && IWE_GOVERNANCE_REPO="$GOV" bash "$ARCHIVE" 44 "$WS" 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then ok "archive-done-wp: a failed move exits non-zero (rc=$rc)"; else bad "archive-done-wp: a failed move exited 0. out: $out"; fi
expect_lacks "archive-done-wp: no success line after a failed move" "✅ WP-" "$out"
expect_has "archive-done-wp: the failure is stated" "❌" "$out"
if [ -d "$WS/$GOV/inbox/WP-044" ]; then ok "archive-done-wp: the card is still in inbox after the failed move"; else bad "archive-done-wp: the card disappeared from inbox"; fi

# ---------------------------------------------------------------------------
echo "--- #954 D: check-wp-transfer-completeness.sh and wp-phase-digest.sh use the same lookup ---"
WS=$(new_ws)
mkdir -p "$WS/$GOV/inbox/WP-044"
printf -- '---\nwp: 44\nstatus: done\nresults_in:\n---\n# WP-044\n' > "$WS/$GOV/inbox/WP-044/WP-044.md"
for arg in 44 044 WP-044; do
  out=$(IWE_GOVERNANCE_REPO="$GOV" bash "$TRANSFER" "$arg" --dry-run "$WS" 2>&1); rc=$?
  expect_eq "transfer check $arg exits 0" 0 "$rc"
  expect_lacks "transfer check $arg finds the padded card" "не найден" "$out"
  expect_has "transfer check $arg inspects it" "WP-044: warn results_in пусто" "$out"
done
out=$(IWE_GOVERNANCE_REPO="$GOV" bash "$TRANSFER" --all --dry-run "$WS" 2>&1)
expect_has "transfer check --all still walks the padded folder" "WP-044: warn results_in пусто" "$out"

WS=$(new_ws)
mkdir -p "$WS/$GOV/inbox/WP-046"
printf -- '---\nstatus: in_progress\n---\n- [ ] one\n- [x] two\n' > "$WS/$GOV/inbox/WP-046/WP-046.md"
printf -- '---\nwp: 46\n---\n# notes\n' > "$WS/$GOV/inbox/b-notes.md"
for arg in 46 046 WP-046; do
  out=$(IWE_WORKSPACE="$WS" IWE_GOVERNANCE_REPO="$GOV" bash "$DIGEST" "$arg" 2>&1); rc=$?
  expect_eq "phase digest $arg exits 0" 0 "$rc"
  expect_has "phase digest $arg reads the card, not the notes" "status=in_progress" "$out"
  expect_has "phase digest $arg counts both checkboxes" "phase_count=2" "$out"
done

# ---------------------------------------------------------------------------
echo "--- library lookup: from the code's own location, never from the data root ---"
SCRIPTS_USED="close-wp.sh archive-done-wp.sh check-wp-transfer-completeness.sh wp-list.py"
install_code() {  # <layout-root> <with-lib: yes|no> [lib-root-relative-dir]
  local root="$1" libdir="${3:-scripts/lib}" f
  mkdir -p "$root/.claude/scripts" "$root/scripts"
  cp "$BUNDLE" "$DIGEST" "$root/.claude/scripts/"
  for f in $SCRIPTS_USED; do cp "$ROOT/scripts/$f" "$root/scripts/"; done
  if [ "$2" = yes ]; then
    mkdir -p "$root/$libdir"
    cp "$LIB" "$root/$libdir/wp-num.sh"
  fi
}
smoke_consumers() {  # <label> <layout-root> <extra env assignments...>: every consumer finds the library and works
  local label="$1" root="$2" ws out rc
  shift 2
  ws=$(new_ws)
  issue_registry "$ws/$GOV/docs/WP-REGISTRY.md" "WP-044"
  card "$ws/$GOV/inbox/WP-044/WP-044.md" 44 in_progress
  out=$(env -i PATH="$PATH" HOME="$HOME" TMPDIR="$TMPDIR" "$@" IWE_WORKSPACE="$ws" IWE_GOVERNANCE_REPO="$GOV" bash "$root/.claude/scripts/wp-sync-bundle.sh" --self-test 2>&1); rc=$?
  if [ "$rc" -eq 0 ] && [[ "$out" == *"lookup: OK ($ws/$GOV/inbox/WP-044/WP-044.md)"* ]]; then ok "$label: wp-sync-bundle.sh finds the library"; else bad "$label: wp-sync-bundle.sh (rc=$rc): $out"; fi
  out=$(env -i PATH="$PATH" HOME="$HOME" TMPDIR="$TMPDIR" "$@" IWE_WORKSPACE="$ws" IWE_GOVERNANCE_REPO="$GOV" bash "$root/.claude/scripts/wp-phase-digest.sh" 44 2>&1); rc=$?
  if [ "$rc" -eq 0 ] && [[ "$out" == *"status=in_progress"* ]]; then ok "$label: wp-phase-digest.sh finds the library"; else bad "$label: wp-phase-digest.sh (rc=$rc): $out"; fi
  out=$(env -i PATH="$PATH" HOME="$HOME" TMPDIR="$TMPDIR" "$@" IWE_GOVERNANCE_REPO="$GOV" bash "$root/scripts/check-wp-transfer-completeness.sh" 44 --dry-run "$ws" 2>&1); rc=$?
  if [ "$rc" -eq 0 ] && [[ "$out" != *"не найден"* ]]; then ok "$label: check-wp-transfer-completeness.sh finds the library"; else bad "$label: check-wp-transfer-completeness.sh (rc=$rc): $out"; fi
  out=$(env -i PATH="$PATH" HOME="$HOME" TMPDIR="$TMPDIR" "$@" IWE_ROOT="$ws" IWE_GOVERNANCE_REPO="$GOV" bash "$root/scripts/close-wp.sh" --wp 44 --summary "layout smoke" 2>&1); rc=$?
  if [ "$rc" -eq 0 ] && [[ "$(sed -n '3p' "$ws/$GOV/docs/WP-REGISTRY.md")" == "| ~~WP-044~~ |"* ]]; then ok "$label: close-wp.sh finds the library"; else bad "$label: close-wp.sh (rc=$rc): $out"; fi
  card "$ws/$GOV/inbox/WP-044/WP-044.md" 44 in_progress
  out=$(cd "$TMP" && env -i PATH="$PATH" HOME="$HOME" TMPDIR="$TMPDIR" "$@" IWE_GOVERNANCE_REPO="$GOV" bash "$root/scripts/archive-done-wp.sh" 44 "$ws" 2>&1); rc=$?
  if [ "$rc" -eq 0 ] && [ -f "$ws/$GOV/archive/wp-contexts/WP-044/WP-044.md" ]; then ok "$label: archive-done-wp.sh finds the library"; else bad "$label: archive-done-wp.sh (rc=$rc): $out"; fi
}

L1="$TMP/layout-checkout"
install_code "$L1" yes
smoke_consumers "layout 1 (repository checkout: <root>/scripts/lib)" "$L1"

L2="$TMP/layout-workspace"
install_code "$L2" no
mkdir -p "$L2/FMT-exocortex-template/scripts/lib"
cp "$LIB" "$L2/FMT-exocortex-template/scripts/lib/wp-num.sh"
smoke_consumers "layout 2 (workspace scripts without lib, template clone next to them)" "$L2"

L3="$TMP/layout-explicit-template"
install_code "$L3" no
T3="$TMP/template-elsewhere"
mkdir -p "$T3/scripts/lib"
cp "$LIB" "$T3/scripts/lib/wp-num.sh"
smoke_consumers "layout 3 (library only under IWE_TEMPLATE)" "$L3" "IWE_TEMPLATE=$T3"

# The data root is substituted by fixtures. A copy of the library lying in the data root
# must NOT be picked up in place of the one next to the code.
L4="$TMP/layout-decoy"
install_code "$L4" yes
smoke_decoy() {
  local ws out rc decoy_root
  ws=$(new_ws)
  decoy_root="$ws/scripts/lib"
  mkdir -p "$decoy_root"
  printf 'wp_num_normalize() { echo 9999; }\nwp_num_find_card() { echo /decoy/path; }\n' > "$decoy_root/wp-num.sh"
  mkdir -p "$ws/FMT-exocortex-template/scripts/lib"
  cp "$decoy_root/wp-num.sh" "$ws/FMT-exocortex-template/scripts/lib/wp-num.sh"
  issue_registry "$ws/$GOV/docs/WP-REGISTRY.md" "WP-044"
  card "$ws/$GOV/inbox/WP-044/WP-044.md" 44 in_progress
  out=$(env -i PATH="$PATH" HOME="$HOME" TMPDIR="$TMPDIR" IWE_TEMPLATE="$ws" IWE_WORKSPACE="$ws" IWE_ROOT="$ws" IWE_GOVERNANCE_REPO="$GOV" bash "$L4/.claude/scripts/wp-sync-bundle.sh" --self-test 2>&1); rc=$?
  if [ "$rc" -eq 0 ] && [[ "$out" == *"lookup: OK ($ws/$GOV/inbox/WP-044/WP-044.md)"* ]] && [[ "$out" != *decoy* ]]; then
    ok "layout 4 (data root with a decoy library): the library next to the code wins"
  else
    bad "layout 4: the decoy in the data root influenced the run (rc=$rc): $out"
  fi
}
smoke_decoy

# No library anywhere: a plain message naming the file and a non-zero exit, for every consumer.
L5="$TMP/layout-no-lib"
install_code "$L5" no
ws5=$(new_ws)
issue_registry "$ws5/$GOV/docs/WP-REGISTRY.md" "WP-044"
card "$ws5/$GOV/inbox/WP-044/WP-044.md" 44 in_progress
for entry in ".claude/scripts/wp-sync-bundle.sh --self-test" ".claude/scripts/wp-phase-digest.sh 44" "scripts/check-wp-transfer-completeness.sh 44" "scripts/close-wp.sh --wp 44 --summary x" "scripts/archive-done-wp.sh 44"; do
  script="${entry%% *}"
  args="${entry#"$script"}"
  # shellcheck disable=SC2086  # $args is a short fixed word list from this file
  out=$(cd "$TMP" && env -i PATH="$PATH" HOME="$HOME" TMPDIR="$TMPDIR" IWE_TEMPLATE="$TMP/does-not-exist" IWE_WORKSPACE="$ws5" IWE_ROOT="$ws5" IWE_GOVERNANCE_REPO="$GOV" bash "$L5/$script" $args 2>&1); rc=$?
  if [ "$rc" -ne 0 ] && [[ "$out" == *wp-num.sh* ]]; then
    ok "no library: $script stops with a message naming wp-num.sh (rc=$rc)"
  else
    bad "no library: $script (rc=$rc) must stop and name wp-num.sh, got: $out"
  fi
done
if [ -d "$ws5/$GOV/inbox/WP-044" ]; then ok "no library: nothing was moved or changed"; else bad "no library: the card folder was touched"; fi

# ---------------------------------------------------------------------------
echo "--- the same python driver: wp-list.py is covered by test_issue_954_wp_list_keys.py ---"
if [ -f "$WPLIST" ]; then ok "wp-list.py present (keys are checked by the pytest file)"; else bad "wp-list.py missing"; fi

echo
if [ "$FAILS" -eq 0 ]; then
  echo "✅ test_issue_954_wp_number_forms: $PASSES checks passed"
  exit 0
fi
echo "❌ test_issue_954_wp_number_forms: $FAILS failed, $PASSES passed" >&2
exit 1
