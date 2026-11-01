#!/usr/bin/env bash
# routing: utility  deterministic=true
#
# check-copy-pairs.sh — побайтовые копии скриптов в шаблоне не разъехались
# с оригиналами (WP-7, чистка шаблона 2026-11-01).
#
# check-seed-drift.sh сверяет только копии в seed/strategy/scripts/, помеченные
# строкой SNAPSHOT. Копии без пометки (они побайтово равны оригиналу) и копии
# вне seed/ (extensions/agent-inbox/, .claude/lib/) не сверял никто. Этот
# скрипт держит их явным списком и дополнительно ищет новые побайтовые пары,
# которых в списке нет: копия появилась — её либо регистрируют здесь, либо
# убирают. Иначе сверка останется разовой.
#
# Удалять копии и ставить ссылки вместо них нельзя: seed/strategy/scripts/
# установщик кладёт в отдельный репозиторий стратегии пользователя, а
# extensions/agent-inbox/ — самостоятельное расширение.
#
# Использование: bash scripts/check-copy-pairs.sh [FMT_DIR]

set -uo pipefail

FMT_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# оригинал|копия
PAIRS=(
    "scripts/day-open-hooks-runner.sh|seed/strategy/scripts/day-open-hooks-runner.sh"
    "scripts/day-open-scaffold.sh|seed/strategy/scripts/day-open-scaffold.sh"
    "scripts/generate-executor-catalog.py|seed/strategy/scripts/generate-executor-catalog.py"
    "scripts/install-hooks.sh|seed/strategy/scripts/install-hooks.sh"
    "scripts/isolate-push.sh|seed/strategy/scripts/isolate-push.sh"
    "scripts/iwe-agent-dispatcher.py|extensions/agent-inbox/scripts/iwe-agent-dispatcher.py"
    "scripts/gate_launch_usage.py|extensions/agent-inbox/scripts/gate_launch_usage.py"
    "scripts/config/pipeline-security-whitelist.yaml|extensions/agent-inbox/scripts/config/pipeline-security-whitelist.yaml"
    "scripts/lib/find-python3.sh|.claude/lib/find-python3.sh"
)

# Где искать незарегистрированные копии: каталоги с исполняемым кодом.
# Тесты и их фикстуры исключены — там одинаковые файлы бывают намеренно.
SCAN_DIRS=(scripts seed extensions .claude/lib .claude/scripts .claude/hooks roles setup)

fail=0
found_unregistered=0
registered=$'\n'

for pair in "${PAIRS[@]}"; do
    orig="${pair%%|*}"
    copy="${pair#*|}"
    registered+="$orig"$'\n'"$copy"$'\n'
    if [ ! -f "$FMT_DIR/$orig" ] || [ ! -f "$FMT_DIR/$copy" ]; then
        echo "FAIL: пара $orig ↔ $copy — одного из файлов нет"
        echo "  Файл переименован или удалён — обновите список PAIRS в scripts/check-copy-pairs.sh"
        fail=1
        continue
    fi
    if ! cmp -s "$FMT_DIR/$orig" "$FMT_DIR/$copy"; then
        echo "FAIL: $copy разошёлся с $orig"
        diff "$FMT_DIR/$orig" "$FMT_DIR/$copy" | head -20 | sed 's/^/    /'
        echo "  Фикс: перенесите правку в оба файла (обычно: cp $orig $copy)"
        fail=1
    fi
done

# Незарегистрированные побайтовые пары среди .sh/.py/.yaml.
existing_dirs=()
for d in "${SCAN_DIRS[@]}"; do
    [ -d "$FMT_DIR/$d" ] && existing_dirs+=("$d")
done
if [ ${#existing_dirs[@]} -gt 0 ]; then
    unregistered=$(
        cd "$FMT_DIR" && find "${existing_dirs[@]}" -type f \
            \( -name '*.sh' -o -name '*.py' -o -name '*.yaml' -o -name '*.yml' \) \
            -not -path '*/tests/*' -not -path '*/fixtures/*' -not -path '*/__pycache__/*' \
            -not -path '*-fixtures/*' -size +0 -print0 \
        | xargs -0 cksum \
        | sort \
        | awk '
            { key = $1 " " $2; path = $3; for (i = 4; i <= NF; i++) path = path " " $i }
            key == prev_key { if (!printed) print prev_path; print path; printed = 1; next }
            { prev_key = key; prev_path = path; printed = 0 }
        '
    )
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        case "$registered" in
            *$'\n'"$f"$'\n'*) continue ;;
        esac
        echo "FAIL: $f побайтово совпадает с другим файлом шаблона, но не зарегистрирован в PAIRS"
        fail=1
        found_unregistered=1
    done <<< "$unregistered"
    if [ "$found_unregistered" -eq 1 ]; then
        echo "  Новая копия: добавьте пару «оригинал|копия» в PAIRS (scripts/check-copy-pairs.sh) или уберите дубль."
    fi
fi

if [ "$fail" -eq 0 ]; then
    echo "PASS: ${#PAIRS[@]} пар копий совпадают с оригиналами, незарегистрированных копий нет"
fi
exit "$fail"
