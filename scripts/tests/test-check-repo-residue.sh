#!/bin/bash
# Regression test for scripts/check-repo-residue.sh. Every case asserts an observable outcome — a
# finding appears or disappears — never "the script ran without error".
#
# Cases pin real defects found in review: quoted paths dropped by awk field splitting, duplicate
# clones missed because ssh and https spell the same repo differently, a corrupted repository
# reporting "all clean", a non-ISO retention date silently hiding an expired archive, one
# unescaped quote breaking the whole json document, and an accepted finding that never came
# back for review. Fixtures are synthetic repositories in a temporary directory; the real
# workspace is never scanned.
#
# Usage: bash scripts/tests/test-check-repo-residue.sh   (exit 0 = all green, 1 = a case failed)
set -uo pipefail
case "${1:-}" in -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac

TEMPLATE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${CHECK_REPO_RESIDUE:-$TEMPLATE_ROOT/scripts/check-repo-residue.sh}"
SEED_ACCEPTED="$TEMPLATE_ROOT/seed/strategy/machine/repo-residue-accepted.tsv"
[ -f "$SCRIPT" ] || { echo "не найден проверяемый скрипт: $SCRIPT"; exit 1; }
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
BACKUPS="$ROOT/backups"
ACCEPTED="$ROOT/accepted.tsv"
mkdir -p "$BACKUPS" "$ROOT/repos"
: > "$ACCEPTED"
PASS=0
FAIL=0

# Fixture commits need an identity; CI runners have none configured.
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

run() {  # run <args...> — prints script output; WORKSPACE_DIR pins the env bootstrap to the sandbox
  WORKSPACE_DIR="$ROOT/repos" IWE_ROOT="$ROOT/repos" REPO_RESIDUE_BACKUPS="$BACKUPS" \
  REPO_RESIDUE_ACCEPTED="$ACCEPTED" REPO_RESIDUE_TODAY="${TODAY_OVERRIDE:-2026-08-02}" \
  bash "$SCRIPT" "$@" 2>/dev/null
}

