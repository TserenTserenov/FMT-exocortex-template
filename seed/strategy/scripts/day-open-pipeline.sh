#!/usr/bin/env bash
# SNAPSHOT — synced manually via script-promote.sh from FMT-exocortex-template/scripts/. Do not edit here directly.
# day-open-pipeline.sh — оркестратор полного конвейера Day Open (WP-356 DOE3)
# Поток: preflight → scaffold → llm-fill (per-section) → checks → commit/push
#
# FMT promotion note (WP-7 FMT-PROMOTE-DAYOPEN1): this entry point plus its 5
# dependencies (day-open-checks-runner.sh, day-open-llm-fill.py,
# day-open-budget-patch.py, update-derived-snapshot.py, llm-proxy-launcher.sh)
# and day-open-scaffold.sh are all promoted here and seeded into
# seed/strategy/scripts/ for new ${IWE_GOVERNANCE_REPO:-DS-strategy} repos. Not yet wired: no launchd
# role registers this pipeline for a new user (see roles/ — none reference
# day-open); that remains a separate follow-up (day-open role, IntegrationGate
# required before implementation).

set -uo pipefail

# SCRIPT_HOME is the directory this copy runs from. Day Open's own helpers (patch
# scripts, hook/check runners, lib/) are taken from here; the tools shared with the
# strategist job (session-guard, preflight, scaffold, server-calendar,
# git-dirty-guard) come from $IWE_SCRIPTS. DATA (WeekPlan, current/, inbox/, logs/
# ...) lives in the governance repository, $DS_STRATEGY.
SCRIPT_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

day_open_fast_forward() {
  local repo="$1" remote="${2:-origin}" source_ref="${3:-refs/heads/main}"
  local upstream="${4:-refs/remotes/origin/main}" head branch tree target target_ref
  DAY_OPEN_SYNC_REPORTED=0
  head=$(git -C "$repo" rev-parse HEAD) || return 1
  branch=$(git -C "$repo" symbolic-ref --quiet HEAD) || return 1
  tree=$(GIT_OPTIONAL_LOCKS=0 git -C "$repo" status --porcelain --untracked-files=all) || return 1
  [ -z "$tree" ] || return 1
  target_ref=$(git -C "$repo" rev-parse --symbolic-full-name "$upstream") || return 1
  # Refresh this exact tracking ref even with a restricted remote.fetch config.
  # Never use a local branch as the fetch destination (e.g. remote=".").
  case "$target_ref" in refs/remotes/*) ;; *) return 1 ;; esac
  git -C "$repo" fetch --quiet --refmap= "$remote" "+$source_ref:$target_ref" || return 1
  target=$(git -C "$repo" rev-parse "$target_ref") || return 1
  [ "$(git -C "$repo" rev-parse HEAD)" = "$head" ] || return 1
  [ "$(git -C "$repo" symbolic-ref --quiet HEAD)" = "$branch" ] || return 1
  tree=$(GIT_OPTIONAL_LOCKS=0 git -C "$repo" status --porcelain --untracked-files=all) || return 1
  [ -z "$tree" ] || return 1
  # A concurrent edit can still land after the check; Git must refuse an
  # overlapping update, even when the user configured merge.autoStash=true.
  if git -C "$repo" merge --ff-only --no-autostash --no-overwrite-ignore --quiet "$target"; then
    day_open_sync_marker_clear "$repo"
    day_open_prune_superseded "$repo" "$target"
    return 0
  fi
  day_open_adopt_twins "$repo" "$target"
}

# A full commit id (SHA-1 or SHA-256), nothing else: HEAD, a branch name, an empty
# field or "-x" in the list file must never reach a git command.
day_open_is_sha() {
  [[ "$1" =~ ^[0-9a-f]{40,64}$ ]]
}

# --- sync-blocked marker -------------------------------------------------------
# When the shared checkout cannot be moved to the published tip (overlapping local
# edits, an unpublished local commit) the reason is kept in a marker file and
# reported once: when the marker appears, when the reason or the paths change, and
# then at most once a week. A successful move removes the marker.
day_open_sync_marker_file() {
  local root
  # Keyed by the physical top level, so a symlinked path and its target share one marker.
  root=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$1")
  printf '%s/day-open-sync-blocked.%s.marker\n' "${DAY_OPEN_STATE_DIR:-$HOME/.claude/state}" \
    "$(printf '%s' "$root" | cksum | cut -d' ' -f1)"
}

day_open_sync_marker_clear() {
  rm -f "$(day_open_sync_marker_file "$1")"
}

# Records why the checkout cannot move and tells the pilot, once per reason. The
# delivery time is stored only after the message was really delivered (tg_notify
# succeeded), together with the reason it was delivered for; a failed send leaves
# the old values, so the next run tries again. Probe runs write nothing.
# DAY_OPEN_SYNC_REPORTED=1 tells the caller the pilot already knows about this block.
day_open_sync_blocked() {
  local repo="$1" target="$2" class="$3" reason="$4" paths="$5"
  local file head behind sig now notified_sig="" notified="" notify=0
  DAY_OPEN_SYNC_REPORTED=0
  [ "${PROBE:-false}" != true ] || return 0
  file=$(day_open_sync_marker_file "$repo")
  mkdir -p "$(dirname "$file")" || return 0
  head=$(git -C "$repo" rev-parse --verify HEAD 2>/dev/null) || return 0
  behind=$(git -C "$repo" rev-list --count "$head..$target" 2>/dev/null || echo "?")
  # One line, always: a path with a line break must not forge another marker field.
  sig="$class|$(printf '%s' "$paths" | tr '\n' ' ')"
  now=${DAY_OPEN_NOW:-$(date +%s)}
  if [ -f "$file" ]; then
    notified_sig=$(sed -n 's/^notified_sig=//p' "$file")
    notified=$(sed -n 's/^notified=//p' "$file")
  fi
  if [ "$notified_sig" != "$sig" ] || [ -z "$notified" ] || [ $((now - notified)) -ge 604800 ]; then
    notify=1
  fi
  if [ "$notify" -eq 0 ]; then
    DAY_OPEN_SYNC_REPORTED=1
  elif command -v tg_notify >/dev/null 2>&1 \
      && tg_notify "⚠️ Day Open: рабочая копия $(basename "$repo") отстаёт от опубликованной на $behind коммитов и не обновляется сама. Причина: $reason. Затронуто: ${paths:-—}. Нужно решение вручную: закоммитить или убрать свои правки, после этого копия догонит сама." protective; then
    notified_sig=$sig
    notified=$now
    DAY_OPEN_SYNC_REPORTED=1
  fi
  {
    printf 'head=%s\ntarget=%s\nbehind=%s\nreason=%s\nsig=%s\n' \
      "$head" "$target" "$behind" "$(printf '%s' "$reason" | tr '\n' ' ')" "$sig"
    printf 'paths=%s\n' "$(printf '%s' "$paths" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    [ -z "$notified" ] || printf 'notified_sig=%s\nnotified=%s\n' "$notified_sig" "$notified"
  } > "$file.tmp" && mv "$file.tmp" "$file"
}

# Superseded refs older than 90 days (by commit date) are dropped once the commit
# is reachable from the published tip; a commit that is not there stays protected.
day_open_prune_superseded() {
  local repo="$1" target="$2" now cutoff ref sha when
  now=${DAY_OPEN_NOW:-$(date +%s)}
  cutoff=$((now - 90 * 86400))
  while IFS=$'\t' read -r ref sha when; do
    [ -n "$ref" ] && [ "${when:-0}" -lt "$cutoff" ] || continue
    git -C "$repo" merge-base --is-ancestor "$sha" "$target" 2>/dev/null || continue
    git -C "$repo" update-ref -d "$ref"
  done < <(git -C "$repo" for-each-ref --format='%(refname)%09%(objectname)%09%(committerdate:unix)' refs/day-open/superseded/)
}

# Publication never resets, rebases or stashes the shared checkout, so a dirty
# tree or a busy origin cannot lose work or wedge the next run.
# The list of our unpublished DayPlan commits survives a failed run; a retry
# publishes exactly that list, never "whatever happens to be ahead of origin".
day_open_pending_file() {
  printf '%s/day-open-pending-publish.list\n' "${DAY_OPEN_STATE_DIR:-$HOME/.claude/state}"
}

# One destination (remote + remote branch) for fetch, verification and push.
# Prints "<remote> <ref>"; refuses configurations where those could differ.
day_open_publish_target() {
  local repo="$1" branch remote ref push_remote
  branch=$(git -C "$repo" symbolic-ref --quiet --short HEAD) || {
    echo "Day Open: detached HEAD, publication destination is ambiguous." >&2
    return 1
  }
  remote=$(git -C "$repo" config --get "branch.$branch.remote") || remote=origin
  ref=$(git -C "$repo" config --get "branch.$branch.merge") || ref="refs/heads/$branch"
  case "$ref" in refs/heads/?*) ;; *)
    echo "Day Open: unsupported upstream ref '$ref' for branch '$branch'." >&2
    return 1 ;;
  esac
  if ! git -C "$repo" remote get-url "$remote" >/dev/null 2>&1; then
    echo "Day Open: '$remote' is not a configured remote for branch '$branch'." >&2
    return 1
  fi
  push_remote=$(git -C "$repo" config --get "branch.$branch.pushRemote" \
    || git -C "$repo" config --get remote.pushDefault || true)
  if [ -n "$push_remote" ] && [ "$push_remote" != "$remote" ]; then
    echo "Day Open: push remote '$push_remote' differs from upstream remote '$remote'; refusing." >&2
    return 1
  fi
  printf '%s %s\n' "$remote" "$ref"
}

# A DayPlan file directly inside current/ or archive/day-plans/ (no further
# directories: a shell glob star would also match "/").
day_open_is_plan_path() {
  local path="$1" name
  case "$path" in
    current/DayPlan\ *.md | archive/day-plans/DayPlan\ *.md) ;;
    *) return 1 ;;
  esac
  name=${path#*DayPlan }
  case "$name" in */*) return 1 ;; esac
}

# A commit is ours to publish only when it touches DayPlan files and the DayPlan archive.
day_open_commit_paths_ok() {
  local repo="$1" sha="$2" path count=0
  while IFS= read -r -d '' path; do
    count=$((count + 1))
    day_open_is_plan_path "$path" || return 1
  done < <(git -C "$repo" diff-tree -r --no-commit-id --name-only -z "$sha")
  [ "$count" -gt 0 ]
}

day_open_patch_id() {
  git -C "$1" diff-tree -p --root --no-commit-id "$2" 2>/dev/null \
    | git -C "$1" patch-id --stable | cut -d' ' -f1
}

# Prints the commit on $target that carries our change: the commit itself, or a
# cherry-picked twin with the same patch-id. Fails when our change is not there.
# Presence is decided by `git cherry`, which compares patch-ids over the whole
# distance to the merge base instead of an arbitrary window, so a long quiet
# stretch of unrelated commits cannot hide the twin. Naming the twin scans the
# last 500 commits; if it is older than that, the tip (which contains it) is named.
day_open_published_equivalent() {
  local repo="$1" target="$2" sha="$3" parent want candidate
  if git -C "$repo" merge-base --is-ancestor "$sha" "$target" 2>/dev/null; then
    echo "$sha"
    return 0
  fi
  parent=$(git -C "$repo" rev-parse --verify --quiet "$sha^") || return 1
  git -C "$repo" cherry "$target" "$sha" "$parent" 2>/dev/null | grep -q '^-' || return 1
  want=$(day_open_patch_id "$repo" "$sha")
  if [ -n "$want" ]; then
    while IFS= read -r candidate; do
      if [ "$(day_open_patch_id "$repo" "$candidate")" = "$want" ]; then
        echo "$candidate"
        return 0
      fi
    done < <(git -C "$repo" log --no-merges -n 500 --format=%H "$target")
  fi
  git -C "$repo" rev-parse "$target"
}

# Same change of the list when python3 with fcntl is missing. Simple on purpose: the lock
# is a FILE <list>.lock whose content is the holder's pid, created atomically (`ln` of a
# prepared file fails when the lock exists). A waiter waits up to DAY_OPEN_LOCK_WAIT_SECS
# (120 s) and then refuses with a message naming the file; it NEVER takes a lock over. If
# the holder was killed inside the millisecond critical section the lock stays until a
# person deletes the file (the message says so). The python/fcntl path locks <list>.flock,
# this one <list>.lock: runs that use different paths do not exclude each other.
day_open_file_mtime() {
  local m
  m=$(stat -c %Y "$1" 2>/dev/null) || m=$(stat -f %m "$1" 2>/dev/null) || return 1
  case "$m" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$m"
}

# Why the lock <file> refused us, in Russian, for the pilot.
day_open_lock_refusal() {
  local lock="$1" pid="" mtime created="неизвестно" err hint=""
  if [ -d "$lock" ]; then
    echo "Day Open: список публикаций не обновлён: $lock — папка, а должен быть файл; удалите её." >&2
    return 0
  fi
  pid=$(cat "$lock" 2>/dev/null)
  if mtime=$(day_open_file_mtime "$lock"); then
    created=$(date -d "@$mtime" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$mtime" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$mtime")
  fi
  case "$pid" in
    ''|*[!0-9]*) ;;
    *)
      err=$(LC_ALL=C kill -0 "$pid" 2>&1)
      case "$err" in *"No such process"*) hint=" Процесс с этим PID не найден: прежний запуск, судя по всему, был прерван." ;; esac
      ;;
  esac
  echo "Day Open: список публикаций заблокирован файлом $lock (PID ${pid:-?}, создан $created); если Day Open не запущен — удалите этот файл.$hint" >&2
}

# Takes <lock>; returns 1 (after saying why) when it stays taken past the wait.
day_open_lock_acquire() {
  local lock="$1" started=$SECONDS prepared
  prepared=$(mktemp "$lock.XXXXXX") || return 1
  printf '%s\n' "$$" > "$prepared"
  while :; do
    # `ln` into an existing directory would succeed by linking inside it.
    [ -d "$lock" ] || ! ln "$prepared" "$lock" 2>/dev/null || break
    if [ -d "$lock" ] || [ $((SECONDS - started)) -gt "${DAY_OPEN_LOCK_WAIT_SECS:-120}" ]; then
      rm -f "$prepared"
      day_open_lock_refusal "$lock"
      return 1
    fi
    sleep 0.1
  done
  rm -f "$prepared"
}

# Removes <lock> only while it still carries this process's pid.
day_open_lock_release() {
  [ "$(cat "$1" 2>/dev/null)" = "$$" ] && rm -f "$1"
  return 0
}

day_open_pending_update_fallback() {
  local file="$1" mode="$2" lock tmp rc=0
  shift 2
  lock="$file.lock"
  day_open_lock_acquire "$lock" || return 1
  case "$mode" in
    record)
      grep -qxF "$(printf '%s\t%s\t%s\t%s' "$@")" "$file" 2>/dev/null \
        || printf '%s\t%s\t%s\t%s\n' "$@" >> "$file" || rc=1
      ;;
    *)
      if [ -f "$file" ]; then
        tmp=$(mktemp "$file.XXXXXX") || { day_open_lock_release "$lock"; return 1; }
        if [ "$mode" = prune ]; then
          awk -F'\t' -v repo="$1" '!($1 == repo && !(length($4) >= 40 && length($4) <= 64 && $4 ~ /^[0-9a-f]+$/))' "$file" > "$tmp"
        else
          # shellcheck disable=SC2086
          awk -F'\t' -v repo="$1" -v list="$(echo $2)" '
            BEGIN { n = split(list, a, " "); for (i = 1; i <= n; i++) drop[a[i]] = 1 }
            !($1 == repo && ($4 in drop))' "$file" > "$tmp"
        fi
        if [ $? -eq 0 ]; then mv "$tmp" "$file" || rc=1; else rm -f "$tmp"; rc=1; fi
      fi
      ;;
  esac
  day_open_lock_release "$lock"
  return "$rc"
}

