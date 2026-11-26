#!/usr/bin/env bash
# wp-inbox-close-gate-smoke.sh — checks scripts/wp-inbox-close-gate.sh (WP-503 Phase 110)
# in a throwaway repository: pre-commit on a manual archive move or deletion of a
# mailbox with «новое» entries, pre-push on the pushed range (new branch, several
# refs, an entry added after the range base, an old archived mailbox left alone).
# Run: bash scripts/tests/wp-inbox-close-gate-smoke.sh → exit 0 = all checks passed.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLS="$(cd "$HERE/.." && pwd)"
GATE="$TOOLS/wp-inbox-close-gate.sh"
# A gate copy alone in a folder: proves the "wp-inbox.sh not found" refusal
# without depending on what is installed on this host.
LONE=$(mktemp -d "${TMPDIR:-/tmp}/wp-inbox-gate-lone.XXXXXX")
cp "$GATE" "$LONE/"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/wp-inbox-gate.XXXXXX")
trap 'rm -rf "$WORK" "$LONE"' EXIT
REPO="$WORK/repo"
NO_TOOLS="$WORK/no-tools"
mkdir -p "$REPO" "$NO_TOOLS"

fail=0
check() {  # check <description> <expected> <actual>
  if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: ожидалось '$2', получено '$3'"; fail=1; fi
}
g() { git -C "$REPO" -c user.email=t@example.invalid -c user.name=t "$@"; }
# The gate with this repo as cwd; IWE_ROOT points at an empty dir: no session semaphores.
gate() { (cd "$REPO" && IWE_SCRIPTS="$TOOLS" IWE_ROOT="$WORK" bash "$GATE" "$@" 2>/dev/null); }
gate_rc() { local rc=0; gate "$@" >/dev/null || rc=$?; echo "$rc"; }
gate_no_tool_rc() {
  local rc=0
  (cd "$REPO" && IWE_SCRIPTS="$NO_TOOLS" IWE_ROOT="$NO_TOOLS" IWE_WORKSPACE="$NO_TOOLS" IWE_TEMPLATE="" \
    bash "$LONE/wp-inbox-close-gate.sh" "$@" >/dev/null 2>&1) || rc=$?
  echo "$rc"
}
push_rc() {  # push_rc <ref lines…>: feed pre-push stdin
  local rc=0
  printf '%s\n' "$@" | gate pre-push >/dev/null || rc=$?
  echo "$rc"
}
new_wp() {  # new_wp <N> <status of entry И-1>
  mkdir -p "$REPO/inbox/WP-$1"
  printf -- '---\nwp: %s\nstatus: done\n---\n' "$1" > "$REPO/inbox/WP-$1/WP-$1.md"
  printf '# Входящие РП-%s\n\n## И-1 · 2026-11-10 · из РП-1 · %s\nВыжимка: x\n' "$1" "$2" > "$REPO/inbox/WP-$1/INBOX.md"
}
ZERO=0000000000000000000000000000000000000000

g init -q -b main
new_wp 7 "новое"
new_wp 8 "учтено"
new_wp 9 "учтено"
mkdir -p "$REPO/archive/wp-contexts/WP-5"
printf '## И-1 · 2026-11-01 · из РП-1 · новое\n' > "$REPO/archive/wp-contexts/WP-5/INBOX.md"
g add -A && g commit -qm base
BASE=$(g rev-parse HEAD)

# pre-commit
check "pre-commit: без закрытия РП → проходит" "0" "$(gate_rc pre-commit)"
check "pre-commit: без закрытия РП не требует wp-inbox.sh" "0" "$(gate_no_tool_rc pre-commit)"
mkdir -p "$REPO/archive/wp-contexts"
g mv inbox/WP-7 archive/wp-contexts/WP-7
check "pre-commit: ручной git mv РП с «новое» → отказ" "1" "$(gate_rc pre-commit)"
check "pre-commit: закрытие без wp-inbox.sh → отказ" "1" "$(gate_no_tool_rc pre-commit)"
g reset -q --hard
g mv inbox/WP-8 archive/wp-contexts/WP-8
check "pre-commit: ручной git mv РП без «новое» → проходит" "0" "$(gate_rc pre-commit)"
g reset -q --hard
g rm -rq inbox/WP-7
check "pre-commit: удаление ящика с «новое» без архива → отказ" "1" "$(gate_rc pre-commit)"
g reset -q --hard

