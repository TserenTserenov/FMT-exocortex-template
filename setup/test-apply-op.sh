#!/bin/bash
# WP-529 F245 step 2: the frozen plan and the single executor in
# setup/lib/apply-op.sh, checked on a synthetic install in a sandbox. The
# executor is not wired into update.sh yet, so this test is its only consumer.
# Every refusal case also asserts that the tree did not change.
# Usage: test-apply-op.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/apply-op.sh
. "$SCRIPT_DIR/setup/lib/apply-op.sh"

# mktemp may return a path through a symlink (/var -> /private/var on macOS);
# the executor works on canonical paths only.
SANDBOX=$(cd -P "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$SANDBOX"' EXIT

PASS=0
FAIL=0
LAST_ERR=""

ok() {
    PASS=$((PASS + 1))
}

bad() {
    FAIL=$((FAIL + 1))
    echo "FAIL: $1" >&2
}

assert_eq() {
    if [ "$2" = "$3" ]; then ok; else bad "$1: ожидалось «$3», получено «$2»"; fi
}

assert_rc() {
    assert_eq "$1 (код возврата)" "$2" "$3"
}

assert_err_has() {
    case "$LAST_ERR" in
        *"$2"*) ok ;;
        *) bad "$1: в диагностике нет «$2»; вся диагностика: $LAST_ERR" ;;
    esac
}

# Runs a command in this shell (the executor keeps its state in variables, a
# subshell would lose it), keeping its stderr in LAST_ERR and its code in RC.
run() {
    local errfile="$SANDBOX/.stderr"
    "$@" 2>"$errfile" >/dev/null
    RC=$?
    LAST_ERR=$(cat "$errfile")
}

# Compact state of a tree: relative path, type, mode, hash or link text.
snapshot() {
    local root=$1 p
    (cd "$root" && find . -mindepth 1 | LC_ALL=C sort | while read -r p; do
        printf '%s %s\n' "$p" "$(apply_op_fingerprint "$root/$p")"
    done)
}

new_install() {
    INSTALL="$SANDBOX/install-$1"
    STAGING="$SANDBOX/staging-$1"
    PLAN="$SANDBOX/plan-$1.tsv"
    mkdir -p "$INSTALL/scripts" "$INSTALL/old" "$STAGING"
    printf 'old rule\n' > "$INSTALL/rule.md"
    chmod 644 "$INSTALL/rule.md"
    printf 'tool v1\n' > "$INSTALL/scripts/tool.sh"
    chmod 755 "$INSTALL/scripts/tool.sh"
    printf 'stale\n' > "$INSTALL/old/stale.md"
    printf 'new rule\n' > "$STAGING/rule.md"
    printf 'tool v2\n' > "$STAGING/tool.sh"
    printf 'added\n' > "$STAGING/added.md"
    APPLY_OP_ROOTS=("$INSTALL")
    apply_op_plan_new "$PLAN"
}

# --- 1. whole cycle: every operation type, modes, chained paths ---------------
new_install 1
apply_op_plan_add "$PLAN" replace "$INSTALL/rule.md" "$STAGING/rule.md" 644
apply_op_plan_add "$PLAN" replace "$INSTALL/scripts/tool.sh" "$STAGING/tool.sh" 755
apply_op_plan_add "$PLAN" mkdir "$INSTALL/docs" - 750
apply_op_plan_add "$PLAN" write "$INSTALL/docs/added.md" "$STAGING/added.md" 600
apply_op_plan_add "$PLAN" mkdir "$INSTALL/deprecated" - 755
apply_op_plan_add "$PLAN" move "$INSTALL/old/stale.md" "$INSTALL/deprecated/stale.md"
apply_op_plan_add "$PLAN" rmdir_if_empty "$INSTALL/old"
apply_op_plan_add "$PLAN" remove "$INSTALL/deprecated/stale.md"
run apply_op_run "$PLAN"
assert_rc "полный цикл" "$RC" 0
assert_eq "замена правила" "$(cat "$INSTALL/rule.md")" "new rule"
assert_eq "замена скрипта" "$(cat "$INSTALL/scripts/tool.sh")" "tool v2"
assert_eq "права скрипта" "$(apply_op__mode_of "$INSTALL/scripts/tool.sh")" 755
assert_eq "права нового файла" "$(apply_op__mode_of "$INSTALL/docs/added.md")" 600
assert_eq "права нового каталога" "$(apply_op__mode_of "$INSTALL/docs")" 750
assert_eq "старый каталог удалён" "$(apply_op_fingerprint "$INSTALL/old")" absent
assert_eq "перенесённый файл потом удалён" "$(apply_op_fingerprint "$INSTALL/deprecated/stale.md")" absent
assert_eq "временных файлов не осталось" "$(find "$INSTALL" -name '.apply-op.*' | wc -l | tr -d ' ')" 0