# Serialised change of the pending list:
#   day_open_pending_update record <repo> <remote> <ref> <sha>
#   day_open_pending_update remove <repo> "<sha> <sha> ..."
#   day_open_pending_update prune  <repo>     (drops this repo's records with a malformed sha)
# Only the matching records are touched; the file is replaced atomically.
day_open_pending_update() {
  local file py="${DAY_OPEN_PYTHON:-python3}"
  file=$(day_open_pending_file)
  mkdir -p "$(dirname "$file")" || return 1
  if ! "$py" -I -c 'import fcntl' >/dev/null 2>&1; then
    echo "Day Open: python3 with fcntl is needed for the kernel lock on the pending-publish list; using a lock file instead." >&2
    day_open_pending_update_fallback "$file" "$@"
    return
  fi
  "$py" -I -c '
import fcntl, os, re, sys, tempfile, time
path, mode, args = sys.argv[1], sys.argv[2], sys.argv[3:]
with open(path + ".flock", "a") as lock:
    deadline = time.time() + 30
    while True:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except OSError:
            if time.time() > deadline:
                sys.exit("Day Open: pending-publish list is locked by another run; giving up.")
            time.sleep(0.05)
    try:
        with open(path, encoding="utf-8") as handle:
            lines = handle.read().splitlines(True)
    except FileNotFoundError:
        lines = []
    if mode == "record":
        entry = "\t".join(args) + "\n"
        if entry in lines:
            sys.exit(0)
        lines.append(entry)
    elif mode == "prune":
        valid = re.compile(r"[0-9a-f]{40,64}")
        lines = [l for l in lines
                 if not (l.split("\t")[0] == args[0] and not valid.fullmatch(l.rstrip("\n").split("\t")[-1]))]
    else:
        repo, drop = args[0], set(args[1].split())
        lines = [l for l in lines if not (l.split("\t")[0] == repo and l.rstrip("\n").split("\t")[-1] in drop)]
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".pending-")
    with os.fdopen(fd, "w", encoding="utf-8") as out:
        out.writelines(lines)
    os.replace(tmp, path)
' "$file" "$@"
}

day_open_pending_record() {
  if ! day_open_is_sha "$4"; then
    echo "Day Open: '$4' is not a commit id; not recording it." >&2
    return 1
  fi
  day_open_pending_update record "$@"
}

# Removes only the named commits of this repository; other records stay.
day_open_pending_remove() {
  [ -f "$(day_open_pending_file)" ] || return 0
  day_open_pending_update remove "$1" "$2" || {
    echo "Day Open: the pending-publish list could not be updated; the record(s) stay: $2" >&2
    return 1
  }
}

# Prints this repository's recorded commits (one per line). A record for another
# destination is skipped with a warning; a record whose commit is gone (gc, a
# rewrite by another agent), whose id is malformed, or that no longer passes the
# DayPlan-only check is dropped from the list. None of them blocks the rest.
day_open_pending_shas() {
  local repo="$1" remote="$2" ref="$3" file entry_repo entry_remote entry_ref sha missing="" malformed=0
  file=$(day_open_pending_file)
  [ -f "$file" ] || return 0
  while IFS=$'\t' read -r entry_repo entry_remote entry_ref sha; do
    [ "$entry_repo" = "$repo" ] || continue
    if ! day_open_is_sha "$sha"; then
      echo "Day Open: a record with a malformed commit id ('$sha') was dropped from the list." >&2
      malformed=1
      continue
    fi
    if [ "$entry_remote" != "$remote" ] || [ "$entry_ref" != "$ref" ]; then
      echo "Day Open: skipping $sha, recorded for $entry_remote $entry_ref, not $remote $ref." >&2
      continue
    fi
    if ! git -C "$repo" cat-file -e "$sha^{commit}" 2>/dev/null; then
      echo "Day Open: recorded commit $sha is gone from the repository; dropping the record." >&2
      missing="$missing $sha"
      continue
    fi
    if ! day_open_commit_paths_ok "$repo" "$sha"; then
      echo "Day Open: recorded commit $sha touches paths outside DayPlan/archive; dropping the record, never publishing it." >&2
      missing="$missing $sha"
      continue
    fi
    printf '%s\n' "$sha"
  done < "$file"
  [ "$malformed" -eq 0 ] || day_open_pending_update prune "$repo"
  [ -z "$missing" ] || day_open_pending_remove "$repo" "$missing"
}

# True when $path existed on $target with exactly this blob at some point.
day_open_blob_in_history() {
  local repo="$1" target="$2" path="$3" blob="$4" candidate
  while IFS= read -r candidate; do
    [ "$(git -C "$repo" rev-parse --verify --quiet "$candidate:$path")" = "$blob" ] && return 0
  done < <(git -C "$repo" log -n 50 --format=%H "$target" -- "$path")
  return 1
}

