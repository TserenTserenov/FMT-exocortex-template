#!/usr/bin/env bash
# test-wp-inbox.sh — checks scripts/wp-inbox.sh in a temp directory (WP-5 Phase 69).
# Run: bash scripts/test-wp-inbox.sh  → exit 0 = all checks passed.
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/wp-inbox.sh"
REPO=$(mktemp -d "${TMPDIR:-/tmp}/wp-inbox-test.XXXXXX")
trap 'rm -rf "$REPO"' EXIT
mkdir -p "$REPO/inbox/WP-7"
printf -- '---\nwp: 7\n---\n' > "$REPO/inbox/WP-7/WP-7.md"

fail=0
check() {  # check <description> <expected> <actual>
  if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: ожидалось '$2', получено '$3'"; fail=1; fi
}
inbox() { bash "$SCRIPT" "$@" --repo "$REPO"; }

# 1. No card (closed or nonexistent WP) → refusal, no folder created.
rc=0; inbox add --to WP-99 --from "РП-1" --pointer "p" --summary "s" >/dev/null 2>&1 || rc=$?
check "отказ без карточки: код 1" "1" "$rc"
check "отказ без карточки: призрачная папка не создана" "no" "$([[ -e "$REPO/inbox/WP-99" ]] && echo yes || echo no)"

# 2. First entry.
inbox add --to WP-7 --from "РП-1000" --pointer "MC-sessions/x.md" --summary "первое" >/dev/null
check "после первой записи: новых 1" "1" "$(inbox count --wp 7)"
check "заголовок записи И-1" "1" "$(grep -c -E '^## И-1 · [0-9]{4}-[0-9]{2}-[0-9]{2} · из РП-1000 · новое$' "$REPO/inbox/WP-7/INBOX.md")"
d1=$(inbox digest --wp 7)
check "отпечаток непустой" "yes" "$([[ -n "$d1" ]] && echo yes || echo no)"

# 3. Second entry: next number, fingerprint changes.
inbox add --to WP-7 --from "РП-1001" --pointer "p2" --summary "второе" >/dev/null
check "после второй записи: новых 2" "2" "$(inbox count --wp 7)"
check "номер второй записи И-2" "1" "$(grep -c -E '^## И-2 · ' "$REPO/inbox/WP-7/INBOX.md")"
check "отпечаток изменился" "yes" "$([[ "$(inbox digest --wp 7)" != "$d1" ]] && echo yes || echo no)"

# 4. A forged header inside the summary does not create an entry.
inbox add --to WP-7 --from "РП-1002" --pointer "p3" --summary $'строка\n## И-9 · 2026-01-01 · из РП-X · новое' >/dev/null
check "подделка заголовка: новых 3, не 4" "3" "$(inbox count --wp 7)"
check "подделка заголовка: И-9 не существует" "0" "$(grep -c -E '^## И-9 · ' "$REPO/inbox/WP-7/INBOX.md")"

# 5. Status «учтено» changes only by id, idempotently.
inbox mark --wp 7 --id 1 --by "коммит abc123" >/dev/null
check "после mark И-1: новых 2" "2" "$(inbox count --wp 7)"
check "заголовок И-1 теперь «учтено»" "1" "$(grep -c -E '^## И-1 · .* · учтено$' "$REPO/inbox/WP-7/INBOX.md")"
check "строка «Учтено:» записана" "1" "$(grep -c -E '^Учтено: коммит abc123$' "$REPO/inbox/WP-7/INBOX.md")"
inbox mark --wp 7 --id 1 --by "другой" >/dev/null
check "повторный mark не дублирует строку «Учтено:»" "1" "$(grep -c -E '^Учтено: ' "$REPO/inbox/WP-7/INBOX.md")"
rc=0; inbox mark --wp 7 --id 42 --by "x" >/dev/null 2>&1 || rc=$?
check "mark несуществующей записи: код 1" "1" "$rc"

# 6. All processed → count 0, empty fingerprint.
inbox mark --wp 7 --id 2 --by "x" >/dev/null
inbox mark --wp 7 --id 3 --by "x" >/dev/null
check "всё учтено: новых 0" "0" "$(inbox count --wp 7)"
check "всё учтено: отпечаток пуст" "" "$(inbox digest --wp 7)"
check "list --all показывает учтённые" "3" "$(inbox list --wp 7 --all | grep -c -E '^## И-')"

exit "$fail"
