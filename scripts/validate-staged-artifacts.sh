#!/usr/bin/env bash
# routing: guard  deterministic=true
# validate-staged-artifacts.sh — корректностная граница pre-commit для
# протокольных артефактов governance-репо (issue #544).
#
# PreToolUse-хук protocol-artifact-validate.sh — ранний слой быстрой обратной
# связи, но он читает индекс ДО выполнения команды, поэтому на слитной форме
# `git add … && git commit` молчит. Этот скрипт вызывается НАСТОЯЩИМ git-хуком
# pre-commit — он видит индекс после любой формы add (маски, -A/-u, слитные
# команды) и читает staged blob (`git show :path`), а не рабочее дерево:
# при частичном стейджинге проверяется именно то содержимое, что попадёт в
# коммит. Проверяются ВСЕ staged-артефакты каждого типа, не один
# лексикографически последний.
#
# Запуск: из .githooks/pre-commit governance-репо (cwd = корень репо).
# Весь вывод — в stderr: stdout git-хука не гарантированно виден пользователю.
# Exit 0 — коммит разрешён; exit 1 — блок с человекочитаемым разбором.
set -uo pipefail

TMPDIR_OWN=$(mktemp -d "${TMPDIR:-/tmp}/staged-artifacts.XXXXXX")
trap 'rm -rf "$TMPDIR_OWN"' EXIT HUP INT TERM

WORKSPACE="${IWE_WORKSPACE:-${IWE_ROOT:-$(cd "$(git rev-parse --show-toplevel)/.." 2>/dev/null && pwd || true)}}"
GOV_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

ERRORS=()

err() { ERRORS+=("$1"); }

# staged_to_tmp <path> — staged blob во временный файл; печатает путь.
staged_to_tmp() {
    local p="$1" tmp
    tmp=$(mktemp "$TMPDIR_OWN/blob.XXXXXX")
    if git show ":$p" > "$tmp" 2>/dev/null; then
        printf '%s\n' "$tmp"
    else
        rm -f "$tmp"
        return 1
    fi
}

validate_dayplan() { # <staged-path> <tmpfile>
    local rel="$1" f="$2"
    local section
    local SECTIONS=(
      "План на сегодня|Plan for Today|Today.s Plan"
      "Календарь|Calendar"
      "IWE за ночь|IWE Overnight"
      "Разбор заметок|Notes Review"
      "Итоги вчера|Yesterday"
    )
    for section in "${SECTIONS[@]}"; do
        grep -qE "$section" "$f" || err "DayPlan $rel: пропущена секция «$section»"
    done

    local headings
    headings=$(grep -cE '^## |^[[:space:]]*<summary>' "$f" 2>/dev/null || true)
    if [ "${headings:-0}" -lt 3 ]; then
        err "DayPlan $rel: секций (## или <summary>) меньше 3 (найдено: ${headings:-0})"
    fi

    local calendar_lines
    calendar_lines=$(awk 'f && /^## /{exit} /Календарь|Calendar/{f=1} f' "$f" 2>/dev/null | wc -l | tr -d ' ')
    if [ "${calendar_lines:-0}" -lt 3 ]; then
        err "DayPlan $rel: секция «Календарь» пустая или слишком короткая (${calendar_lines:-0} строк)"
    fi

    if grep -q "Наработки Scout" "$f" 2>/dev/null; then
        if ! awk 'f && /^## /{exit} /Наработки Scout/{f=1} f' "$f" 2>/dev/null | grep -iqE 'наход|capture|статус|нет|find|disabled|not configured'; then
            err "DayPlan $rel: секция «Наработки Scout» пустая (допустимы маркеры 'нет находок', 'disabled', 'not configured')"
        fi
    fi

    if ! grep -qE "~[0-9]+\.?[0-9]*x" "$f" && ! grep -qiE "мультипликатор.*(не считаю|не наст)" "$f"; then
        err "DayPlan $rel: мультипликатор не найден — нужен '~N.Nx' в строке бюджета или явная оговорка «мультипликатор не считаю»"
    fi

    # Mandatory check — только если сконфигурирован. Конфиг существует, но
    # не читается (битый YAML) — fail-closed: обязательная граница не вправе
    # молча пропустить проверку из-за инфраструктурной ошибки. Python без
    # резолвера/интерпретатора — пропуск с WARN (оценить конфиг нечем).
    local config="$WORKSPACE/memory/day-rhythm-config.yaml"
    local py=""
    if [ -f "$WORKSPACE/scripts/lib/find-python3.sh" ]; then
        py=$("$WORKSPACE/scripts/lib/find-python3.sh" 2>/dev/null) || py=""
    fi
    if [ -f "$config" ]; then
        if [ -z "$py" ]; then
            echo "WARN: day-rhythm-config.yaml есть, но python3 не найден — mandatory-проверка DayPlan пропущена" >&2
        else
            # Коды: 0 = mandatory сконфигурирован; 1 = валидный конфиг (map)
            # без mandatory; 2 = любая ошибка (нет PyYAML, битый YAML, корень
            # не map, включая пустой файл/null) — fail-closed (ревью #544).
            local py_rc=0
            "$py" -c "
import sys
try:
    import yaml
    d = yaml.safe_load(open(sys.argv[1]))
except Exception:
    sys.exit(2)
if not isinstance(d, dict):
    sys.exit(2)
sys.exit(0 if d.get('mandatory_daily_wps') else 1)
" "$config" 2>/dev/null || py_rc=$?
            case "$py_rc" in
                0)
                    grep -qi "mandatory" "$f" || err "DayPlan $rel: mandatory check не найден (mandatory_daily_wps сконфигурирован)"
                    ;;
                1)
                    : # валидный конфиг без mandatory — проверка не требуется
                    ;;
                *)
                    # 2 — ошибки чтения/схемы; прочие коды (126/127/сигнал) —
                    # тоже fail-closed: неизвестный исход проверки ≠ «не
                    # сконфигурирован».
                    err "DayPlan $rel: day-rhythm-config.yaml существует, но не читается (нет PyYAML / битый или пустой YAML / корень не map / интерпретатор упал rc=$py_rc) — mandatory-проверка невозможна, fail-closed"
                    ;;
            esac
        fi
    fi

    if ! grep -qE "~[0-9]+\.?[0-9]* ?[hч] РП" "$f"; then
        err "DayPlan $rel: бюджет дня не в формате '~Xч РП / ~Yч физ'"
    fi

    # Carry-over: предыдущий DayPlan ищется на диске (другие файлы — не часть
    # индекса, это нормально), сам артефакт проверен из staged blob выше.
    local prev
    prev=$(ls "$GOV_ROOT"/current/DayPlan\ *.md 2>/dev/null | sort | tail -2 | head -1)
    if [ -n "$prev" ] && [ "$prev" != "$GOV_ROOT/$rel" ]; then
        grep -qiE 'carry.over|carry_over' "$f" || \
            err "DayPlan $rel: carry-over из предыдущего Day Close отсутствует (предыдущий: $(basename "$prev"))"
    fi
}