# Our commit is already published when the target holds its content for every
# path it touches (all or nothing; a path absent on both sides counts as equal).
# This covers the two-machine case: Day Close elsewhere moved yesterday's plan and
# only today's new plan file travelled in a different commit, so no patch-id matches.
# Chosen over recording sha -> published sha at salvage time: it needs no state that
# can be lost or go stale, and it is checked against the real target every time.
# Two exceptions, both narrow and both only for a file our commit ADDS (a path that
# was not in sha^), so an edit to an existing file is never covered (an edit would
# exist only in the reflog after the branch moves):
#  - archive/day-plans/<plan>: the same path on the target is authoritative, because
#    Day Close owns the archive and may have added a closing summary;
#  - current/<plan>: gone from the target because Day Close has moved it. It counts
#    as published when the archive copy exists on the target (any content, for the
#    same reason: the archived file is the plan's final form and our copy is a stale
#    earlier version), or when the target's history holds exactly our blob.
# On refusal, DAY_OPEN_UNPUBLISHED_PATH names the first path that is not covered.
day_open_content_published() {
  local repo="$1" target="$2" sha="$3" path mine theirs count=0 added
  DAY_OPEN_UNPUBLISHED_PATH=""
  while IFS= read -r -d '' path; do
    count=$((count + 1))
    mine=$(git -C "$repo" rev-parse --verify --quiet "$sha:$path" || true)
    theirs=$(git -C "$repo" rev-parse --verify --quiet "$target:$path" || true)
    [ "$mine" = "$theirs" ] && continue
    added=""
    [ -z "$(git -C "$repo" rev-parse --verify --quiet "$sha^:$path" || true)" ] && added=1
    case "$path" in
      archive/day-plans/*)
        if [ -n "$theirs" ] && [ -n "$added" ] && day_open_is_plan_path "$path"; then
          continue
        fi ;;
      current/*)
        if [ -n "$mine" ] && [ -z "$theirs" ] && day_open_is_plan_path "$path"; then
          day_open_blob_in_history "$repo" "$target" "$path" "$mine" && continue
          if [ -n "$added" ] && git -C "$repo" rev-parse --verify --quiet "$target:archive/day-plans/${path#current/}" >/dev/null; then
            continue
          fi
        fi ;;
    esac
    DAY_OPEN_UNPUBLISHED_PATH="$path"
    return 1
  done < <(git -C "$repo" diff-tree -r --no-commit-id --name-only -z --root "$sha")
  [ "$count" -gt 0 ]
}

# Our commit conflicted on the pair "move yesterday, add today" (Day Close ran on
# the other machine). Transfer only today's new plan files, as a new commit built
# with plumbing (no hooks run, author and message are the original's). An existing
# file with different content is never resolved by picking a side.
# Returns 0 committed, 3 nothing left to carry (today's plan is already there
# with identical content), 1 cannot be carried.
day_open_salvage_new_plan() {
  local wt="$1" sha="$2" path same=0 tree new
  local added=()
  while IFS= read -r -d '' path; do
    case "$path" in current/*) ;; *) continue ;; esac
    day_open_is_plan_path "$path" || continue
    if git -C "$wt" cat-file -e "HEAD:$path" 2>/dev/null; then
      [ "$(git -C "$wt" rev-parse "HEAD:$path")" = "$(git -C "$wt" rev-parse "$sha:$path")" ] || return 1
      same=$((same + 1))
      continue
    fi
    added+=("$path")
  done < <(git -C "$wt" diff-tree -r --no-commit-id --name-only --diff-filter=A -z "$sha")
  if [ "${#added[@]}" -eq 0 ]; then
    [ "$same" -gt 0 ] && return 3
    return 1
  fi
  git -C "$wt" checkout "$sha" -- "${added[@]}" >/dev/null 2>&1 || return 1
  tree=$(git -C "$wt" write-tree) || return 1
  new=$(git -C "$wt" log -1 --format=%B "$sha" | GIT_AUTHOR_NAME=$(git -C "$wt" log -1 --format=%an "$sha") \
    GIT_AUTHOR_EMAIL=$(git -C "$wt" log -1 --format=%ae "$sha") \
    GIT_AUTHOR_DATE=$(git -C "$wt" log -1 --format=%aI "$sha") \
    git -C "$wt" commit-tree "$tree" -p HEAD) || return 1
  git -C "$wt" update-ref --no-deref HEAD "$new"
}

day_open_report_dropped() {
  local sha="$1" reason="$2"
  echo "Day Open: commit $sha removed from the publication list: $reason. The local commit and unsaved work are preserved." >&2
  if command -v tg_notify >/dev/null 2>&1; then
    tg_notify "⚠️ Day Open: коммит $sha снят с публикации ($reason); локальная копия сохранена." protective || true
  fi
}

# Apply our commits onto a clean detached copy of $target and push it.
# Returns 0 published or already there (commits that could not be applied are
# listed in DAY_OPEN_DROPPED), 2 nothing publishable, 1 transient failure.
# The shared checkout is not touched.
day_open_isolated_push() {
  local repo="$1" remote="$2" ref="$3" target="$4" shas="$5"
  local base wt sha conflicts salvage applied=0 skipped=0 rc=0
  DAY_OPEN_DROPPED=""
  base=$(mktemp -d "${TMPDIR:-/tmp}/day-open-publish.XXXXXX") || return 1
  wt="$base/tree"
  git -C "$repo" worktree prune >/dev/null 2>&1
  if ! git -C "$repo" worktree add --detach --quiet "$wt" "$target" >/dev/null 2>&1; then
    rm -rf "$base"
    return 1
  fi
  for sha in $shas; do
    if git -C "$wt" cherry-pick "$sha" >/dev/null 2>&1; then
      applied=$((applied + 1))
      continue
    fi
    conflicts=$(git -C "$wt" diff --name-only --diff-filter=U | tr '\n' ' ')
    # Nothing unmerged, index and tree clean: the change is already on the target
    # (an empty cherry-pick), so it counts as published instead of retrying forever.
    if [ -z "$conflicts" ] && git -C "$wt" diff --cached --quiet && git -C "$wt" diff --quiet; then
      git -C "$wt" cherry-pick --skip >/dev/null 2>&1 || git -C "$wt" cherry-pick --abort >/dev/null 2>&1
      skipped=$((skipped + 1))
      continue
    fi
    git -C "$wt" cherry-pick --abort >/dev/null 2>&1
    if [ -z "$conflicts" ]; then
      rc=1
      break
    fi
    day_open_salvage_new_plan "$wt" "$sha"
    salvage=$?
    if [ "$salvage" -eq 0 ]; then
      applied=$((applied + 1))
    elif [ "$salvage" -eq 3 ]; then
      skipped=$((skipped + 1))
    else
      DAY_OPEN_DROPPED="${DAY_OPEN_DROPPED}${sha}"$'\n'
      day_open_report_dropped "$sha" "conflict in ${conflicts}and no new plan file to carry over"
    fi
  done
  if [ "$rc" -eq 0 ] && [ "$applied" -gt 0 ]; then
    if git -C "$wt" push --quiet "$remote" "HEAD:$ref" >/dev/null 2>&1; then
      DAY_OPEN_PUBLISHED_SHA=$(git -C "$wt" rev-parse HEAD)
    else
      rc=1
    fi
  elif [ "$rc" -eq 0 ] && [ "$skipped" -gt 0 ]; then
    DAY_OPEN_PUBLISHED_SHA=$(git -C "$repo" rev-parse "$target")
  elif [ "$rc" -eq 0 ]; then
    rc=2
  fi
  git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1
  rm -rf "$base"
  return "$rc"
}

# One publication attempt against the freshest remote state.
day_open_publish_attempt() {
  local repo="$1" remote="$2" ref="$3" shas="$4" target sha open="" equivalent
  DAY_OPEN_DROPPED=""
  git -C "$repo" fetch --quiet --refmap= "$remote" "+$ref:refs/day-open/target" 2>/dev/null || return 1
  target=$(git -C "$repo" rev-parse --verify refs/day-open/target) || return 1
  for sha in $shas; do
    if equivalent=$(day_open_published_equivalent "$repo" "$target" "$sha"); then
      DAY_OPEN_PUBLISHED_SHA="$equivalent"
    elif day_open_content_published "$repo" "$target" "$sha"; then
      DAY_OPEN_PUBLISHED_SHA="$target"
    else
      open="${open}${sha}"$'\n'
    fi
  done
  [ -n "$open" ] || return 0
  # Fast path keeps the checkout and origin identical: our single commit sits
  # directly on the remote tip, so a plain push carries nothing else.
  sha=${open%%$'\n'*}
  if [ "$open" = "${sha}"$'\n' ] && [ "$(git -C "$repo" rev-parse "$sha^" 2>/dev/null)" = "$target" ] \
      && git -C "$repo" push --quiet "$remote" "$sha:$ref" >/dev/null 2>&1; then
    DAY_OPEN_PUBLISHED_SHA="$sha"
    return 0
  fi
  day_open_isolated_push "$repo" "$remote" "$ref" "$target" "$open"
}

# After a cherry-pick publication the checkout holds the original commits and
# origin their twins (or, with Day Close elsewhere, a commit carrying only today's
# plan), so the branch would stay diverged and every later fast-forward would be
# skipped. When every local-only commit is published (patch-equivalent twin, or its
# content already on $target), move the branch to $target in one two-way tree merge:
# unrelated staged/unstaged/untracked work is kept, an overlapping edit makes Git
# refuse. Every commit the move leaves behind first gets a ref under
# refs/day-open/superseded/, so nothing lives only in the reflog. No reset, rebase
# or stash. Refusal is not an error of the publication: the reason, its class and
# the overlapping paths are left in DAY_OPEN_ADOPT_REASON/_CLASS/_PATHS.
# Class "transient" is a lost race; every other class is reported through the marker.
day_open_adopt_try() {
  local repo="$1" target="$2" head ref sha path out local_commits
  DAY_OPEN_ADOPT_REASON=""
  DAY_OPEN_ADOPT_CLASS=""
  DAY_OPEN_ADOPT_PATHS=""
  head=$(git -C "$repo" rev-parse --verify HEAD) || { DAY_OPEN_ADOPT_REASON="no HEAD"; DAY_OPEN_ADOPT_CLASS=transient; return 1; }
  ref=$(git -C "$repo" symbolic-ref --quiet HEAD) || { DAY_OPEN_ADOPT_REASON="detached HEAD"; DAY_OPEN_ADOPT_CLASS=transient; return 1; }
  [ "$head" != "$target" ] || return 0
  if [ -n "$(git -C "$repo" rev-list --merges "$target..$head")" ]; then
    DAY_OPEN_ADOPT_REASON="merge commits between the branch and the published tip"
    DAY_OPEN_ADOPT_CLASS=merges
    return 1
  fi
  local_commits=$(git -C "$repo" rev-list "$target..$head")
  for sha in $local_commits; do
    if ! day_open_published_equivalent "$repo" "$target" "$sha" >/dev/null \
        && ! day_open_content_published "$repo" "$target" "$sha"; then
      DAY_OPEN_ADOPT_REASON="local commit $sha is not published (${DAY_OPEN_UNPUBLISHED_PATH:-no twin}: its content is not on the published tip)"
      DAY_OPEN_ADOPT_CLASS=unpublished
      DAY_OPEN_ADOPT_PATHS="$DAY_OPEN_UNPUBLISHED_PATH"
      return 1
    fi
  done
  # read-tree would silently overwrite an ignored file that the move creates.
  while IFS= read -r -d '' path; do
    if [ -e "$repo/$path" ] && ! git -C "$repo" ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
      DAY_OPEN_ADOPT_REASON="untracked or ignored file would be overwritten: $path"
      DAY_OPEN_ADOPT_CLASS=untracked
      DAY_OPEN_ADOPT_PATHS="$path"
      return 1
    fi
  done < <(git -C "$repo" diff --name-only --diff-filter=A -z "$head" "$target")
  if ! out=$(git -C "$repo" read-tree -m -u "$head" "$target" 2>&1); then
    DAY_OPEN_ADOPT_REASON="overlapping local edits: $(echo "$out" | tr '\n' ' ')"
    DAY_OPEN_ADOPT_CLASS=overlap
    # Read-tree names only the first clash; the real overlap is every path that differs
    # between the branch and the tip AND carries local edits.
    DAY_OPEN_ADOPT_PATHS=$(comm -12 \
      <(git -C "$repo" -c core.quotepath=off diff --name-only "$head" "$target" | sort) \
      <(git -C "$repo" -c core.quotepath=off status --porcelain --untracked-files=all | cut -c4- | sort) \
      | tr '\n' ' ')
    return 1
  fi
  for sha in $local_commits; do
    git -C "$repo" update-ref "refs/day-open/superseded/$sha" "$sha"
  done
  if git -C "$repo" update-ref -m "day-open: adopt published twins" "$ref" "$target" "$head" 2>/dev/null; then
    return 0
  fi
  for sha in $local_commits; do
    git -C "$repo" update-ref -d "refs/day-open/superseded/$sha"
  done
  DAY_OPEN_ADOPT_CLASS=transient
  # Roll the tree back only while HEAD is still where we started; if another agent
  # moved it meanwhile, undoing would mix their commit with a reverted tree.
  if [ "$(git -C "$repo" rev-parse --verify HEAD 2>/dev/null)" = "$head" ]; then
    git -C "$repo" read-tree -m -u "$target" "$head" >/dev/null 2>&1
    DAY_OPEN_ADOPT_REASON="branch update was refused; tree restored"
  else
    DAY_OPEN_ADOPT_REASON="HEAD moved during the update; the merged tree was left as is, not rolled back"
  fi
  return 1
}

# Wrapper: success clears the sync-blocked marker and prunes old superseded refs;
# a lasting refusal is reported through the marker (once per reason).
day_open_adopt_twins() {
  if day_open_adopt_try "$1" "$2"; then
    day_open_sync_marker_clear "$1"
    day_open_prune_superseded "$1" "$2"
    return 0
  fi
  if [ "$DAY_OPEN_ADOPT_CLASS" != transient ]; then
    day_open_sync_blocked "$1" "$2" "$DAY_OPEN_ADOPT_CLASS" "$DAY_OPEN_ADOPT_REASON" "$DAY_OPEN_ADOPT_PATHS"
  fi
  return 1
}

# day_open_publish <repo> [commit]: record <commit> (if given), then publish
# every recorded commit of this repository. Sets DAY_OPEN_PUBLISHED_SHA.
day_open_publish() {
  local repo="$1" sha="${2:-}" root dest remote ref shas fresh rc=1
  DAY_OPEN_PUBLISHED_SHA=""
  DAY_OPEN_DROPPED=""
  root=$(git -C "$repo" rev-parse --show-toplevel) || return 1
  dest=$(day_open_publish_target "$root") || return 1
  remote=${dest%% *}
  ref=${dest#* }
  if [ -n "$sha" ]; then
    if ! day_open_is_sha "$sha"; then
      echo "Day Open: '$sha' is not a commit id; refusing to publish it." >&2
      return 1
    fi
    if ! day_open_commit_paths_ok "$root" "$sha"; then
      echo "Day Open: commit $sha touches paths outside DayPlan/archive; not publishing it automatically (preserved locally)." >&2
      return 1
    fi
    day_open_pending_record "$root" "$remote" "$ref" "$sha" || return 1
  fi
  shas=$(day_open_pending_shas "$root" "$remote" "$ref") || return 1
  for _attempt in 1 2 3; do
    if [ -z "$shas" ]; then
      echo "Day Open: no recorded DayPlan commit to publish." >&2
      return 1
    fi
    day_open_publish_attempt "$root" "$remote" "$ref" "$shas"
    rc=$?
    if [ -n "$DAY_OPEN_DROPPED" ]; then
      day_open_pending_remove "$root" "$DAY_OPEN_DROPPED"
      shas=$(day_open_pending_shas "$root" "$remote" "$ref") || return 1
    fi
    [ "$rc" -eq 2 ] && break
    if [ "$rc" -eq 0 ]; then
      day_open_pending_remove "$root" "$shas"
      # Target: the freshest origin that still contains what we published.
      fresh="$DAY_OPEN_PUBLISHED_SHA"
      if git -C "$root" fetch --quiet --refmap= "$remote" "+$ref:refs/day-open/target" 2>/dev/null \
          && git -C "$root" merge-base --is-ancestor "$DAY_OPEN_PUBLISHED_SHA" refs/day-open/target 2>/dev/null; then
        fresh=$(git -C "$root" rev-parse refs/day-open/target)
      fi
      day_open_adopt_twins "$root" "$fresh" \
        || echo "Day Open: shared checkout left on its own commits, not moved automatically: $DAY_OPEN_ADOPT_REASON" >&2
      return 0
    fi
  done
  echo "Day Open: publication failed; local commit and unsaved work are preserved, the commit stays recorded for the next run." >&2
  return 1
}

# --- CLI args ---
FORCE=false
PROBE=false
SCAFFOLD_ONLY=false
DATE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force|-f)      FORCE=true; shift ;;
    # --probe (WP-484, test stand): dry-run — real preflight+scaffold+LLM-fill+checks,
    # writes to a "(probe)" suffixed file (never the real DayPlan), skips commit/push/
    # archive-move/TG. Implies --force (guards are about real-file state, irrelevant here).
    --probe)         PROBE=true; FORCE=true; shift ;;
    # --scaffold-only (issue #434): the deterministic skeleton (step 3) needs
    # no LLM Proxy at all — only step 4 (LLM Fill) does. Before this flag,
    # an unreachable/unprovisioned proxy made step 2's healthcheck abort the
    # whole run, so an install without a proxy could never get even the
    # skeleton. The incomplete draft stays outside the governance repo and
    # returns 10: it is never published as an opened day (issue #983).
    --scaffold-only) SCAFFOLD_ONLY=true; shift ;;
    --date|-d)       DATE="$2"; shift 2 ;;
    *)               DATE="$1"; shift ;;
  esac
done
# issue #924: an explicit --date/-d or positional date is the caller's exact choice
# and is never second-guessed below; only the auto "today" default is a candidate
# for the day_boundary shift (applied once $CONFIG is known, further down).
DATE_WAS_AUTO=false
[ -z "$DATE" ] && DATE_WAS_AUTO=true
DATE="${DATE:-$(date +%Y-%m-%d)}"
PROBE_START_S=$SECONDS

# --- Secrets (must load before the first tg_notify call of a normal run — WP-5 Ubuntu-audit
# П2, 2026-07-22: TG_TOKEN/TG_CHAT used to be assigned after both the D2-dedup and
# pipeline-started notifications, so those two silently no-op'd every run) ---
source_env_if_present() {
  [ -f "$1" ] || return 0
  set -a
  source "$1"
  set +a
}
load_secrets() {
  source_env_if_present "$HOME/.config/aist/env"
  source_env_if_present "$HOME/IWE/.secrets/anthropic_key.env"  # Anthropic API key for llm-proxy (WP-356)
  # WP-484 Ф50b named this file as the readable ANTHROPIC_API_KEY source for the
  # remote-gateway fallback below (line ~534) but never sourced it -- the fallback
  # chain silently resolved to empty and the authorized probe 401'd (found live
  # 2026-08-05 running --probe ahead of a scheduled test run).
  source_env_if_present "$HOME/.iwe/.proxy-env"
  # WP-484 F64 (06.08): TELEGRAM_* live in ~/.secrets/tg-bots (canonical source per
  # lib/telegram.sh) — none of the three files above carry them on the remote server, so every
  # tg_notify on the server (incl. the "День открыт" digest and all aborts) was a
  # silent no-op since the migration. Same fix as day-open-pipeline-watchdog.sh.
  source_env_if_present "$HOME/.secrets/tg-bots"
  TG_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
  TG_CHAT="${TELEGRAM_CHAT_ID:-}"
}

# --- Helper: send TG notification, transport unified onto lib/telegram.sh ---
# MUST be defined before first call (regression fix 2026-06-29). WP-538 Ф3:
# was a raw curl POST duplicating http_code/ok:true checking that
# scripts/lib/telegram.sh already does, with 3x retry instead of one shot.
# Template note: the admission-gate rate limiter (telegram_send_gated) lives
# only in the author's personal governance repo so far, not this template's
# notification-render.sh — this promotion carries the transport fix only, not
# a gated call site.
tg_notify() {
  local msg="$1"
  if [ "$PROBE" = "true" ]; then
    echo "  [probe: TG suppressed] $msg" | head -1
    return 0
  fi
  # The unattended strategist owns failure reporting and retries. Intermediate
  # pipeline notices would otherwise precede its one actionable alarm, while a
  # successful digest or an intentional deferral still needs direct delivery.
  if [ "${DAY_OPEN_NOTIFICATION_OWNER:-}" = "strategist" ] \
     && [ "${2:-}" != "terminal" ] && [ "${2:-}" != "protective" ]; then
    echo "  [strategist: intermediate TG notice deferred to owner]"
    return 0
  fi
  # A scheduler retry after a deferral whose notice was DELIVERED earlier today (strategist.sh sets
  # DAY_OPEN_QUIET_RETRY=1 from the "[tg delivered]" line below): the "started" and "deferred" notices went out with
  # the first run, and the scheduler comes back up to seven times a day, so repeating them sent up to fourteen
  # messages a day. The digest and every alarm still go out: the patterns match the START of the message (its emoji
  # and fixed words), not a phrase somewhere inside a digest or an alarm reason (red team, round 37).
  if [ "${DAY_OPEN_QUIET_RETRY:-}" = "1" ]; then
    case "$msg" in
      "🌅 Day Open pipeline started for "*|"⏸ Day Open "*" отложен: "*)
        echo "  [retry after a deferral: TG suppressed] $msg" | head -1
        return 0
        ;;
    esac
  fi
  if [ -z "${TG_TOKEN:-}" ] || [ -z "${TG_CHAT:-}" ]; then
    echo "  [no tg credentials] $msg" | head -1
    return 1
  fi
  telegram_send "$msg" || { echo "  [tg delivery FAILED] $msg" | head -2; return 1; }
  # What strategist.sh reads: only a delivered deferral notice lets the day's retries keep quiet (red team, round 38:
  # after a failed first send the retries must try again, not stay silent all day).
  echo "  [tg delivered] $msg" | head -1
  return 0
}

# A refusal while the workspace is being resolved (below) happens before the normal path
# loads the secrets and the Telegram transport (after the snapshot refresh child below has
# started with the plain environment), so load them here and report the way abort() does:
# a failed night run must not be silent (issue #974). The exit code is unchanged.
early_abort() {
  local reason="$1"
  echo "❌ $reason" >&2
  if [ -f "$SCRIPT_HOME/lib/telegram.sh" ]; then
    # shellcheck source=/dev/null
    . "$SCRIPT_HOME/lib/telegram.sh"
    load_secrets
    tg_notify "🚨 Day Open pipeline aborted: ${reason}" || true
  fi
  exit 1
}

# issue #974: strategist.sh runs the copy inside the template checkout
# (<workspace>/FMT-exocortex-template/scripts/), a SIBLING of the governance
# repo, so deriving the repo from this file's location made the template look
# like the governance repo. The template ships update-manifest.json at its root
# and a governance repo never does: for a template copy the workspace root and
# the governance repo come from the environment (lib/common.sh, as in
# day-open-preflight.sh); a copy promoted into the governance repo itself keeps
# deriving both from its location, which also beats a stale inherited environment.
if [ -f "$SCRIPT_HOME/../update-manifest.json" ]; then
  [ -f "$SCRIPT_HOME/lib/common.sh" ] \
    || early_abort "lib/common.sh не найден рядом с $0 — копия шаблона неполная, обновите шаблон"
  # Subshells: common.sh defines its own tg_notify(), which would replace the one above.
  # shellcheck source=/dev/null
  IWE="$( . "$SCRIPT_HOME/lib/common.sh" && iwe_resolve_root 2>&1 )" \
    || early_abort "Не определён корень рабочего пространства: $IWE"
  # shellcheck source=/dev/null
  GOV_REPO="$( . "$SCRIPT_HOME/lib/common.sh" && iwe_resolve_governance_repo )"
  DS_STRATEGY="$IWE/$GOV_REPO"
  if [ ! -d "$DS_STRATEGY" ]; then
    if [ -n "${IWE_WORKSPACE:-}" ]; then ROOT_SOURCE="IWE_WORKSPACE"
    elif [ -n "${IWE_ROOT:-}" ]; then ROOT_SOURCE="IWE_ROOT"
    else ROOT_SOURCE="расположение скрипта (или WORKSPACE_DIR из .exocortex.env)"
    fi
    early_abort "Governance-репозиторий не найден: $DS_STRATEGY. Корень $IWE взят из: $ROOT_SOURCE — проверьте, что он верный и не устарел, и что в нём есть каталог $GOV_REPO (имя задаёт переменная IWE_GOVERNANCE_REPO; без неё берётся имя репозитория управления по умолчанию)"
  fi
  SCRIPTS_FALLBACK="$SCRIPT_HOME"
else
  DS_STRATEGY="$(cd "$SCRIPT_HOME/.." && pwd)"
  IWE="$(cd "$DS_STRATEGY/.." && pwd)"
  GOV_REPO="$(basename "$DS_STRATEGY")"
  SCRIPTS_FALLBACK="$IWE/scripts"
fi
# Child patch steps (4.2/4.3) fall back to ~/IWE when IWE_ROOT is unset —
# a launchd/cron env typically has no IWE_ROOT, so pass the resolved root down.
export IWE_ROOT="$IWE"
# issue #756: session-guard.sh, day-open-scaffold.sh and the other shared helpers
# called below live inside the template (FMT-exocortex-template/scripts/), not
# directly under $IWE/scripts -- that directory does not exist on any install
# where the template sits as a subdirectory of the workspace (the layout
# setup.sh itself produces). $IWE_SCRIPTS is written once at install/update time
# (install-iwe-paths.sh's .iwe-paths, sourced via ~/.zshenv; the systemd unit
# templates bake it into Environment=) rather than re-resolved on every
# invocation -- an inherited value from a DIFFERENT checkout (e.g. running this
# exact script from an isolated worktree with the main workspace's env still
# exported) would silently win over the co-located fallback. The fallback is the
# directory this copy runs from for a template copy (issue #974: there is no
# <workspace>/scripts on that layout) and $IWE/scripts for a promoted copy, for
# an install where scripts really were flattened into the workspace root.
IWE_SCRIPTS="${IWE_SCRIPTS:-$SCRIPTS_FALLBACK}"
export IWE_SCRIPTS
# Every child process, including the background snapshot refresh below, must
# resolve the same governance repository as this pipeline. launchd/cron do not
# inherit the interactive shell setting, so export the one resolved above before
# the first child process starts.
export IWE_GOVERNANCE_REPO="$GOV_REPO"
CONFIG="$DS_STRATEGY/exocortex/day-rhythm-config.yaml"

# issue #924: day_boundary ("HH:MM", default none = no shift) lets the pilot say
# that work done after midnight but before this hour still belongs to the day
# that's ending, not a new one. Only the auto "today" default is a candidate —
# an explicit --date/-d is the caller's exact choice and is never second-guessed.
# Reads $IWE/memory/day-rhythm-config.yaml (the pilot's live config), not
# $CONFIG ($DS_STRATEGY/exocortex/..., a snapshot day-close.sh only refreshes
# once at Day Close) -- a same-day edit to day_boundary must take effect on
# this same night's run, not wait for the next Day Close to refresh the
# snapshot. day-open-scaffold.sh (step 3 below) already treats the live copy
# as authoritative for the same reason (it passes it explicitly to
# day-open-preflight.sh), this is the same source for the same key.
# Scoped to the day_open: block (same precaution as STRATEGY_DAY_NAME below —
# a same-named key elsewhere can't hijack this lookup; resets on the next
# top-level key so a later block's own day_boundary can't be picked up
# either) and skips commented-out lines: a bare top-level grep would also
# match the shipped default's commented-out example line, silently turning
# the shift on. Read for any date: the commit window of "yesterday" follows
# the boundary even when --date is given explicitly.
DAY_BOUNDARY=$(awk '
  /^[^[:space:]]/ && !/^day_open:/ { f=0 }
  /^day_open:/ { f=1 }
  f && /day_boundary:/ && !/^[[:space:]]*#/ { print; exit }
' "$IWE/memory/day-rhythm-config.yaml" 2>/dev/null \
  | sed -E 's/.*day_boundary:[[:space:]]*"?([0-9]{1,2}:[0-9]{2})"?.*/\1/')
if [ "$DATE_WAS_AUTO" = true ] && [[ "$DAY_BOUNDARY" =~ ^([0-9]{1,2}):([0-9]{2})$ ]]; then
  boundary_min=$(( 10#${BASH_REMATCH[1]} * 60 + 10#${BASH_REMATCH[2]} ))
  now_min=$(( 10#$(date +%H) * 60 + 10#$(date +%M) ))
  if [ "$now_min" -lt "$boundary_min" ]; then
    DATE=$(date -j -v-1d -f "%Y-%m-%d" "$DATE" "+%Y-%m-%d" 2>/dev/null \
      || date -d "$DATE - 1 day" "+%Y-%m-%d" 2>/dev/null)
  fi
fi

# issue #924: the day boundary also decides which commits belong to "yesterday".
# Half-open window [YDAY <boundary>, DATE <boundary>) as "SINCE|UNTIL" for
# `git log`: a commit exactly at the boundary opens the new day, none is counted
# twice. No boundary (or 00:00) keeps the calendar day. KEEP IN SYNC with the
# copy in day-open-pipeline.sh / day-open-scaffold.sh (test_issue_924 compares them).
iwe_day_window() {
  local yday="$1" today="$2" b="${3:-}" bm=0 em
  if [[ "$b" =~ ^([0-9]{1,2}):([0-9]{2})$ ]]; then
    bm=$(( 10#${BASH_REMATCH[1]} * 60 + 10#${BASH_REMATCH[2]} ))
  fi
  if [ "$bm" -eq 0 ]; then
    printf '%s 00:00:00|%s 23:59:59' "$yday" "$yday"
    return 0
  fi
  em=$(( bm - 1 ))
  printf '%s %02d:%02d:00|%s %02d:%02d:59' \
    "$yday" $(( bm / 60 )) $(( bm % 60 )) "$today" $(( em / 60 )) $(( em % 60 ))
}

# shellcheck source=lib/ledger-path.sh
. "$SCRIPT_HOME/lib/ledger-path.sh"

# Quarantine only provably orphaned semaphores (dead recorded pid). Old
# semaphores without pid proof are reported and kept for manual review.
mkdir -p "$IWE/.iwe-runtime"
bash "$IWE_SCRIPTS/session-guard.sh" audit --cleanup-orphans \
  >> "$IWE/.iwe-runtime/session-orphan-sweep.log" 2>&1 || true

# ============================================
# 1.5. Opportunistic derived_snapshot refresh (WP-425 Level 2a)
# Runs update-derived-snapshot.py --if-stale-days=10 in background.
# Non-blocking: Day Open continues even if the refresh fails.
#
# Above every early-exit branch on purpose (WP-5 VDV correction, 2026-07-09):
# it serves guide freshness, not today's plan, so it must fire on every
# invocation regardless of how Day Open itself resolves. `--if-stale-days`
# is the only throttle — don't move it back below an early-exit.
# Runs before secrets are sourced further down — fine today, since
# update-derived-snapshot.py authenticates via the claude CLI session, not
# via any of AIST_ENV/ANTHROPIC_ENV. If it ever needs those, source secrets
# before this block instead of moving the block back down.
# ============================================
echo "=== 1.5. Snapshot refresh (opportunistic) ==="
(python3 "$SCRIPT_HOME/update-derived-snapshot.py" --if-stale-days 10 \
  >> "$DS_STRATEGY/logs/personal-guide-update.log" 2>&1 || true) &
SNAPSHOT_PID=$!
echo "  snapshot refresh pid=$SNAPSHOT_PID (background, non-blocking)"

# Telegram transport behind tg_notify() (defined near the top of this file).
# shellcheck source=lib/telegram.sh
. "$SCRIPT_HOME/lib/telegram.sh"

# --- Helper: portable single-field read from a Y-m-d date string ---
# BSD `date -j` (macOS) vs GNU `date -d` (Linux/remote server) -- third use of this
# exact shape (P2: YDAY_DOW below was the second, inlined before this existed).
portable_date_field() {
  local input="$1" fmt="$2"
  date -j -f "%Y-%m-%d" "$input" "$fmt" 2>/dev/null || date -d "$input" "$fmt" 2>/dev/null
}

# Correlate kind and for_date inside one parsed event. Grepping the two fields
# independently can combine different events from a mixed legacy ledger and report a
# close that never happened for the requested date.
ledger_ref_has_digest_for_date() {
  local ledger_rel="$1"
  local target="$2"
  local allow_legacy="$3"
  local ref content
  # WP-529 (continuation, 19.08): resolved once per function call, not at
  # script top-level — this function only runs on the checks-runner path, and
  # a script-wide resolve would run PyYAML detection even for invocations
  # that never reach it. No bare-python3 fallback: the resolver's own first
  # candidate is already bare `python3` from PATH.
  local _resolved_python3
  _resolved_python3=$("$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/find-python3.sh" 2>/dev/null) || _resolved_python3=""
  [ -n "$_resolved_python3" ] || return 1

  for ref in HEAD origin/main; do
    content=$(cd "$DS_STRATEGY" && git show "$ref:$ledger_rel" 2>/dev/null) || content=""
    [ -n "$content" ] || continue
    if printf '%s' "$content" | "$_resolved_python3" -c '
import sys

import yaml

target, allow_legacy = sys.argv[1], sys.argv[2] == "true"
try:
    doc = yaml.safe_load(sys.stdin.read()) or {}
except Exception:
    raise SystemExit(1)
events = doc.get("events") if isinstance(doc, dict) else []
for event in events if isinstance(events, list) else []:
    if not isinstance(event, dict) or event.get("kind") != "facts_digest":
        continue
    data = event.get("data")
    if not isinstance(data, dict):
        continue
    if data.get("for_date") == target or (allow_legacy and "for_date" not in data):
        raise SystemExit(0)
raise SystemExit(1)
' "$target" "$allow_legacy"; then
      return 0
    fi
  done
  return 1
}

# --- Secrets: loaded here, after the snapshot refresh child was started with the
# plain environment (see 1.5 above) and before the first tg_notify call ---
load_secrets

# --- Guard: already published today (D2 dedup) ---
# Checks by file presence in git history, not commit message prefix —
# so both automated ("feat(dayplan):") and manual ("day-open:") commits are detected.
# WP-484 (2026-07-14): fetch origin first. Day Open now runs independently from
# both the pilot's Mac (01:00) and the always-on remote server (scheduler
# catch-up, 04:00-22:00) as a deliberate primary+backup pair — a local-only git
# log missed a same-day commit the other side had already pushed, so whichever
# ran second redid the whole scaffold+LLM-fill for nothing.
if [ "$FORCE" != "true" ]; then
  cd "$DS_STRATEGY" || exit 1
  DAYPLAN_FILE="current/DayPlan $DATE.md"
  OTHER_COMMIT=""
  if git fetch --quiet --refmap= origin '+refs/heads/main:refs/remotes/origin/main' 2>/dev/null; then
    OTHER_COMMIT=$(git log -1 --format=%H refs/remotes/origin/main --since="$DATE 00:00:00" --until="$DATE 23:59:59" -- "$DAYPLAN_FILE" 2>/dev/null) || OTHER_COMMIT=""
  fi
  if [ -n "$OTHER_COMMIT" ]; then
    echo "  DayPlan already published today ($DATE, this machine or the other) — nothing to do."
    tg_notify "📋 DayPlan $DATE already published today. Use --force to regenerate." terminal
    # Record success heartbeat here too: the other machine did the work, but
    # day-open-pipeline-watchdog.sh only checks THIS machine's heartbeat file.
    # Without this, every day the two machines settle this D2 race the "losing"
    # side never writes success — its watchdog fires a false dead-man's-switch
    # alert even though a DayPlan genuinely exists for today.
    mkdir -p "$HOME/.claude/state"
    jq -n \
      --arg date "$DATE" \
      --arg commit "$OTHER_COMMIT" \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{date: $date, commit_hash: $commit, timestamp: $ts, status: "success", note: "done by the other machine"}' \
      > "$HOME/.claude/state/day-open-pipeline-last-success.json"
    exit 0
  fi
  LOCAL_COMMIT=$(git log -1 --format=%H HEAD --since="$DATE 00:00:00" --until="$DATE 23:59:59" -- "$DAYPLAN_FILE" 2>/dev/null) || LOCAL_COMMIT=""
  if [ -n "$LOCAL_COMMIT" ]; then
    # A previous run committed but could not publish. Publish that exact commit
    # from an isolated copy instead of regenerating or failing forever.
    if day_open_publish "$DS_STRATEGY" "$LOCAL_COMMIT"; then
      echo "  DayPlan was committed locally but not published; published now ($DAY_OPEN_PUBLISHED_SHA) — nothing to regenerate."
      tg_notify "📋 DayPlan $DATE опубликован из локального коммита (восстановление после сбоя публикации)." terminal
      mkdir -p "$HOME/.claude/state"
      jq -n \
        --arg date "$DATE" \
        --arg commit "$DAY_OPEN_PUBLISHED_SHA" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{date: $date, commit_hash: $commit, timestamp: $ts, status: "success", note: "published from a local commit after an earlier failure"}' \
        > "$HOME/.claude/state/day-open-pipeline-last-success.json"
      exit 0
    fi
    echo "  DayPlan is committed locally and publication still fails; the commit stays recorded, regeneration skipped."
    tg_notify "⚠️ DayPlan $DATE сохранён локально, публикация не удалась. Коммит записан для повтора, повторная генерация пропущена; проверьте сеть или конфликт." protective
    exit 1
  fi
fi

# Notify pilot that pipeline has started (helps diagnose silent hangs)
tg_notify "🌅 Day Open pipeline started for $DATE"

# --- Lock file (prevent concurrent runs) ---
# DAY_OPEN_LOCK_FILE exists so tests can keep the lock inside a throwaway dir
# instead of the machine-wide /tmp path a real run holds.
LOCK_FILE="${DAY_OPEN_LOCK_FILE:-/tmp/day-open-pipeline.lock}"
if [ -f "$LOCK_FILE" ]; then
  LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
  if kill -0 "$LOCK_PID" 2>/dev/null; then
    echo "❌ Day Open already running (PID $LOCK_PID). Abort."
    exit 0
  else
    rm -f "$LOCK_FILE"
  fi
fi
echo $$ > "$LOCK_FILE"
# Trap set later (cleanup(), near PROXY_PID) already does `rm -f "$LOCK_FILE"` —
# a duplicate trap here would just get overwritten by that later `trap ... EXIT`.

# --- State store (pipeline heartbeat) ---
STATE_DIR="$HOME/.claude/state"
HEARTBEAT_FILE="$STATE_DIR/day-open-pipeline-last-success.json"
mkdir -p "$STATE_DIR"

# --- Paths ---
CURRENT_DIR="$DS_STRATEGY/current"
DAYPLAN_NAME="DayPlan $DATE.md"
if [ "$PROBE" = "true" ]; then
  DAYPLAN_NAME="DayPlan $DATE (probe).md"
fi
DAYPLAN_PATH="$CURRENT_DIR/$DAYPLAN_NAME"
if [ "$SCAFFOLD_ONLY" = "true" ] && [ "$PROBE" != "true" ]; then
  # Keep an incomplete draft separate from the canonical plan. A later full
  # run can write current/DayPlan without overwriting edits to this draft or
  # making git-dirty-guard mistake the draft for governance work.
  DAYPLAN_PATH="$IWE/.tmp/day-open-scaffold/$DAYPLAN_NAME"
fi
# WP-484 27.07: старый формат "WeekPlan W{N} {дата}.md" сменился на
# "WeekPlan {год}-W{N} {дата} (night-cycle).md" (week-open-orchestrator.sh) — жёсткий
# glob "WeekPlan W*.md" переставал матчить ЛЮБОЙ реальный файл сразу как только старый
# формат исчез из current/ (обнаружено 27.07 при сборке --probe: пайплайн абортил бы на
# каждом прогоне, включая strategy_day, ещё ДО собственной проверки этого случая —
# тот же класс регрессии, что WP-149 уже поймал у build-strategic-context.py). Принимает
# оба формата, берёт самый свежий по mtime (не первый по алфавиту — конвенции WeekPlan
# W* и WeekPlan {год}-W* сортируются по-разному, mtime однозначен).
# Excludes "(probe)" files defensively (WP-484 27.07, independent review): a
# week-open-orchestrator.sh --probe run writes a "(probe)"-suffixed WeekPlan into
# this same directory — if it were ever left behind (crash before its own cleanup),
# this glob picking "newest by mtime" would otherwise silently feed test content
# into the pilot's real DayPlan. Belt-and-suspenders alongside that script's own
# end-of-run cleanup.
WEEKPLAN_PATH=$(ls -t "$CURRENT_DIR"/WeekPlan\ *.md 2>/dev/null | grep -v '(probe)' | head -1 || true)
WP_REGISTRY="$DS_STRATEGY/docs/WP-REGISTRY.md"
# WP-7 Ф-DRIFT-DATA-PIPELINES D1 (13.07): было memory/cp-profile.json, который не
# писал ни один механизм. update-derived-snapshot.py (шаг 1.5 выше) уже пишет сюда.
# issue #1132: inbox/WP-425/ — платформенный номер РП автора, не имеющий смысла
# для чужого governance-репо; путь должен совпадать с _resolve_snapshot_path().
CP_PROFILE="$DS_STRATEGY/.cache/derived_snapshot.json"
CALENDAR_OUT="$IWE/.tmp/calendar-$DATE.txt"
# issue #877: the shipped script carries NO built-in gateway address. The old
# default was the maintainer's private Railway gateway, which a user install can
# never authenticate against (no secret for it is provisioned anywhere), so the
# failure surfaced as an HTTP 401 that reads like a key-rotation problem.
# Resolution order: explicit LLM_PROXY_URL, then PLATFORM_LLM_PROXY_URL (from the
# environment, or from the workspace env file that setup.sh writes), else empty
# and step 2 stops with a direct "gateway not configured" message. The platform
# value carries a "/v1" suffix, while every call below appends its own "/v1/...".
if [ -z "${LLM_PROXY_URL:-}" ]; then
  _platform_proxy="${PLATFORM_LLM_PROXY_URL:-}"
  if [ -z "$_platform_proxy" ] && [ -f "$SCRIPT_HOME/lib/common.sh" ]; then
    # Read in a subshell: common.sh defines its own tg_notify(), which would replace
    # this pipeline's (probe-aware, telegram.sh-based) one for the rest of the run.
    # shellcheck source=lib/common.sh
    _platform_proxy=$( . "$SCRIPT_HOME/lib/common.sh" && iwe_env_get "$IWE/.exocortex.env" PLATFORM_LLM_PROXY_URL 2>/dev/null ) || _platform_proxy=""
  fi
  _platform_proxy="${_platform_proxy%/}"
  _platform_proxy="${_platform_proxy%/v1}"
  # Installs made before this fix carry the address older setup.sh wrote as an
  # active value; it answers HTTP 404 on every path. Only this one known value is
  # ignored (with a note) - any other user-supplied URL is left alone.
  if [ "$_platform_proxy" = "https://llm.aisystant.com" ]; then
    echo "  Note: PLATFORM_LLM_PROXY_URL is the legacy placeholder older setup.sh wrote (that address does not answer) - ignored." >&2
    _platform_proxy=""
  fi
  LLM_PROXY_URL="$_platform_proxy"
  unset _platform_proxy
fi
# Every call below appends its own "/v1/...": accept an explicit URL given with the
# suffix or a trailing slash too, instead of probing ".../v1/v1/health".
LLM_PROXY_URL="${LLM_PROXY_URL%/}"
LLM_PROXY_URL="${LLM_PROXY_URL%/v1}"
PROXY_PORT="${PROXY_PORT:-18765}"
PROXY_PID=""
# WP-484 Ф48b (04.08): a remote gateway is the normal target. This pipeline runs
# on either machine of the dual-machine pair (see note below) -- a Mac-local
# address is simply wrong on the remote server, and was the root cause of the
# 30.07/02.08/04.08 stale-credential recurrences on the Mac. Local-only
# branches below (spawn-if-missing, kill-on-port self-heal) only make sense
# for an actual localhost target, so they're gated on PROXY_IS_LOCAL.
case "$LLM_PROXY_URL" in
  http://localhost:*|http://127.0.0.1:*) PROXY_IS_LOCAL=true ;;
  *) PROXY_IS_LOCAL=false ;;
esac

# --- Helper: reap a stale .git/HEAD.lock left by a crashed prior git process ---
# WP-484 Ф95 (15.08): a run that dies mid-commit (any abort() after `git add`)
# leaves this lock behind — nothing swept it, so it blocked every commit until
# a human found it manually. Only ever removes a lock whose holder is provably
# dead (no live git process at all); a live git process (this run's own, or a
# genuinely concurrent one) is left untouched, matching the same PID-liveness
# principle session-guard.sh already uses for semaphores.
reap_stale_git_lock() {
  local lock="$DS_STRATEGY/.git/HEAD.lock"
  [ -f "$lock" ] || return 0
  # Match on this repo's own path, not a bare `git` process name — the server
  # runs unrelated git activity for other repos/users constantly, and a
  # name-only match would find those and never reap anything.
  if pgrep -f "git.*$DS_STRATEGY" >/dev/null 2>&1; then
    echo "  git lock present but a git process for this repo is running — leaving it (may be legitimate)"
    return 0
  fi
  echo "  stale git lock found, no live git process for this repo — removing: $lock"
  rm -f "$lock"
}

# --- Helper: abort with notification + proxy cleanup ---
# issue #893: a caller (strategist.sh's morning scenario) needs to tell "no
# gateway configured -- retry with --scaffold-only" apart from every other
# abort reason without re-deriving LLM_PROXY_URL/PLATFORM_LLM_PROXY_URL
# itself (that resolution already lives in one place, §2 above, and #894's
# whole point is not to grow a second copy of it). A distinct exit code is
# the same contract this file already uses for exit 7/8 below.
abort() {
  local reason="$1" code="${2:-1}"
  echo "❌ $reason"
  tg_notify "🚨 Day Open pipeline aborted: ${reason}"
  if [ "$PROBE" = "true" ]; then
    local wall_min=$(( (SECONDS - PROBE_START_S) / 60 ))
    echo ""
    echo "=== PROBE SUMMARY ==="
    echo "  date=$DATE verdict=🔴 red (abort) reason=\"$reason\" wall_min=$wall_min attention_min=0"
  fi
  exit "$code"
}

# Cleanup proxy on exit
cleanup() {
  if [ -n "$PROXY_PID" ]; then
    kill "$PROXY_PID" 2>/dev/null || true
    wait "$PROXY_PID" 2>/dev/null || true
    PROXY_PID=""
  fi
  rm -f "$LOCK_FILE" 2>/dev/null || true
  # Same class of leak as week-open-orchestrator.sh/month-open-orchestrator.sh
  # (WP-484 27.07 independent review): a "(probe)"-suffixed DayPlan left behind
  # after this exits (crash, or --probe run not rerun) sits in current/ where the
  # WeekPlan glob above already defends against — but nothing was cleaning up
  # THIS script's own probe file. Found running night-cycle-day.sh --probe.
  if [ "$PROBE" = "true" ]; then
    rm -f "$DAYPLAN_PATH" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if [ "$SCAFFOLD_ONLY" = "true" ] && [ "$PROBE" != "true" ] && [ -e "$DAYPLAN_PATH" ]; then
  echo "  Incomplete scaffold already exists; preserving it unchanged: $DAYPLAN_PATH"
  echo "  Edits in this draft are not copied automatically into a fully filled DayPlan."
  exit 10
fi

# ============================================
# 0. Extension graph — "before" hooks (WP-529 Ф11)
# ============================================
# extensions/day-open.before*.md — same bash-block-in-Markdown mechanism as
# the existing "checks" hook (day-open-checks-runner.sh), so it runs
# correctly unattended under launchd/cron with no LLM in the loop. No files
# present → day-open-hooks-runner.sh no-ops silently (most installs won't
# have one). A failing "before" hook blocks Day Open the same way a failing
# "checks" block does — a before-hook can run ahead of and mutate
# DS_STRATEGY state, so letting its failure through as a soft warning risks
# committing whatever it left behind (Codex review, 2026-08-28).
echo "=== 0. Extension graph: before ==="
BEFORE_HOOK_OUT=$(bash "$SCRIPT_HOME/day-open-hooks-runner.sh" before 2>&1)
BEFORE_HOOK_EXIT=$?
echo "$BEFORE_HOOK_OUT"
if [ $BEFORE_HOOK_EXIT -ne 0 ]; then
  tg_notify "❌ Day Open aborted: a 'before' extension hook failed for $DATE. See output above."
  abort "before-hook failed — see output above"
fi

# ============================================
# 1. Pre-flight healthcheck
# ============================================
echo "=== 1. Pre-flight ==="
PREFLIGHT_JSON=$(bash "$IWE_SCRIPTS/day-open-preflight.sh" "$DATE" "$CONFIG" 2>/dev/null || echo '{"calendar":"unknown"}')
CALENDAR_PF=$(echo "$PREFLIGHT_JSON" | jq -r '.calendar // "unknown"')
SCOUT_PF=$(echo "$PREFLIGHT_JSON" | jq -r '.scout // "unknown"')
TRIAGE_PF=$(echo "$PREFLIGHT_JSON" | jq -r '.triage // "unknown"')
MEMORY_PF=$(echo "$PREFLIGHT_JSON" | jq -r '.memory // "unknown"')

echo "  calendar=$CALENDAR_PF scout=$SCOUT_PF triage=$TRIAGE_PF memory=$MEMORY_PF"
# issue #1279: under a frozen canon the memory backup is published in the
# background; a failed last attempt is surfaced here (advisory, never aborts).
if [ -f "$IWE_SCRIPTS/exocortex-publish.sh" ]; then
  EXO_PUBLISH_RC=0
  EXO_PUBLISH_LINE=$(bash "$IWE_SCRIPTS/exocortex-publish.sh" status 2>/dev/null) || EXO_PUBLISH_RC=$?
  [ "$EXO_PUBLISH_RC" -eq 3 ] && echo "  ⚠ $EXO_PUBLISH_LINE"
fi

if [ "$CALENDAR_PF" = "fail" ]; then abort "Calendar preflight failed"; fi
if [ "$SCOUT_PF" = "fail" ]; then abort "Scout preflight failed"; fi

# Triage is input to the plan, not an advisory signal.  Before its 06:30 grace
# deadline, its producer may still be publishing the current report: defer with
# the same exit-7 contract that the scheduler already retries for Day Close and
# Week Close.  A missing report after the deadline is a genuine failure, while
# an intentionally absent subsystem remains an allowed degraded configuration.
if [ "$TRIAGE_PF" = "pending" ]; then
  echo "  Triage report for $DATE is pending — deferring Day Open for the next scheduler tick."
  tg_notify "⏸ Day Open $DATE отложен: отчёт feedback-triage ещё готовится. Повторится автоматически до 06:30." terminal
  exit 7
fi
if [ "$TRIAGE_PF" != "ok" ] && [ "$TRIAGE_PF" != "disabled" ]; then
  abort "Triage preflight failed"
fi

# ============================================
# 1.1. Day Close race guard (root cause of 2026-07-01 stale plan)
# launchd fires Day Open at 01:04, but the pilot often does yesterday's Day Close
# in the morning (~05:30). If Day Open runs first it reads stale WeekPlan/frontmatter
# and the LLM hallucinates "closed WP" counts. Defer (exit 0, not abort) when
# yesterday's Day Close isn't done yet — the day-close.after trigger will
# re-run this pipeline with --force once the close lands. --force bypasses the guard.
#
# WP-5 Ubuntu-portability audit (2026-07-22, П1): replaced the commit-message regex
# guard (matched literal "day-close.*$YDAY" text — broke silently whenever the close
# commit's wording drifted, most recently detecting only the close's *start* lock
# marker instead of its completion) with a deterministic signal: presence of
# yesterday's archived DayPlan. day-close step 10c (SKILL.md) writes it as the last
# thing before/with the commit, so its existence in HEAD or origin/main means the
# close genuinely landed — no dependency on any particular wording.
#
# WP-484 peer session with Kimi (2026-07-28): the archived-DayPlan signal is blind
# to strategy_day. On strategy_day, day-open-scaffold.sh skips DayPlan generation
# entirely by design (§3. Scaffold below, exit-2 branch) — so an archived DayPlan
# for that date can never exist, whether or not Day Close actually ran. Found live:
# every day right after a strategy_day (e.g. every Tuesday, given strategy_day:
# monday) deferred Day Open indefinitely on this guard, even though the prior
# day's Day Close had genuinely landed. Branch on whether YDAY was strategy_day and
# use a different deterministic signal for that case: the `facts_digest` ledger
# event day-close-prepare.sh appends at the end of every real Day Close (not just
# strategy_day) — same "concrete artifact, not wording" spirit as the DayPlan check.
# ============================================
if [ "$FORCE" != "true" ]; then
  YDAY=$(date -j -v-1d -f "%Y-%m-%d" "$DATE" "+%Y-%m-%d" 2>/dev/null \
    || date -d "$DATE - 1 day" "+%Y-%m-%d" 2>/dev/null)
  if [ -n "$YDAY" ]; then
    (cd "$DS_STRATEGY" && git fetch origin main --quiet 2>/dev/null || true)

    YDAY_DOW=$(portable_date_field "$YDAY" "+%u")
    # Scoped to the day_open: block (not a flat grep) so a same-named key
    # elsewhere in the file can't silently hijack this lookup (review finding,
    # WP-484 peer session 2026-07-28).
    STRATEGY_DAY_NAME=$(awk '/^day_open:/{f=1} f && /strategy_day:/{print $2; exit}' "$CONFIG" 2>/dev/null)
    case "${STRATEGY_DAY_NAME:-monday}" in
      monday) STRATEGY_DOW=1 ;; tuesday) STRATEGY_DOW=2 ;; wednesday) STRATEGY_DOW=3 ;;
      thursday) STRATEGY_DOW=4 ;; friday) STRATEGY_DOW=5 ;; saturday) STRATEGY_DOW=6 ;;
      # Fail-open on an unrecognized value, matching day-open-scaffold.sh's own
      # default (STRATEGY_DOW=0 there) — an unparsed config must not accidentally
      # match a real day-of-week and route into the wrong signal below.
      sunday) STRATEGY_DOW=7 ;; *) STRATEGY_DOW=0 ;;
    esac

    # Only defer when there was actually work to close: if yesterday had zero commits
    # in the governance repo, there is nothing to close and deferring would stall the
    # plan forever on a genuinely quiet day.
    YDAY_WINDOW=$(iwe_day_window "$YDAY" "$DATE" "$DAY_BOUNDARY")
    YDAY_COMMITS=$(cd "$DS_STRATEGY" && git log HEAD origin/main --since="${YDAY_WINDOW%%|*}" --until="${YDAY_WINDOW##*|}" --format=%H 2>/dev/null | head -1)

    if [ "${YDAY_DOW:-0}" = "$STRATEGY_DOW" ]; then
      YDAY_LEDGER="machine/ledger/$(ledger_path_rel day "$YDAY")"  # git-relative, see comment below
      # Two steps, not one `git show ... | grep` pipe (review finding, WP-484
      # peer session 2026-07-28): with `pipefail` (set at the top of this file),
      # a pipeline's exit status is that of its last-failing command — if the
      # ledger exists on HEAD (already committed) but not yet on origin/main
      # (not yet pushed — the exact window between day-close-prepare.sh and the
      # close's final push), the second `git show` fails and pipefail reports
      # the whole pipe as failed even though grep already matched, silently
      # dropping DC_DONE back to empty and reproducing the very bug this fixes.
      DC_DONE=""
      if ledger_ref_has_digest_for_date "$YDAY_LEDGER" "$YDAY" true; then
        DC_DONE=yes
      fi
      # WP-484 (2026-07-28, independent review caught a first version of this fix
      # that trusted ANY facts_digest found in TODAY's file — wrong, because that
      # file can legitimately hold a digest for a different day (e.g. today's own
      # ordinary close), which would then be misread as "yesterday's close is done".
      # Older day-close-prepare.sh versions stamped a late catch-up into the run day's
      # ledger and kept the target only in data.for_date. New writes use the target
      # file, but retain this fallback for already committed mixed legacy ledgers.
      if [ -z "$DC_DONE" ]; then
        # git-relative string, not a filesystem write -- ledger_path() also
        # mkdir's, which would land in the wrong place here (this runs before
        # the script's own `cd "$DS_STRATEGY"` below) -- ledger_path_rel()
        # is the mkdir-free twin for exactly this case.
        TODAY_LEDGER="machine/ledger/$(ledger_path_rel day "$DATE")"
        if ledger_ref_has_digest_for_date "$TODAY_LEDGER" "$YDAY" false; then
          DC_DONE=yes
        fi
      fi
      if [ -z "$DC_DONE" ] && [ -n "$YDAY_COMMITS" ]; then
        echo "  Day Close for $YDAY (strategy_day) not done yet (no facts_digest in ledger) — deferring Day Open (will regenerate after close)."
        tg_notify "⏸ Day Open $DATE отложен: Day Close за $YDAY (день стратегирования) ещё не сделан. Пересоберётся после закрытия (или запусти с --force)." terminal
        # Ф32 п.11 (WP-484, 31.07): deferred ≠ done — exit 7 tells the scheduler to
        # retry on the next window tick instead of burning the daily marker.
        exit 7
      fi
      if [ -n "$DC_DONE" ]; then
        echo "  Day Close for $YDAY found (strategy_day, ledger facts_digest present) — proceeding."
      else
        echo "  No commits for $YDAY (quiet day, nothing to close) — proceeding."
      fi
    else
      YDAY_DAYPLAN="archive/day-plans/DayPlan $YDAY.md"
      DC_DONE=$(cd "$DS_STRATEGY" && git log HEAD origin/main --format="" --name-only -- "$YDAY_DAYPLAN" 2>/dev/null | head -1)
      if [ -z "$DC_DONE" ] && [ -n "$YDAY_COMMITS" ]; then
        echo "  Day Close for $YDAY not done yet (no archived DayPlan) — deferring Day Open (will regenerate after close)."
        tg_notify "⏸ Day Open $DATE отложен: закрытие $YDAY ещё не долетело до сервера (гонка расписаний, не поломка). Пересоберётся автоматически после закрытия (или запусти с --force)." terminal
        # Ф32 п.11 (WP-484, 31.07): deferred ≠ done — exit 7, scheduler retries next tick.
        exit 7
      fi
      if [ -n "$DC_DONE" ]; then
        echo "  Day Close for $YDAY found (archived DayPlan present) — proceeding."
      else
        echo "  No commits for $YDAY (quiet day, nothing to close) — proceeding."
      fi
    fi
  fi
