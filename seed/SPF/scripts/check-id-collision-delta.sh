#!/usr/bin/env bash
# check-id-collision-delta.sh — delta-aware ID-collision guard for Pack repos.
# see DP.SC.181, WP-388 Phase 14 (ArchGate 2026-06-14, variant A).
#
# Two independent checks:
#  1. ID collision: a staged-added entity file introduces an ID (PREFIX.TYPE.N)
#     already claimed by another file/section in the repo.
#  2. Distinctions mode: a staged edit to *-distinctions.md adds a NEW section
#     beyond the scalability threshold (2026-07-18, reconciliation SPF.SPEC.003 ↔
#     process/03-distinctions-work.md — drift drive DP.D.249/250).
# Innocent edits and unique new IDs pass. Complements the global
# pack-lint (warning) and CI check-pack-collisions.sh (backstop).
#
# Root cause 1: parallel agents in the same working directory independently
# take max+1 and collide (WP-388 Phase 14). find scans the working tree,
# so it also catches an uncommitted file from a second agent before push.
#
# Root cause 2: once *-distinctions.md crosses the scalability threshold,
# new distinctions must go into a separate file
# (02-domain-entities/<DOMAIN>.D.<NNN>-slug.md), not a new section — otherwise
# the same dual-registry pattern that caused the DP.D.249/250 collision is
# recreated. Below the threshold the file is still in single-file mode —
# growing by sections is legitimate. Edits/renames/deletions of existing
# sections (section count does not increase) are allowed in both modes.
#
# Exit codes:
#   0 — no collisions/mode violations (or nothing to check)
#   1 — one of the checks found a violation (commit is blocked)

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
[ -z "$REPO_ROOT" ] && exit 0

ID_RE='^[A-Z]+\.[A-Z]+\.[0-9]+'
status=0

# All entity files in the repo with their IDs (excluding .git/archive/inbox/template).
# Prints lines "ID<TAB>path". Exact ID comparison, no glob boundaries (180 ≠ 1800).
# 2026-07-18 (drift DP.D): scan section IDs inside multi-entity files
# ("### DP.D.NNN:", "## [DP.D.NNN]") — 01B-distinctions.md carries ~130 sections,
# basename scan was blind to them → collisions between files and sections (DP.D.034/249/250 etc.).
all_entity_ids() {
  {
    find "$REPO_ROOT" -name '*.md' -type f 2>/dev/null \
      | grep -Ev '/(\.git|archive|inbox)/' \
      | grep -Ev '/_[^/]*/' \
      | while IFS= read -r path; do
          eid=$(basename "$path" | grep -oE "$ID_RE" || true)
          [ -n "$eid" ] && printf '%s\t%s\n' "$eid" "$path"
        done
    grep -rHoE '^#{2,3} +\[?[A-Z]+\.[A-Z]+\.[0-9]+\]?' "$REPO_ROOT/pack" --include='*.md' 2>/dev/null \
      | grep -Ev '/(\.git|archive|inbox)/' \
      | grep -Ev '/_[^/]*/' \
      | sed -E 's/^(.*\.md):#{2,3} +\[?([A-Z]+\.[A-Z]+\.[0-9]+)\]?.*$/\2\t\1/' \
      || true
  } | sort -u
}

# --- Check 1: ID collision (staged-added .md under pack/, delta-aware) ---
ADDED=$(git diff --cached --name-only --diff-filter=A -- 'pack/*.md' 'pack/**/*.md' 2>/dev/null || true)

if [ -n "$ADDED" ]; then
  ENTITY_INDEX=$(all_entity_ids)

  while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    id=$(basename "$rel" | grep -oE "$ID_RE" || true)
    [ -z "$id" ] && continue   # not an ID-bearing file (e.g. 00-pack-manifest.md)

    abs="$REPO_ROOT/$rel"
    others=$(printf '%s\n' "$ENTITY_INDEX" \
      | awk -F'\t' -v id="$id" '$1==id{print $2}' \
      | grep -vF "$abs" || true)

    [ -z "$others" ] && continue

    status=1
    prefix=$(printf '%s' "$id" | grep -oE '^[A-Z]+\.[A-Z]+')
    maxn=$(printf '%s\n' "$ENTITY_INDEX" \
      | awk -F'\t' -v p="$prefix." 'index($1, p)==1{print $1}' \
      | grep -oE '[0-9]+$' | sort -n | tail -1)
    nextn=$(( ${maxn:-0} + 1 ))

    echo "🚫 ID collision: the file being added claims the already-existing $id"
    echo "   adding:          $rel"
    printf '%s\n' "$others" | sed "s|^$REPO_ROOT/|   conflict:      |"
    echo "   next free ID:    $prefix.$nextn"
    echo "   → Rename the new file to the next free ID (both the filename and the id: field inside)."
    echo ""
  done <<< "$ADDED"
fi

# --- Check 2: distinctions mode (staged-added/modified *-distinctions.md) ---
DIST_MODE_THRESHOLD=40  # see SPF.SPEC.003 § Size limit + process/03-distinctions-work.md § Output
D_HEADER_RE='^#{2,3} +\[?[A-Z]+\.D\.[0-9]+\]?'
DIST_CHANGED=$(git diff --cached --name-only --diff-filter=ACM -- 'pack/*.md' 'pack/**/*.md' 2>/dev/null \
  | grep -E -- '-distinctions\.md$' \
  | grep -Ev '/(\.git|archive|inbox)/' \
  | grep -Ev '/_[^/]*/' || true)

if [ -n "$DIST_CHANGED" ]; then
  while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    git cat-file -e "HEAD:$rel" 2>/dev/null || continue  # new file (new/small Pack, mode not yet chosen) — skip

    head_n=$(git show "HEAD:$rel" 2>/dev/null | grep -cE "$D_HEADER_RE" || true)
    staged_n=$(git show ":$rel" 2>/dev/null | grep -cE "$D_HEADER_RE" || true)
    head_n=${head_n:-0}
    staged_n=${staged_n:-0}

    if [ "$head_n" -ge "$DIST_MODE_THRESHOLD" ] && [ "$staged_n" -gt "$head_n" ]; then
      status=1
      echo "🚫 New section in $rel: was $head_n distinctions, now $staged_n (single-file mode threshold — $DIST_MODE_THRESHOLD)."
      echo "   The file is already in index+card mode (SPF.SPEC.003) — create the new distinction"
      echo "   as a separate file <DOMAIN>.D.<NNN>-slug.md in 02-domain-entities/, not as a new section here."
      echo ""
    fi
  done <<< "$DIST_CHANGED"
fi

[ "$status" -eq 0 ] && exit 0

echo "This is the ID-collision/distinctions-mode guard (WP-388 Phase 14, SPF.SPEC.003), not a system failure. It cannot be bypassed — fix the issue as described above."
exit 1
