#!/bin/bash
# WP-529 F245 step 2: frozen plan and the single executor of file writes.
#
# Sourced, never executed. Not wired into update.sh yet: the blocks that
# setup/update-write-sites.tsv classifies as "plan" move onto it one by one.
# Bash 3.2 compatible (no associative arrays, no mapfile, no python): update.sh
# has to keep working on a stock macOS.
#
# Model (agreed in the F245 design sessions, 29.10.2026): the plan is built and
# frozen first; apply_op takes only an operation id and reads everything else
# from the frozen row. Reliability model is "process abort only": a stopped
# process leaves the tree in a state the future journal can classify; power
# loss and concurrent third-party edits between two checks are not covered.
#
# Plan file (TSV, one operation per row, no empty fields; "-" = not used):
#   #apply-op-plan v1
#   id  type  path  arg  before  after
# Fingerprint of a path (before / after):
#   absent | file:MODE:SHA256 | dir:MODE | link:TARGET
# Types: write, replace, remove, mkdir, rmdir_if_empty, move.
#   write    path absent -> file from staging file ARG
#   replace  path file  -> file from staging file ARG
#   remove   path file or link -> absent
#   mkdir    path absent -> dir (the parent is its own earlier operation)
#   rmdir_if_empty  path dir -> absent; a non-empty directory is a refusal
#   move     path -> ARG (destination absent, same filesystem), content as is
# Mode is part of the "after" fingerprint: it is set on the temporary file
# before the rename, there is no separate chmod operation.
#
# Return codes: apply_op 0 done, 1 this operation refused and the tree was not
# touched by it, 2 failed after a change started (the executor stops; retry is
# unsafe until the journal exists). apply_op_run adds: a refusal after earlier
# operations ran is a partial application, code 2. The builder and the executor
# share state, so a plan is built completely first; after a stop apply_op_end
# releases the executor.
#
# Caller sets APPLY_OP_ROOTS (array of canonical absolute directories) before
# apply_op_begin; every path of the plan must be inside one of them.

APPLY_OP_HEADER='#apply-op-plan v1'
APPLY_OP_TYPES=" write replace remove mkdir rmdir_if_empty move "

if stat -c '%a' / >/dev/null 2>&1; then
    apply_op__mode_of() { stat -c '%a' "$1"; }
    apply_op__dev_of() { stat -c '%d' "$1"; }
else
    apply_op__mode_of() { stat -f '%Lp' "$1"; }
    apply_op__dev_of() { stat -f '%d' "$1"; }
fi

apply_op__msg() {
    printf 'apply_op: %s\n' "$*" >&2
}

apply_op__reset() {
    AO_TYPE=()
    AO_PATH=()
    AO_ARG=()
    AO_BEFORE=()
    AO_AFTER=()
    AO_CHAIN=""
    APPLY_OP_TOTAL=0
    APPLY_OP_NEXT=0
    APPLY_OP_ACCEPTED=""
    APPLY_OP_STOPPED=""
}
apply_op__reset

apply_op__sha256() {
    local out
    if command -v shasum >/dev/null 2>&1; then
        out=$(shasum -a 256 < "$1" 2>/dev/null) || return 1
    elif command -v sha256sum >/dev/null 2>&1; then
        out=$(sha256sum < "$1" 2>/dev/null) || return 1
    else
        return 1
    fi
    printf '%s\n' "${out%% *}"
}

# 0644 and 644 are the same mode; the short form is padded to three digits.
apply_op__norm_mode() {
    case "$1" in
        0[0-7][0-7][0-7]) printf '%s\n' "${1#0}" ;;
        [0-7] | [0-7][0-7]) printf '%03d\n' "$1" ;;
        *) printf '%s\n' "$1" ;;
    esac
}