fi

# ============================================
# 1.1b. Week Close race guard (WP-484 Ф46, found 2026-08-02/03: 3x "LLM Proxy
# authorized probe failed" Telegram alerts near midnight on a Sunday). Late
# Sunday night, an author-only night-cycle orchestrator (week-open-orchestrator.sh,
# ~23:50, not delivered by this template -- it depends on the author's shared-
# checkout publish gateway and a private LLM proxy, same class of author-only
# infra as issue #595) closes the outgoing week and opens the next one on the
# author's own install; if this pipeline also runs for that same Sunday's date
# while that cycle is mid-flight, it can burn an attempt on an LLM Proxy call
# that's about to become moot, or produce a plan for a day whose week context
# is still in flux. On a template install without that orchestrator, WeekReport
# is produced earlier and by a different, delivered path: week-review.md, Пн
# 00:00 (issue #596) -- so this guard only matters in practice for that
# orchestrator's ~23:50 Sunday window; it's a no-op wait otherwise.
#
# Signal choice (2026-08-03, peer session with Codex+Hermes, corrected during
# implementation): a start-of-cycle marker would pass almost immediately after
# the cycle begins, defeating the guard -- the real completion signal is the
# WeekReport file's presence itself (not a commit message, which silently
# breaks on wording drift per this same file's own §1.1 lesson, WP-5 2026-07-22).
#
# issue #596: the exact filename here (`WeekReport {ISO-year}-W{ISO-week}.md`,
# e.g. "WeekReport 2026-W35.md") never matched the real naming convention used
# everywhere else (`WeekReport W{N} YYYY-MM-DD.md`, N = ISO week number, date =
# that week's Monday, e.g. "WeekReport W35 2026-08-24.md") -- this guard could
# never find the file it was checking for and always deferred. Fixed to build
# the real filename.
#
# exit 7 = confirmed not closed yet -> defer, same contract as §1.1 above
#          (scheduler retries next tick, this run doesn't burn the daily marker).
# exit 8 = couldn't even check (origin unreachable) -> fail closed on a distinct
#          code, never silently treated as "not closed" from stale/absent data.
# ============================================
TARGET_DOW=$(portable_date_field "$DATE" "+%u")
CURRENT_HOUR=$(TZ=Asia/Nicosia date +%H)
if [ "$FORCE" != "true" ] && [ "${TARGET_DOW:-0}" = "7" ] && [ "$((10#$CURRENT_HOUR))" -ge 23 ]; then
  TARGET_WEEK_NUM=$((10#$(portable_date_field "$DATE" "+%V")))
  TARGET_WEEK_MONDAY=$(date -j -v-6d -f "%Y-%m-%d" "$DATE" "+%Y-%m-%d" 2>/dev/null \
    || date -d "$DATE - 6 day" "+%Y-%m-%d" 2>/dev/null)
  TARGET_WEEK="W${TARGET_WEEK_NUM} ${TARGET_WEEK_MONDAY}"
  if ! (cd "$DS_STRATEGY" && git fetch origin main --quiet 2>/dev/null); then
    echo "  Week Close guard: cannot refresh origin/main for week $TARGET_WEEK -- failing closed"
    tg_notify "🚨 Day Open $DATE заблокирован: не смог обновить origin/main, чтобы проверить закрытие недели $TARGET_WEEK. Нужна ручная проверка сети/репозитория."
    exit 8
  fi
  WEEK_REPORT_REL="current/WeekReport ${TARGET_WEEK}.md"
  WEEK_CLOSED=$(cd "$DS_STRATEGY" && git log HEAD origin/main --format="" --name-only -- "$WEEK_REPORT_REL" 2>/dev/null | head -1)
  if [ -z "$WEEK_CLOSED" ]; then
    echo "  Week $TARGET_WEEK not closed yet (no '$WEEK_REPORT_REL' in HEAD/origin) -- deferring Day Open"
    tg_notify "⏸ Day Open $DATE отложен: неделя $TARGET_WEEK ещё закрывается (после 23:00 вс). Пересоберётся автоматически после завершения цикла." terminal
    # Same contract as §1.1: deferred ≠ done -- exit 7 tells the scheduler to
    # retry on the next window tick instead of burning the daily marker.
    exit 7
  fi
  echo "  Week $TARGET_WEEK already closed ('$WEEK_REPORT_REL' found) -- proceeding."
fi

# ============================================
# 1.2. Git hooks provisioning self-heal (found 2026-07-23: force-push incident)
# core.hooksPath is per-checkout, not versioned — a fresh/reprovisioned clone
# silently falls back to the empty default .git/hooks, disabling the whole
# .githooks/ stack (including the pre-push force-push guard, WP-436) with no
# visible signal until something actually force-pushes over shared history.
# Self-heal here rather than just warn: this check runs on every Day Open on
# every machine that has this pipeline (server + Mac), so fixing it in place
# also covers checkouts this session has no direct access to.
# ============================================
if [ -d "$DS_STRATEGY/.githooks" ] && [ -n "$(ls -A "$DS_STRATEGY/.githooks" 2>/dev/null)" ]; then
  CURRENT_HOOKS_PATH=$(git -C "$DS_STRATEGY" config core.hooksPath 2>/dev/null || echo "")
  if [ "$CURRENT_HOOKS_PATH" != ".githooks" ]; then
    echo "=== 1.2. Git hooks: core.hooksPath='$CURRENT_HOOKS_PATH' (expected .githooks) — self-healing ==="
    if bash "$SCRIPT_HOME/install-hooks.sh" "$DS_STRATEGY" >/dev/null 2>&1; then
      echo "  Fixed: core.hooksPath=.githooks (force-push guard now active)"
      tg_notify "⚠️ Day Open: core.hooksPath на $DS_STRATEGY был не .githooks — pre-push force-push guard молчал. Автоматически починил (install-hooks.sh)." protective
    else
      echo "  WARN: install-hooks.sh failed — hooks still inactive, needs manual attention"
      tg_notify "🚨 Day Open: core.hooksPath на $DS_STRATEGY сломан, автопочинка (install-hooks.sh) тоже упала — force-push guard не активен, нужна ручная проверка." protective
    fi
  fi
fi

# ============================================
# 1.3. Input freshness self-heal (WP-484 Ф90, 2026-08-12): priorities.yaml and
# WP-REGISTRY.md are read straight off local disk by LLM Fill below. On a
# shared checkout (remote server) a live agent session can hold the tree's sync
# semaphore for hours after finishing its own work (found live: 11h46m past
# report.md completion) — the periodic sync timer correctly refuses to touch
# the tree while that semaphore stands, so these two files silently go stale
# for however long the semaphore lasts, and Day Open builds tonight's plan
# from yesterday's data. `git show <ref>:<path>` reads a blob straight from
# the object database without touching the working tree or index at all — no
# lock, no semaphore, safe regardless of what any other session is doing.
# Scoped to exactly these two inputs (not a general pull): a full sync still
# needs the semaphore respected, this only unblocks what Day Open itself
# reads. `git fetch` above (D2 dedup guard) already refreshed origin/main's
# ref; if that fetch failed offline, this diff is silently a no-op against a
# stale ref, which is the same degradation the rest of this pipeline already
# accepts everywhere else fetch can fail.
# ============================================
echo "=== 1.3. Input freshness self-heal ==="
for _f_rel in current/priorities.yaml docs/WP-REGISTRY.md; do
  _f_abs="$DS_STRATEGY/$_f_rel"
  _f_origin=$(cd "$DS_STRATEGY" && git show "origin/main:$_f_rel" 2>/dev/null || true)
  if [ -z "$_f_origin" ]; then
    echo "  skipped (origin/main unreadable, e.g. offline): $_f_rel"
  elif diff -q <(printf '%s' "$_f_origin") "$_f_abs" >/dev/null 2>&1; then
    echo "  already fresh: $_f_rel"
  else
    printf '%s' "$_f_origin" > "$_f_abs"
    echo "  refreshed from origin/main (local was stale): $_f_rel"
  fi
done

# ============================================
# 2. Ensure LLM Proxy available
# ============================================
# issue #434: skipped entirely under --scaffold-only — only step 4 (LLM Fill)
# below actually needs the proxy; the deterministic scaffold (step 3) does not.
if [ "$SCAFFOLD_ONLY" != "true" ]; then
echo "=== 2. LLM Proxy healthcheck ==="
# issue #877: no gateway address resolved (see the resolution chain near the top).
# Say so directly instead of probing an empty URL, and do not send the reader
# hunting for a key rotation - there is no key problem, there is no gateway.
if [ -z "$LLM_PROXY_URL" ]; then
  echo "  LLM gateway is not configured: LLM_PROXY_URL and PLATFORM_LLM_PROXY_URL are both empty."
  # exit 9 = no gateway configured -> caller should retry with --scaffold-only
  # (issue #893), same contract class as exit 7/8 elsewhere in this file.
  abort "LLM gateway is not configured - set LLM_PROXY_URL to your gateway (or PLATFORM_LLM_PROXY_URL). This is not an API-key problem. Use --scaffold-only to build the plan without the LLM fill." 9
fi
PROXY_HEALTH=$(curl -s "${LLM_PROXY_URL}/v1/health" 2>/dev/null | grep -q "ok" && echo "ok" || echo "fail")
if [ "$PROXY_HEALTH" != "ok" ]; then
  if $PROXY_IS_LOCAL; then
    # lsof (Mac) with ss fallback (NixOS server lacks lsof) — verified live: this
    # machine has lsof but not ss, so a bare ss-only version (as copied without
    # testing into month-open-night-run.sh:78) would silently break the Mac side
    # of the exact dual-machine pair this pipeline is designed to run on. Only
    # checking port occupancy either way, PID unused below.
    if lsof -ti :"$PROXY_PORT" >/dev/null 2>&1 || ss -tln 2>/dev/null | grep -q ":$PROXY_PORT "; then
      # Port already held by another process — likely a live proxy the check above
      # missed on a transient blip. Spawning here would just crash into "Address
      # already in use" and spam the error log without helping (found 2026-07-11).
      echo "  Health check failed but port $PROXY_PORT is already held — not spawning a second proxy, just waiting."
    else
      echo "  Proxy not running. Starting via launcher (loads OPENROUTER_API_KEY from secrets)..."
      bash "$SCRIPT_HOME/llm-proxy-launcher.sh" "$PROXY_PORT" &
      PROXY_PID=$!
    fi
  else
    echo "  Remote proxy ($LLM_PROXY_URL) failed health check — nothing local to spawn, just waiting/retrying."
  fi
  # Retry up to 10 times (20s total) — launcher needs extra time to source secrets + import
  for _i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 2
    PROXY_HEALTH=$(curl -s "${LLM_PROXY_URL}/v1/health" 2>/dev/null | grep -q "ok" && echo "ok" || echo "fail")
    [ "$PROXY_HEALTH" = "ok" ] && break
    echo "  Waiting for proxy (attempt $_i/10)..."
  done
  if [ "$PROXY_HEALTH" != "ok" ]; then
    abort "LLM Proxy unavailable (tried to start, failed)"
  fi
fi
echo "  Proxy OK"

# Alive != authorized: /v1/health never touches upstream credentials, so a proxy
# orphan that outlived a key rotation keeps answering "ok" while 401-ing every
# real call (2026-07-30 04:30 — 7/7 fill chunks failed with HTTP 401, day not
# opened). Same request contract as day-open-llm-fill.py: no "model" field, the
# proxy routes by verification_class.
# WP-484 Ф50b (04.08): LLM_PROXY_SECRET was never actually provisioned anywhere
# this pipeline runs -- confirmed live from the remote server. What IS already provisioned
# and already authenticates against this same gateway: PROXY_SHARED_SECRET
# (root-only /etc/iwe/env, used by iwe-llm-health/iwe-overnight-auditor) and
# ANTHROPIC_API_KEY (~/.iwe/.proxy-env, readable by the pilot's own account -- the one this pipeline's
# actual execution context can see). Falls back through what's really there
# instead of requiring a secret nobody would ever provision under this exact name.
LLM_PROXY_SECRET="${LLM_PROXY_SECRET:-${PROXY_SHARED_SECRET:-${ANTHROPIC_API_KEY:-}}}"
AUTH_PROBE_ARGS=(-H 'content-type: application/json')
[ -n "${LLM_PROXY_SECRET:-}" ] && AUTH_PROBE_ARGS+=(-H "X-IWE-Internal-Secret: ${LLM_PROXY_SECRET}")
AUTH_PROBE_BODY='{"messages":[{"role":"user","content":"ping"}],"max_tokens":1,"verification_class":"trivial"}'
AUTH_CODE=$(curl -s -o /dev/null -w '%{http_code}' -m 30 -X POST "${LLM_PROXY_URL}/v1/messages" \
  "${AUTH_PROBE_ARGS[@]}" -d "$AUTH_PROBE_BODY" 2>/dev/null) || AUTH_CODE="000"
if [ "$AUTH_CODE" != "200" ]; then
  if $PROXY_IS_LOCAL; then
    # Self-heal (WP-484, found 2026-08-04): this probe first caught this failure mode
    # on 2026-07-30 and has correctly fired on every recurrence since (2026-08-02 x3,
    # 2026-08-04) -- but detection never had matching remediation, so the same
    # process (confirmed 2026-08-04: same pid, 9 days uptime across all of the above)
    # kept serving the stale credential until a human happened to restart it by hand.
    # Kill the process holding the port and let launchd's KeepAlive respawn it fresh
    # (re-sources the secrets file) -- same fix two independent peer-session
    # diagnoses (2026-07-03, 2026-08-02) already landed on; retry the probe once
    # before falling back to abort.
    echo "  Authorized probe failed (HTTP $AUTH_CODE) — restarting local proxy and retrying once"
    STALE_PIDS=$(lsof -ti :"$PROXY_PORT" 2>/dev/null || true)
    for _pid in $STALE_PIDS; do kill "$_pid" 2>/dev/null || true; done
    for _i in 1 2 3 4 5 6 7 8 9 10; do
      sleep 2
      curl -s "${LLM_PROXY_URL}/v1/health" 2>/dev/null | grep -q "ok" && break
      echo "  Waiting for proxy respawn (attempt $_i/10)..."
    done
  else
    # Remote gateway (WP-484 Ф48b, 04.08): no local process to kill -- Railway
    # supervises its own restarts (railway.toml restartPolicyType=ON_FAILURE).
    # A 401 here almost always means LLM_PROXY_SECRET is unset/wrong on this
    # host (confirmed missing on the remote server at cutover time), not a crashed
    # process -- one short wait only covers a mid-deploy blip on Railway's side.
    echo "  Authorized probe failed (HTTP $AUTH_CODE) on remote gateway — short wait and retry once"
    sleep 5
  fi
  AUTH_CODE=$(curl -s -o /dev/null -w '%{http_code}' -m 30 -X POST "${LLM_PROXY_URL}/v1/messages" \
    "${AUTH_PROBE_ARGS[@]}" -d "$AUTH_PROBE_BODY" 2>/dev/null) || AUTH_CODE="000"
  if [ "$AUTH_CODE" != "200" ]; then
    if $PROXY_IS_LOCAL; then
      tg_notify "🚨 Day Open aborted: LLM proxy on port $PROXY_PORT still fails after restart (HTTP $AUTH_CODE) — credential itself is likely dead at the provider, needs manual rotation (WP-399), not just a process restart."
    else
      tg_notify "🚨 Day Open aborted: remote LLM proxy ($LLM_PROXY_URL) still fails (HTTP $AUTH_CODE) — check LLM_PROXY_SECRET on this host matches Railway's PROXY_SHARED_SECRET, or WP-399 key rotation."
    fi
    abort "LLM Proxy authorized probe failed after restart (HTTP $AUTH_CODE)"
  fi
  echo "  Proxy authorized probe OK after restart"
else
  echo "  Proxy authorized probe OK"
fi
else
  echo "=== 2. LLM Proxy healthcheck — SKIPPED (--scaffold-only) ==="
fi

# ============================================
# 3. Scaffold
# ============================================
echo "=== 3. Scaffold ==="
if [ -z "$WEEKPLAN_PATH" ] || [ ! -f "$WEEKPLAN_PATH" ]; then
  abort "WeekPlan not found in $CURRENT_DIR"
fi

mkdir -p "$IWE/.tmp"
if [ "$CALENDAR_PF" = "disabled" ]; then
  : > "$CALENDAR_OUT"  # issue #942: calendar_source: none, nothing to fetch
else
  bash "$IWE_SCRIPTS/server-calendar.sh" "$DATE" "$CONFIG" > "$CALENDAR_OUT" 2>/dev/null || true
fi

# Generate scaffold to temp file first (for hash guard)
mkdir -p "$(dirname "$DAYPLAN_PATH")"
SCAFFOLD_TEMP="$DAYPLAN_PATH.scaffold.tmp"
SCAFFOLD_SCRIPT="$IWE_SCRIPTS/day-open-scaffold.sh"
SCAFFOLD_READ_ONLY=0
if [ "$SCAFFOLD_ONLY" = "true" ] || [ "$PROBE" = "true" ]; then
  SCAFFOLD_READ_ONLY=1
fi
DAY_OPEN_SCAFFOLD_READ_ONLY="$SCAFFOLD_READ_ONLY" bash "$SCAFFOLD_SCRIPT" "$DATE" > "$SCAFFOLD_TEMP" || {
  SC=$?
  if [ $SC -eq 2 ]; then
    echo "  Strategy day — no DayPlan generated."
    rm -f "$SCAFFOLD_TEMP"
    tg_notify "📋 Strategy day — Day Open skipped." terminal
    exit 0
  fi
  # Diagnostics for bug-2026-07-10 repro (день, когда scaffold "не найден" без явной причины)
  DIAG="pwd=$(pwd) PATH=$PATH scaffold_exists=$([ -e "$SCAFFOLD_SCRIPT" ] && echo yes || echo no) scaffold_x=$([ -x "$SCAFFOLD_SCRIPT" ] && echo yes || echo no) ls=$(ls -la "$SCAFFOLD_SCRIPT" 2>&1)"
  echo "  DIAG: $DIAG"
  tg_notify "🚨 Day Open pipeline aborted: Scaffold failed (exit $SC)
$DIAG"
  exit 1
}

# --- Input hash guard (D2: dedup manual retriggers) ---
# Include git HEAD so that any new commits in repo invalidate the hash
HEAD_HASH=$(cd "$DS_STRATEGY" && git rev-parse HEAD 2>/dev/null || echo "no-git")
INPUT_HASH_FILE="$IWE/.tmp/day-open-input-hash-$DATE.txt"
INPUT_HASH=$( (cat "$SCAFFOLD_TEMP" "$WEEKPLAN_PATH" "$CALENDAR_OUT" 2>/dev/null; echo "$HEAD_HASH") | shasum -a 256 | awk '{print $1}' )
# --force must beat BOTH guards: the D2 guard above already honors it, and its
# own user-facing message ("Use --force to regenerate") promises a regenerate —
# without this bypass the promise died here on unchanged inputs (review F64).
if [ "$FORCE" != "true" ] && [ -f "$INPUT_HASH_FILE" ]; then
  PREV_HASH=$(cat "$INPUT_HASH_FILE")
  if [ "$PREV_HASH" = "$INPUT_HASH" ]; then
    echo "  Input hash unchanged — DayPlan already generated for this data set. Skipping."
    rm -f "$SCAFFOLD_TEMP"
    tg_notify "📋 DayPlan $DATE already up-to-date (input hash unchanged). Skipping LLM Fill." terminal
    exit 0
  fi
fi
# WP-484 F64 (06.08): the hash write itself moved AFTER a successful push (step 6).
# Writing it here poisoned every retry when a run died between scaffold and push
# (live case 06.08 03:03: runner timeout kill after LLM fill, before commit —
# each rerun then skipped with "already generated" while nothing was published).
# Same bug class as the probe-hash leak fixed 28.07.

if [ "$SCAFFOLD_ONLY" = "true" ]; then
  # Build the caveat before publishing the draft. A failed formatter must
  # never leave an unmarked PENDING file that a repeat preserves as complete.
  CAVEAT_TMP="$SCAFFOLD_TEMP.caveat"
  awk '
    !inserted && /^# / {
      print
      print ""
      print "<!-- day-open-status: scaffold -->"
      print "> ⚠️ **Каркас плана: день не открыт.** Шлюз модели не настроен; разделы `PENDING` не заполнены. Правки в этом черновике не переносятся автоматически в готовый DayPlan."
      inserted=1
      next
    }
    { print }
    END { if (!inserted) exit 1 }
  ' "$SCAFFOLD_TEMP" > "$CAVEAT_TMP" || {
    rm -f "$CAVEAT_TMP"
    abort "Could not mark incomplete scaffold: $DAYPLAN_PATH"
  }
  mv "$CAVEAT_TMP" "$DAYPLAN_PATH" || abort "Could not save incomplete scaffold: $DAYPLAN_PATH"
  rm -f "$SCAFFOLD_TEMP"
