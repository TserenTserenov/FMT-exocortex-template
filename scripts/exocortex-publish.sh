#!/usr/bin/env bash
# routing: helper  skill=day-close  called-by=day-close.sh,memory-exocortex-sync.sh  deterministic=true
# see issue #1279 (WP-7 Ф265 item Е), WP-520 (frozen governance canon)
# exocortex-publish.sh — publishes the memory backup mirror <governance>/exocortex/
# while the governance checkout ("canon") is frozen, without ever writing into it.
#
# Why: under the default freeze (session-guard.sh FROZEN_CANONICAL_PATHS) nothing may
# write into the canonical checkout directly. Before this helper the memory hook skipped
# the mirror and day-close.sh step 1 wrote into the frozen canon anyway (#1279).
#
# How:
#   snapshot  — refreshes a durable snapshot of what exocortex/ must contain. The copy
#               rules are NOT re-implemented here: day-close.sh --exocortex-snapshot DIR
#               runs its own step 1 (ownership manifest, protected roots, HOME rendering)
#               with DIR as the target. extensions/ is added with the hook's contract
#               (flat *.md/*.yaml/*.yml, copy-only). The snapshot lives under the runtime
#               directory and survives failures; the first snapshot is seeded from the
#               last fetched origin tip (git archive of a local ref, never the lagging
#               canon checkout) so the ownership manifest keeps its history.
#   publish   — in a persistent isolated worktree of the governance repo (reset to the
#               freshly fetched origin tip before each attempt) applies the snapshot to
#               exocortex/ under the #536 ownership contract: it copies only what day-close
#               owns (manifest files, CLAUDE.md/AGENTS.md/params.yaml/day-rhythm, rules/,
#               extensions/) and deletes only files origin's own manifest lists as owned,
#               with a matching hash, that the snapshot no longer has. Unknown entries and
#               roots of other writers are never touched. It commits only exocortex/ paths
#               and publishes through a stamped scripts/ds-publish.sh (the canon's when it
#               carries "# ds-publish version:", otherwise the template's seed copy).
#   run       — snapshot, then publish.
#   status    — one line about the last publish attempt; exit 3 when it failed or when
#               the snapshot has waited longer than IWE_EXOCORTEX_PUBLISH_STALE_HOURS
#               (default 24) for a successful publish (a killed run writes no status).
#
# Options: --background (detach; output goes to the publish log), --if-due (publish only
# when the last attempt is older than IWE_EXOCORTEX_PUBLISH_MIN_INTERVAL seconds, default
# 900 — the hook uses it so that every memory edit does not become its own push).
#
# Concurrency: one lock for the snapshot (held while it is written or copied out), one for
# the publish. A publish that finds another one running leaves a "pending" marker and
# exits 0; the holder re-checks the marker after releasing the lock, so a marker left
# in that window is not lost. Background runs are detached into their own session /
# process group (setsid, else perl setpgrp), so a group kill of the caller does not
# abort them. The hook throttles its own triggers (see memory-exocortex-sync.sh).
#
# Paths (KEEP IN SYNC with .claude/hooks/memory-exocortex-sync.sh, which reads the stamp):
#   $RUNTIME_DIR/exocortex-publish/snapshot/        the snapshot (exocortex/ content)
#   $RUNTIME_DIR/exocortex-publish/snapshot.stamp   mtime = start of the last good snapshot
#   $RUNTIME_DIR/exocortex-publish/worktree/        the isolated worktree
#   $RUNTIME_DIR/exocortex-publish/publish.log      background output
#   $RUNTIME_DIR/exocortex-publish/run.active       pid of a running "run" (hook reads it)
#   $RUNTIME_DIR/exocortex-publish/run.pending      a hook trigger that arrived meanwhile
#   $RUNTIME_DIR/exocortex-publish/trigger.stamp    mtime = last hook trigger
#   $RUNTIME_DIR/state/exocortex-publish.status     key=value status of the last attempt
# RUNTIME_DIR = $IWE_RUNTIME_DIR, else $WORKSPACE_DIR/.iwe-runtime (IWE_RUNTIME is a host
# name by contract DP.IWE.011 §C, not a directory — see canon-reconcile-published.sh).
#
# Exit codes: 0 ok / nothing to do / queued | 1 failure (recorded in the status file)
#             2 usage | 3 status: the last attempt failed | 90 snapshot skipped (no memory source)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../.claude/lib/iwe-env-bootstrap.sh" || exit 1