# pre-push: closing WP-8 (clean) and, on another branch, WP-7 (new entries)
g checkout -qb clean
g mv inbox/WP-8 archive/wp-contexts/WP-8 && g commit -qm close8
CLEAN=$(g rev-parse HEAD)
g checkout -q main
g checkout -qb dirty
g mv inbox/WP-7 archive/wp-contexts/WP-7 && g commit -qm close7
DIRTY=$(g rev-parse HEAD)
check "pre-push: закрытие РП без «новое» → проходит (старый архив WP-5 не мешает)" "0" \
  "$(push_rc "refs/heads/clean $CLEAN refs/heads/main $BASE")"
check "pre-push: закрытие РП с «новое» → отказ" "1" "$(push_rc "refs/heads/dirty $DIRTY refs/heads/main $BASE")"
check "pre-push: две ссылки, одна с «новое» → отказ" "1" \
  "$(push_rc "refs/heads/clean $CLEAN refs/heads/main $BASE" "refs/heads/dirty $DIRTY refs/heads/x $BASE")"
check "pre-push: удаление ссылки пропускается" "0" "$(push_rc "(delete) $ZERO refs/heads/old $BASE")"
check "pre-push: новая ветка без origin/main → отказ (нет базы)" "1" "$(push_rc "refs/heads/clean $CLEAN refs/heads/new $ZERO")"
g update-ref refs/remotes/origin/main "$BASE"
check "pre-push: новая ветка, база через origin/main → проходит" "0" "$(push_rc "refs/heads/clean $CLEAN refs/heads/new $ZERO")"
check "pre-push: новая ветка с закрытием РП с «новое» → отказ" "1" "$(push_rc "refs/heads/dirty $DIRTY refs/heads/new $ZERO")"

# Entry added after the range base, then the mailbox deleted without an archive copy:
# the gate reads the last version before the deletion, not the base.
g checkout -q main
g checkout -qb late
printf '\n## И-2 · 2026-11-20 · из РП-2 · новое\nВыжимка: y\n' >> "$REPO/inbox/WP-9/INBOX.md"
g commit -qam "entry for 9"
g rm -rq inbox/WP-9 && g commit -qm "drop 9"
LATE=$(g rev-parse HEAD)
check "pre-push: запись добавлена после базы, ящик удалён → отказ" "1" "$(push_rc "refs/heads/late $LATE refs/heads/main $BASE")"

# A rebase carried a new entry into the archive copy inside the closing commit.
g checkout -q main
g checkout -qb carried
g mv inbox/WP-8 archive/wp-contexts/WP-8
printf '\n## И-2 · 2026-11-20 · из РП-3 · новое\nВыжимка: z\n' >> "$REPO/archive/wp-contexts/WP-8/INBOX.md"
g add archive/wp-contexts/WP-8/INBOX.md && g commit -qm "close 8 after rebase"
CARRIED=$(g rev-parse HEAD)
check "pre-push: запись перенесена в архивную копию в коммите закрытия → отказ" "1" \
  "$(push_rc "refs/heads/carried $CARRIED refs/heads/main $BASE")"

# Lease and lock pushes: a root commit (no shared history) to a new refs/notes/* ref.
LEASE=$(printf 'lease\n' | g commit-tree "$(g mktree </dev/null)")
check "pre-push: корневой коммит в refs/notes/* (замок публикации) → проходит" "0" \
  "$(push_rc "refs/notes/lease $LEASE refs/notes/lease $ZERO")"

# A merge carries a new entry into the archive copy: the closing commit itself is
# clean, git log shows no diff for the merge, the net base→tip check catches it.
g checkout -q main
g checkout -qb mbase
g commit -q --allow-empty -m "fork point"
MBASE=$(g rev-parse HEAD)
g checkout -qb mfeature
g mv inbox/WP-8 archive/wp-contexts/WP-8 && g commit -qm "close 8"
g checkout -q mbase
printf '\n## И-2 · 2026-11-20 · из РП-4 · новое\nВыжимка: m\n' >> "$REPO/inbox/WP-8/INBOX.md"
g commit -qam "entry for 8 on main"
g checkout -q mfeature
g merge -q --no-edit mbase >/dev/null 2>&1
MERGED=$(g rev-parse HEAD)
check "слияние: новая запись дошла в архивную копию" "1" \
  "$(g show "$MERGED:archive/wp-contexts/WP-8/INBOX.md" | grep -c '· новое$')"
check "pre-push: слияние переносит запись «новое» в архив → отказ" "1" \
  "$(push_rc "refs/heads/mfeature $MERGED refs/heads/x $MBASE")"

# A status edited by hand reaches the hook as a refusal, not a pass.
g checkout -q main
g checkout -qb handedit
printf '## И-1 · 2026-11-10 · из РП-1 · разобрано 13.11\n' > "$REPO/inbox/WP-9/INBOX.md"
g commit -qam "hand edit"
g mv inbox/WP-9 archive/wp-contexts/WP-9
check "pre-commit: заголовок правлен руками → отказ" "1" "$(gate_rc pre-commit)"
g reset -q --hard