validate_weekplan() { # <staged-path> <tmpfile>
    local rel="$1" f="$2"
    local lines headings
    lines=$(wc -l < "$f" | tr -d ' ')
    headings=$(grep -cE '^## |^[[:space:]]*<summary>' "$f" 2>/dev/null || true)
    if [ "${lines:-0}" -gt 80 ] && [ "${headings:-0}" -lt 3 ]; then
        err "WeekPlan $rel: больше 80 строк ($lines), но секций (## или <summary>) меньше 3 (${headings:-0}) — структурируй через ## или <details><summary>"
    fi
}

validate_weekreport() { # <staged-path> <tmpfile>
    local rel="$1" f="$2"
    grep -q "Итоги" "$f" || err "WeekReport $rel: нет секции «Итоги»"
}

# Обход ВСЕХ staged-артефактов каждого типа (а не одного sort|tail -1):
# коммит с двумя WeekPlan не должен прятать невалидный за валидным.
# -z + --diff-filter=ACMRT: имена с пробелами/юникодом не ломают разбор;
# удалённые файлы не проверяются (проверять нечего), type-change (файл стал
# симлинком) — проверяется. Перечисление индекса — fail-closed: не смогли
# прочитать индекс → блок, а не молчаливый пропуск (ревью #544, раунд 2).
STAGED_FILE="$TMPDIR_OWN/staged.list"
if ! git diff --cached --name-only -z --diff-filter=ACMRT > "$STAGED_FILE" 2>"$TMPDIR_OWN/staged.err"; then
    echo "⛔ Не удалось перечислить индекс (git diff --cached) — коммит заблокирован (fail-closed):" >&2
    sed 's/^/  /' "$TMPDIR_OWN/staged.err" >&2
    exit 1
fi
while IFS= read -r -d '' rel; do
    case "$rel" in
        current/DayPlan*.md)    kind=dayplan ;;
        current/WeekPlan*.md)   kind=weekplan ;;
        current/WeekReport*.md) kind=weekreport ;;
        *) continue ;;
    esac
    tmp=$(staged_to_tmp "$rel") || {
        echo "⛔ Не удалось прочитать staged blob $rel — коммит заблокирован (fail-closed)." >&2
        exit 1
    }
    case "$kind" in
        dayplan)    validate_dayplan "$rel" "$tmp" ;;
        weekplan)   validate_weekplan "$rel" "$tmp" ;;
        weekreport) validate_weekreport "$rel" "$tmp" ;;
    esac
    rm -f "$tmp"
done < "$STAGED_FILE"

if [ ${#ERRORS[@]} -gt 0 ]; then
    echo "⛔ PROTOCOL ARTIFACT VALIDATION FAILED (pre-commit, staged blob):" >&2
    printf '  - %s\n' "${ERRORS[@]}" >&2
    echo "Проверяется содержимое ИНДЕКСА (git show :path), не рабочего дерева —" >&2
    echo "после правки файла повтори git add." >&2
    exit 1
fi
exit 0