GOVERNANCE_REPO="${GOVERNANCE_REPO:-${IWE_GOVERNANCE_REPO:-DS-strategy}}"
CANON="$WORKSPACE_DIR/$GOVERNANCE_REPO"
RUNTIME_DIR="${IWE_RUNTIME_DIR:-$WORKSPACE_DIR/.iwe-runtime}"
META="$RUNTIME_DIR/exocortex-publish"
SNAP="$META/snapshot"
STAMP="$META/snapshot.stamp"
SEEDED="$META/snapshot.seeded"
WT="$META/worktree"
PENDING="$META/publish.pending"
RUN_ACTIVE="$META/run.active"
RUN_PENDING="$META/run.pending"
PUBLISH_LOG="$META/publish.log"
STATUS_FILE="$RUNTIME_DIR/state/exocortex-publish.status"
TIP_REF="refs/exocortex-publish/tip"
MIN_INTERVAL="${IWE_EXOCORTEX_PUBLISH_MIN_INTERVAL:-900}"
STALE_HOURS="${IWE_EXOCORTEX_PUBLISH_STALE_HOURS:-24}"
DAY_CLOSE="$SCRIPT_DIR/day-close.sh"
# Roots of exocortex/ written by other mechanisms: published as origin has them,
# never taken from (or deleted by) the snapshot.
PRESERVED_ROOTS="agent-fault-profile hindsight decisions memory"
# Transaction files of day-close's copier: local to the snapshot, never published.
LOCAL_ONLY_NAMES=".day-close-backup.lock .day-close-backup-quarantine"

say() { echo "exocortex-publish: $*"; }
warn() { echo "exocortex-publish: $*" >&2; }

usage() {
  echo "usage: exocortex-publish.sh snapshot|publish|run|status [--background] [--if-due]" >&2
  exit 2
}

now_iso() { date "+%Y-%m-%dT%H:%M:%S%z"; }

# mtime_epoch FILE — GNU stat first: BSD "stat -f" exists on Linux too but means
# something else there and still exits 0.
mtime_epoch() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

find_python3() {
  local c
  for c in python3 python; do
    if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys; raise SystemExit(sys.version_info[0] != 3)' >/dev/null 2>&1; then
      printf '%s' "$c"; return 0
    fi
  done
  return 1
}

# --- status file -------------------------------------------------------------

status_get() {  # <key>
  [ -f "$STATUS_FILE" ] || return 0
  sed -n "s/^$1=//p" "$STATUS_FILE" | tail -n 1
}

# write_status <ok|fail> <reason> [published_sha]
write_status() {
  local result="$1" reason="$2" sha="${3:-}" last_ok last_ok_epoch tmp
  mkdir -p "$(dirname "$STATUS_FILE")" || return 0
  last_ok=$(status_get last_ok); last_ok_epoch=$(status_get last_ok_epoch)
  [ -n "$sha" ] || sha=$(status_get published_sha)
  if [ "$result" = ok ]; then last_ok=$(now_iso); last_ok_epoch=$(date +%s); fi
  tmp=$(mktemp "$STATUS_FILE.XXXXXX") || return 0
  {
    echo "last_attempt=$(now_iso)"
    echo "last_attempt_epoch=$(date +%s)"
    echo "attempt_id=$(date +%s).$$.${RANDOM}"
    echo "result=$result"
    echo "reason=$(printf '%s' "$reason" | tr '\n' ' ')"
    echo "published_sha=$sha"
    echo "last_ok=$last_ok"
    echo "last_ok_epoch=$last_ok_epoch"
  } > "$tmp" && mv -f "$tmp" "$STATUS_FILE"
}

# Exit 0 when the snapshot has a successful publish no older than STALE_HOURS
# behind it (or there is no snapshot yet), 1 otherwise. Covers a background run
# killed before it could write any status: the old "ok" would hide it.
snapshot_published_recently() {
  local stamp_epoch ok_epoch
  [ -f "$STAMP" ] || return 0
  stamp_epoch=$(mtime_epoch "$STAMP") || return 0
  ok_epoch=$(status_get last_ok_epoch)
  [ -n "$ok_epoch" ] || ok_epoch=0
  [ "$stamp_epoch" -le $((ok_epoch + STALE_HOURS * 3600)) ]
}

