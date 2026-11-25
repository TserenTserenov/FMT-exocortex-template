#!/usr/bin/env bash
# routing: helper  called-by=governance-repo .githooks/pre-commit,pre-push  deterministic=true
# wp-inbox-close-gate.sh — governance repo hook delegate (WP-503 Phase 110).
# Lives in the scripts folder next to wp-inbox.sh (the template's install-hooks.sh
# copies only pre-commit and pre-push into a governance repo, so a delegate kept
# beside them would never reach a template user).
#
# A WP is closed by moving inbox/WP-N/ to archive/wp-contexts/WP-N/. Its inbound
# mailbox (inbox/WP-N/INBOX.md, written by scripts/wp-inbox.sh) must hold no
# «новое» entries at that moment: the owner either moves each entry into
# «Осталось» of the card or marks it «учтено» with the pilot's consent. The
# archive copy keeps every entry, and an archived mailbox gains no new
# «новое» entries afterwards (a stale branch merged or rebased onto it).
#
#   wp-inbox-close-gate.sh pre-commit   index vs HEAD; catches a manual git mv
#   wp-inbox-close-gate.sh pre-push     stdin = git pre-push ref lines; catches
#                                       commits replayed by cherry-pick/rebase,
#                                       which never run pre-commit
#
# The mailbox format is parsed by `wp-inbox.sh check-text` only; this file
# finds the closings and reads the right blob. wp-inbox.sh missing is a refusal
# only when a closing is found: nothing else here needs it.
# Exit: 0 pass · 1 refused.
# Compatible: bash 3.2+

set -uo pipefail

ZERO_SHA=0000000000000000000000000000000000000000
INBOX_RE='^inbox/WP-[0-9]+/INBOX\.md$'
ARCH_RE='^archive/wp-contexts/WP-[0-9]+/INBOX\.md$'

find_inbox_tool() {
  local dir
  for dir in "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" \
             "${IWE_SCRIPTS:-}" "${IWE_ROOT:-$HOME/IWE}/scripts" \
             "${IWE_TEMPLATE:+$IWE_TEMPLATE/scripts}" \
             "${IWE_WORKSPACE:-$HOME/IWE}/FMT-exocortex-template/scripts"; do
    if [ -n "$dir" ] && [ -f "$dir/wp-inbox.sh" ]; then
      printf '%s\n' "$dir/wp-inbox.sh"
      return 0
    fi
  done
  return 1
}

wp_num_of() {
  printf '%s\n' "$1" | sed -E 's#^(inbox|archive/wp-contexts)/WP-([0-9]+)/INBOX\.md$#\2#'
}

# fresh_headers <git object spec>: the «новое» headers of that mailbox on stdout.
# Exit 0 read (any number of headers), 1 unreadable blob or unparseable header.
fresh_headers() {
  local out rc
  out=$(git show "$1" | bash "$INBOX_TOOL" check-text)
  rc=$?
  [ "$rc" -le 1 ] || return 1
  printf '%s\n' "$out"
}

# entries_kept <mailbox before the closing> <archive copy> <WP number>: every
# entry that was «новое» before the closing is still in the archive copy, so
# deleting it by hand in the closing commit does not count as processing it.
entries_kept() {
  local before="$1" arch="$2" num="$3" fresh arch_text head id refused=0
  fresh=$(fresh_headers "$before") || { echo "❌ РП-$num: ящик до закрытия не прочитан ($before)" >&2; return 1; }
  [ -n "$fresh" ] || return 0
  arch_text=$(git show "$arch") || return 1
  while IFS= read -r head; do
    [ -n "$head" ] || continue
    id=$(printf '%s\n' "$head" | LC_ALL=C sed -E 's/^(## И-[0-9]+ · ).*/\1/')
    printf '%s\n' "$arch_text" | LC_ALL=C grep -q "^$id" && continue
    echo "❌ РП-$num: запись ${id% · } была «новое» и пропала из архивной копии ящика — запись удаляют не руками, а через wp-inbox.sh mark." >&2
    refused=1
  done <<EOF
$fresh
EOF
  return "$refused"
}

# check_archived <mailbox before the closing> <archive copy> <WP number>
check_archived() {
  check_box "$2" "$3" "$INBOX_TOOL" || return 1
  entries_kept "$1" "$2" "$3"
}

