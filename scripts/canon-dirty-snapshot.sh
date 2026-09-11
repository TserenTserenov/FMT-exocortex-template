#!/usr/bin/env bash
# canon-dirty-snapshot.sh <repo-path> <snapshot-dir> -- double snapshot of every
# uncommitted path of a checkout before the Ф3 ref replacement (WP-530 Ф38,
# Kimi amendment 1: `cp -a` copies + textual diffs + untracked hash list, then a
# self-check that every listed path is in the snapshot with the same hash).
# Read-only towards the repo. Exit 0 = snapshot complete and verified; 1 = not.
set -uo pipefail
REPO="$1"; SNAP="$2"
cd "$REPO" || exit 2
mkdir -p "$SNAP/files" "$SNAP/proposals"
git rev-parse HEAD > "$SNAP/old_head.txt"
git stash list > "$SNAP/stash-list.txt"
git status --porcelain -z > "$SNAP/status.z"
git status --porcelain > "$SNAP/status.txt"
git diff > "$SNAP/tracked.diff"
git diff --cached > "$SNAP/staged.diff"
git diff --cached --name-only -z > "$SNAP/staged-paths.z"
: > "$SNAP/manifest.sha256"
: > "$SNAP/manifest.stat"
find . -type d -empty -not -path './.git/*' | sort > "$SNAP/empty-dirs.txt"
# GNU-first (Linux/coreutils), BSD fallback (macOS) -- same order and same
# rationale as iwe_file_mtime_date() in scripts/lib/common.sh: this pilot's
# own hosts span both (Mac + tsekh-1 Linux), and the reverse check order has
# previously broken the Linux branch of stat -f/-c detection.
portable_stat_line() {  # <path> -- "type perm size mtime", one format picked once per host
  if stat --version >/dev/null 2>&1; then
    stat -c '%F %a %s %Y' -- "$1"
  else
    stat -f '%HT %Lp %z %m' -- "$1"
  fi
}
record() {  # <path> -- content hash + stat line (+ symlink target) for one path
  if [ -L "$1" ]; then printf '%s %s\n' "$(printf '%s' "$(readlink "$1")" | git hash-object --stdin)" "$1" >> "$SNAP/manifest.sha256"
  else printf '%s %s\n' "$(git hash-object "$1")" "$1" >> "$SNAP/manifest.sha256"; fi
  if [ -L "$1" ]; then printf 'link %s -> %s\n' "$1" "$(readlink "$1")" >> "$SNAP/manifest.stat"
  else printf '%s %s\n' "$(portable_stat_line "$1")" "$1" >> "$SNAP/manifest.stat"; fi
}
# every path git reports (modified, staged, untracked) -- copied with metadata
git status --porcelain -z | while IFS= read -r -d '' entry; do
  p="${entry:3}"
  # renames/copies carry a second NUL-terminated field (the old path): consume it, snapshot the new one
  case "${entry:0:1}${entry:1:1}" in R*|C*|*R|*C) IFS= read -r -d '' _old_path ;; esac
  [ -e "$p" ] || [ -L "$p" ] || { printf 'DELETED %s\n' "$p" >> "$SNAP/manifest.sha256"; continue; }
  if [ -d "$p" ] && [ ! -L "$p" ]; then
    find "$p" \( -type f -o -type l \) | while read -r f; do
      mkdir -p "$SNAP/files/$(dirname "$f")"; cp -a "$f" "$SNAP/files/$f"; record "$f"
    done
  else
    mkdir -p "$SNAP/files/$(dirname "$p")"; cp -a "$p" "$SNAP/files/$p"; record "$p"
  fi
done
# self-check: every manifest entry exists in the snapshot with the same hash
bad=0
while read -r h p; do
  [ "$h" = "DELETED" ] && continue
  [ -e "$SNAP/files/$p" ] || [ -L "$SNAP/files/$p" ] || { echo "MISSING in snapshot: $p" >&2; bad=1; continue; }
  if [ -L "$p" ]; then
    [ "$(printf '%s' "$(readlink "$SNAP/files/$p")" | git hash-object --stdin)" = "$h" ] || { echo "HASH MISMATCH in snapshot: $p" >&2; bad=1; }
    [ "$(readlink "$SNAP/files/$p")" = "$(readlink "$p")" ] || { echo "SYMLINK MISMATCH in snapshot: $p" >&2; bad=1; }
  else
    [ "$(git hash-object "$SNAP/files/$p")" = "$h" ] || { echo "HASH MISMATCH in snapshot: $p" >&2; bad=1; }
    [ "$(portable_stat_line "$SNAP/files/$p" | cut -d' ' -f1-3)" = "$(portable_stat_line "$p" | cut -d' ' -f1-3)" ] || { echo "STAT MISMATCH in snapshot: $p" >&2; bad=1; }
  fi
done < "$SNAP/manifest.sha256"
n=$(grep -vc '^DELETED' "$SNAP/manifest.sha256")
[ "$bad" = 0 ] && echo "snapshot ok: $n files in $SNAP (old_head $(cut -c1-9 "$SNAP/old_head.txt"))" || { echo "snapshot INCOMPLETE" >&2; exit 1; }