else
  mv "$SCAFFOLD_TEMP" "$DAYPLAN_PATH"
fi
echo "  Scaffold OK: $DAYPLAN_PATH"

# ============================================
# 4. LLM Fill (per-section)
# ============================================
if [ "$SCAFFOLD_ONLY" != "true" ]; then
echo "=== 4. LLM Fill ==="
# Fill stderr is duplicated into a per-day file next to the night-cycle logs: on
# the morning path (scheduler → strategist → this script) the per-chunk failure
# reasons otherwise land only in ~/logs/strategist/*.log, where nobody looked
# during the 2026-07-30 04:30 incident.
DAY_OPEN_LOG="$DS_STRATEGY/machine/logs/day-open-$DATE.log"
if [ "$PROBE" = "true" ]; then
  DAY_OPEN_LOG=$(mktemp)  # probe runs must not write real artifacts
fi
mkdir -p "$(dirname "$DAY_OPEN_LOG")"

# PD-dashboard sync (WP-417 tile source). read_dashboard_snapshot()
# (dashboard_render.py) reads the latest local daily/*.yaml and already
# degrades softly if the repo/file is missing or stale (falls back to the
# latest available snapshot, or skips the tile entirely) -- a failed sync
# here must not block the DayPlan, same principle as the ${IWE_GOVERNANCE_REPO:-DS-strategy} git
# pull below. Found live 04.09 (WP-417 peer-session
# 2026-09-04-09-wp417-panel-verify-close): the repo was never cloned on
# the remote server at all, so the tile silently showed "not calculated" every day.
# PD_DASHBOARD_CLONE_URL is per-installation (e.g. a read-only deploy-key SSH
# alias) -- unset means this reader wasn't provisioned, skip quietly, same as
# any other unconfigured optional integration in this pipeline.
PD_DASHBOARD_DIR="$IWE/${DASHBOARD_REPO_NAME:-PD-dashboard}"
if [ -d "$PD_DASHBOARD_DIR/.git" ]; then
  if ! { DASHBOARD_BRANCH=$(git -C "$PD_DASHBOARD_DIR" symbolic-ref --quiet --short HEAD) \
      && DASHBOARD_REMOTE=$(git -C "$PD_DASHBOARD_DIR" config --get "branch.$DASHBOARD_BRANCH.remote") \
      && DASHBOARD_SOURCE_REF=$(git -C "$PD_DASHBOARD_DIR" config --get "branch.$DASHBOARD_BRANCH.merge") \
      && day_open_fast_forward "$PD_DASHBOARD_DIR" "$DASHBOARD_REMOTE" "$DASHBOARD_SOURCE_REF" '@{upstream}'; } >>"$DAY_OPEN_LOG" 2>&1; then
    echo "  [pd-dashboard-sync] safe update skipped -- панель покажет последний доступный снимок" | tee -a "$DAY_OPEN_LOG"
  fi