# A stale archive copy from an earlier closing must not stand in for the mailbox
# being deleted now (a reopen that copied the folder back).
g checkout -q main
g checkout -qb stale
cp -R "$REPO/inbox/WP-8" "$REPO/archive/wp-contexts/WP-8"
g add archive/wp-contexts/WP-8 && g commit -qm "old archive copy"
printf '\n## И-2 · 2026-11-20 · из РП-5 · новое\nВыжимка: s\n' >> "$REPO/inbox/WP-8/INBOX.md"
g commit -qam "entry for reopened 8"
g rm -rq inbox/WP-8
check "pre-commit: устаревшая архивная копия не подменяет удаляемый ящик → отказ" "1" "$(gate_rc pre-commit)"
g reset -q --hard

# The closing commit drops a «новое» entry from the archive copy by hand.
g checkout -q main
g checkout -qb dropped
g mv inbox/WP-7 archive/wp-contexts/WP-7
printf '# Входящие РП-7\n' > "$REPO/archive/wp-contexts/WP-7/INBOX.md"
g add archive/wp-contexts/WP-7/INBOX.md
check "pre-commit: запись «новое» вычеркнута из архивной копии руками → отказ" "1" "$(gate_rc pre-commit)"
g commit -qm "close 7, entry dropped"
check "pre-push: запись «новое» вычеркнута из архивной копии руками → отказ" "1" \
  "$(push_rc "refs/heads/dropped $(g rev-parse HEAD) refs/heads/main $BASE")"

# An entry «новое» at base, marked «учтено» inside the range, then the mailbox
# deleted without an archive copy: processed, so the push passes.
g checkout -q main
g checkout -qb marked
IWE_SCRIPTS="$TOOLS" bash "$TOOLS/wp-inbox.sh" mark --wp 7 --id 1 --by "тест" --repo "$REPO" >/dev/null
g commit -qam "mark 7"
g rm -rq inbox/WP-7 && g commit -qm "drop 7"
check "pre-push: запись отмечена «учтено» в диапазоне, ящик удалён → проходит" "0" \
  "$(push_rc "refs/heads/marked $(g rev-parse HEAD) refs/heads/main $BASE")"

# A WP already closed at base; a stale branch added an entry to its open mailbox
# before that. Merge and rebase carry the entry into the archive copy silently.
g checkout -q main
g checkout -qb stale9
printf '\n## И-2 · 2026-11-21 · из РП-6 · новое\nВыжимка: late\n' >> "$REPO/inbox/WP-9/INBOX.md"
g commit -qam "late entry for 9"
STALE9=$(g rev-parse HEAD)
g checkout -q main
g checkout -qb closed9
g mv inbox/WP-9 archive/wp-contexts/WP-9 && g commit -qm "close 9"
CLOSED9=$(g rev-parse HEAD)
g checkout -qb merged9 "$STALE9"
g merge -q --no-edit closed9 >/dev/null 2>&1
check "слияние: поздняя запись ушла в архивную копию закрытого РП" "1" \
  "$(g show HEAD:archive/wp-contexts/WP-9/INBOX.md | grep -c '· новое$')"
check "pre-push: слияние приносит «новое» в архив закрытого РП → отказ" "1" \
  "$(push_rc "refs/heads/merged9 $(g rev-parse HEAD) refs/heads/main $CLOSED9")"
g checkout -qb rebased9 "$STALE9"
g rebase -q closed9 >/dev/null 2>&1
check "rebase: поздняя запись ушла в архивную копию закрытого РП" "1" \
  "$(g show HEAD:archive/wp-contexts/WP-9/INBOX.md | grep -c '· новое$')"
check "pre-push: rebase приносит «новое» в архив закрытого РП → отказ" "1" \
  "$(push_rc "refs/heads/rebased9 $(g rev-parse HEAD) refs/heads/main $CLOSED9")"
g checkout -q closed9
printf '\n## И-2 · 2026-11-21 · из РП-6 · новое\nВыжимка: by hand\n' >> "$REPO/archive/wp-contexts/WP-9/INBOX.md"
g add archive/wp-contexts/WP-9/INBOX.md
check "pre-commit: запись «новое» дописана в архивную копию → отказ" "1" "$(gate_rc pre-commit)"
g reset -q --hard
check "pre-push: закрытый в базе РП без новых записей → проходит" "0" \
  "$(push_rc "refs/heads/closed9 $CLOSED9 refs/heads/main $BASE")"

exit "$fail"