# Prints the fingerprint of PATH without following a final symlink.
apply_op_fingerprint() {
    local p=$1 mode hash target
    if [ -L "$p" ]; then
        target=$(readlink "$p"; printf x) || return 1
        target=${target%x}
        target=${target%$'\n'}   # readlink's own newline; one more means a real one
        case "$target" in
            *$'\t'* | *$'\n'*)
                apply_op__msg "цель ссылки содержит табуляцию или перевод строки: $p"
                return 1
                ;;
        esac
        printf 'link:%s\n' "$target"
    elif [ -d "$p" ]; then
        mode=$(apply_op__mode_of "$p") || return 1
        printf 'dir:%s\n' "$(apply_op__norm_mode "$mode")"
    elif [ -f "$p" ]; then
        mode=$(apply_op__mode_of "$p") || return 1
        mode=$(apply_op__norm_mode "$mode")
        hash=$(apply_op__sha256 "$p") || {
            apply_op__msg "нет инструмента sha256 (shasum или sha256sum)"
            return 1
        }
        printf 'file:%s:%s\n' "$mode" "$hash"
    elif [ -e "$p" ]; then
        printf 'other\n'
    else
        printf 'absent\n'
    fi
}

apply_op__fp_valid() {
    local fp=$1 hash
    case "$fp" in
        absent | other) return 0 ;;
        file:[0-7][0-7][0-7]:* | file:[0-7][0-7][0-7][0-7]:*)
            hash=${fp#file:*:}
            [ "${#hash}" -eq 64 ] || return 1
            case "$hash" in *[!0-9a-f]*) return 1 ;; esac
            return 0
            ;;
        dir:[0-7][0-7][0-7] | dir:[0-7][0-7][0-7][0-7]) return 0 ;;
        link:?*) return 0 ;;
    esac
    return 1
}

# Allowed roots must exist as canonical directories and must not be "/".
apply_op__roots_ok() {
    local root resolved
    if [ -z "${APPLY_OP_ROOTS+x}" ] || [ "${#APPLY_OP_ROOTS[@]}" -eq 0 ]; then
        apply_op__msg "APPLY_OP_ROOTS пуст: не заданы корни, куда разрешена запись"
        return 1
    fi
    for root in ${APPLY_OP_ROOTS[@]+"${APPLY_OP_ROOTS[@]}"}; do
        resolved=$(cd -P "$root" 2>/dev/null && pwd -P) || resolved=""
        if [ "$root" = "/" ] || [ "$resolved" != "$root" ]; then
            apply_op__msg "корень записи не канонический существующий каталог: $root"
            return 1
        fi
    done
}

# Absolute, normalised, inside an allowed root, never the root itself.
apply_op__path_ok() {
    local p=$1 root
    case "$p" in /*) ;; *) return 1 ;; esac
    case "$p" in
        *$'\t'* | *$'\n'* | *//* | */ | */./* | */../* | */. | */..) return 1 ;;
    esac
    for root in ${APPLY_OP_ROOTS[@]+"${APPLY_OP_ROOTS[@]}"}; do
        case "$p" in "$root"/?*) return 0 ;; esac
    done
    return 1
}

# The parent must exist and contain no symlink component: a swapped directory
# would redirect the write outside the plan.
apply_op__parent_ok() {
    local parent resolved
    parent=$(dirname "$1")
    resolved=$(cd -P "$parent" 2>/dev/null && pwd -P) || return 1
    [ "$resolved" = "$parent" ]
}

# State of PATH after the first UPTO rows of the loaded plan; empty if untouched.
apply_op__chain() {
    local p=$1 upto=$2 i=1
    AO_CHAIN=""
    while [ "$i" -le "$upto" ]; do
        if [ "${AO_PATH[$i]}" = "$p" ]; then
            if [ "${AO_TYPE[$i]}" = move ]; then
                AO_CHAIN=absent
            else
                AO_CHAIN=${AO_AFTER[$i]}
            fi
        fi
        if [ "${AO_TYPE[$i]}" = move ] && [ "${AO_ARG[$i]}" = "$p" ]; then
            AO_CHAIN=${AO_AFTER[$i]}
        fi
        i=$((i + 1))
    done
}