# --- 2. order and replay ------------------------------------------------------
new_install 2
apply_op_plan_add "$PLAN" replace "$INSTALL/rule.md" "$STAGING/rule.md" 644
apply_op_plan_add "$PLAN" write "$INSTALL/added.md" "$STAGING/added.md" 644
BEFORE=$(snapshot "$INSTALL")
apply_op_begin "$PLAN"
run apply_op 2
assert_rc "вторая операция раньше первой" "$RC" 1
assert_err_has "порядок" "порядок нарушен"
assert_eq "дерево не менялось при нарушении порядка" "$(snapshot "$INSTALL")" "$BEFORE"
run apply_op 1
assert_rc "первая операция" "$RC" 0
run apply_op 1
assert_rc "повтор уже выполненной операции" "$RC" 1
assert_err_has "повтор" "уже выполнена"
run apply_op 99
assert_rc "номер вне плана" "$RC" 1
run apply_op x1
assert_rc "номер не число" "$RC" 1

# --- 3. the tree changed after the plan was built -----------------------------
new_install 3
apply_op_plan_add "$PLAN" replace "$INSTALL/rule.md" "$STAGING/rule.md" 644
apply_op_plan_add "$PLAN" write "$INSTALL/added.md" "$STAGING/added.md" 644
printf 'user edit\n' > "$INSTALL/rule.md"
BEFORE=$(snapshot "$INSTALL")
run apply_op_begin "$PLAN"
assert_rc "правка пользователя после плана" "$RC" 1
assert_err_has "правка пользователя" "изменился после построения плана"
assert_eq "дерево не менялось (прежняя правка пользователя цела)" "$(snapshot "$INSTALL")" "$BEFORE"

# --- 3b. the tree changed between accepting the plan and the operation --------
new_install 31
apply_op_plan_add "$PLAN" replace "$INSTALL/rule.md" "$STAGING/rule.md" 644
apply_op_begin "$PLAN"
printf 'edited meanwhile\n' > "$INSTALL/rule.md"
run apply_op 1
assert_rc "правка между приёмкой плана и операцией" "$RC" 1
assert_err_has "предусловие перед операцией" "ожидалось"
assert_eq "правка пользователя цела" "$(cat "$INSTALL/rule.md")" "edited meanwhile"
new_install 32
apply_op_plan_add "$PLAN" move "$INSTALL/old/stale.md" "$INSTALL/scripts/stale.md"
apply_op_begin "$PLAN"
printf 'appeared\n' > "$INSTALL/scripts/stale.md"
run apply_op 1
assert_rc "назначение переноса занято между приёмкой и операцией" "$RC" 1
assert_err_has "назначение занято" "назначение переноса занято"
assert_eq "источник переноса на месте" "$(cat "$INSTALL/old/stale.md")" stale

# --- 4. a mode-only change is not "the same file" for remove ------------------
new_install 4
apply_op_plan_add "$PLAN" remove "$INSTALL/scripts/tool.sh"
chmod 700 "$INSTALL/scripts/tool.sh"
run apply_op_begin "$PLAN"
assert_rc "удаление при изменённых правах" "$RC" 1
assert_err_has "права" "изменился после построения плана"
assert_eq "файл на месте" "$(cat "$INSTALL/scripts/tool.sh")" "tool v1"

# --- 5. staging swapped after the freeze --------------------------------------
new_install 5
apply_op_plan_add "$PLAN" replace "$INSTALL/rule.md" "$STAGING/rule.md" 644
apply_op_begin "$PLAN"
printf 'swapped\n' > "$STAGING/rule.md"
BEFORE=$(snapshot "$INSTALL")
run apply_op 1
assert_rc "подмена источника после заморозки" "$RC" 1
assert_err_has "подмена источника" "подмена после заморозки"
assert_eq "цель не тронута" "$(snapshot "$INSTALL")" "$BEFORE"
new_install 5b
apply_op_plan_add "$PLAN" replace "$INSTALL/rule.md" "$STAGING/rule.md" 644
printf 'swapped before begin\n' > "$STAGING/rule.md"
run apply_op_begin "$PLAN"
assert_rc "подмена источника до приёмки плана" "$RC" 1
assert_err_has "подмена до приёмки" "не совпало с планом"

