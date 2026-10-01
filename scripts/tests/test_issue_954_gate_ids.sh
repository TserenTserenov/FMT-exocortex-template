#!/usr/bin/env bash
# Regression for issue #954 (session-guard half): the WP-518 hypothesis gate looked the card
# up by the id exactly as typed (inbox/<id>/<id>.md), so `open --wp 44`, `--wp 044` and
# `--wp WP-44` walked past it and opened a session on a card still marked
# `hypothesis_relation: unclassified`; only the one spelling that happens to equal the folder
# name (`WP-044`) was blocked. The card must be found by the NORMALISED number, whatever form
# the caller typed. Every blocking check also demands the gate's own message, so a session
# that fails for some other reason cannot pass for a blocked one.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/gate-ids-954.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/home" "$TMP/tmp"
export HOME="$TMP/home" TMPDIR="$TMP/tmp"
unset IWE_ROOT IWE_WORKSPACE IWE_GOVERNANCE_REPO IWE_TEMPLATE IWE_SCRIPTS IWE_SESSIONS_ROOT

GUARD="$ROOT/scripts/session-guard.sh"
GOV=DS-strategy
PASSES=0
FAILS=0
ok()  { echo "  ✅ PASS: $*"; PASSES=$((PASSES + 1)); }
bad() { echo "  ❌ FAIL: $*" >&2; FAILS=$((FAILS + 1)); }

new_ws() {  # a workspace whose governance repo is a git repository; prints its path
  local d
  d=$(mktemp -d "$TMP/ws.XXXXXX")
  mkdir -p "$d/$GOV/inbox"
  git -C "$d/$GOV" init -q
  git -C "$d/$GOV" config user.name "Gate Test"
  git -C "$d/$GOV" config user.email "gate-test@example.invalid"
  printf '%s\n' "$d"
}

open_session() {  # <workspace> <wp as typed>; prints stdout+stderr, returns the exit code
  IWE_ROOT="$1" IWE_GOVERNANCE_REPO="$GOV" bash "$GUARD" open --wp "$2" --agent kimi \
    --slug gate-ids --session-id gate-ids --owner-pid "$$" --close-path peer-session 2>&1
}

check_forms() {  # <card path under inbox> <relation> <expect: blocked|open> <forms...>
  local card="$1" relation="$2" expect="$3" form ws out rc
  shift 3
  for form in "$@"; do
    ws=$(new_ws)
    mkdir -p "$(dirname "$ws/$GOV/inbox/$card")"
    printf -- '---\nwp: 44\nhypothesis_relation: "%s"\n---\n# card\n' "$relation" > "$ws/$GOV/inbox/$card"
    out=$(open_session "$ws" "$form"); rc=$?
    if [ "$expect" = blocked ]; then
      if [ "$rc" -ne 0 ] && [[ "$out" == *"не классифицирована по гипотезе"* ]]; then
        ok "--wp $form on $card (unclassified): blocked by the gate"
      else
        bad "--wp $form on $card (unclassified) must be blocked by the gate (rc=$rc): $out"
      fi
    else
      if [ "$rc" -eq 0 ] && [ -f "$ws/.iwe-runtime/sessions/kimi-gate-ids.open" ]; then
        ok "--wp $form on $card ($relation): opens"
      else
        bad "--wp $form on $card ($relation) must open (rc=$rc): $out"
      fi
    fi
  done
}

echo "--- unclassified card in the canonical padded folder: every spelling is blocked ---"
check_forms "WP-044/WP-044.md" unclassified blocked WP-044 44 044 WP-44 wp-044

echo "--- unclassified card in an older unpadded folder: every spelling is blocked ---"
check_forms "WP-45/WP-45.md" unclassified blocked WP-45 45 045 WP-045

echo "--- unclassified flat legacy card: every spelling is blocked ---"
check_forms "WP-046.md" unclassified blocked WP-046 46 046 WP-46

