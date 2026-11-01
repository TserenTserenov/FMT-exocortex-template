#!/usr/bin/env bash
# routing: utility  deterministic=true
#
# check-shipped-config-secrets.sh — настройки, которые шаблон ставит
# пользователю как рабочие, не ссылаются на секреты и личные папки автора
# (WP-7, чистка шаблона 2026-11-01).
#
# Повод: шаблонный .mcp.json поставлял сервер ext-railway с командой из
# авторского каталога секретов ({{HOME_DIR}}/.secrets/...). У пользователей
# этого файла нет, и сервер падал при каждом запуске агента. Разовая чистка
# не защищает от повторения — эта проверка держит границу в CI.
#
# Что проверяется: только файлы, которые установка или обновление делают
# действующей настройкой пользователя (сливают или копируют как есть).
# Образцы (*.sample, *.example) пользователь копирует сам — они не
# проверяются. Код, который сам ищет необязательный токен в домашней папке
# (например scripts/iwe-grep-secret.sh), сюда тоже не относится.
#
# Использование: bash scripts/check-shipped-config-secrets.sh [FMT_DIR]

set -uo pipefail

FMT_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Действующие настройки: .mcp.json копируется установкой и обновлением,
# extensions/*.json вливаются в него, .claude/settings.json сливается
# с настройками пользователя.
CONFIG_FILES=(.mcp.json .claude/settings.json)
for f in "$FMT_DIR"/extensions/*.json; do
    [ -f "$f" ] && CONFIG_FILES+=("${f#"$FMT_DIR"/}")
done

# Каталог секретов в любом виде и абсолютные пути в чью-то домашнюю папку.
# Заготовки вроде {{HOME_DIR}}/.claude допустимы: путь ведёт в домашнюю
# папку самого пользователя, а не в каталог секретов.
# Буквальный /Users/ здесь — шаблон поиска, не путь: файл внесён в исключения
# сторожа захардкоженных путей (HARDCODE_USER_PATH_SKIP_FILES_RE в
# setup/validate-template.sh).
PATTERN='\.secrets/|/Users/[A-Za-z0-9._-]+/|/home/[A-Za-z0-9._-]+/|/root/'

fail=0
checked=0
for rel in "${CONFIG_FILES[@]}"; do
    file="$FMT_DIR/$rel"
    [ -f "$file" ] || continue
    checked=$((checked + 1))
    hits=$(grep -nE "$PATTERN" "$file" || true)
    if [ -n "$hits" ]; then
        echo "FAIL: $rel ссылается на секреты или личную папку — у пользователя этого пути нет"
        printf '%s\n' "$hits" | sed 's/^/    /'
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "  Фикс: вынесите такую настройку в образец (*.sample), который человек копирует и правит сам."
    exit 1
fi
echo "PASS: $checked файл(ов) настроек по умолчанию не ссылаются на секреты и личные папки"
exit 0
