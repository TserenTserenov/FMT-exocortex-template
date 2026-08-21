#!/usr/bin/env bash
# day-open-bottleneck-patch.sh — deterministic "Горлышко недели" injection (WP-484 Ф2)
#
# Runs AFTER day-open-llm-fill.py in day-open-pipeline.sh (moved 2026-07-14 — see BUGFIX
# below) so this script always has the last, authoritative word on "Горлышко недели":
# llm-fill.py fills whole `<details>` chunks generically and cannot be trusted to leave
# this sub-section untouched, since day-open.checks.md hard-blocks hand-written content
# here without the BY-SCRIPT marker (feedback_skill_manual_synthesis_bypass, 2026-05-28-04).
#
# Reused by extensions/day-open.after.md (interactive path) so both call sites share one
# correct implementation instead of two divergent copies.
#
# BUGFIX (WP-484 Ф2, 2026-07-13): the previous inline copy of this logic (still visible in
# after.md's git history) anchored its replacement regex on a closing "**Контекст недели W"
# markdown-bold string that day-open-scaffold.sh has not emitted since it moved to
# <details><summary><b> HTML markup — the substitution silently no-opped on every run.
# Verified empirically against scaffold.sh's actual output before fixing.
#
# BUGFIX (code-review same day): the first version of this script picked the latest YAML
# by mtime with no date check, and treated the honest BOTTLENECK-PENDING marker as
# terminal (same as BY-SCRIPT) for idempotency. Two bugs followed: (1) day-open.checks.md's
# second bottleneck check requires a YAML dated exactly today — an older file passed the
# marker check only to hard-block on that second check, moving the failure instead of
# removing it; (2) once BOTTLENECK-PENDING was written, a later run with a real same-day
# YAML available would never upgrade it (the after.md text promising "next run picks it up"
# was false). Both fixed below: reject non-today YAML as unavailable, and only BY-SCRIPT
# counts as done.
#
# Usage: day-open-bottleneck-patch.sh <dayplan-path>

set -uo pipefail

IWE="${IWE_ROOT:-$HOME/IWE}"
DAYPLAN="${1:?Usage: day-open-bottleneck-patch.sh <dayplan-path>}"

if [ ! -f "$DAYPLAN" ]; then
  echo "  ⚠️ bottleneck-patch: $DAYPLAN not found — skip" >&2
  exit 0
fi

# Real analysis already inserted — the only truly terminal state.
if grep -q "<!-- BY-SCRIPT: bottleneck-section-from-yaml.sh -->" "$DAYPLAN" 2>/dev/null; then
  echo "  bottleneck-patch: BY-SCRIPT marker already present — skip"
  exit 0
fi

TODAY=$(date +%Y-%m-%d)
RUNS_DIR="$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/bottleneck-pick-runs"
# bug-2026-07-17: `stat -f` is BSD/macOS syntax — on the Linux server it's the
# filesystem-status flag instead, so this silently produced garbage there (never a
# same-day YAML), always falling through to BOTTLENECK-PENDING regardless of freshness.
# Filenames are ISO-date-prefixed, so a plain lexical sort orders them chronologically
# without needing mtime at all — portable across both platforms.
LATEST_YAML=$(find "$RUNS_DIR" -name "*-weekplan*.yaml" 2>/dev/null | sort | tail -1)

# day-open.checks.md's second bottleneck check requires a YAML dated exactly today —
# accepting an older one here would insert a BY-SCRIPT section that passes the first
# check only to hard-block on the second. Treat anything not dated today as unavailable.
if [ -n "$LATEST_YAML" ] && [[ "$(basename "$LATEST_YAML")" != "$TODAY-weekplan"* ]]; then
  echo "  bottleneck-patch: latest YAML ($(basename "$LATEST_YAML")) is not dated $TODAY — treating as unavailable" >&2
  LATEST_YAML=""
fi

