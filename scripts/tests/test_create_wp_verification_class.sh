#!/usr/bin/env bash
# Regression test for the structural-hole fix (protocol-open.md Шаг 4.5 /
# create-wp.sh): 18 of 20 audited WPs that needed a staged plan (/decompose)
# never got one, because create-wp.sh had no --verification-class flag at
# all and could not know whether the WP qualified. This test locks down the
# fix: the flag is mandatory, and open-loop/problem-framing WPs with budget
# ≥3h get a visible, persistent checklist reminder in the generated context
# file's «Осталось» section (create-wp.sh is deterministic=true and cannot
# call the non-deterministic /decompose skill itself).

set -euo pipefail

# Template root comes from this file's own location, never from $HOME (CI checks
# the repository out elsewhere); HOME and TMPDIR stay inside the test's temp dir.
TEMPLATE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
export TMPDIR
export HOME="$TMPDIR/home"
mkdir -p "$HOME"

cp -R "$TEMPLATE_ROOT/seed/strategy" "$TMPDIR/strategy"
export IWE_ROOT="$TMPDIR"
export IWE_GOVERNANCE_REPO="strategy"

CREATE_WP="$TEMPLATE_ROOT/scripts/create-wp.sh"
REMINDER="Запустить /decompose — план по этапам"
# --no-artifactor-check on every call: the Artifactor Gate runs before the
# verification-class gate (covered by test_create_wp_artifactor_gate.sh), so the
# negative scenarios below would otherwise be refused by the wrong gate.

run_and_get_wp_file() {
  # $1=title $2=budget $3=class ; remaining args passed through
  local title="$1" budget="$2" class="$3"
  shift 3
  local out
  out=$(bash "$CREATE_WP" --title "$title" --budget "$budget" --priority P3 \
    --verification-class "$class" --no-consent-check --no-artifactor-check "$@" 2>&1) || {
    echo "FAIL: create-wp.sh rejected a valid call ($title)" >&2
    echo "$out" >&2
    exit 1
  }
  find "$TMPDIR/strategy/inbox" -maxdepth 1 -type d -name 'WP-*' | sort | tail -1
}

# --- Scenario 1: trivial, budget well above 3h → no reminder (class gates it, not budget alone) ---
wp_dir=$(run_and_get_wp_file "Тривиальный крупный" "8h" "trivial")
grep -q "verification_class: trivial" "$wp_dir"/WP-*.md ||
  { echo "FAIL: verification_class not written to frontmatter" >&2; exit 1; }
grep -q "$REMINDER" "$wp_dir"/WP-*.md &&
  { echo "FAIL: trivial WP got the /decompose reminder" >&2; exit 1; }

# --- Scenario 2: closed-loop, budget above 3h → still no reminder (method is known) ---
wp_dir=$(run_and_get_wp_file "Закрытый цикл крупный" "5h" "closed-loop")
grep -q "$REMINDER" "$wp_dir"/WP-*.md &&
  { echo "FAIL: closed-loop WP got the /decompose reminder" >&2; exit 1; }

# --- Scenario 3: open-loop, budget <3h → no reminder (too small to force decomposition) ---
wp_dir=$(run_and_get_wp_file "Открытый маленький" "2h" "open-loop")
grep -q "$REMINDER" "$wp_dir"/WP-*.md &&
  { echo "FAIL: open-loop <3h WP got the /decompose reminder" >&2; exit 1; }

# --- Scenario 4: open-loop, budget ≥3h (exact 3h) → reminder present ---
wp_dir=$(run_and_get_wp_file "Открытый на границе" "3h" "open-loop")
grep -q "$REMINDER" "$wp_dir"/WP-*.md ||
  { echo "FAIL: open-loop 3h WP missing the /decompose reminder" >&2; exit 1; }

# --- Scenario 5: problem-framing, budget as a range whose upper bound is ≥3h → reminder present ---
wp_dir=$(run_and_get_wp_file "Проблемная рамка диапазон" "2-4h" "problem-framing")
grep -q "$REMINDER" "$wp_dir"/WP-*.md ||
  { echo "FAIL: problem-framing 2-4h (upper bound 4 >= 3) WP missing the /decompose reminder" >&2; exit 1; }

# --- Scenario 6: missing --verification-class → hard refusal, no silent WP ---
before=$(find "$TMPDIR/strategy/inbox" -maxdepth 1 -type d -name 'WP-*' | wc -l | tr -d ' ')
set +e
out=$(bash "$CREATE_WP" --title "Без класса" --budget "5h" --priority P3 --no-consent-check --no-artifactor-check 2>&1)
rc=$?
set -e
[ "$rc" -ne 0 ] ||
  { echo "FAIL: create-wp.sh accepted a call without --verification-class" >&2; exit 1; }
grep -q -- "--verification-class обязателен" <<<"$out" ||
  { echo "FAIL: rejection message does not name the missing flag" >&2; echo "$out" >&2; exit 1; }
after=$(find "$TMPDIR/strategy/inbox" -maxdepth 1 -type d -name 'WP-*' | wc -l | tr -d ' ')
[ "$after" -eq "$before" ] ||
  { echo "FAIL: a WP was created despite the missing --verification-class" >&2; exit 1; }

# --- Scenario 7: unknown class value → same hard refusal, not a silent typo-accept ---
before=$(find "$TMPDIR/strategy/inbox" -maxdepth 1 -type d -name 'WP-*' | wc -l | tr -d ' ')
set +e
out=$(bash "$CREATE_WP" --title "Класс с опечаткой" --budget "5h" --priority P3 \
  --verification-class "openloop" --no-consent-check --no-artifactor-check 2>&1)
rc=$?
set -e
[ "$rc" -ne 0 ] ||
  { echo "FAIL: create-wp.sh accepted an unknown --verification-class value" >&2; exit 1; }
grep -q -- "--verification-class обязателен" <<<"$out" ||
  { echo "FAIL: unknown class refused for the wrong reason (expected the verification-class gate)" >&2; echo "$out" >&2; exit 1; }
grep -q -- "Передано: openloop" <<<"$out" ||
  { echo "FAIL: rejection message does not echo the rejected value" >&2; echo "$out" >&2; exit 1; }
after=$(find "$TMPDIR/strategy/inbox" -maxdepth 1 -type d -name 'WP-*' | wc -l | tr -d ' ')
[ "$after" -eq "$before" ] ||
  { echo "FAIL: a WP was created despite the unknown --verification-class" >&2; exit 1; }

echo "✓ --verification-class is mandatory and correctly gates the /decompose checklist reminder"
