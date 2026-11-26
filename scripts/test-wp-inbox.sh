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

# 7. --rev reads the committed mailbox, not the lagging working tree.
mkdir -p "$REPO/inbox/WP-8"
printf -- '---\nwp: 8\n---\n' > "$REPO/inbox/WP-8/WP-8.md"
git -C "$REPO" init -q
git -C "$REPO" -c user.email=t@example.invalid -c user.name=t add -A
git -C "$REPO" -c user.email=t@example.invalid -c user.name=t commit -qm base
inbox add --to WP-8 --from "РП-2000" --pointer "p" --summary "в рабочей копии, не закоммичено" >/dev/null
check "--rev HEAD: незакоммиченная запись не видна" "0" "$(inbox count --wp 8 --rev HEAD)"
check "без --rev: рабочая копия видит запись" "1" "$(inbox count --wp 8)"
check "--rev HEAD: отпечаток пуст" "" "$(inbox digest --wp 8 --rev HEAD)"
git -C "$REPO" -c user.email=t@example.invalid -c user.name=t add -A
git -C "$REPO" -c user.email=t@example.invalid -c user.name=t commit -qm entry
check "--rev HEAD после коммита: отпечаток как у рабочей копии" "$(inbox digest --wp 8)" "$(inbox digest --wp 8 --rev HEAD)"
rc=0; inbox add --to WP-8 --from "x" --pointer "p" --summary "s" --rev HEAD >/dev/null 2>&1 || rc=$?
check "add с --rev отклонён: код 2" "2" "$rc"
rc=0; inbox count --wp 8 --rev no-such-ref >/dev/null 2>&1 || rc=$?
check "несуществующая ревизия: код 1" "1" "$rc"

# 8. pending: only WPs with «новое» entries, oldest first.
check "pending: только РП с новыми записями" "WP-8	1" "$(inbox pending | cut -f1,2)"
inbox add --to WP-7 --from "РП-3000" --pointer "p" --summary "ещё" >/dev/null
check "pending: два РП" "2" "$(inbox pending | wc -l | tr -d ' ')"
check "pending --rev HEAD: незакоммиченный WP-7 не виден" "WP-8" "$(inbox pending --rev HEAD | cut -f1)"

# 9. check-text (WP-503 Phase 110): 0 nothing new, 1 new entries, 2 unparseable header.
ct() { local rc=0; bash "$SCRIPT" check-text >/dev/null 2>&1 || rc=$?; echo "$rc"; }
check "check-text: есть «новое» → код 1" "1" "$(ct < "$REPO/inbox/WP-7/INBOX.md")"
check "check-text: заголовки «новое» в stdout" "## И-4" "$(bash "$SCRIPT" check-text < "$REPO/inbox/WP-7/INBOX.md" 2>/dev/null | cut -d' ' -f1,2 || true)"
check "check-text: всё учтено → код 0" "0" "$(printf '## И-1 · 2026-11-03 · из РП-5 · учтено\nУчтено: x\n' | ct)"
check "check-text: пустой ящик → код 0" "0" "$(printf '' | ct)"
check "check-text: заголовок поправлен руками → код 2" "2" "$(printf '## И-1 · 2026-11-03 · из РП-5 · разобрано 13.11\n' | ct)"
check "check-text: битый байт в тексте не скрывает следующее «новое» (UTF-8 локаль)" "1" \
  "$(printf '## И-1 · 2026-11-03 · из РП-5 · учтено\nВыжимка: \xd0\n## И-2 · 2026-11-04 · из РП-6 · новое\n' | LC_ALL=en_US.UTF-8 ct)"
mkdir -p "$REPO/inbox/WP-6"
printf '## И-1 · 2026-11-03 · из РП-5 · учтено\nВыжимка: \xd0\n## И-2 · 2026-11-04 · из РП-6 · новое\n' > "$REPO/inbox/WP-6/INBOX.md"
check "list --all: битый байт не обрывает список (UTF-8 локаль)" "2" \
  "$(LC_ALL=en_US.UTF-8 inbox list --wp 6 --all | grep -c -E '^## И-')"