echo "--- the same cards once classified: every spelling opens (the block is not a side effect of the form) ---"
check_forms "WP-044/WP-044.md" tests open WP-044 44 044 WP-44
check_forms "WP-45/WP-45.md" operational open 45 045

echo "--- an id that is not a number keeps the old exact-id lookup ---"
ws=$(new_ws)
mkdir -p "$ws/$GOV/inbox/WP-X"
printf -- '---\nhypothesis_relation: "unclassified"\n---\n' > "$ws/$GOV/inbox/WP-X/WP-X.md"
out=$(open_session "$ws" WP-X); rc=$?
if [ "$rc" -ne 0 ] && [[ "$out" == *"не классифицирована по гипотезе"* ]]; then
  ok "--wp WP-X: still blocked by the exact-id lookup"
else
  bad "--wp WP-X must still be blocked (rc=$rc): $out"
fi

put() {  # <workspace> <path under inbox> <wp: field or ""> <hypothesis_relation or "">
  local f="$1/$GOV/inbox/$2"
  mkdir -p "$(dirname "$f")"
  {
    printf -- '---\n'
    [ -z "$3" ] || printf 'wp: %s\n' "$3"
    [ -z "$4" ] || printf 'hypothesis_relation: "%s"\n' "$4"
    printf -- '---\n# file\n'
  } > "$f"
}

expect_gate() {  # <description> <workspace> <wp as typed> <blocked|open>
  local out rc
  out=$(open_session "$2" "$3"); rc=$?
  if [ "$4" = blocked ]; then
    if [ "$rc" -ne 0 ] && [[ "$out" == *"не классифицирована по гипотезе"* ]]; then ok "$1"; else bad "$1: must be blocked by the gate (rc=$rc): $out"; fi
  else
    if [ "$rc" -eq 0 ] && [ -f "$2/.iwe-runtime/sessions/kimi-gate-ids.open" ]; then ok "$1"; else bad "$1: must open (rc=$rc): $out"; fi
  fi
}

echo "--- the card is judged by its own file: a note that merely carries 'wp: 46' neither hides it nor blocks ---"
for form in WP-046 46 046 WP-46; do
  ws=$(new_ws)
  put "$ws" "WP-046.md" "" unclassified            # the card: no wp: field, so the grep fallback cannot see it
  put "$ws" "h-notes.md" 46 ""                      # a note about the same WP
  expect_gate "--wp $form: flat unclassified card + a note with 'wp: 46' -> blocked" "$ws" "$form" blocked
done
for form in WP-046 46; do
  ws=$(new_ws)
  put "$ws" "h-notes.md" 46 unclassified            # no card at all; the note even carries the field
  expect_gate "--wp $form: only a note (never a card) -> opens" "$ws" "$form" open
done

echo "--- every place the card is written counts: any unclassified candidate blocks ---"
for form in WP-044 44; do
  ws=$(new_ws)
  put "$ws" "WP-044/WP-044.md" 44 tests             # classified folder card ...
  put "$ws" "WP-044.md" 44 unclassified             # ... and a stale flat duplicate that is not
  expect_gate "--wp $form: classified folder card + unclassified flat duplicate -> blocked" "$ws" "$form" blocked
done

echo "--- a flat card with a slug (WP-044-task.md) is a card: the library and wp-list.py read it, so does the gate ---"
for form in WP-044 44 044 WP-44 wp-044; do
  ws=$(new_ws)
  put "$ws" "WP-044-task.md" "" unclassified        # the only card of the WP, flat, with a slug
  expect_gate "--wp $form: the only card is flat with a slug and unclassified -> blocked" "$ws" "$form" blocked
done
ws=$(new_ws)
put "$ws" "WP-044-task.md" "" tests
expect_gate "--wp 44: the same flat card with a slug, classified -> opens" "$ws" 44 open
ws=$(new_ws)
put "$ws" "WP-44-old-slug.md" "" unclassified       # the older, unpadded spelling with a slug
expect_gate "--wp 44: an unpadded flat card with a slug (WP-44-old-slug.md), unclassified -> blocked" "$ws" 44 blocked
ws=$(new_ws)
put "$ws" "WP-440-other.md" "" unclassified         # the neighbour 440 is not WP 44
put "$ws" "WP-0440.md" "" unclassified
expect_gate "--wp 44: unclassified cards of 440 and 0440 are other WPs -> opens" "$ws" 44 open