pass() { echo "  ✅ $1"; PASS=$((PASS+1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }

check() {  # check <name> <expect-found|expect-absent> <pattern> <output>
  local name="$1" mode="$2" pattern="$3" out="$4"
  if printf '%s' "$out" | grep -q "$pattern"; then
    [ "$mode" = "expect-found" ] && pass "$name" || fail "$name — нашлось, а не должно"
  else
    [ "$mode" = "expect-absent" ] && pass "$name" || fail "$name — не нашлось"
  fi
}

mkrepo() {  # mkrepo <path> [origin-url]
  local p="$1" url="${2:-}"
  mkdir -p "$p" && git -C "$p" init -q
  [ -n "$url" ] && git -C "$p" remote add origin "$url"
  return 0
}

commit_in() {  # commit_in <repo> <message> — plumbing, so no commit hooks run
  local p="$1" msg="$2" tree parent commit
  echo "$msg" > "$p/content.txt"
  git -C "$p" add content.txt
  tree=$(git -C "$p" write-tree)
  # --verify: plain `rev-parse HEAD` prints the literal "HEAD" in an empty repo instead of nothing
  parent=$(git -C "$p" rev-parse --verify HEAD 2>/dev/null || true)
  if [ -n "$parent" ]; then
    commit=$(git -C "$p" commit-tree "$tree" -p "$parent" -m "$msg")
  else
    commit=$(git -C "$p" commit-tree "$tree" -m "$msg")
  fi
  git -C "$p" update-ref HEAD "$commit"
}

echo "1. Файлы данных с пробелом и кавычкой в имени"
mkrepo "$ROOT/repos/spaces" "https://example.com/spaces.git"
touch "$ROOT/repos/spaces/my export.dump" "$ROOT/repos/spaces/plain.dump"
out=$(run)
check "файл с пробелом виден" expect-found "my export.dump" "$out"
check "обычный файл виден" expect-found "plain.dump" "$out"

echo "2. Дубли при разной форме адреса"
mkrepo "$ROOT/repos/proj-https" "https://github.com/acme/proj.git"
mkrepo "$ROOT/repos/proj-ssh" "git@github.com:acme/proj.git"
mkrepo "$ROOT/repos/other-a" "https://github.com/acme/other.git"
mkrepo "$ROOT/repos/other-b" "https://github.com/acme/other"
out=$(run)
check "ssh и https — один репозиторий" expect-found "github.com/acme/proj:" "$out"
check "с суффиксом и без — один репозиторий" expect-found "github.com/acme/other:" "$out"

echo "3. Битый репозиторий"
mkrepo "$ROOT/repos/broken" "https://example.com/broken.git"
commit_in "$ROOT/repos/broken" "работа, которую потеряют"
rm -f "$ROOT/repos/broken/.git/HEAD"
out=$(run)
check "битый репозиторий не молчит" expect-found "битый-репозиторий" "$out"

echo "4. Срок хранения архива"
mkdir -p "$BACKUPS/bad-format" "$BACKUPS/expired-iso" "$BACKUPS/future"
printf 'expires: 31-01-2020\ncontains_personal_data: true\n' > "$BACKUPS/bad-format/RETENTION.yaml"
printf 'expires: 2020-01-01\ncontains_personal_data: true\n' > "$BACKUPS/expired-iso/RETENTION.yaml"
printf 'expires: 2030-01-01\n' > "$BACKUPS/future/RETENTION.yaml"
out=$(run)
check "нечитаемая дата не прячется" expect-found "нечитаемый-срок" "$out"
check "просроченный по ISO виден" expect-found "просроченный-архив" "$out"
check "будущий срок молчит" expect-absent "future:" "$out"
check "заголовок архивов один" expect-found "(архивы)" "$out"
hdr=$(printf '%s' "$out" | grep -c "📁 (архивы)")
[ "$hdr" -eq 1 ] && pass "заголовок напечатан ровно один раз" || fail "заголовков архивов: $hdr (ожидался 1)"

echo "5. Машинный вывод с кавычкой в имени ветки"
mkrepo "$ROOT/repos/quoted" "https://example.com/quoted.git"
commit_in "$ROOT/repos/quoted" "начало"
git -C "$ROOT/repos/quoted" branch 'feat/say"hi"' 2>/dev/null
out=$(run --json)
if printf '%s' "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
  pass "машинный вывод остаётся валидным"
else
  fail "машинный вывод сломан кавычкой"
fi

echo "6. Репозиторий без сервера — одна находка вместо шума"
mkrepo "$ROOT/repos/noremote"
commit_in "$ROOT/repos/noremote" "локальная работа"
git -C "$ROOT/repos/noremote" branch extra1 2>/dev/null
git -C "$ROOT/repos/noremote" branch extra2 2>/dev/null
out=$(run)
check "нет серверной копии — сказано прямо" expect-found "нет-серверной-копии" "$out"
n=$(printf '%s' "$out" | grep -c "ветка-без-публикации noremote" || true)
[ "$n" -eq 0 ] && pass "ветки этого репозитория не дублируют находку" || fail "веток продублировано: $n"

echo "7. Файл принятых решений с лишним пробелом"
printf 'spaces \tданные-вне-git\tplain.dump \tпроверка пробела\t2030-01-01\n' > "$ACCEPTED"
out=$(run)
check "лишний пробел не ломает подавление" expect-absent "plain.dump" "$out"
check "принят один файл — соседний виден" expect-found "my export.dump" "$out"

echo "8. Срок повторного решения"
printf 'spaces\tданные-вне-git\tplain.dump\tразобрать позже\t2020-01-01\n' > "$ACCEPTED"
out=$(run)
check "истёкший срок поднимает решение снова" expect-found "просрочено.*spaces/данные-вне-git/plain.dump" "$out"
printf 'spaces\tданные-вне-git\tplain.dump\tбез даты\t\n' > "$ACCEPTED"
out=$(run)
check "решение без даты не бессрочное" expect-found "нет-срока" "$out"

echo "8a. Принятая находка скрывает только себя"
mkrepo "$ROOT/repos/branches" "https://example.com/branches.git"
commit_in "$ROOT/repos/branches" "начало"
git -C "$ROOT/repos/branches" branch foo 2>/dev/null
git -C "$ROOT/repos/branches" branch bar 2>/dev/null
printf 'branches\tветка-без-публикации\tfoo\tэксперимент, решено оставить\t2030-01-01\n' > "$ACCEPTED"
out=$(run)
check "принятая ветка скрыта" expect-absent "foo:" "$out"
check "новая ветка того же класса видна" expect-found "bar:" "$out"
printf 'branches\tветка-без-публикации\tfoo\tэксперимент\t2020-01-01\n' > "$ACCEPTED"
out=$(run)
check "истёкшее принятие показывает ветку снова" expect-found "просрочено.*branches/ветка-без-публикации/foo" "$out"
printf 'branches\tветка-без-публикации\t*\tархивная копия, все ветки осознанно\t2030-01-01\n' > "$ACCEPTED"
out=$(run)
check "звёздочка скрывает весь класс" expect-absent "bar:" "$out"
printf 'branches\tветка-без-публикации\tстарое решение\t2030-01-01\n' > "$ACCEPTED"
out=$(run)
check "строка старого формата ничего не скрывает" expect-found "foo:" "$out"
check "строка старого формата просит миграции" expect-found "старый-формат" "$out"

echo "8b. Отложенные правки — по одной на запись"
mkrepo "$ROOT/repos/stashed" "https://example.com/stashed.git"
commit_in "$ROOT/repos/stashed" "начало"
echo "правка 1" > "$ROOT/repos/stashed/content.txt"
git -C "$ROOT/repos/stashed" stash -q
first=$(git -C "$ROOT/repos/stashed" rev-parse "stash@{0}" | cut -c1-12)
printf 'stashed\tstash\t%s\tпроверено\t2030-01-01\n' "$first" > "$ACCEPTED"
out=$(run)
check "принятая отложенная правка скрыта" expect-absent "$first" "$out"
echo "правка 2" > "$ROOT/repos/stashed/content.txt"
git -C "$ROOT/repos/stashed" stash -q
out=$(run)
check "новая отложенная правка видна" expect-found "stash@{0}" "$out"
check "принятая не всплыла из-за сдвига номера" expect-absent "$first" "$out"

echo "8c. Данные внутри неотслеживаемых и игнорируемых папок"
mkrepo "$ROOT/repos/datadirs" "https://example.com/datadirs.git"
printf 'data/\n*.sql\n' > "$ROOT/repos/datadirs/.gitignore"
git -C "$ROOT/repos/datadirs" add .gitignore
commit_in "$ROOT/repos/datadirs" "начало"
mkdir -p "$ROOT/repos/datadirs/exports" "$ROOT/repos/datadirs/data" "$ROOT/repos/datadirs/data2" \
  "$ROOT/repos/datadirs/node_modules/pkg" "$ROOT/repos/datadirs/_backups/2026"
touch "$ROOT/repos/datadirs/exports/db.dump" "$ROOT/repos/datadirs/data/a.sql" \
  "$ROOT/repos/datadirs/data2/b.sql" "$ROOT/repos/datadirs/node_modules/pkg/seed.sql" \
  "$ROOT/repos/datadirs/_backups/one" "$ROOT/repos/datadirs/_backups/2026/two"
: > "$ACCEPTED"
out=$(run)
check "файл в неотслеживаемой папке виден" expect-found "exports/db.dump" "$out"
check "файл в игнорируемой папке виден" expect-found "data/a.sql" "$out"
check "игнорируемый по маске файл виден" expect-found "data2/b.sql" "$out"
check "папка зависимостей не обходится в быстром режиме" expect-absent "node_modules/pkg/seed.sql" "$out"
n=$(printf '%s' "$out" | grep -c "_backups/" || true)
[ "$n" -eq 1 ] && pass "папка _backups — одна находка" || fail "находок _backups: $n (ожидалась 1)"
out=$(run --deep)
check "глубокий режим заходит в папку зависимостей" expect-found "node_modules/pkg/seed.sql" "$out"
check "глубокий режим видит то же, что быстрый" expect-found "data/a.sql" "$out"

echo "8d. Отслеживаемый файл с маской данных — не находка"
mkrepo "$ROOT/repos/tracked" "https://example.com/tracked.git"
echo "create table t();" > "$ROOT/repos/tracked/schema.sql"
git -C "$ROOT/repos/tracked" add schema.sql
commit_in "$ROOT/repos/tracked" "начало"
echo "alter table t;" >> "$ROOT/repos/tracked/schema.sql"
out=$(run)
check "изменённый отслеживаемый файл не считается данными вне git" expect-absent "schema.sql" "$out"

echo "8e. Машинные находки принимаются поштучно"
printf '(машина)\tдубль-рабочей-копии\tgithub.com/acme/proj: proj-https, proj-ssh\tобе нужны\t2030-01-01\n(архивы)\tпросроченный-архив\texpired-iso\tудалю в декабре\t2030-01-01\n' > "$ACCEPTED"
out=$(run)
check "принятый дубль скрыт" expect-absent "github.com/acme/proj:" "$out"
check "другой дубль виден" expect-found "github.com/acme/other:" "$out"
check "принятый архив скрыт" expect-absent "expired-iso:" "$out"
check "другой архив виден" expect-found "bad-format:" "$out"
mkrepo "$ROOT/repos/proj-third" "https://github.com/acme/proj"
out=$(run)
check "третья копия возвращает дубль" expect-found "github.com/acme/proj: proj-https, proj-ssh, proj-third" "$out"
rm -rf "$ROOT/repos/proj-third"
out=$(run --json)
if printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert all("item" in i for i in d["items"]) and d["items"]' 2>/dev/null; then
  pass "в машинном выводе у каждой находки есть «что»"
else
  fail "в машинном выводе нет поля item"
fi

echo "9. Поставляемый файл принятых решений — только шапка"
cp "$SEED_ACCEPTED" "$ACCEPTED"
out=$(run)
check "шапка не даёт находок о решениях" expect-absent "ТРЕБУЕТ ПОВТОРНОГО РЕШЕНИЯ" "$out"
rows=$(grep -cv '^#' "$SEED_ACCEPTED" || true)
[ "$rows" -eq 0 ] && pass "в поставке нет ни одной принятой находки" || fail "в поставке строк с решениями: $rows"

echo "10. Программа ничего не меняет"
# Files under .git are excluded: git status may legitimately refresh its own index.
before=$(find "$ROOT/repos" "$BACKUPS" -type f -not -path "*/.git/*" -print0 | LC_ALL=C sort -z | xargs -0 cksum)
run --deep >/dev/null
after=$(find "$ROOT/repos" "$BACKUPS" -type f -not -path "*/.git/*" -print0 | LC_ALL=C sort -z | xargs -0 cksum)
[ "$before" = "$after" ] && pass "файлы рабочих копий и архивов не тронуты" || fail "прогон изменил файлы"
run >/dev/null; rc=$?
[ "$rc" -eq 2 ] && pass "при находках код выхода 2" || fail "код выхода $rc, ожидался 2"

echo
echo "Итог: успешно $PASS, провалено $FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