# check_archive_growth <archive copy before> <after> <WP number>: an already
# archived mailbox must not gain «новое» entries — a stale branch merged or
# rebased onto a closed WP carries its entry there, where nobody reads it.
check_archive_growth() {
  local before="$1" after="$2" num="$3" old new added
  new=$(fresh_headers "$after") || { echo "❌ РП-$num: архивная копия ящика не прочитана ($after)" >&2; return 1; }
  [ -n "$new" ] || return 0
  old=$(fresh_headers "$before" 2>/dev/null) || old=""
  added=$(printf '%s\n' "$new" | LC_ALL=C grep -vxF -f <(printf '%s\n' "$old") || true)
  [ -n "$added" ] || return 0
  echo "❌ РП-$num закрыт, а в архивную копию его ящика пришла запись «новое» (слияние или rebase устаревшей ветки):" >&2
  printf '%s\n' "$added" >&2
  echo "   Уберите её из архивной копии и подайте заново: в ящик действующего РП (wp-inbox.sh add --to WP-M) или в inbox/backlog-with-triggers.md (правило отправителя, protocol-work §2в)." >&2
  return 1
}

# check_box <git object spec> <WP number> <tool>: 0 clean, 1 refused.
check_box() {
  local obj="$1" num="$2" tool="$3" rc
  if ! git cat-file -e "$obj" 2>/dev/null; then
    echo "❌ РП-$num: ящик входящих не прочитан ($obj) — проверка закрытия невозможна" >&2
    return 1
  fi
  git show "$obj" | bash "$tool" check-text --wp "$num" >&2
  rc=$?
  [ "$rc" -eq 0 ] && return 0
  return 1
}

require_tool() {
  if ! INBOX_TOOL=$(find_inbox_tool); then
    echo "❌ Закрытие РП с ящиком входящих, но wp-inbox.sh не найден (IWE_SCRIPTS, IWE_ROOT/scripts, шаблон) — проверить ящик нельзя. Восстановите установку (/iwe-update)." >&2
    return 1
  fi
}

# Hint for the sender rule (protocol-work §2): this session's WP comes from its
# session semaphore, matched by the worktree path. No semaphore, no hint.
sender_hint() {
  local top sem own changed num
  top=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
  sem=$(grep -lxE "(isolated_worktree|governance_worktree): ${top}" \
        "${IWE_ROOT:-$HOME/IWE}"/.iwe-runtime/sessions/*.open 2>/dev/null | head -1)
  [ -n "$sem" ] || return 0
  own=$(sed -nE 's/^wp: *WP-?([0-9]+).*/\1/p' "$sem" | head -1)
  [ -n "$own" ] || return 0
  changed=$(git diff --cached --name-only --diff-filter=M 2>/dev/null \
            | sed -nE 's|^inbox/WP-([0-9]+)/WP-[0-9]+\.md$|\1|p')
  for num in $changed; do
    [ "$num" = "$own" ] && continue
    echo "ℹ️  Сессия РП-$own меняет карточку РП-$num. Если это знание для РП-$num, а не правка владельца — запись в его ящик: wp-inbox.sh add --to WP-$num (правило отправителя, protocol-work §2)." >&2
  done
}


# git output captured with its own exit check: a failing git call must not
# read as "nothing was closed".
git_out() {
  local out
  if ! out=$(git "$@"); then
    echo "❌ git $* не выполнился — проверка ящиков входящих невозможна" >&2
    return 1
  fi
  printf '%s\n' "$out"
}

gate_pre_commit() {
  local deleted modified closed grown path num arch changed refused=0
  git rev-parse --verify -q HEAD >/dev/null || return 0
  deleted=$(git_out diff --cached --name-only --no-renames --diff-filter=D HEAD) || return 1
  modified=$(git_out diff --cached --name-only --no-renames --diff-filter=M HEAD -- archive/wp-contexts) || return 1
  closed=$(printf '%s\n' "$deleted" | grep -E "$INBOX_RE" || true)
  grown=$(printf '%s\n' "$modified" | grep -E "$ARCH_RE" || true)
  if [ -z "$closed" ] && [ -z "$grown" ]; then
    sender_hint
    return 0
  fi
  require_tool || return 1
  for path in $closed; do
    num=$(wp_num_of "$path")
    arch="archive/wp-contexts/WP-$num/INBOX.md"
    # The archive copy counts only when this commit adds or changes it: a stale
    # copy left by an earlier closing must not stand in for the mailbox deleted now.
    changed=$(git_out diff --cached --name-only HEAD -- "$arch") || return 1
    if [ -n "$changed" ] && git cat-file -e ":$arch" 2>/dev/null; then
      check_archived "HEAD:$path" ":$arch" "$num" || refused=1
    else
      check_box "HEAD:$path" "$num" "$INBOX_TOOL" || refused=1
    fi
  done
  for arch in $grown; do
    check_archive_growth "HEAD:$arch" ":$arch" "$(wp_num_of "$arch")" || refused=1
  done
  return "$refused"
}

# Base of the pushed range: the remote tip, or for a new branch its fork point
# from origin/main. No trustworthy base = refusal, not a silent pass.
range_base() {
  local local_sha="$1" remote_sha="$2"
  if [ "$remote_sha" != "$ZERO_SHA" ]; then
    git cat-file -e "${remote_sha}^{commit}" 2>/dev/null && { printf '%s\n' "$remote_sha"; return 0; }
    return 1
  fi
  git rev-parse --verify -q origin/main >/dev/null || return 1
  git merge-base origin/main "$local_sha"
}

# archive_written <before rev> <after rev> <archive path>: 0 when the archive
# copy exists at <after> and changed since <before>.
archive_written() {
  local changed
  changed=$(git_out diff --name-only "$1" "$2" -- "$3") || return 2
  [ -n "$changed" ] && git cat-file -e "$2:$3" 2>/dev/null
}

# check_closing <commit with the deletion> <its parent> <inbox path>: the
# mailbox as it stood when the closing happened.
check_closing() {
  local commit="$1" before="$2" path="$3" num arch rc
  require_tool || return 1
  num=$(wp_num_of "$path")
  arch="archive/wp-contexts/WP-$num/INBOX.md"
  archive_written "$before" "$commit" "$arch"
  rc=$?
  case "$rc" in
    0) check_archived "$before:$path" "$commit:$arch" "$num" ;;
    1) check_box "$before:$path" "$num" "$INBOX_TOOL" ;;
    *) return 1 ;;
  esac
}