# ---------------------------------------------------------------------------
# The shared reader is found the way the other consumers find it: from the real file's location
# (symlinks followed), the sibling template clone, IWE_TEMPLATE. A copy of the guard without
# lib/wp-num.sh next to it used to load nothing and fall back to the exact names silently.
WARN="wp-num.sh не найдена: гейт гипотезы проверяет только точные имена карточек"

open_with() {  # <guard script> <workspace> <wp as typed> [VAR=value ...]: open --wp with any copy of the guard
  local guard="$1" ws="$2" wp="$3"
  shift 3
  env IWE_ROOT="$ws" IWE_GOVERNANCE_REPO="$GOV" "$@" bash "$guard" open --wp "$wp" --agent kimi \
    --slug gate-ids --session-id gate-ids --owner-pid "$$" --close-path peer-session 2>&1
}

expect_gate_with() {  # <description> <blocked|open> <guard> <workspace> <wp as typed> [VAR=value ...]; keeps the output in LAST_OUT
  local desc="$1" want="$2" guard="$3" ws="$4" wp="$5" rc
  shift 5
  LAST_OUT=$(open_with "$guard" "$ws" "$wp" "$@"); rc=$?
  if [ "$want" = blocked ]; then
    if [ "$rc" -ne 0 ] && [[ "$LAST_OUT" == *"не классифицирована по гипотезе"* ]]; then ok "$desc"; else bad "$desc: must be blocked by the gate (rc=$rc): $LAST_OUT"; fi
  else
    if [ "$rc" -eq 0 ] && [ -f "$ws/.iwe-runtime/sessions/kimi-gate-ids.open" ]; then ok "$desc"; else bad "$desc: must open (rc=$rc): $LAST_OUT"; fi
  fi
}

expect_warnings() {  # <description> <expected count of the missing-library warning in LAST_OUT>
  local n
  n=$(grep -c -F -- "$WARN" <<<"$LAST_OUT")
  if [ "$n" = "$2" ]; then ok "$1"; else bad "$1: expected $2 warning line(s), got $n: $LAST_OUT"; fi
}

echo "--- a copy of the guard with no lib/wp-num.sh next to it finds the library through IWE_TEMPLATE ---"
TEMPLATE="$TMP/template"
mkdir -p "$TEMPLATE/scripts/lib" "$TMP/copy/scripts"
cp "$ROOT/scripts/lib/wp-num.sh" "$TEMPLATE/scripts/lib/wp-num.sh"
COPY_GUARD="$TMP/copy/scripts/session-guard.sh"
cp "$GUARD" "$COPY_GUARD"
for form in 44 wp-044 WP-044; do
  ws=$(new_ws)
  put "$ws" "WP-044/WP-044.md" 44 unclassified     # the canonical card: only the library can reach it from "44"
  expect_gate_with "copy + IWE_TEMPLATE, --wp $form: canonical unclassified card -> blocked" blocked "$COPY_GUARD" "$ws" "$form" IWE_TEMPLATE="$TEMPLATE"
  expect_warnings "copy + IWE_TEMPLATE, --wp $form: no missing-library warning" 0
done

card_ws() {  # <relation>: a fresh workspace holding the canonical card of WP-044 with that relation; prints its path
  local d
  d=$(new_ws)
  put "$d" "WP-044/WP-044.md" 44 "$1"
  printf '%s\n' "$d"
}