# Splits the plan file into the AO_* arrays; checks the layout only.
apply_op__load() {
    local plan=$1 header id type path arg before after extra
    apply_op__reset
    if [ ! -f "$plan" ]; then
        apply_op__msg "план не найден: $plan"
        return 1
    fi
    {
        IFS= read -r header || true
        if [ "$header" != "$APPLY_OP_HEADER" ]; then
            apply_op__msg "неверный заголовок плана (ожидался «${APPLY_OP_HEADER}»)"
            return 1
        fi
        while IFS=$'\t' read -r id type path arg before after extra || [ -n "$id" ]; do
            APPLY_OP_TOTAL=$((APPLY_OP_TOTAL + 1))
            if [ -n "$extra" ] || [ -z "$after" ]; then
                apply_op__msg "строка $APPLY_OP_TOTAL плана: нужно ровно 6 непустых колонок"
                return 1
            fi
            if [ "$id" != "$APPLY_OP_TOTAL" ]; then
                apply_op__msg "строка плана: номер «${id}» вместо $APPLY_OP_TOTAL (номера идут подряд с 1)"
                return 1
            fi
            AO_TYPE[APPLY_OP_TOTAL]=$type
            AO_PATH[APPLY_OP_TOTAL]=$path
            AO_ARG[APPLY_OP_TOTAL]=$arg
            AO_BEFORE[APPLY_OP_TOTAL]=$before
            AO_AFTER[APPLY_OP_TOTAL]=$after
        done
    } < "$plan"
}