# Three passes over base..tip.
# 1) Every commit that deletes inbox/WP-N/INBOX.md, read in that commit: catches
#    an entry added after base and a rebase carrying an entry into the archive copy.
# 2) The net change base→tip for mailboxes open at base and archived at tip:
#    catches a merge commit (git log shows no diff for merges) carrying a new
#    entry into the archive copy. A deletion without an archive copy is left to
#    pass 1, which reads it in its own commit (an entry marked inside the range).
# 3) Archive copies changed base→tip: a WP already closed at base must not gain
#    «новое» entries from a stale branch merged or rebased onto it.
check_range() {
  local base="$1" tip="$2" log line commit="" net path num arch rc refused=0
  log=$(git_out log --no-renames --diff-filter=D --name-only --format='C %H' "$base..$tip" -- inbox) || return 1
  while IFS= read -r line; do
    case "$line" in
      "C "*) commit="${line#C }" ;;
      "") ;;
      *)
        printf '%s\n' "$line" | grep -qE "$INBOX_RE" || continue
        check_closing "$commit" "$commit^" "$line" || refused=1
        ;;
    esac
  done <<EOF
$log
EOF
  net=$(git_out diff --no-renames --diff-filter=D --name-only "$base" "$tip" -- inbox) || return 1
  for path in $(printf '%s\n' "$net" | grep -E "$INBOX_RE" || true); do
    num=$(wp_num_of "$path")
    arch="archive/wp-contexts/WP-$num/INBOX.md"
    archive_written "$base" "$tip" "$arch"
    rc=$?
    [ "$rc" -eq 1 ] && continue
    require_tool || return 1
    { [ "$rc" -eq 0 ] && check_archived "$base:$path" "$tip:$arch" "$num"; } || refused=1
  done
  net=$(git_out diff --no-renames --diff-filter=M --name-only "$base" "$tip" -- archive/wp-contexts) || return 1
  for arch in $(printf '%s\n' "$net" | grep -E "$ARCH_RE" || true); do
    require_tool || return 1
    check_archive_growth "$base:$arch" "$tip:$arch" "$(wp_num_of "$arch")" || refused=1
  done
  return "$refused"
}

gate_pre_push() {
  local local_sha remote_ref remote_sha tip base refused=0
  while read -r _ local_sha remote_ref remote_sha; do
    [ -n "${local_sha:-}" ] || continue
    [ "$local_sha" = "$ZERO_SHA" ] && continue
    # Branches and tags only, as the freeze and fast-forward checks: lease and
    # lock pushes go to refs/notes/* with root commits that share no history.
    case "$remote_ref" in
      refs/heads/*|refs/tags/*) ;;
      *) continue ;;
    esac
    tip=$(git rev-parse --verify -q "${local_sha}^{commit}") || continue
    if ! base=$(range_base "$tip" "$remote_sha"); then
      echo "❌ Push blocked ($remote_ref): нет базы для проверки ящиков входящих — выполните git fetch origin и повторите." >&2
      refused=1
      continue
    fi
    check_range "$base" "$tip" || refused=1
  done
  if [ "$refused" -ne 0 ]; then
    echo "❌ Push blocked: отправляемые коммиты закрывают РП с неразобранным ящиком входящих (РП-503 Ф110)." >&2
  fi
  return "$refused"
}

case "${1:-}" in
  pre-commit) gate_pre_commit ;;
  pre-push) gate_pre_push ;;
  *) echo "usage: $0 pre-commit|pre-push" >&2; exit 2 ;;
esac
