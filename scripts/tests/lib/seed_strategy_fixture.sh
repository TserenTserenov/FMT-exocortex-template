#!/usr/bin/env bash
# seed_strategy_fixture.sh — shared helper for tests that copy seed/strategy
# into an isolated tmpdir and need create-wp.sh to succeed against it.
#
# create-wp.sh's WeekPlan step (4/6) needs a real current/WeekPlan*.md to
# write into; seed/strategy ships one (current/WeekPlan W1.md) so a normal
# `git clone` has it. But `update.sh` never syncs seed/ to an existing
# install (seed/ is a one-time bootstrap template, correctly excluded from
# the ongoing-update manifest by design — re-syncing it into an existing
# fork could clobber a user's own edits under seed/strategy for no benefit,
# since it's only ever read once at setup.sh time) — found by cold review
# 03.08: a copy of this template obtained any way other than a fresh git
# clone of the exact commit that added the fixture won't have it, and the
# two tests that depended on its presence would fail for a reason that has
# nothing to do with what they're actually testing. Providing a minimal
# fixture here if one is missing makes the tests self-sufficient regardless
# of how the caller's local template copy was obtained.

# ensure_weekplan_fixture <strategy_dir> — idempotent: no-op if a
# current/WeekPlan*.md already exists (the real seed one, when present, is
# used as-is).
ensure_weekplan_fixture() {
  local strategy_dir="$1"
  if ! ls "$strategy_dir"/current/WeekPlan*.md >/dev/null 2>&1; then
    mkdir -p "$strategy_dir/current"
    cat > "$strategy_dir/current/WeekPlan W1.md" <<'WPEOF'
---
type: week-plan
week: W1
status: draft
agent: Стратег
---

# WeekPlan W1

**Фокус:** [заполняется на первой стратегической сессии]

| 🚦 | # | РП | h | Источник | P | Статус | Результат |
|----|---|-----|---|----------|---|--------|-----------|
| — | — | — | — | — | — | — | — |
WPEOF
  fi
}