echo "--- a symlink to the guard: the library is looked for next to the REAL file, then in the usual places ---"
mkdir -p "$TMP/lnk"
ln -s "$GUARD" "$TMP/lnk/guard-a.sh"                # the real file has lib/wp-num.sh next to it
ln -s guard-a.sh "$TMP/lnk/guard-b.sh"             # a second hop, relative
ln -s "$COPY_GUARD" "$TMP/lnk/guard-c.sh"          # the real file has no library next to it ...
for link in guard-a.sh guard-b.sh; do
  ws=$(card_ws unclassified)
  expect_gate_with "symlink $link (real file with its library), --wp 44: blocked" blocked "$TMP/lnk/$link" "$ws" 44
  expect_warnings "symlink $link: no missing-library warning" 0
done
ws=$(card_ws unclassified)
expect_gate_with "symlink to a copy with no library + IWE_TEMPLATE, --wp 44: blocked" blocked "$TMP/lnk/guard-c.sh" "$ws" 44 IWE_TEMPLATE="$TEMPLATE"
expect_warnings "symlink to a copy + IWE_TEMPLATE: no missing-library warning" 0

echo "--- the template clone next to the workspace is found without any variable ---"
SIBLING="$TMP/sibling-ws"
mkdir -p "$SIBLING/scripts" "$SIBLING/FMT-exocortex-template/scripts/lib"
cp "$GUARD" "$SIBLING/scripts/session-guard.sh"
cp "$ROOT/scripts/lib/wp-num.sh" "$SIBLING/FMT-exocortex-template/scripts/lib/wp-num.sh"
ws=$(card_ws unclassified)
expect_gate_with "workspace copy + sibling FMT-exocortex-template, --wp 44: blocked" blocked "$SIBLING/scripts/session-guard.sh" "$ws" 44
ln -s "$SIBLING/scripts/session-guard.sh" "$TMP/lnk/guard-d.sh"
ws=$(card_ws unclassified)
expect_gate_with "symlink to that workspace copy (its sibling clone is found from the real file), --wp 44: blocked" blocked "$TMP/lnk/guard-d.sh" "$ws" 44

echo "--- no library anywhere: the session still opens on the exact names, and the gate says it checks less ---"
mkdir -p "$TMP/empty-template"
ws=$(card_ws unclassified)
expect_gate_with "no library, --wp 44: the card is reachable only through the number -> opens" open "$COPY_GUARD" "$ws" 44
expect_warnings "no library, --wp 44: the warning is printed once" 1
ws=$(card_ws unclassified)
expect_gate_with "IWE_TEMPLATE without the library, --wp 44: opens" open "$COPY_GUARD" "$ws" 44 IWE_TEMPLATE="$TMP/empty-template"
expect_warnings "IWE_TEMPLATE without the library: the warning is printed once" 1
ws=$(card_ws unclassified)
expect_gate_with "no library, --wp WP-044: the exact name still blocks" blocked "$COPY_GUARD" "$ws" WP-044
expect_warnings "no library, --wp WP-044: the warning is printed once" 1
ws=$(card_ws tests)
expect_gate_with "library present (the guard in the repository), classified card -> opens" open "$GUARD" "$ws" 44
expect_warnings "library present: no warning" 0

# ---------------------------------------------------------------------------
# The field is read from the card's own frontmatter: grep over the whole file let a trailing
# comment hide `unclassified` and let a YAML example in the body fake it.
check_field() {  # <description> <blocked|open> <card text>
  local ws
  ws=$(new_ws)
  mkdir -p "$ws/$GOV/inbox/WP-044"
  printf '%s' "$3" > "$ws/$GOV/inbox/WP-044/WP-044.md"
  expect_gate "$1" "$ws" 44 "$2"
}