cmd_status() {
  if ! snapshot_published_recently; then
    local last_ok; last_ok=$(status_get last_ok)
    echo "снимок памяти не опубликован дольше ${STALE_HOURS} ч (последняя успешная публикация: ${last_ok:-никогда}); снимок сохранён, повтор при следующем запуске"
    return 3
  fi
  if [ ! -f "$STATUS_FILE" ]; then
    echo "публикация бэкапа памяти ещё не выполнялась"
    return 0
  fi
  local result reason when sha
  result=$(status_get result); reason=$(status_get reason)
  when=$(status_get last_attempt); sha=$(status_get published_sha)
  case "$result" in
    ok)   echo "последняя публикация бэкапа памяти успешна ($when${sha:+, коммит ${sha:0:12}}): $reason"; return 0 ;;
    *)    echo "последняя публикация бэкапа памяти НЕ удалась ($when): $reason; снимок сохранён, повтор при следующем запуске"; return 3 ;;
  esac
}

# --- locks (scripts/lib/dirty-guard-lock.sh: one lock per process) ------------

load_lock_lib() {
  local lib="$SCRIPT_DIR/lib/dirty-guard-lock.sh"
  unset DGLOCK_LIB_READY
  # shellcheck source=lib/dirty-guard-lock.sh
  if [ -r "$lib" ] && . "$lib" && [ "${DGLOCK_LIB_READY:-}" = 1 ]; then
    return 0
  fi
  warn "библиотека блокировок недоступна: $lib"
  return 1
}

# take_lock <name> <wait-seconds>: 0 taken, 1 busy, 2 error
take_lock() {
  local dir="$META/locks/$1" waited=0 rc
  mkdir -p "$dir" || return 2
  # shellcheck disable=SC2034  # read by the lock library's messages
  DGLOCK_PREFIX="exocortex-publish:"
  while :; do
    rc=0; dglock_acquire "$dir" "exocortex-publish" || rc=$?
    case "$rc" in
      0) return 0 ;;
      1) [ "$waited" -ge "$2" ] && return 1 ;;
      *) warn "блокировка $1: ${DGLOCK_REASON:-}"; return 2 ;;
    esac
    sleep 1
    waited=$((waited + 1))
  done
}

# --- snapshot ----------------------------------------------------------------

is_member() {  # <word> <list>
  case " $2 " in *" $1 "*) return 0 ;; esac
  return 1
}