rm -rf "$REPO/inbox/WP-6"
check "check-text --wp: текст отказа называет РП и два исхода" "2" \
  "$(bash "$SCRIPT" check-text --wp WP-7 < "$REPO/inbox/WP-7/INBOX.md" 2>&1 >/dev/null | grep -cE 'РП-7 нельзя переносить в архив|согласие пилота на «учтено»')"

# 10. archive-done-wp.sh refuses a WP with «новое» entries before touching anything,
# even with IWE_ARCHIVE_ALLOW_PENDING=1, and archives it once every entry is processed.
# A private copy of both scripts: no session-guard.sh next to them, no host state touched.
TOOLS=$(mktemp -d "${TMPDIR:-/tmp}/wp-inbox-tools.XXXXXX")
trap 'rm -rf "$REPO" "$TOOLS"' EXIT
cp "$SCRIPT" "$(dirname "$SCRIPT")/archive-done-wp.sh" "$TOOLS/"
printf -- '---\nwp: 7\nstatus: in_progress\n---\n' > "$REPO/inbox/WP-7/WP-7.md"
mkdir -p "$REPO/archive/wp-contexts"
git -C "$REPO" -c user.email=t@example.invalid -c user.name=t add -A
git -C "$REPO" -c user.email=t@example.invalid -c user.name=t commit -qm wp7
archive() { local rc=0; IWE_GOVERNANCE_REPO_PATH="$REPO" "$@" bash "$TOOLS/archive-done-wp.sh" 7 "$REPO" >/dev/null 2>&1 || rc=$?; echo "$rc"; }
check "архивация при «новое»: код 1" "1" "$(archive env)"
check "архивация при «новое»: папка осталась в inbox" "yes" "$([[ -d "$REPO/inbox/WP-7" ]] && echo yes || echo no)"
check "архивация при «новое»: карточка не тронута" "status: in_progress" "$(grep '^status:' "$REPO/inbox/WP-7/WP-7.md")"
check "IWE_ARCHIVE_ALLOW_PENDING=1 не обходит ящик: код 1" "1" "$(archive env IWE_ARCHIVE_ALLOW_PENDING=1)"
inbox mark --wp 7 --id 4 --by "перенесено в «Осталось» (тест)" >/dev/null
check "после разбора: архивация прошла" "0" "$(archive env)"
check "после разбора: папка в архиве" "yes" "$([[ -f "$REPO/archive/wp-contexts/WP-7/INBOX.md" ]] && echo yes || echo no)"

# 11. Delivery id (WP-418 F10): the same id is written once; the entry carries it.
mkdir -p "$REPO/inbox/WP-9"; printf -- '---\nwp: 9\n---\n' > "$REPO/inbox/WP-9/WP-9.md"
out1=$(inbox add --to WP-9 --from "РП-418" --pointer "p" --summary "s" --delivery-id "d-abc")
out2=$(inbox add --to WP-9 --from "РП-418" --pointer "p" --summary "s" --delivery-id "d-abc")
check "доставка: первая запись И-1" "yes" "$([[ "$out1" == "И-1 записана в"* ]] && echo yes || echo no)"
check "доставка: повтор не пишет вторую запись" "yes" "$([[ "$out2" == "И-1 уже записана (доставка d-abc) в"* ]] && echo yes || echo no)"
check "доставка: в ящике одна запись" "1" "$(grep -c -E '^## И-' "$REPO/inbox/WP-9/INBOX.md")"
check "доставка: запись несёт идентификатор" "1" "$(grep -c -x 'Доставка: d-abc' "$REPO/inbox/WP-9/INBOX.md")"
inbox add --to WP-9 --from "РП-418" --pointer "p" --summary "s" --delivery-id "d-xyz" >/dev/null
check "доставка: другой идентификатор — новая запись" "2" "$(grep -c -E '^## И-' "$REPO/inbox/WP-9/INBOX.md")"
rc=0; inbox add --to WP-9 --from "x" --pointer "p" --summary "s" --delivery-id 'bad id;rm' >/dev/null 2>&1 || rc=$?
check "доставка: недопустимый идентификатор — код 2" "2" "$rc"
check "доставка: ящик с идентификаторами проходит check-text" "1" "$(rc=0; bash "$SCRIPT" check-text < "$REPO/inbox/WP-9/INBOX.md" >/dev/null 2>&1 || rc=$?; echo $rc)"

exit "$fail"
