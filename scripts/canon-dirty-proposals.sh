#!/usr/bin/env bash
# canon-dirty-proposals.sh <repo-path> <snapshot-dir> <new-head-oid> -- turn a
# canon-dirty-snapshot.sh snapshot into per-path proposals against the new HEAD
# (WP-530 Ф38 / Ф3 step 5, Kimi: the pilot must see both sides -- what origin
# added and what the snapshot carries -- before anything is committed).
#
# For every snapshotted path:
#   tracked in old and new HEAD  -> three-way merge (base = old HEAD blob,
#                                   ours = snapshot, theirs = new HEAD blob) via
#                                   `git merge-file -p`; conflict markers stay in
#                                   the proposal and are counted in INDEX.md
#   identical to new HEAD        -> listed as "already on origin", no proposal
#   untracked / new in snapshot  -> proposal = the snapshot file as-is
# Nothing is written into the repo; proposals live under <snapshot-dir>/proposals.
set -uo pipefail
REPO="$1"; SNAP="$2"; NEW_HEAD="$3"
OLD_HEAD=$(cat "$SNAP/old_head.txt")
PROPOSALS="$SNAP/proposals"; mkdir -p "$PROPOSALS"
INDEX="$SNAP/INDEX.md"
{
  echo "# Предложения по возврату незакоммиченного содержимого"
  echo
  echo "old_head: $OLD_HEAD · new_head: $NEW_HEAD · снимок: $SNAP"
  echo
  echo "| путь | вид | уникальных строк снимка vs new HEAD | конфликтных блоков | предложение |"
  echo "|---|---|---|---|---|"
} > "$INDEX"
n_same=0; n_merge=0; n_new=0; n_conf=0
while read -r h p; do
  [ "$h" = "DELETED" ] && continue
  [ -n "$p" ] || continue
  snap="$SNAP/files/$p"
  [ -e "$snap" ] || [ -L "$snap" ] || continue
  if [ -L "$snap" ]; then
    mkdir -p "$PROPOSALS/$(dirname "$p")"; cp -a "$snap" "$PROPOSALS/$p"; n_new=$((n_new+1))
    printf '| %s | симлинк -> %s | - | 0 | proposals/%s |\n' "$p" "$(readlink "$snap")" "$p" >> "$INDEX"; continue
  fi
  new_blob=$(git -C "$REPO" rev-parse -q --verify "$NEW_HEAD:$p" 2>/dev/null || true)
  if [ -n "$new_blob" ] && [ "$new_blob" = "$h" ]; then
    n_same=$((n_same+1)); continue
  fi
  mkdir -p "$PROPOSALS/$(dirname "$p")"
  if [ -n "$new_blob" ]; then
    uniq_lines=$(comm -23 <(sort -u "$snap") <(git -C "$REPO" show "$NEW_HEAD:$p" | sort -u) | grep -vc '^\s*$')
    old_blob=$(git -C "$REPO" rev-parse -q --verify "$OLD_HEAD:$p" 2>/dev/null || true)
    base=$(mktemp); theirs=$(mktemp)
    if [ -n "$old_blob" ]; then git -C "$REPO" show "$OLD_HEAD:$p" > "$base"; else : > "$base"; fi
    git -C "$REPO" show "$NEW_HEAD:$p" > "$theirs"
    if ! git merge-file -p -L "снимок" -L "старый HEAD" -L "новый HEAD" "$snap" "$base" "$theirs" > "$PROPOSALS/$p" 2>/dev/null \
       && [ ! -s "$PROPOSALS/$p" ]; then
      # merge-file cannot merge binaries: the proposal is the snapshot itself, marked as such
      cp -a "$snap" "$PROPOSALS/$p"; rm -f "$base" "$theirs"; n_new=$((n_new+1))
      printf '| %s | бинарный, снимок как есть | - | 0 | proposals/%s |\n' "$p" "$p" >> "$INDEX"; continue
    fi
    conflicts=$(grep -c '^<<<<<<< ' "$PROPOSALS/$p")
    # append-only sections (Осталось/Журнал) usually conflict only because both
    # sides appended at the same spot; the union variant keeps both blocks in
    # order (snapshot first) for the pilot to compare against the marked one.
    [ "$conflicts" -gt 0 ] && git merge-file -p --union "$snap" "$base" "$theirs" > "$PROPOSALS/$p.union"
    rm -f "$base" "$theirs"
    n_merge=$((n_merge+1)); [ "$conflicts" -gt 0 ] && n_conf=$((n_conf+1))
    variant="proposals/$p"; [ "$conflicts" -gt 0 ] && variant="$variant (+ .union)"
    printf '| %s | tracked, 3-way | %s | %s | %s |\n' "$p" "$uniq_lines" "$conflicts" "$variant" >> "$INDEX"
  else
    cp -a "$snap" "$PROPOSALS/$p"; n_new=$((n_new+1))
    printf '| %s | новый файл | %s | 0 | proposals/%s |\n' "$p" "$(grep -vc '^\s*$' "$snap")" "$p" >> "$INDEX"
  fi
done < "$SNAP/manifest.sha256"
{
  echo
  echo "Уже на origin байт-в-байт (предложение не нужно): $n_same · трёхсторонних предложений: $n_merge (с конфликтами: $n_conf) · новых файлов: $n_new"
} >> "$INDEX"
echo "index: $INDEX (same=$n_same merge=$n_merge conflicts=$n_conf new=$n_new)"