# copy_tree_entries <src> <dst> <skip-list>: copies every top-level entry of src
# (dotfiles included) except the names in skip-list.
copy_tree_entries() {
  local src="$1" dst="$2" skip="$3" entry name
  mkdir -p "$dst" || return 1
  for entry in "$src"/* "$src"/.[!.]* "$src"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    name=$(basename "$entry")
    is_member "$name" "$skip" && continue
    cp -pR "$entry" "$dst/" || return 1
  done
}

# Seeds the first snapshot from the last fetched origin tip: the publisher's own
# ref, else the canon's remote-tracking branch (both local, no network). Never the
# canon checkout itself: it lags behind origin while it is frozen.
seed_snapshot() {
  [ -f "$SEEDED" ] && return 0
  mkdir -p "$SNAP" || return 1
  local ref="" cand tmp
  if git -C "$CANON" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    for cand in "$TIP_REF" "refs/remotes/origin/$(resolve_branch)"; do
      if git -C "$CANON" cat-file -e "$cand:exocortex" 2>/dev/null; then ref="$cand"; break; fi
    done
  fi
  if [ -n "$ref" ]; then
    tmp=$(mktemp -d "$META/seed.XXXXXX") || return 1
    if ! git -C "$CANON" archive --format=tar "$ref" -- exocortex | tar -x -C "$tmp"; then
      rm -rf -- "$tmp"; return 1
    fi
    copy_tree_entries "$tmp/exocortex" "$SNAP" "$PRESERVED_ROOTS $LOCAL_ONLY_NAMES" || { rm -rf -- "$tmp"; return 1; }
    rm -rf -- "$tmp"
  fi
  : > "$SEEDED"
}

# Same contract as memory-exocortex-sync.sh: flat *.md/*.yaml/*.yml, copy-only.
snapshot_extensions() {
  local src="$WORKSPACE_DIR/extensions" f
  [ -d "$src" ] || return 0
  for f in "$src"/*.md "$src"/*.yaml "$src"/*.yml; do
    [ -f "$f" ] || continue
    mkdir -p "$SNAP/extensions" || return 1
    cp -p "$f" "$SNAP/extensions/" || return 1
  done
}

cmd_snapshot() {
  load_lock_lib || return 1
  mkdir -p "$META" || { warn "не удалось создать $META"; return 1; }
  local rc=0
  take_lock snapshot 60 || rc=$?
  if [ "$rc" -ne 0 ]; then
    warn "снимок памяти не обновлён: блокировка снимка занята или недоступна"
    return 1
  fi
  trap 'dglock_release' EXIT
  if ! seed_snapshot; then
    dglock_release; trap - EXIT
    warn "не удалось подготовить снимок из $CANON/exocortex"
    return 1
  fi
  : > "$STAMP.new"
  rc=0
  bash "$DAY_CLOSE" --exocortex-snapshot "$SNAP" || rc=$?
  case "$rc" in
    0|4)
      if snapshot_extensions; then
        mv -f "$STAMP.new" "$STAMP"; rc=0
      else
        warn "extensions/ не скопированы в снимок"; rc=1
      fi ;;
    90) rm -f "$STAMP.new" ;;
    *)  rm -f "$STAMP.new"; warn "снимок памяти не обновлён (day-close.sh --exocortex-snapshot, код $rc)"; rc=1 ;;
  esac
  dglock_release; trap - EXIT
  return "$rc"
}

# --- publish -----------------------------------------------------------------

# Internal: applies the snapshot to <worktree>/exocortex under the snapshot lock.
# Runs as its own process because the lock library holds one lock per process.
cmd_apply() {
  local rc=0 py
  # Only our own worktree may be changed here.
  [ "$1" = "$WT" ] || { warn "_apply: ожидалась изолированная копия $WT, получено $1"; return 1; }
  py=$(find_python3) || { warn "python3 не найден — снимок не перенесён"; return 1; }
  load_lock_lib || return 1
  take_lock snapshot 60 || { warn "блокировка снимка занята"; return 1; }
  trap 'dglock_release' EXIT
  if [ -e "$SNAP/.day-close-backup-incomplete" ]; then
    warn "снимок неполный (прерванное копирование) — не публикуется"
    dglock_release; trap - EXIT
    return 1
  fi
  "$py" - "$SNAP" "$1/exocortex" "$PRESERVED_ROOTS" <<'PY' || rc=$?
# Applies the snapshot under the #536 ownership contract (see the header).
import hashlib, json, os, shutil, sys
from pathlib import Path, PurePosixPath

snap, dst = Path(sys.argv[1]), Path(sys.argv[2])
preserved = set(sys.argv[3].split())
MANIFEST = ".day-close-backup-manifest.json"
SPECIALS = ["CLAUDE.md", "AGENTS.md", "params.yaml", "day-rhythm-config.yaml", MANIFEST]
OWNED_TREES = ["rules", "extensions"]

def owned_files(root):
    path = root / MANIFEST
    if not path.is_file() or path.is_symlink():
        return {}
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        print(f"exocortex-publish: manifest {path} unreadable ({exc}); nothing pruned", file=sys.stderr)
        return {}
    files = payload.get("files") if isinstance(payload, dict) else None
    if not isinstance(files, dict) or payload.get("schema_version") != 1:
        print(f"exocortex-publish: manifest {path} has an unknown schema; nothing pruned", file=sys.stderr)
        return {}
    return files

def safe_rel(raw):
    rel = PurePosixPath(raw)
    if rel.is_absolute() or not rel.parts or any(p in ("", ".", "..") for p in rel.parts):
        return None
    if rel.parts[0] in preserved:
        return None
    return rel

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()

snap_owned = owned_files(snap)
origin_owned = owned_files(dst)  # read before the snapshot's manifest replaces it

to_copy = set()
for raw in snap_owned:
    rel = safe_rel(raw)
    if rel is not None and (snap / rel).is_file():
        to_copy.add(rel)
for name in SPECIALS:
    if (snap / name).is_file():
        to_copy.add(PurePosixPath(name))
for tree in OWNED_TREES:
    base = snap / tree
    if base.is_dir() and not base.is_symlink():
        for path in base.rglob("*"):
            if path.is_file() and not path.is_symlink():
                to_copy.add(PurePosixPath(path.relative_to(snap).as_posix()))

for rel in sorted(to_copy):
    target = dst / rel
    for parent in reversed(target.relative_to(dst).parents):
        node = dst / parent
        if node.is_symlink() or (node.exists() and not node.is_dir()):
            raise SystemExit(f"exocortex-publish: {node} is in the way of {rel}")
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.is_symlink():
        target.unlink()
    elif target.is_dir():
        raise SystemExit(f"exocortex-publish: {target} is a directory, expected a file")
    shutil.copy2(snap / rel, target)

pruned = 0
for raw, recorded in origin_owned.items():
    rel = safe_rel(raw)
    if rel is None or raw in snap_owned or (snap / rel).exists():
        continue
    target = dst / rel
    if target.is_symlink() or not target.is_file():
        continue
    if sha256(target) != recorded:
        print(f"exocortex-publish: kept {rel}: changed since it was backed up", file=sys.stderr)
        continue
    target.unlink()
    pruned += 1
    parent = target.parent
    while parent != dst and not any(parent.iterdir()):
        parent.rmdir()
        parent = parent.parent
print(f"exocortex-publish: {len(to_copy)} file(s) applied, {pruned} owned file(s) pruned")
PY
  dglock_release; trap - EXIT
  return "$rc"
}

resolve_branch() {
  if [ -n "${IWE_EXOCORTEX_PUBLISH_BRANCH:-}" ]; then
    printf '%s' "$IWE_EXOCORTEX_PUBLISH_BRANCH"; return
  fi
  local b
  b=$(git -C "$CANON" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
  [ -n "$b" ] || b=$(git -C "$CANON" symbolic-ref --quiet --short HEAD 2>/dev/null)
  printf '%s' "${b:-main}"
}

# A copy without the "# ds-publish version: N" stamp predates --exact-commit
# (#1230) and rejects it; update.sh keeps such copies when their hash is unknown,
# so the canon's copy is used only when stamped, else the template's seed copy.
ds_publish_stamped() {
  grep -qE '^# ds-publish version: [0-9]+$' "$1" 2>/dev/null
}

resolve_ds_publish() {
  local c
  for c in "${IWE_EXOCORTEX_DS_PUBLISH:-}" "$CANON/scripts/ds-publish.sh" \
           "${IWE_TEMPLATE:-}/seed/strategy/scripts/ds-publish.sh" "$SCRIPT_DIR/../seed/strategy/scripts/ds-publish.sh"; do
    case "$c" in /*) ;; *) continue ;; esac
    [ -f "$c" ] && ds_publish_stamped "$c" && { printf '%s' "$c"; return 0; }
  done
  return 1
}

fetch_tip() {  # <branch>
  local err
  err=$(git -C "$CANON" fetch --quiet origin "+refs/heads/$1:$TIP_REF" 2>&1) || {
    printf '%s' "$(printf '%s' "$err" | tail -n 1)"
    return 1
  }
}

# Creates or reuses the isolated worktree; on return it sits on a clean $TIP_REF.
prepare_worktree() {
  local canon_common wt_common
  canon_common=$(cd "$CANON" && cd "$(git rev-parse --git-common-dir)" && pwd -P) || return 1
  if [ -e "$WT/.git" ]; then
    wt_common=$( (cd "$WT" && cd "$(git rev-parse --git-common-dir 2>/dev/null)" && pwd -P) 2>/dev/null) || wt_common=""
    if [ "$wt_common" != "$canon_common" ]; then
      # Leftover of another repository or a broken worktree: it lives in our own
      # runtime directory, so it is safe to drop and re-create.
      rm -rf -- "$WT"
      git -C "$CANON" worktree prune >/dev/null 2>&1 || true
    fi
  elif [ -e "$WT" ]; then
    rm -rf -- "$WT"
  fi
  if [ ! -e "$WT" ]; then
    git -C "$CANON" worktree prune >/dev/null 2>&1 || true
    mkdir -p "$(dirname "$WT")" || return 1
    git -C "$CANON" worktree add --quiet --detach "$WT" "$TIP_REF" >/dev/null 2>&1 || return 1
  fi
  git -C "$WT" checkout --quiet --force --detach "$TIP_REF" >/dev/null 2>&1 || return 1
  git -C "$WT" reset --quiet --hard "$TIP_REF" >/dev/null 2>&1 || return 1
  git -C "$WT" clean -ffdq >/dev/null 2>&1 || return 1
}

publish_once() {
  local branch err sha tip publisher out rc staged stray published
  if [ ! -d "$CANON" ] || ! git -C "$CANON" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    write_status fail "$CANON не является git-репозиторием"; return 1
  fi
  git -C "$CANON" remote get-url origin >/dev/null 2>&1 || { write_status fail "у $GOVERNANCE_REPO нет remote origin"; return 1; }
  [ -f "$STAMP" ] && [ -d "$SNAP" ] || { write_status fail "снимка памяти ещё нет (сначала snapshot)"; return 1; }
  publisher=$(resolve_ds_publish) || { write_status fail "не найден совместимый ds-publish.sh (со строкой «# ds-publish version:») ни в $GOVERNANCE_REPO, ни в шаблоне — запустите update.sh"; return 1; }
  branch=$(resolve_branch)

  err=$(fetch_tip "$branch") || { write_status fail "fetch origin/$branch не удался: $err"; return 1; }
  prepare_worktree || { write_status fail "не удалось подготовить изолированную копию $WT"; return 1; }
  bash "$SELF" _apply "$WT" || { write_status fail "не удалось перенести снимок в изолированную копию"; return 1; }

  git -C "$WT" add --all -- exocortex >/dev/null 2>&1 || { write_status fail "git add exocortex/ не удался"; return 1; }
  staged=$(git -C "$WT" diff --cached --name-only)
  stray=$(printf '%s\n' "$staged" | grep -v '^exocortex/' | grep -v '^$' || true)
  if [ -n "$stray" ]; then
    git -C "$WT" reset --quiet --hard "$TIP_REF" >/dev/null 2>&1 || true
    write_status fail "в коммит попали пути вне exocortex/: $(printf '%s' "$stray" | head -n 3 | tr '\n' ' ')"; return 1
  fi
  tip=$(git -C "$WT" rev-parse "$TIP_REF")
  if [ -z "$staged" ]; then
    write_status ok "без изменений: origin/$branch уже содержит снимок" "$tip"
    say "без изменений — origin/$branch уже содержит снимок памяти"
    return 0
  fi

  local -a ident=()
  if [ -z "$(git -C "$WT" config user.email 2>/dev/null)" ]; then
    ident=(-c "user.name=IWE exocortex backup" -c "user.email=iwe-exocortex-backup@localhost")
  fi
  out=$(git -C "$WT" ${ident[@]+"${ident[@]}"} commit --quiet -m "exocortex: бэкап памяти ($(date '+%Y-%m-%d %H:%M'))" 2>&1) || {
    write_status fail "коммит отклонён: $(printf '%s' "$out" | tail -n 1)"; return 1
  }
  sha=$(git -C "$WT" rev-parse HEAD)

  rc=0
  out=$(bash "$publisher" "$WT" normal --branch "$branch" --from-commit "$sha" --exact-commit "$sha" \
        --reason "exocortex backup (#1279)" 2>&1) || rc=$?
  printf '%s\n' "$out"
  if [ "$rc" -ne 0 ]; then
    write_status fail "ds-publish.sh код $rc: $(printf '%s' "$out" | tail -n 1)"; return 1
  fi
  published=$(printf '%s' "$out" | sed -n 's/.*published as \([0-9a-f]\{7,40\}\).*/\1/p' | tail -n 1)
  fetch_tip "$branch" >/dev/null 2>&1 || true
  if [ -n "$published" ]; then
    published=$(git -C "$CANON" rev-parse --verify --quiet "$published^{commit}" 2>/dev/null || printf '%s' "$published")
  else
    published=$(git -C "$CANON" rev-parse --verify --quiet "$TIP_REF^{commit}" 2>/dev/null || printf '%s' "$sha")
  fi
  write_status ok "опубликовано в origin/$branch" "$published"
  say "опубликовано в origin/$branch как ${published:0:12}"
  return 0
}