# --- 6. paths outside the roots, malformed plans ------------------------------
new_install 6
mkdir -p "$SANDBOX/outside"
printf 'x\n' > "$SANDBOX/outside/file"
apply_op_plan_add "$PLAN" remove "$SANDBOX/outside/file"
run apply_op_begin "$PLAN"
assert_rc "путь вне корня" "$RC" 1
assert_err_has "вне корня" "вне разрешённых корней"
assert_eq "чужой файл цел" "$(cat "$SANDBOX/outside/file")" x
new_install 6b
printf '#apply-op-plan v1\n1\tremove\t%s\t-\tabsent\tabsent\n' "$INSTALL/../outside/file" > "$PLAN"
run apply_op_begin "$PLAN"
assert_rc "путь с .." "$RC" 1
printf '%s\n' '#apply-op-plan v1' "$(printf '1\tremove\t%s\t-\t%s\tabsent\textra' "$INSTALL/rule.md" "$(apply_op_fingerprint "$INSTALL/rule.md")")" > "$PLAN"
run apply_op_begin "$PLAN"
assert_rc "лишняя колонка" "$RC" 1
assert_err_has "лишняя колонка" "ровно 6"
printf '%s\n' '#apply-op-plan v1' "$(printf '1\tchmod\t%s\t-\tabsent\tabsent' "$INSTALL/rule.md")" > "$PLAN"
run apply_op_begin "$PLAN"
assert_rc "неизвестный тип" "$RC" 1
assert_err_has "неизвестный тип" "неизвестный тип"
printf '%s\n' '#apply-op-plan v2' > "$PLAN"
run apply_op_begin "$PLAN"
assert_rc "чужая версия формата" "$RC" 1
new_install 6d
APPLY_OP_ROOTS=()
run apply_op_begin "$PLAN"
assert_rc "пустой список корней" "$RC" 1
assert_err_has "корни" "APPLY_OP_ROOTS пуст"
new_install 6c
TAB_PATH="$INSTALL/a"$'\t'"b"
run apply_op_plan_add "$PLAN" write "$TAB_PATH" "$STAGING/added.md" 644
assert_rc "табуляция в пути при построении плана" "$RC" 1
assert_err_has "табуляция" "табуляцию"

# --- 7. conflict between two sources of one plan is caught before any write ---
new_install 7
apply_op_plan_add "$PLAN" replace "$INSTALL/rule.md" "$STAGING/rule.md" 644
{
    ORIGINAL_FP=$(apply_op_fingerprint "$INSTALL/rule.md")
    NEW_HASH=$(apply_op__sha256 "$STAGING/added.md")
    printf '2\treplace\t%s\t%s\t%s\tfile:644:%s\n' "$INSTALL/rule.md" "$STAGING/added.md" "$ORIGINAL_FP" "$NEW_HASH"
} >> "$PLAN"
BEFORE=$(snapshot "$INSTALL")
run apply_op_begin "$PLAN"
assert_rc "два источника на один путь" "$RC" 1
assert_err_has "конфликт источников" "конфликт источников"
assert_eq "дерево не менялось при конфликте" "$(snapshot "$INSTALL")" "$BEFORE"

# --- 8. move: occupied destination, filesystem boundary -----------------------
new_install 8
printf 'taken\n' > "$INSTALL/old/taken.md"
apply_op_plan_add "$PLAN" move "$INSTALL/old/stale.md" "$INSTALL/old/taken.md"
run apply_op_begin "$PLAN"
assert_rc "назначение переноса занято" "$RC" 1
assert_err_has "занятое назначение" "уже занято"
new_install 8b
apply_op_plan_add "$PLAN" move "$INSTALL/old/stale.md" "$INSTALL/scripts/stale.md"
apply_op_begin "$PLAN"
apply_op__dev_of() {
    case "$1" in */old) echo 1 ;; *) echo 2 ;; esac
}
run apply_op 1
assert_rc "перенос между файловыми системами" "$RC" 1
assert_err_has "границы файловых систем" "не атомарен"
assert_eq "источник на месте" "$(cat "$INSTALL/old/stale.md")" stale
unset -f apply_op__dev_of
if stat -c '%d' / >/dev/null 2>&1; then
    apply_op__dev_of() { stat -c '%d' "$1"; }
else
    apply_op__dev_of() { stat -f '%d' "$1"; }
fi

