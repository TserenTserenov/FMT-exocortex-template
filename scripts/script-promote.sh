#!/usr/bin/env bash
# routing: utility  deterministic=true
# see DP.SC.159, DP.ROLE.059
# script-promote.sh — промоция личного скрипта (или всех общих скриптов) в платформенный шаблон IWE
#
# Поток: личная папка/<script> → подстановки → FMT/scripts/<script>
# Личные константы заменяются на параметры среды (env vars).
#
# Использование:
#   bash script-promote.sh <путь-к-скрипту> [--dry-run] [--force]
#   bash script-promote.sh --all [--dry-run] [--force]
#
# Примеры:
#   bash script-promote.sh ~/IWE/DS-strategy/scripts/my-tool.sh --dry-run
#   bash script-promote.sh ~/IWE/DS-strategy/scripts/my-tool.sh
#   bash script-promote.sh ~/IWE/DS-strategy/scripts/my-tool.sh --force
#   bash script-promote.sh --all
#
# --force: пропустить guard сравнения с FMT HEAD (если FMT отличается намеренно)
# --all: пройти по всем scripts/*.sh|*.py, общим для личной копии и FMT — без --force
#        каждый диверзировавший файл ПРОПУСКАЕТСЯ (не блокирует остальные), см. WP-485:
#        ручное копирование в обход этого guard уже стирало фиксы, сделанные прямо в FMT
#        (issue #220/#259, коммит 238a5c1) — --all существует, чтобы массовая
#        синхронизация впредь шла через тот же guard, что и промоция одного файла.

set -uo pipefail

IWE="${IWE_WORKSPACE:-$HOME/IWE}"
FMT_DIR="${IWE_TEMPLATE:-$IWE/FMT-exocortex-template}"
GOV_REPO_AUTHOR="${IWE_GOVERNANCE_REPO:-DS-strategy}"
GOV_REPO_TMPL="DS-strategy"
VALIDATOR="$FMT_DIR/scripts/validate-fmt-scripts.sh"

SRC=""
dry_run=false
force=false
batch_all=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) dry_run=true ;;
        --force)   force=true ;;
        --all)     batch_all=true ;;
        --*)       echo "Неизвестный флаг: $arg" >&2; exit 1 ;;
        *)         if [[ -z "$SRC" ]]; then SRC="$arg"; else echo "Слишком много аргументов" >&2; exit 1; fi ;;
    esac
done

if ! $batch_all && [[ -z "$SRC" || ! -f "$SRC" ]]; then
    echo "Использование: $0 <путь-к-скрипту> [--dry-run] [--force]" >&2
    echo "        или:   $0 --all [--dry-run] [--force]" >&2
    echo "Пример: $0 ~/IWE/\$GOV_REPO/scripts/my-tool.sh" >&2
    exit 1
fi