is_due() {
  local last now
  last=$(status_get last_attempt_epoch)
  [ -n "$last" ] || return 0
  now=$(date +%s)
  [ $((now - last)) -ge "$MIN_INTERVAL" ]
}

cmd_publish() {
  local if_due="$1" rc=0 lrc round=0
  load_lock_lib || { write_status fail "библиотека блокировок недоступна"; return 1; }
  mkdir -p "$META" || return 1
  if [ "$if_due" = 1 ] && ! is_due; then
    say "публикация отложена: прошлая попытка моложе ${MIN_INTERVAL}с (снимок сохранён, опубликуется позже или на Day Close)"
    return 0
  fi
  while :; do
    lrc=0; take_lock publish 0 || lrc=$?
    case "$lrc" in
      0) ;;
      1) : > "$PENDING"; say "публикация уже идёт — поставлена в очередь"; return "$rc" ;;
      *) write_status fail "блокировка публикации недоступна"; return 1 ;;
    esac
    trap 'dglock_release' EXIT
    while :; do
      rm -f "$PENDING"
      rc=0; publish_once || rc=$?
      round=$((round + 1))
      [ -f "$PENDING" ] && [ "$round" -lt 5 ] || break
    done
    dglock_release; trap - EXIT
    # A marker written between the last check and the release has no other
    # reader: take the lock again for it (a busy lock means its holder sees it).
    [ -f "$PENDING" ] && [ "$round" -lt 5 ] || break
  done
  return "$rc"
}