# --- 9. symlinks: never replaced silently, checked by text --------------------
new_install 9
ln -s rule.md "$INSTALL/link-to-rule"
apply_op_plan_add "$PLAN" replace "$INSTALL/link-to-rule" "$STAGING/rule.md" 644
run apply_op_begin "$PLAN"
assert_rc "замена ссылки без пометки в плане" "$RC" 1
assert_err_has "замена ссылки" "ссылку в замену не подменяем"
assert_eq "ссылка цела" "$(readlink "$INSTALL/link-to-rule")" rule.md
new_install 9b
ln -s rule.md "$INSTALL/link-to-rule"
apply_op_plan_add "$PLAN" remove "$INSTALL/link-to-rule"
ln -sfn other.md "$INSTALL/link-to-rule"
run apply_op_begin "$PLAN"
assert_rc "удаление ссылки с изменённой целью" "$RC" 1
assert_err_has "цель ссылки" "изменился после построения плана"
ln -sfn rule.md "$INSTALL/link-to-rule"
run apply_op_run "$PLAN"
assert_rc "удаление ссылки с прежней целью" "$RC" 0
assert_eq "ссылка удалена, цель цела" "$(apply_op_fingerprint "$INSTALL/link-to-rule")-$(cat "$INSTALL/rule.md")" "absent-old rule"

# --- 10. a symlinked parent is refused at execution ---------------------------
new_install 10
mkdir -p "$SANDBOX/elsewhere" "$INSTALL/real-dir"
apply_op_plan_add "$PLAN" write "$INSTALL/real-dir/file.md" "$STAGING/added.md" 644
apply_op_begin "$PLAN"
rm -rf "$INSTALL/real-dir"
ln -s "$SANDBOX/elsewhere" "$INSTALL/real-dir"
run apply_op 1
assert_rc "родитель подменён ссылкой после проверки плана" "$RC" 1
assert_err_has "родитель-ссылка" "содержит ссылку"
assert_eq "за пределы корня ничего не записано" "$(ls -A "$SANDBOX/elsewhere" | wc -l | tr -d ' ')" 0

new_install 10b
mkdir -p "$INSTALL/a/b" "$SANDBOX/away/b"
apply_op_plan_add "$PLAN" write "$INSTALL/a/b/file.md" "$STAGING/added.md" 644
apply_op_begin "$PLAN"
mv "$INSTALL/a" "$SANDBOX/a-moved"
ln -s "$SANDBOX/away" "$INSTALL/a"
run apply_op 1
assert_rc "ссылка не в родителе, а в предке пути" "$RC" 1
assert_err_has "ссылка в предке" "содержит ссылку"
assert_eq "в обход корня ничего не записано" "$(ls -A "$SANDBOX/away/b" | wc -l | tr -d ' ')" 0

# --- 11. non-empty directory and failure after a change started ---------------
new_install 11
apply_op_plan_add "$PLAN" rmdir_if_empty "$INSTALL/old"
run apply_op_run "$PLAN"
assert_rc "каталог не пуст" "$RC" 1
assert_err_has "непустой каталог" "не пуст"
assert_eq "содержимое каталога цело" "$(cat "$INSTALL/old/stale.md")" stale

new_install 12
apply_op_plan_add "$PLAN" replace "$INSTALL/rule.md" "$STAGING/rule.md" 644
apply_op_plan_add "$PLAN" write "$INSTALL/added.md" "$STAGING/added.md" 644
apply_op_begin "$PLAN"
# A mv that reports success without moving: the after-check must catch it.
mv() { return 0; }
run apply_op 1
unset -f mv
assert_rc "сбой после начала изменения" "$RC" 2
assert_err_has "сбой остановил исполнитель" "исполнитель остановлен"
run apply_op 2
assert_rc "операция после сбоя" "$RC" 1
assert_err_has "остановка" "остановлен после сбоя"
rm -f "$INSTALL"/.apply-op.*

# --- 12. empty plan, roots, builder -------------------------------------------
new_install 13
run apply_op_run "$PLAN"
assert_rc "пустой план" "$RC" 0
APPLY_OP_ROOTS=("install-13")
run apply_op_begin "$PLAN"
assert_rc "корень не канонический" "$RC" 1
APPLY_OP_ROOTS=("$INSTALL")
assert_eq "0644 и 644 — один режим" "$(apply_op__norm_mode 0644)" 644

echo "apply-op: $PASS проверок прошли, $FAIL не прошли"
[ "$FAIL" -eq 0 ]