elif [ -n "${PD_DASHBOARD_CLONE_URL:-}" ]; then
  if ! git clone "$PD_DASHBOARD_CLONE_URL" "$PD_DASHBOARD_DIR" >>"$DAY_OPEN_LOG" 2>&1; then
    echo "  [pd-dashboard-sync] git clone failed -- тайл табло будет пропущен" | tee -a "$DAY_OPEN_LOG"
  fi
fi

FILL_ERR_TMP=$(mktemp)
FILL_EXIT=0
# WP-529 (continuation, 19.08): day-open-llm-fill.py imports yaml — resolved
# here via the F6 shared resolver instead of bare `python3`, same class of
# defect as route-task.sh (Evgenii's finding #5): bare python3 can be a
# different, yaml-less interpreter than the resolver would find. Unlike the
# earlier best-effort skip sites in this migration, this call IS the pipeline
# stage's core work — a missing interpreter has to surface through the
# existing FILL_EXIT!=0 error path below (Telegram + log diagnostics), not a
# silent skip.
_RESOLVED_PYTHON3=$("$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/find-python3.sh" 2>/dev/null) || _RESOLVED_PYTHON3=""
if [ -z "$_RESOLVED_PYTHON3" ]; then
  echo "[ERROR] no python3 with PyYAML found (checked PATH and the resolver's standard candidate list, see scripts/lib/find-python3.sh)" > "$FILL_ERR_TMP"
  FILL_EXIT=1