# run = snapshot + publish, repeated while hook triggers arrived meanwhile
# (run.pending); run.active lets the hook skip launching a second run.
cmd_run() {
  local if_due="$1" rc=0 round=0
  mkdir -p "$META" || return 1
  while :; do
    echo "$$" > "$RUN_ACTIVE"
    while :; do
      rm -f "$RUN_PENDING"
      rc=0; cmd_snapshot || rc=$?
      if [ "$rc" -ne 0 ] && [ "$rc" -ne 90 ]; then
        # A failed refresh still leaves the previous snapshot: publish what we have.
        warn "снимок не обновлён — публикуется предыдущий снимок"
      fi
      rc=0; cmd_publish "$if_due" || rc=$?
      round=$((round + 1))
      [ -f "$RUN_PENDING" ] && [ "$round" -lt 3 ] || break
    done
    [ "$(cat "$RUN_ACTIVE" 2>/dev/null)" = "$$" ] && rm -f "$RUN_ACTIVE"
    [ -f "$RUN_PENDING" ] && [ "$round" -lt 3 ] || break
  done
  return "$rc"
}

# Detaches the background run into its own session / process group, so that a
# group kill of the caller (launchd job end, CI step, sandbox) does not take it
# down mid-publish. Falls back to a plain nohup only when neither tool exists.
launch_detached() {
  if command -v setsid >/dev/null 2>&1; then
    nohup setsid bash "$SELF" "$@" >>"$PUBLISH_LOG" 2>&1 </dev/null &
  elif command -v perl >/dev/null 2>&1; then
    nohup perl -e 'setpgrp(0, 0); exec @ARGV or die "exec: $!"' bash "$SELF" "$@" >>"$PUBLISH_LOG" 2>&1 </dev/null &
  else
    nohup bash "$SELF" "$@" >>"$PUBLISH_LOG" 2>&1 </dev/null &
  fi
  echo "$!"
}

# --- main --------------------------------------------------------------------

[ "$#" -ge 1 ] || usage
CMD="$1"; shift
if [ "$CMD" = "_apply" ]; then
  [ "$#" -eq 1 ] || usage
  cmd_apply "$1"; exit $?
fi
BACKGROUND=0; IF_DUE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --background) BACKGROUND=1 ;;
    --if-due) IF_DUE=1 ;;
    *) usage ;;
  esac
  shift
done

case "$CMD" in
  snapshot|publish|run|status) ;;
  *) usage ;;
esac

if [ "$BACKGROUND" = 1 ] && [ "$CMD" != status ]; then
  mkdir -p "$META" || exit 1
  args=("$CMD"); [ "$IF_DUE" = 1 ] && args+=(--if-due)
  pid=$(launch_detached "${args[@]}")
  say "запущено в фоне (pid $pid, журнал $PUBLISH_LOG)"
  exit 0
fi

case "$CMD" in
  status)   cmd_status ;;
  snapshot) cmd_snapshot ;;
  publish)  cmd_publish "$IF_DUE" ;;
  run)      cmd_run "$IF_DUE" ;;
esac
