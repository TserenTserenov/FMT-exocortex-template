#!/bin/bash
# ledger-path.sh — single point of truth for machine/ledger/ file paths
# (WP-484, 31.07: pilot decision to move flat day-/week-/month-*.yaml files
# into a year/month hierarchy so the folder doesn't grow unbounded forever).
# Source, don't execute: `. "$(dirname "${BASH_SOURCE[0]}")/lib/ledger-path.sh"`
#
# Was 24 hand-written path constructions across 14 scripts (day-<period>.yaml
# flat in one directory) — the P2 threshold for extraction, same principle
# already applied to escape_json() in preclose-helpers.sh.

# ledger_path <scale> <period> [ledger-root, default $IWE_LEDGER_DIR] — prints
# the full hierarchical path, creating parent directories so callers can
# write immediately without a separate mkdir -p.
#   day   period=YYYY-MM-DD -> <root>/day/YYYY/MM/day-YYYY-MM-DD.yaml
#   week  period=YYYY-Wnn   -> <root>/week/YYYY/week-YYYY-Wnn.yaml
#   month period=YYYY-MM    -> <root>/month/YYYY/month-YYYY-MM.yaml
ledger_path() {
  local scale="$1" period="$2" root="${3:-$IWE_LEDGER_DIR}"
  local path
  path="$(ledger_path_rel "$scale" "$period")" || return 1
  path="$root/$path"
  mkdir -p "$(dirname "$path")"
  echo "$path"
}

# ledger_path_rel <scale> <period> — same suffix as ledger_path(), WITHOUT the
# root prefix and without the mkdir side effect. For callers that need a
# repo-relative string (git show <rel-path>, a pointer field inside a ledger
# event's own JSON payload) where creating a directory would be wrong or
# pointless — e.g. day-open-pipeline.sh reads a PAST day's ledger via `git
# show HEAD:<path>` before it has cd'd into the repo at all.
ledger_path_rel() {
  # Separate statements, not `local a="$1" b="$2" c="${b:...}"` in one line —
  # bash 3.2 (macOS default, Apple GPLv3 licensing freeze) doesn't reliably see
  # an earlier assignment in the SAME `local` statement when a later one reads
  # it (live-reproduced: year came out empty). Same class of quirk already
  # documented elsewhere in this codebase for bash 3.2.
  local scale="$1"
  local period="$2"
  local year="${period:0:4}"
  case "$scale" in
    day)   echo "day/$year/${period:5:2}/day-$period.yaml" ;;
    week)  echo "week/$year/week-$period.yaml" ;;
    month) echo "month/$year/month-$period.yaml" ;;
    *) echo "ledger_path_rel: недопустимый scale '$scale' (day|week|month)" >&2; return 1 ;;
  esac
}