else
  "$_RESOLVED_PYTHON3" "$SCRIPT_HOME/day-open-llm-fill.py" \
    --scaffold "$DAYPLAN_PATH" \
    --weekplan "$WEEKPLAN_PATH" \
    --wp-registry "$WP_REGISTRY" \
    --wp-dir "$DS_STRATEGY/inbox" \
    --cp-profile "$CP_PROFILE" \
    --calendar "$CALENDAR_OUT" \
    --fleeting-notes "$DS_STRATEGY/inbox/fleeting-notes.md" \
    --priorities "$DS_STRATEGY/current/priorities.yaml" \
    --out "$DAYPLAN_PATH" \
    --proxy-url "$LLM_PROXY_URL" \
    --proxy-secret "$LLM_PROXY_SECRET" 2> "$FILL_ERR_TMP" || FILL_EXIT=$?
fi
cat "$FILL_ERR_TMP" >&2
{ echo "=== LLM Fill $(date '+%H:%M:%S') exit=$FILL_EXIT ==="; cat "$FILL_ERR_TMP"; } >> "$DAY_OPEN_LOG"
if [ "$FILL_EXIT" -eq 2 ]; then
  echo "  Partial fill — some sections remain PENDING."
  FILL_WARNS=$(grep '\[WARN\]' "$FILL_ERR_TMP" | head -5 || true)
  tg_notify "⚠️ DayPlan $DATE partially filled — some PENDING sections remain. Scaffold saved; Day Open will retry.
$FILL_WARNS"
  rm -f "$FILL_ERR_TMP"
  exit 1
elif [ "$FILL_EXIT" -ne 0 ]; then
  echo "  LLM fill failed — leaving scaffold for manual completion."
  FILL_ERRS=$(grep -E '\[WARN\]|\[ERROR\]' "$FILL_ERR_TMP" | head -5 || true)
  tg_notify "❌ LLM fill failed for $DATE (exit $FILL_EXIT) — scaffold saved, needs manual completion.
$FILL_ERRS"
  rm -f "$FILL_ERR_TMP"
  exit 1
fi
rm -f "$FILL_ERR_TMP"
echo "  LLM Fill OK"
else
  echo "=== 4. LLM Fill — SKIPPED (--scaffold-only) ==="
fi

# ============================================
# 4.2. Bottleneck patch (deterministic, AFTER LLM Fill — WP-484, moved 2026-07-14)
# llm-fill.py's has_pending check is whole-chunk: a second marker (week_context) in the
# same <details> block as "Горлышко недели" made it regenerate that whole chunk even
# when this script had already run first, overwriting its BOTTLENECK-PENDING/BY-SCRIPT
# marker with unmarked prose. Running last makes this script the authoritative source.
# ============================================
echo "=== 4.2. Bottleneck patch ==="
bash "$SCRIPT_HOME/day-open-bottleneck-patch.sh" "$DAYPLAN_PATH" 2>&1 || true


# Shared resolver for the deterministic patch steps below (4.3, 4.55-4.57).
# WP-529 F7 port (peer session 2026-08-21-17): ledger-render imports yaml, so a
# bare `python3` can be a yaml-less interpreter (same defect class as F6/F9);
# the stdlib-only patches get the same binary with a soft fallback — a missing
# resolver must not break steps that never needed PyYAML in the first place.
_PATCH_PY=$("$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/find-python3.sh" 2>/dev/null) || _PATCH_PY=""
[ -n "$_PATCH_PY" ] || _PATCH_PY=python3
# ============================================
# 4.3. Ledger render (deterministic, AFTER LLM Fill — same reason as 4.2 above:
# WP-484 Ф16.2 2b). Appends render-open.py's ledger sections (Итоги вчера/Очередь
# решений/Предлагаемые действия, Ф16.2 2c) as an ADDITIONAL block near the end of
# the DayPlan — never touches day-open-scaffold.sh's own legacy "Итоги вчера" block
# (CONCEPT-night-cycle.md §16: parallel run during migration, not a replacement).
# True no-op (file byte-identical) until scripts/day-close-prepare.sh (Ф16.2 2a,
# WP-485) starts landing facts_digest ledger events most nights — see the script's
# own docstring for the graceful-degradation design.
# ============================================
echo "=== 4.3. Ledger render ==="
"$_PATCH_PY" "$SCRIPT_HOME/day-open-ledger-render-patch.py" \
  --dayplan "$DAYPLAN_PATH" \
  --date "$DATE" 2>&1 || true

# ============================================
# 4.5. Budget patch (deterministic: sum h column, no LLM hallucination)
# ============================================
echo "=== 4.5. Budget patch ==="
python3 "$SCRIPT_HOME/day-open-budget-patch.py" \
  --dayplan "$DAYPLAN_PATH" \
  --priorities "$DS_STRATEGY/current/priorities.yaml" 2>&1 || true

# ============================================
# 4.55. Priorities patch (deterministic — WP-484, pilot instruction 16.08: Day
# Open must never fail to run because of a priorities discrepancy; the finding
# belongs in the DayPlan itself, not as a commit-blocking exit 1). Writes into
# «Требует внимания» while the section header is still guaranteed to exist
# (before archive/sync can touch the file) — same slot pattern as 4.5 above.
# Ported from the author pipeline (WP-529 F7): resolver-based interpreter, not
# bare python3 — see _PATCH_PY above.
# ============================================
echo "=== 4.55. Priorities patch ==="
"$_PATCH_PY" "$SCRIPT_HOME/day-open-priorities-patch.py" \
  --dayplan "$DAYPLAN_PATH" \
  --priorities "$DS_STRATEGY/current/priorities.yaml" 2>&1 || true

# ============================================
# 4.56. Close-error patch (deterministic — WP-484 F113: the night runner exports
# IWE_CLOSE_ERROR instead of stopping before this pipeline when the Close half
# fails. Empty/unset in every other invocation (manual runs, probes, installs
# without a night cycle) — no-op then. Same non-blocking pattern as 4.55.
# ============================================
echo "=== 4.56. Close-error patch ==="
"$_PATCH_PY" "$SCRIPT_HOME/day-open-close-error-patch.py" \
  --dayplan "$DAYPLAN_PATH" \
  --error "${IWE_CLOSE_ERROR:-}" 2>&1 || true

# ============================================
# 4.57. Version-check patch (deterministic — WP-484 stage-0 wiring: a stale
# checkout is a visible finding, not a silent commit block). Template port
# guard (WP-529 F7, peer consensus 2026-08-21-17): comparing HEAD..origin/main
# only makes sense when such a remote ref exists. A template/offline install
# without it is a NORMAL mode, not a pipeline error — diagnose to stderr and
# move on, never non-zero, never a DayPlan «Требует внимания» entry.
# ============================================
echo "=== 4.57. Version-check patch ==="
if git -C "$DS_STRATEGY" remote get-url origin >/dev/null 2>&1 \
   && git -C "$DS_STRATEGY" rev-parse --verify --quiet origin/main >/dev/null 2>&1; then
  "$_PATCH_PY" "$SCRIPT_HOME/day-open-version-check-patch.py" \
    --dayplan "$DAYPLAN_PATH" \
    --repo "$DS_STRATEGY" 2>&1 || true
else
  echo "version-check: no origin/main to compare against — skipped (comparison context unavailable, normal for template/offline installs)" >&2
fi

# ============================================
# 4.58. Sync-banner patch (deterministic, AFTER LLM Fill so the fill cannot erase
# it — Refs #1245). While the sync-blocked marker of the shared checkout is
# present the registry of work products, the week plan and the inbox were read
# from a stale copy; the plan says so once. No marker: the plan stays as it was
# (a block left by an earlier run is removed). Never blocks Open.
# ============================================
echo "=== 4.58. Sync-banner patch ==="
SYNC_MARKER=$(day_open_sync_marker_file "$DS_STRATEGY")
"$_PATCH_PY" "$SCRIPT_HOME/day-open-sync-banner-patch.py" \
  --dayplan "$DAYPLAN_PATH" --marker "$SYNC_MARKER" --repo "$DS_STRATEGY" 2>&1 || true