# promote_one SRC — промотирует один файл. Возврат: 0 промотирован/эквивалентен,
# 2 пропущен guard'ом (FMT ушёл вперёд), 1 прочая ошибка (валидация/smoke-test).
promote_one() {
    local src="$1" fname dest result head_version tmp_dir tmp_file smoke_result
    fname=$(basename "$src")
    dest="$FMT_DIR/scripts/$fname"

    echo "🔄 Промоция: $fname"
    echo "   Откуда: $src"
    echo "   Куда:   $dest"
    echo ""

    # Подстановки: личные константы → параметры среды
    # Порядок важен: сначала длинный путь ($HOME/IWE), потом короткий ($HOME)
    result=$(sed \
        -e "s|$HOME/IWE|\${IWE:-\$HOME/IWE}|g" \
        -e "s|$HOME|\$HOME|g" \
        -e "s|$GOV_REPO_AUTHOR|\${IWE_GOVERNANCE_REPO:-$GOV_REPO_TMPL}|g" \
        "$src")

    # Guard: FMT HEAD содержит более свежую версию? Проверяется и в --dry-run —
    # иначе `--all --dry-run` рапортует «всё промотируется», хотя часть файлов
    # разошлась и реальный прогон их пропустит (WP-485).
    # Сравниваем $result (после подстановок) с HEAD:scripts/$fname — не с working tree.
    # Цель: поймать случай когда runtime-копия stale и перетирает фиксы, уже залитые в FMT.
    # Новый файл (нет в HEAD) → guard молчит. FMT не git-репо → guard молчит.
    if ! $force && git -C "$FMT_DIR" rev-parse HEAD >/dev/null 2>&1; then
        head_version=$(git -C "$FMT_DIR" show "HEAD:scripts/$fname" 2>/dev/null || true)
        if [[ -n "$head_version" ]]; then
            if ! diff -q <(printf '%s\n' "$result") <(printf '%s\n' "$head_version") >/dev/null 2>&1; then
                echo "⚠️  ПРОПУЩЕН: FMT HEAD содержит другую версию $fname" >&2
                echo "   Вероятно, в FMT уже есть фиксы, которых нет в вашей копии." >&2
                echo "   Промоция перетрёт эти изменения." >&2
                echo "" >&2
                echo "   Текущая версия в FMT HEAD:" >&2
                echo "     git -C \"$FMT_DIR\" show HEAD:scripts/$fname" >&2
                echo "   Что будет промотировано (после подстановок):" >&2
                echo "     bash \"$0\" \"$src\" --dry-run" >&2
                echo "" >&2
                echo "   Продолжить (если разница намеренная):" >&2
                echo "     $0 \"$src\" --force" >&2
                return 2
            fi
        fi
    fi

    if $dry_run; then
        echo "--- dry-run: результат после подстановок (guard пройден) ---"
        printf '%s\n' "$result"
        echo "--- конец ---"
        return 0
    fi

    # Валидация результата через временный файл
    tmp_dir=$(mktemp -d)
    tmp_file="$tmp_dir/$fname"
    printf '%s\n' "$result" > "$tmp_file"
    chmod +x "$tmp_file"

    if [[ -f "$VALIDATOR" ]]; then
        if ! bash "$VALIDATOR" "$tmp_dir" 2>&1; then
            rm -rf "$tmp_dir"
            echo "" >&2
            echo "❌ После подстановок остались личные хардкоды." >&2
            echo "   Используй --dry-run для просмотра и исправь вручную." >&2
            return 1
        fi
    fi

    # Smoke-тест: запустить в изолированном env с шаблонными переменными
    # Цель: убедиться что скрипт не падает с exit 1 при чужом окружении
    # Используем --help или пустой запуск — ожидаем exit 0 или exit 1 только от validation
    # 5s alarm (perl, портативно — тот же приём, что в kimi-peer-adapter.sh): демон-скрипты
    # (while true; do ...; done без обработки --help) иначе висят здесь бесконечно —
    # нашлось на kimi-session-watchdog.sh, script-promote.sh завис на смоук-тесте.
    echo "   smoke-test с шаблонным окружением..."
    smoke_result=0
    env -i \
        HOME="/tmp/iwe-smoke-user" \
        IWE="/tmp/iwe-smoke-user/IWE" \
        IWE_GOVERNANCE_REPO="DS-strategy" \
        PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" \
        perl -e 'alarm 5; exec @ARGV' -- bash "$tmp_file" --help > /dev/null 2>&1 || smoke_result=$?

    # exit 0 = OK, exit 1 = validation error (приемлемо — скрипт без аргументов)
    # exit 127 = команда не найдена (зависимость сломана) — блокер
    # exit 142 = SIGALRM (perl alarm) — скрипт не завершился за 5с, похоже на демон
    # с циклом while true; это не баг зависимости, просто пропускаем дальше.
    if [[ $smoke_result -eq 127 ]]; then
        rm -rf "$tmp_dir"
        echo "❌ Smoke-тест: exit 127 — скрипт не может запуститься в чужом окружении." >&2
        echo "   Проверь зависимости (python3, jq, и т.п.) и абсолютные пути." >&2
        return 1
    fi
    if [[ $smoke_result -eq 142 ]]; then
        echo "   smoke-test: таймаут 5с (похоже на демон с бесконечным циклом, не блокер)"
    else
        echo "   smoke-test: OK (exit $smoke_result)"
    fi

    # Скопировать в FMT
    cp "$tmp_file" "$dest"
    chmod +x "$dest"
    rm -rf "$tmp_dir"

    echo ""
    echo "✅ Промотирован: FMT/scripts/$fname"
    return 0
}

finalize() {
    local changelog_script="$FMT_DIR/scripts/changelog-append.sh"
    [[ -f "$changelog_script" ]] && bash "$changelog_script"

    local manifest_script="$FMT_DIR/generate-manifest.sh"
    if [[ -f "$manifest_script" ]]; then
        echo "🔄 Пересборка update-manifest.json..."
        bash "$manifest_script" 2>&1
    else
        echo "⚠️  generate-manifest.sh не найден — обнови update-manifest.json вручную"
    fi
}

if $batch_all; then
    total=0 synced=0 skipped=0 failed=0
    for f in "$IWE"/scripts/*.sh "$IWE"/scripts/*.py; do
        [[ -f "$f" ]] || continue
        fname=$(basename "$f")
        [[ -f "$FMT_DIR/scripts/$fname" ]] || continue  # только общие файлы — новые сюда не добавляем автоматом
        total=$((total + 1))
        promote_one "$f"; rc=$?
        case "$rc" in
            0) synced=$((synced + 1)) ;;
            2) skipped=$((skipped + 1)) ;;
            *) failed=$((failed + 1)) ;;
        esac
        echo ""
    done

    echo "Итог --all: $total общих файлов · $synced промотировано · $skipped пропущено (разошлись — нужен ручной разбор + --force) · $failed ошибок"

    if $dry_run; then
        exit 0
    fi
    if [[ $synced -gt 0 ]]; then
        finalize
        echo "Следующий шаг:"
        echo "  cd $FMT_DIR && git status && git add scripts/ CHANGELOG.md update-manifest.json && git commit -m 'feat: promote scripts to platform (--all)'"
    fi
    [[ $skipped -eq 0 && $failed -eq 0 ]]
    exit $?
fi

promote_one "$SRC"
rc=$?
if [[ $rc -eq 0 ]] && ! $dry_run; then
    finalize
    echo "Следующий шаг:"
    echo "  cd $FMT_DIR && git add scripts/$(basename "$SRC") CHANGELOG.md update-manifest.json && git commit -m 'feat: promote $(basename "$SRC") to platform'"
fi
exit $rc