if [ -n "$LATEST_YAML" ]; then
  SECTION=$(bash "$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/bottleneck-section-from-yaml.sh" "$LATEST_YAML" 2>/dev/null)
  if [ -z "$SECTION" ]; then
    echo "  ⚠️ bottleneck-patch: $LATEST_YAML found but generator produced no output — treating as no-yaml" >&2
    LATEST_YAML=""
  fi
fi

if [ -z "$LATEST_YAML" ]; then
  # No today-dated YAML. If an earlier run already left the honest marker, there is
  # nothing new to say — stop here instead of re-writing the same content.
  if grep -q "<!-- BOTTLENECK-PENDING:" "$DAYPLAN" 2>/dev/null; then
    echo "  bottleneck-patch: still no today-dated YAML — BOTTLENECK-PENDING marker stands"
    exit 0
  fi
  # Honest, visible "not done" marker — never a silent gap (WP-484 invariant).
  # Distinct from a hand-written heading: day-open.checks.md recognizes this marker
  # and reports it as a non-blocking 🟡 in «Требует внимания» instead of hard-blocking,
  # since nobody is claiming a fake analysis — the headless run structurally cannot
  # invoke the /bottleneck-pick LLM skill on its own.
  SECTION="<!-- BOTTLENECK-PENDING: no-yaml-headless -->
**Горлышко недели:** нет данных — headless-конвейер не может вызвать LLM-скилл \`/bottleneck-pick\`. Запусти вручную: \`/bottleneck-pick --target weekplan --layer intra --horizon week --depth 1\`."
fi

python3 - "$DAYPLAN" "$SECTION" <<'PYEOF'
import re
import sys

path, section = sys.argv[1], sys.argv[2]
content = open(path).read()

# BUGFIX (WP-484, confirmed on 2026-07-14 headless run): the "Контекст недели" <details>
# chunk holds a second, independent PENDING marker (week_context) — llm-fill.py's
# has_pending check is whole-chunk, so that marker alone made it regenerate this whole
# chunk and overwrite an already-inserted BOTTLENECK-PENDING with unmarked prose.
# Anchor on "**Горлышко недели" itself (present in all 3 possible prior states) instead
# of one specific predecessor marker, so this script always has the final, authoritative
# word — paired with running it after llm-fill.py in day-open-pipeline.sh now.
# bug-2026-07-17: llm-fill.py regenerated «Контекст недели» via LLM and dropped that
# chunk's own </details> — with no boundary before the NEXT section's opening tag, the
# match ran through to "Итоги вчера"'s closing </details> and deleted that whole section.
# `\n<summary><b>` is a hard backstop: a details block never nests a second <summary>,
# so this boundary holds even when </details> itself goes missing upstream.
pattern = re.compile(
    r'(?:<!-- PENDING: bottleneck-week.*?-->|<!-- BOTTLENECK-PENDING:.*?-->)?'
    r'\s*\n*\*\*Горлышко недели.*?'
    r'(?=\n\n<!-- PENDING: week_context|\n\n\*\*Контекст недели:|\n\n</details>|\n<summary><b>)',
    re.DOTALL,
)


# `\s*\n*` above greedily swallows the blank line separating this section from whatever
# precedes it (the </summary> line, in every observed state) as part of the match, so
# the replacement must restore it explicitly — otherwise the closing tag and the marker
# comment end up jammed onto one line.
def replace(m):
    tail = section.strip()
    # The `\n<summary><b>` backstop above is zero-width and stops one section short of
    # a real </details> — reaching it means the current chunk's own closing tag was
    # already missing upstream (bug-2026-07-17), so restore it here instead of leaving
    # this section jammed straight into the next one's <summary>.
    if content[m.end():m.end() + 2] != "\n\n":
        tail += "\n\n</details>\n\n<details>"
    return "\n\n" + tail


content_new, n = pattern.subn(replace, content, count=1)

if n == 0:
    print("  ⚠️ bottleneck-patch: anchor not found — DayPlan structure unexpected, left untouched")
else:
    open(path, "w").write(content_new)
    print("  bottleneck-patch: inserted")
PYEOF