echo "--- the value is a single-line plain or quoted scalar (a subset of YAML): a quoted one is taken whole, only a comment may follow its closing quote ---"
check_field "bare value -> blocked" blocked $'---\nwp: 44\nhypothesis_relation: unclassified\n---\n# card\n'
check_field "double-quoted value (what create-wp.sh writes) -> blocked" blocked $'---\nwp: 44\nhypothesis_relation: "unclassified"\n---\n# card\n'
check_field "single-quoted value -> blocked" blocked $'---\nwp: 44\nhypothesis_relation: \'unclassified\'\n---\n# card\n'
check_field "bare value + trailing comment -> blocked" blocked $'---\nwp: 44\nhypothesis_relation: unclassified # выбрать позже\n---\n# card\n'
check_field "double-quoted value + trailing comment -> blocked" blocked $'---\nwp: 44\nhypothesis_relation: "unclassified"   # pick later\n---\n# card\n'
check_field "single-quoted value + trailing comment -> blocked" blocked $'---\nwp: 44\nhypothesis_relation: \'unclassified\'   # pick later\n---\n# card\n'
check_field "CRLF line endings -> blocked" blocked $'---\r\nwp: 44\r\nhypothesis_relation: "unclassified"\r\n---\r\n# card\r\n'
check_field "a # inside double quotes belongs to the value (\"unclassified # example\") -> opens" open $'---\nwp: 44\nhypothesis_relation: "unclassified # example"\n---\n# card\n'
check_field "a # inside single quotes belongs to the value ('unclassified # example') -> opens" open $'---\nwp: 44\nhypothesis_relation: \'unclassified # example\'\n---\n# card\n'
check_field "an unterminated quote is not stripped on its own (\"unclassified) -> opens" open $'---\nwp: 44\nhypothesis_relation: "unclassified\n---\n# card\n'
check_field "a stray closing quote is not stripped on its own (unclassified\") -> opens" open $'---\nwp: 44\nhypothesis_relation: unclassified"\n---\n# card\n'
check_field "text after the closing quote that is not a comment -> opens" open $'---\nwp: 44\nhypothesis_relation: "unclassified"x\n---\n# card\n'
check_field "a value that only starts with the word -> opens" open $'---\nwp: 44\nhypothesis_relation: unclassified-ish\n---\n# card\n'
check_field "a chosen value + trailing comment -> opens" open $'---\nwp: 44\nhypothesis_relation: tests  # chosen\n---\n# card\n'
# What the subset does NOT do is written in the comment of card_is_unclassified; pinned here so that
# the comment keeps telling the truth.
check_field "documented limit: an escape sequence is not decoded (\"unclassifi\\u0065d\" stays literal) -> opens" open $'---\nwp: 44\nhypothesis_relation: "unclassifi\\u0065d"\n---\n# card\n'
check_field "documented limit: a multi-line plain scalar is judged by its first line (unclassified + a continuation line) -> blocked" blocked $'---\nwp: 44\nhypothesis_relation: unclassified\n  example\n---\n# card\n'

echo "--- where the field is looked for: the first NON-EMPTY line --- makes a frontmatter, and only the frontmatter is read ---"
check_field "frontmatter says operational, a YAML example in the body says unclassified -> opens" open $'---\nwp: 44\nhypothesis_relation: operational\n---\n# card\n\nExample:\n\n```yaml\nhypothesis_relation: unclassified\n```\n'
check_field "frontmatter says tests, a second --- block in the body says unclassified -> opens" open $'---\nwp: 44\nhypothesis_relation: "tests"\n---\n# card\n\n---\nhypothesis_relation: unclassified\n---\n'
check_field "no such field in the frontmatter, an example in the body -> opens (an absent field is not blocked)" open $'---\nwp: 44\nstatus: pending\n---\n# card\n\nhypothesis_relation: unclassified\n'
check_field "a UTF-8 BOM before the first --- does not hide the frontmatter (operational + an example in the body) -> opens" open $'\xEF\xBB\xBF---\nwp: 44\nhypothesis_relation: operational\n---\n# card\n\nhypothesis_relation: unclassified\n'
check_field "a UTF-8 BOM before the first --- (the frontmatter says unclassified) -> blocked" blocked $'\xEF\xBB\xBF---\nwp: 44\nhypothesis_relation: "unclassified"\n---\n# card\n'
check_field "a blank first line, a frontmatter that says independent, a fenced example with unclassified in the body -> opens" open $'\n---\nhypothesis_relation: independent\n---\nПример:\n```yaml\nhypothesis_relation: unclassified\n```\n'
check_field "blank lines before the frontmatter (the frontmatter says tests, a bare example line below it) -> opens" open $'\n\n  \n---\nhypothesis_relation: tests\n---\nhypothesis_relation: unclassified\n'
check_field "blank lines before the frontmatter (the frontmatter says unclassified) -> blocked" blocked $'\n\n---\nhypothesis_relation: "unclassified"\n---\n# card\n'
check_field "CRLF: a blank first line, then a frontmatter that says unclassified -> blocked" blocked $'\r\n---\r\nhypothesis_relation: unclassified\r\n---\r\n'
check_field "CRLF: a blank first line, a frontmatter that says operational, an example below -> opens" open $'\r\n---\r\nhypothesis_relation: operational\r\n---\r\nhypothesis_relation: unclassified\r\n'
check_field "a BOM, a blank line, then the frontmatter that says unclassified -> blocked" blocked $'\xEF\xBB\xBF\n---\nhypothesis_relation: unclassified\n---\n'