SYNC_WARN=$("$_PATCH_PY" "$SCRIPT_HOME/day-open-sync-banner-patch.py" \
  --marker "$SYNC_MARKER" --repo "$DS_STRATEGY" --print-text 2>/dev/null || true)

# ============================================
# 4.59. Multiplier backfill patch (deterministic — WP-484 Ф117, pilot decision
# 18.08 + peer-session 2026-09-01-18-wp484-backlog-continue: wakatime-cli only
# supports --today, so a Close that ran late or on a host without the CLI
# leaves yesterday's multiplier honestly PENDING. This backfills it from the
# WakaTime HTTP API once synced. Same non-blocking-finding pattern as the
# patches above — never blocks Open, never fabricates a value.
# ============================================
if [ "$SCAFFOLD_ONLY" = "true" ]; then
  # Backfill can call WakaTime and append to the tracked governance ledger.
  # A local, incomplete draft must not trigger either side effect.
  echo "=== 4.59. Multiplier backfill patch — SKIPPED (scaffold-only) ==="
else
  echo "=== 4.59. Multiplier backfill patch ==="
  "$_PATCH_PY" "$SCRIPT_HOME/day-open-multiplier-backfill-patch.py" \
    --dayplan "$DAYPLAN_PATH" \
    --ledger-root "$DS_STRATEGY/machine/ledger/day" \
    --date "$DATE" \
    --ledger-append "$SCRIPT_HOME/ledger-append.sh" 2>&1 || true
fi

# ============================================
# 4.6. Sync + archive stale DayPlans (moved ahead of Checks — WP-484 Ф2)
# BUGFIX (2026-07-13): this used to run in step 6, AFTER Checks (step 5) — but one of
# the checks (day-open.checks.md «current/ без зависших DayPlan») hard-blocks commit
# if any non-today DayPlan sits in current/. Archiving only after that check had
# already failed meant the pipeline could never self-heal a leftover from a Day Close
# that ran late or incompletely: the one mechanism able to fix the condition always
# ran too late to prevent the block it was fixing.
# ============================================
echo "=== 4.6. Sync + archive ==="
cd "$DS_STRATEGY" || abort "Cannot cd to repo"

TODAY=$(date +%Y-%m-%d)
ARCHIVE_DIR="$DS_STRATEGY/archive/day-plans"
ARCHIVED_PATHS=()
# Archive destination paths for THIS run only (WP-484, found 13.08): the commit
# used to stage/pathspec the whole $ARCHIVE_DIR/, which pulled foreign dirty or
# staged files (leftovers of other agents' sessions) into the DayPlan commit, and
# the session-guard scope gate then correctly blocked the open.
ARCHIVE_TARGETS=()

if [ "$PROBE" = "true" ] || [ "$SCAFFOLD_ONLY" = "true" ]; then
  echo "  [draft/probe] sync/archive-move skipped — no git state touched"
else
# Sync is optional housekeeping: a stale or dirty copy must not discard the
# DayPlan already rendered above. No stash/rebase/reset in the source tree.
if ! day_open_fast_forward "$DS_STRATEGY"; then
  # A lasting refusal (overlapping edits, an unpublished local commit) that the pilot
  # already got through the sync-blocked marker is not repeated in general words;
  # any other failure (unsaved edits before the check, no connection) still is.
  [ "${DAY_OPEN_SYNC_REPORTED:-0}" = 1 ] \
    || tg_notify "⚠️ Day Open: обновление пропущено (несохранённые правки или нет связи); локальная работа и готовый DayPlan сохранены" protective
fi

# Archive stale DayPlans (move + overwrite, and record the deletion).
# Bug history (feedback_dayplan_archive_silent_skip.md): `git mv ... || true` silently
# skipped when the archive copy already existed (Day Close had archived an earlier copy),
# leaving a stale DayPlan stuck in current/. And the commit pathspec listed only archive/,
# so the current/ deletion was never committed even when git mv did run.
for f in "$CURRENT_DIR"/DayPlan\ *.md; do
  [ -f "$f" ] || continue
  basename_f=$(basename "$f")
  echo "$basename_f" | grep -qF "$TODAY" && continue   # keep today's plan in current/
  if git mv -f "$f" "$ARCHIVE_DIR/" 2>/dev/null; then
    echo "  archived (git mv): $basename_f"
  else
    # Untracked or rename edge case: move on disk, then stage the new location explicitly.
    mv -f "$f" "$ARCHIVE_DIR/"
    git add "$ARCHIVE_DIR/$basename_f"
    echo "  archived (mv fallback): $basename_f"
  fi
  ARCHIVED_PATHS+=("$f")   # old current/ path: include below so the deletion is committed
  ARCHIVE_TARGETS+=("$ARCHIVE_DIR/$basename_f")   # new archive/ path: staged individually below
done
fi

# Refs #1245: the sync above may have just created the marker (first refusal). The inputs
# were read before it, so the plan and the digest say so now. Only ever adds or refreshes
# the block here: a marker cleared by a successful move does not make today's inputs fresh.
if [ "$PROBE" != "true" ] && [ "$SCAFFOLD_ONLY" != "true" ] && [ -f "$SYNC_MARKER" ]; then
  "$_PATCH_PY" "$SCRIPT_HOME/day-open-sync-banner-patch.py" \
    --dayplan "$DAYPLAN_PATH" --marker "$SYNC_MARKER" --repo "$DS_STRATEGY" 2>&1 || true
  SYNC_WARN=$("$_PATCH_PY" "$SCRIPT_HOME/day-open-sync-banner-patch.py" \
    --marker "$SYNC_MARKER" --repo "$DS_STRATEGY" --print-text 2>/dev/null || true)
fi

# session-guard.sh scope gate (added 2026-07-07, WP-7 SGFIX3) blocks any new/renamed
# path that isn't declared in an active session's note-file log — a headless launchd
# run has no session open, so DayPlan (new file every day) and the archive moves always
# tripped it (bug found 2026-07-08, same class as the [allow:current] bug below: a guard
# added after this pipeline was written, nobody updated the pipeline for it).
# Agent id is a dedicated "day-open-pipeline", not "claude-code": note-file's
# select_semaphore matches any open semaphore for the given agent name and fails
# loudly on 2+ candidates — "claude-code" would collide with a live interactive
# session open on the same machine at the same time.
SG_AGENT="day-open-pipeline"
if [ "$PROBE" != "true" ] && [ "$SCAFFOLD_ONLY" != "true" ]; then
  # WP-484 F91: explicit --slug keeps note-file resolution unambiguous when the
  # agent has 2+ open semaphores (a stale housekeeping semaphore used to make
  # both note-file calls fail in one run); the slug is fixed by the `open
  # --housekeeping day-open` call above. --owner-pid from the author copy is NOT
  # ported: this parser swallows unknown flags and misparses the PID as positional.
  bash "$IWE_SCRIPTS/session-guard.sh" open --housekeeping day-open --agent "$SG_AGENT" 2>/dev/null || true
  bash "$IWE_SCRIPTS/session-guard.sh" note-file "$DAYPLAN_PATH" --agent "$SG_AGENT" --slug day-open
  for f in "${ARCHIVED_PATHS[@]+"${ARCHIVED_PATHS[@]}"}"; do
    bash "$IWE_SCRIPTS/session-guard.sh" note-file "$ARCHIVE_DIR/$(basename "$f")" --agent "$SG_AGENT" --slug day-open
  done
fi

# ============================================
# 4.8. Extension graph — "after" hooks (WP-529 Ф11)
# ============================================
# Same mechanism and failure semantics as the "before" hook at the top of
# this script (see its comment) — runs after DayPlan generation/patches, so
# a hook that enriches the DayPlan (e.g. extensions/day-open.after.session-
# orphans.md) sees the final content, and Checks below validates whatever
# it left behind.
echo "=== 4.8. Extension graph: after ==="
if [ "$SCAFFOLD_ONLY" = "true" ]; then
  echo "  deferred: after hooks need a fully filled DayPlan"
else
  AFTER_HOOK_OUT=$(bash "$SCRIPT_HOME/day-open-hooks-runner.sh" after 2>&1)
  AFTER_HOOK_EXIT=$?
  echo "$AFTER_HOOK_OUT"
  if [ $AFTER_HOOK_EXIT -ne 0 ]; then
    tg_notify "❌ Day Open aborted: an 'after' extension hook failed for $DATE. See output above."
    abort "after-hook failed — see output above"
  fi
fi

# ============================================
# 5. Checks
# ============================================
echo "=== 5. Checks ==="
CHECKS_OUT=$(bash "$SCRIPT_HOME/day-open-checks-runner.sh" "$DAYPLAN_PATH" 2>&1)
CHECKS_EXIT=$?
echo "$CHECKS_OUT"

if [ "$SCAFFOLD_ONLY" = "true" ]; then
  if [ "$CHECKS_EXIT" -ne 0 ]; then
    echo "  Draft checks found problems; the incomplete scaffold remains local."
  fi
  echo "  Incomplete scaffold saved locally: $DAYPLAN_PATH"
  echo "  Edits in this draft are not copied automatically into a fully filled DayPlan."
  echo "  Day Open is incomplete; no commit, push, digest or success heartbeat."
  if [ "$PROBE" = "true" ]; then
    echo "=== PROBE SUMMARY ==="
    echo "  date=$DATE verdict=🟡 incomplete (scaffold) checks_exit=$CHECKS_EXIT"
  fi
  exit 10
fi

if [ $CHECKS_EXIT -ne 0 ]; then
  tg_notify "❌ DayPlan checks failed for $DATE. Commit blocked. Fix and retry."
  abort "Checks failed — see output above"
fi

# ============================================
# 6. Commit + Push
# ============================================
if [ "$PROBE" = "true" ]; then
  echo "=== 6. Commit + Push — SKIPPED (probe) ==="
  COMMIT_HASH="(probe, not committed)"
  echo "  Probe file left for review: $DAYPLAN_PATH"
else
echo "=== 6. Commit + Push ==="
cd "$DS_STRATEGY" || abort "Cannot cd to repo"
reap_stale_git_lock

git add "$DAYPLAN_PATH"
for f in "${ARCHIVE_TARGETS[@]+"${ARCHIVE_TARGETS[@]}"}"; do
  git add "$f"
done

# [allow:current]: the new-files guard (peer-audit 2026-06-04) blocks any commit that adds
# files under current/ without this tag. Every unattended run hit this — the guard was added
# after this line was written and nobody updated it (bug found 2026-07-02).
git commit -m "feat(dayplan): $DATE — auto Day Open (WP-356) [allow:current]" --trailer "Co-Authored-By: Kimi <noreply@moonshot.ai>" -- "$DAYPLAN_PATH" ${ARCHIVE_TARGETS[@]+"${ARCHIVE_TARGETS[@]}"} ${ARCHIVED_PATHS[@]+"${ARCHIVED_PATHS[@]}"} || abort "Git commit failed"

# Capture the local result for the success receipt; publication keeps the
# existing Git destination configuration and never rebases this checkout.
COMMIT_HASH=$(git rev-parse HEAD) || abort "Cannot resolve DayPlan commit"
day_open_publish "$DS_STRATEGY" "$COMMIT_HASH" \
  || abort "Git push failed — local DayPlan commit and unsaved work preserved; the commit stays recorded for the next run"
# The receipt names the commit that is actually on the remote (a cherry-picked twin after a race).
COMMIT_HASH="${DAY_OPEN_PUBLISHED_SHA:-$COMMIT_HASH}"

# WP-484 F64: input-hash means "this data set is PUBLISHED", so it is recorded
# only after the remote accepted the commit (see the guard comment at step 3).
if [ "$PROBE" != "true" ]; then
  echo "$INPUT_HASH" > "$INPUT_HASH_FILE"
fi

bash "$IWE_SCRIPTS/session-guard.sh" close --housekeeping day-open --agent "$SG_AGENT" 2>/dev/null || true

echo "  Published: $COMMIT_HASH"
fi

# ============================================
# 7. Morning digest
# ============================================
echo "=== 7. Morning Digest ==="
SHORT_HASH="${COMMIT_HASH:0:8}"
PLAN_ROWS=$(sed -n '/<details open>/,/<\/details>/p' "$DAYPLAN_PATH" 2>/dev/null | \
  awk -F'|' 'NF>=6 && /\*\*WP/ {
    rp=$5; h=$6;
    gsub(/\*\*/, "", rp); gsub(/ — .*/, "", rp);
    sub(/^[[:space:]]+/, "", rp); sub(/[[:space:]]+$/, "", rp);
    printf "  %s\n", substr(rp, 1, 45)
  }' | head -6 || true)
PLAN_ROWS="${PLAN_ROWS:-  нет данных}"
MSG="✅ День открыт: $DATE"$'\n\n'
MSG+="📋 Сегодня:"$'\n'"${PLAN_ROWS}"$'\n\n'
MSG+="💾 ${SHORT_HASH}"

# WP-149 gate-dopo (peer-session 2026-06-23-07): surface rung_fidelity from last render.
GATE_STATUS_FILE="$DS_STRATEGY/current/gate-status.yaml"
if [ -f "$GATE_STATUS_FILE" ]; then
  GATE_ST=$(grep -E "^  status:" "$GATE_STATUS_FILE" 2>/dev/null | awk '{print $2}' | tr -d "'\"")
  if [ "${GATE_ST:-ok}" != "ok" ] && [ -n "${GATE_ST:-}" ]; then
    echo "  ⚠️ rung_fidelity: $GATE_ST — проверь $GATE_STATUS_FILE"
    MSG+="\n⚠️ Руководство: rung_fidelity=$GATE_ST (gate-status.yaml)"
  fi
fi

# Refs #1245: the same stale-input warning as in the DayPlan (one source of text). It goes in
# LAST, after every other line of the digest, so the 4096 limit counts the finished text.
# Telegram refuses a message over 4096 characters and the whole digest would be lost: the
# script cuts only the banner, never the digest.
if [ -n "${SYNC_WARN:-}" ]; then
  MSG_WITH_WARN=$(printf '%s' "$MSG" | "$_PATCH_PY" "$SCRIPT_HOME/day-open-sync-banner-patch.py" \
    --digest "$SYNC_WARN" 2>/dev/null) && [ -n "$MSG_WITH_WARN" ] && MSG="$MSG_WITH_WARN"
fi

tg_notify "$MSG" terminal

if [ "$PROBE" = "true" ]; then
  echo "  [probe] real heartbeat not touched (watchdog reads only real runs)"
else
  # Record success heartbeat for dead-man's switch watchdog
  jq -n \
    --arg date "$DATE" \
    --arg commit "$COMMIT_HASH" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{date: $date, commit_hash: $commit, timestamp: $ts, status: "success"}' \
    > "$HEARTBEAT_FILE"
  echo "  Heartbeat recorded: $HEARTBEAT_FILE"
fi

# ============================================
# PROBE SUMMARY (WP-484 test stand — attention_min vs wall_min)
# attention_min: this pipeline has ZERO pilot-blocking steps in its normal path
# (abort() ends the run, it never pauses waiting on a human) — so attention_min is
# structurally 0 for every probe unless a future step type changes that. Not a
# guess: derived from reading the script, same way quick-close.yaml's reflex/ai vs
# pilot,blocking step types make session-close's attention_min = 0 in the happy path.
# ============================================
if [ "$PROBE" = "true" ]; then
  WALL_MIN=$(( (SECONDS - PROBE_START_S) / 60 ))
  VERDICT="🔴 red"
  [ "$CHECKS_EXIT" -eq 0 ] && VERDICT="🟢 green"
  echo ""
  echo "=== PROBE SUMMARY ==="
  echo "  date=$DATE verdict=$VERDICT checks_exit=$CHECKS_EXIT wall_min=$WALL_MIN attention_min=0"
  echo "  file=$DAYPLAN_PATH"
fi

echo "=== Done ==="