apply_op__check_row() {
    local i=$1 type path arg before after src_hash
    type=${AO_TYPE[$i]}
    path=${AO_PATH[$i]}
    arg=${AO_ARG[$i]}
    before=${AO_BEFORE[$i]}
    after=${AO_AFTER[$i]}

    case "$APPLY_OP_TYPES" in
        *" $type "*) ;;
        *)
            apply_op__msg "операция $i: неизвестный тип «${type}»"
            return 1
            ;;
    esac
    if ! apply_op__path_ok "$path"; then
        apply_op__msg "операция $i: путь вне разрешённых корней или не нормализован: $path"
        return 1
    fi
    if ! apply_op__fp_valid "$before" || ! apply_op__fp_valid "$after" ||
        [ "$before" = other ] || [ "$after" = other ]; then
        apply_op__msg "операция $i: неверный отпечаток («${before}» → «${after}»)"
        return 1
    fi

    case "$type:${before%%:*}:${after%%:*}" in
        write:absent:file | replace:file:file | remove:file:absent | remove:link:absent | \
            mkdir:absent:dir | rmdir_if_empty:dir:absent | move:file:file | move:link:link) ;;
        *)
            apply_op__msg "операция $i ($type): состояние «${before}» → «${after}» для этого типа недопустимо (ссылку в замену не подменяем молча)"
            return 1
            ;;
    esac

    case "$after" in
        file:[0-7][0-7][0-7]:* | dir:[0-7][0-7][0-7]) ;;
        absent) ;;
        *)
            apply_op__msg "операция $i: режим со спецбитами не поддерживается: «${after}»"
            return 1
            ;;
    esac
    case "$after" in
        file:[0-3]* | dir:[0-4]* | dir:6*)
            apply_op__msg "операция $i: режим без чтения (и обхода для каталога) владельцем не поддерживается: «${after}»"
            return 1
            ;;
    esac

    case "$type" in
        write | replace)
            case "$arg" in /*) ;; *)
                apply_op__msg "операция $i: источник должен быть абсолютным путём: $arg"
                return 1
                ;;
            esac
            if [ ! -f "$arg" ] || [ -L "$arg" ]; then
                apply_op__msg "операция $i: источник не обычный файл: $arg"
                return 1
            fi
            src_hash=$(apply_op__sha256 "$arg") || src_hash=""
            if [ "$src_hash" != "${after##*:}" ]; then
                apply_op__msg "операция $i: содержимое источника не совпало с планом (подмена после заморозки?): $arg"
                return 1
            fi
            ;;
        move)
            if ! apply_op__path_ok "$arg" || [ "$arg" = "$path" ]; then
                apply_op__msg "операция $i: назначение переноса вне корней, не нормализовано или совпадает с источником: $arg"
                return 1
            fi
            if [ "$after" != "$before" ]; then
                apply_op__msg "операция $i: перенос не меняет содержимое, «после» должно равняться «до»"
                return 1
            fi
            ;;
        *)
            if [ "$arg" != "-" ]; then
                apply_op__msg "операция $i ($type): аргумент не используется, должен быть «-»"
                return 1
            fi
            ;;
    esac

    apply_op__chain "$path" $((i - 1))
    if [ -n "$AO_CHAIN" ] && [ "$AO_CHAIN" != "$before" ]; then
        apply_op__msg "операция $i: конфликт источников — ожидает «${before}», а предыдущие операции оставят «${AO_CHAIN}»: $path"
        return 1
    fi
    if [ "$type" = move ]; then
        apply_op__chain "$arg" $((i - 1))
        if [ -n "$AO_CHAIN" ] && [ "$AO_CHAIN" != absent ]; then
            apply_op__msg "операция $i: назначение переноса занято предыдущими операциями: $arg"
            return 1
        fi
    fi
}

# The parent of a path must exist when its operation runs: live, or made by an
# earlier mkdir of this plan and not removed since. Caught here, a plan that is
# bound to fail halfway is refused before the first write.
apply_op__parent_planned() {
    local i=$1 parent
    parent=$(dirname "$2")
    apply_op__chain "$parent" $((i - 1))
    if [ -n "$AO_CHAIN" ]; then
        case "$AO_CHAIN" in
            dir:*) return 0 ;;
        esac
    elif [ -d "$parent" ] && [ ! -L "$parent" ]; then
        return 0
    fi
    apply_op__msg "операция $i: родитель не существует к моменту операции: $parent"
    return 1
}

# Accepts the plan: layout, every row, chains between rows, then the live tree
# against the first touch of every path. Nothing is written.
apply_op_begin() {
    local plan=$1 i live parent
    if [ -n "$APPLY_OP_STOPPED" ]; then
        apply_op__msg "исполнитель остановлен после сбоя на операции $APPLY_OP_STOPPED; новый план принимать только после apply_op_end"
        return 1
    fi
    apply_op__roots_ok || return 1
    apply_op__load "$plan" || return 1
    i=1
    while [ "$i" -le "$APPLY_OP_TOTAL" ]; do
        apply_op__check_row "$i" || return 1
        i=$((i + 1))
    done
    i=1
    while [ "$i" -le "$APPLY_OP_TOTAL" ]; do
        apply_op__chain "${AO_PATH[$i]}" $((i - 1))
        if [ -z "$AO_CHAIN" ]; then
            live=$(apply_op_fingerprint "${AO_PATH[$i]}") || return 1
            if [ "$live" != "${AO_BEFORE[$i]}" ]; then
                apply_op__msg "операция $i: ${AO_PATH[$i]} изменился после построения плана (ожидалось «${AO_BEFORE[$i]}», на диске «${live}»)"
                return 1
            fi
        fi
        if [ "${AO_TYPE[$i]}" = move ]; then
            apply_op__chain "${AO_ARG[$i]}" $((i - 1))
            if [ -z "$AO_CHAIN" ]; then
                live=$(apply_op_fingerprint "${AO_ARG[$i]}") || return 1
                if [ "$live" != absent ]; then
                    apply_op__msg "операция $i: назначение переноса уже занято: ${AO_ARG[$i]}"
                    return 1
                fi
            fi
            apply_op__parent_planned "$i" "${AO_ARG[$i]}" || return 1
        fi
        apply_op__parent_planned "$i" "${AO_PATH[$i]}" || return 1
        i=$((i + 1))
    done
    APPLY_OP_NEXT=1
    APPLY_OP_ACCEPTED=1
}

# Refusal: the tree was not touched.
apply_op__refuse() {
    apply_op__msg "операция $1 отклонена: $2"
    return 1
}

# Failure after a change started: the executor stops.
apply_op__fail() {
    APPLY_OP_STOPPED=$1
    apply_op__msg "операция $1 не удалась: $2; исполнитель остановлен, повтор небезопасен до появления журнала"
    return 2
}

apply_op__verify_after() {
    local id=$1 path=$2 expected=$3 live
    live=$(apply_op_fingerprint "$path") || live="?"
    if [ "$live" != "$expected" ]; then
        apply_op__fail "$id" "после записи $path ожидалось «${expected}», на диске «${live}»"
        return 2
    fi
}

# Installs the staging file through a sibling temporary file: content and mode
# are set on the temporary file, the target is touched by one rename.
apply_op__install_file() {
    local id=$1 path=$2 src=$3 after=$4 mode hash dir tmp tmp_hash
    mode=${after#file:}
    mode=${mode%%:*}
    hash=${after##*:}
    dir=$(dirname "$path")
    tmp=$(mktemp "$dir/.apply-op.XXXXXX") || {
        apply_op__refuse "$id" "не создать временный файл рядом с $path"
        return 1
    }
    if ! cp "$src" "$tmp"; then
        rm -f "$tmp"
        apply_op__refuse "$id" "не скопировать источник во временный файл для $path"
        return 1
    fi
    tmp_hash=$(apply_op__sha256 "$tmp") || tmp_hash=""
    if [ "$tmp_hash" != "$hash" ]; then
        rm -f "$tmp"
        apply_op__refuse "$id" "источник изменился во время копирования: $src"
        return 1
    fi
    if ! chmod "0$mode" "$tmp"; then
        rm -f "$tmp"
        apply_op__refuse "$id" "не выставить права временного файла для $path"
        return 1
    fi
    if ! mv -f "$tmp" "$path"; then
        rm -f "$tmp"
        apply_op__fail "$id" "не заменить $path"
        return 2
    fi
}

apply_op() {
    local id=$1 type path arg before after live dst_live
    if [ -n "$APPLY_OP_STOPPED" ]; then
        apply_op__refuse "$id" "исполнитель остановлен после сбоя на операции $APPLY_OP_STOPPED"
        return 1
    fi
    if [ -z "$APPLY_OP_ACCEPTED" ]; then
        apply_op__refuse "$id" "план не принят: сначала apply_op_begin"
        return 1
    fi
    case "$id" in '' | *[!0-9]*)
        apply_op__refuse "$id" "номер операции не число"
        return 1
        ;;
    esac
    id=$((10#$id))
    if [ "$id" -lt 1 ] || [ "$id" -gt "$APPLY_OP_TOTAL" ]; then
        apply_op__refuse "$id" "номер вне плана (в плане операций: $APPLY_OP_TOTAL)"
        return 1
    fi
    if [ "$id" -ne "$APPLY_OP_NEXT" ]; then
        apply_op__refuse "$id" "порядок нарушен или операция уже выполнена (следующая по плану: $APPLY_OP_NEXT)"
        return 1
    fi
    type=${AO_TYPE[$id]}
    path=${AO_PATH[$id]}
    arg=${AO_ARG[$id]}
    before=${AO_BEFORE[$id]}
    after=${AO_AFTER[$id]}

    if ! apply_op__parent_ok "$path"; then
        apply_op__refuse "$id" "родитель $path не существует или содержит ссылку"
        return 1
    fi
    live=$(apply_op_fingerprint "$path") || {
        apply_op__refuse "$id" "не снять отпечаток $path"
        return 1
    }
    if [ "$live" != "$before" ]; then
        apply_op__refuse "$id" "$path: ожидалось «${before}», на диске «${live}»"
        return 1
    fi

    case "$type" in
        write | replace)
            if [ "$(apply_op__sha256 "$arg" 2>/dev/null)" != "${after##*:}" ]; then
                apply_op__refuse "$id" "источник $arg не совпал с планом (подмена после заморозки)"
                return 1
            fi
            apply_op__install_file "$id" "$path" "$arg" "$after" || return $?
            ;;
        mkdir)
            if ! mkdir "$path"; then
                apply_op__refuse "$id" "не создать каталог $path"
                return 1
            fi
            if ! chmod "0${after#dir:}" "$path"; then
                apply_op__fail "$id" "не выставить права каталога $path"
                return 2
            fi
            ;;
        remove)
            rm -f "$path" || {
                apply_op__fail "$id" "не удалить $path"
                return 2
            }
            ;;
        rmdir_if_empty)
            if ! rmdir "$path" 2>/dev/null; then
                apply_op__refuse "$id" "каталог $path не пуст или не удаляется (неожиданное состояние)"
                return 1
            fi
            ;;
        move)
            if ! apply_op__parent_ok "$arg"; then
                apply_op__refuse "$id" "родитель назначения $arg не существует или содержит ссылку"
                return 1
            fi
            dst_live=$(apply_op_fingerprint "$arg") || dst_live="?"
            if [ "$dst_live" != absent ]; then
                apply_op__refuse "$id" "назначение переноса занято: $arg"
                return 1
            fi
            if [ "$(apply_op__dev_of "$(dirname "$path")")" != "$(apply_op__dev_of "$(dirname "$arg")")" ]; then
                apply_op__refuse "$id" "перенос между файловыми системами не атомарен: $path → $arg"
                return 1
            fi
            mv "$path" "$arg" || {
                apply_op__fail "$id" "не перенести $path в $arg"
                return 2
            }
            apply_op__verify_after "$id" "$arg" "$after" || return 2
            after=absent
            ;;
    esac
    apply_op__verify_after "$id" "$path" "$after" || return 2
    APPLY_OP_NEXT=$((APPLY_OP_NEXT + 1))
}

# Accepts the plan and applies every operation in order; stops at the first
# refusal or failure and returns its code.
apply_op_run() {
    local id rc
    apply_op_begin "$1" || return 1
    id=1
    while [ "$id" -le "$APPLY_OP_TOTAL" ]; do
        apply_op "$id"
        rc=$?
        if [ "$rc" -eq 1 ] && [ "$id" -gt 1 ]; then
            APPLY_OP_STOPPED=$id
            apply_op__msg "план применён частично: операции 1..$((id - 1)) выполнены, операция $id отклонена; исполнитель остановлен"
            return 2
        fi
        [ "$rc" -eq 0 ] || return "$rc"
        id=$((id + 1))
    done
    apply_op_end
}

# Releases the executor: after a run that stopped, or when the plan is dropped.
apply_op_end() {
    apply_op__reset
}

# Plan builder: the only writer of the plan format. "before" is derived from the
# plan so far or, for the first touch of a path, from the live tree.
#   apply_op_plan_new FILE
#   apply_op_plan_add FILE TYPE PATH [ARG [MODE]]
#     write/replace: ARG = staging file, MODE = octal mode of the result
#     mkdir: MODE;  move: ARG = destination;  remove/rmdir_if_empty: nothing
apply_op_plan_new() {
    printf '%s\n' "$APPLY_OP_HEADER" > "$1"
}

apply_op_plan_add() {
    local file=$1 type=$2 path=$3 arg=${4:--} mode=${5:--} before after hash field
    if [ -n "$APPLY_OP_ACCEPTED" ]; then
        apply_op__msg "исполнитель держит принятый план: сначала apply_op_end (построитель и исполнитель делят состояние)"
        return 1
    fi
    for field in "$path" "$arg"; do
        case "$field" in
            *$'\t'* | *$'\n'*)
                apply_op__msg "в пути нельзя табуляцию или перевод строки: $field"
                return 1
                ;;
        esac
    done
    apply_op__load "$file" || return 1
    apply_op__chain "$path" "$APPLY_OP_TOTAL"
    if [ -n "$AO_CHAIN" ]; then
        before=$AO_CHAIN
    else
        before=$(apply_op_fingerprint "$path") || return 1
    fi
    case "$type" in
        write | replace)
            hash=$(apply_op__sha256 "$arg") || {
                apply_op__msg "не прочитать источник: $arg"
                return 1
            }
            after="file:$(apply_op__norm_mode "$mode"):$hash"
            ;;
        mkdir) after="dir:$(apply_op__norm_mode "$mode")" ;;
        remove | rmdir_if_empty) after=absent ;;
        move) after=$before ;;
        *)
            apply_op__msg "неизвестный тип «${type}»"
            return 1
            ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$((APPLY_OP_TOTAL + 1))" "$type" "$path" "$arg" "$before" "$after" >> "$file"
}