echo "--- no frontmatter: only the initial block of key: value lines is read, never the rest of the document ---"
check_field "a file of one line, the field only (the WP-518 fixture) -> blocked" blocked $'hypothesis_relation: "unclassified"\n'
check_field "the same line without the final newline -> blocked" blocked 'hypothesis_relation: "unclassified"'
check_field "key: value lines, the field among them -> blocked" blocked $'wp: 44\nstatus: pending\nhypothesis_relation: unclassified\nbudget: 3h\n'
check_field "blank lines, then key: value lines with the field -> blocked" blocked $'\n\nwp: 44\nhypothesis_relation: unclassified\n'
check_field "a BOM, then key: value lines with the field -> blocked" blocked $'\xEF\xBB\xBFwp: 44\nhypothesis_relation: unclassified\n'
check_field "CRLF key: value lines with the field -> blocked" blocked $'wp: 44\r\nhypothesis_relation: unclassified\r\n'
check_field "no space after the colon (hypothesis_relation:\"unclassified\", what the old gate also recognised) -> blocked" blocked $'hypothesis_relation:"unclassified"\n'
check_field "key: value lines with a chosen value -> opens" open $'wp: 44\nhypothesis_relation: tests\n'
check_field "a quoted # belongs to the value here too -> opens" open $'wp: 44\nhypothesis_relation: "unclassified # example"\n'
check_field "the field after a Markdown heading -> opens" open $'# Карточка\nhypothesis_relation: unclassified\n'
check_field "a heading, then a --- block with the field: the delimiter is not the first line, the block is body -> opens" open $'# Карточка\n---\nhypothesis_relation: unclassified\n---\n'
check_field "a heading, a prose line, then the field -> opens" open $'# Карточка\nПример:\nhypothesis_relation: unclassified\n'
check_field "the field after a blank line -> opens" open $'wp: 44\n\nhypothesis_relation: unclassified\n'
check_field "the field after a prose line -> opens" open $'Описание карточки\nhypothesis_relation: unclassified\n'
check_field "key: value lines, then a heading, then the field -> opens" open $'wp: 44\n# Title\nhypothesis_relation: unclassified\n'
check_field "the field only inside a backtick fence below key: value lines -> opens" open $'wp: 44\n```yaml\nhypothesis_relation: unclassified\n```\n'
check_field "the field only inside a tilde fence below a heading -> opens" open $'# Card\n\n~~~yaml\nhypothesis_relation: unclassified\n~~~\n'
check_field "a file that starts with a fence -> opens" open $'```yaml\nhypothesis_relation: unclassified\n```\n'
check_field "a --- line that is not the first line, the field below it -> opens" open $'wp: 44\n---\nhypothesis_relation: unclassified\n'
check_field "an empty card file -> opens (nothing to read is not a block, and not a crash under set -u)" open ''

echo
if [ "$FAILS" -eq 0 ]; then
  echo "✅ test_issue_954_gate_ids: $PASSES checks passed"
  exit 0
fi
echo "❌ test_issue_954_gate_ids: $FAILS failed, $PASSES passed" >&2
exit 1
