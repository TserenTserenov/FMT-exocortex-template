#!/usr/bin/env bash
# create-wp.sh --result must insert into the "### РП → Результаты" table
# regardless of how its separator row is drawn (issue #901). The literal
# match for "|---|" only covered a three-dash cell; a real Strategy.md with
# four-dash cells (or spaced/aligned cells) fell through to the next table
# below the section — wrong columns, silently.

set -euo pipefail

# Resolve relative to this script's own location, not $HOME/IWE (issue #901
# regression test: run-issue-tests.sh invokes test_issue_*.sh via a bare
# `bash "$t"`, no IWE_TEMPLATE export — the $HOME/IWE fallback only worked on
# a dev machine and broke silently in CI, where the checkout lives elsewhere).
TEMPLATE_ROOT="${IWE_TEMPLATE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

cp -R "$TEMPLATE_ROOT/seed/strategy" "$TMPDIR/strategy"
. "$TEMPLATE_ROOT/scripts/tests/lib/seed_strategy_fixture.sh"
ensure_weekplan_fixture "$TMPDIR/strategy"

# Reproduce the pilot's real Strategy.md shape (four-dash separator on the
# target table) AND the actual failure mechanism from #901: the unbounded
# literal search for "|---|" ran PAST the target section and landed in the
# next table BELOW it — not the unrelated table above, which the search
# never reaches in the first place (old or new code). The trap table below
# is what makes this test fail on the pre-fix code.
cat > "$TMPDIR/strategy/docs/Strategy.md" <<'MDEOF'
# Strategy

### Цели на горизонт (июнь — декабрь 2026)

| # | Цель | Критерий done |
|---|------|----------------|
| 1 | Пример цели | готово |

### РП → Результаты

| РП | Репо / Система | Результат | Статус |
|----|---------------|-----------|--------|
| WP-1 | some-repo | R1 | pending |

### Ревью

| РП | Дата | Вердикт |
|---|---|---|
| WP-2 | 2026-08-01 | ок |
MDEOF

export IWE_TEMPLATE="$TEMPLATE_ROOT"
export IWE_ROOT="$TMPDIR"
export IWE_GOVERNANCE_REPO="strategy"

OUT=$(cd "$TMPDIR" && bash "$TEMPLATE_ROOT/scripts/create-wp.sh" \
  --title "Issue 901 Regression" \
  --budget 3h \
  --priority P4 \
  --verification-class closed-loop \
  --result R2 \
  --no-consent-check \
  --no-artifactor-check 2>&1) || { echo "FAIL: create-wp.sh exited non-zero" >&2; echo "$OUT" >&2; exit 1; }

echo "$OUT" | grep -q "Strategy.md:.*добавлен" ||
  { echo "FAIL: create-wp.sh did not report a Strategy.md insertion" >&2; echo "$OUT" >&2; exit 1; }

STRATEGY_FILE="$TMPDIR/strategy/docs/Strategy.md"

# The new row must land inside "### РП → Результаты" ...
awk '/^### РП → Результаты/{f=1} f && /^### /  && !/^### РП → Результаты/{exit} f' "$STRATEGY_FILE" \
  | grep -q "R2" ||
  { echo "FAIL: new row not found inside the target section" >&2; cat "$STRATEGY_FILE" >&2; exit 1; }

# ... and must NOT have leaked into the "### Ревью" table BELOW the target
# section — this is the actual pre-fix failure mode (#901): the old literal
# "|---|" search had no upper bound and ran past the target section into
# whatever table came next.
awk '/^### Ревью/{f=1} f' "$STRATEGY_FILE" | grep -q "R2" &&
  { echo "FAIL: new row leaked into the trap table below the section (the real #901 mechanism)" >&2; cat "$STRATEGY_FILE" >&2; exit 1; }

# Sanity: the unrelated table above the section was never a candidate for
# either the old or the new code (search always starts at section_start),
# but assert it anyway so a future refactor that moves section_start earlier
# would be caught.
awk '/^### Цели на горизонт/{f=1} f && /^### РП → Результаты/{exit} f' "$STRATEGY_FILE" \
  | grep -q "R2" &&
  { echo "FAIL: new row leaked into the unrelated table above the section" >&2; cat "$STRATEGY_FILE" >&2; exit 1; }

echo "✓ --result inserted into the correct table despite a four-dash separator"
