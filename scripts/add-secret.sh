#!/usr/bin/env bash
# routing: utility  deterministic=true
# add-secret.sh — единый способ сохранить любой API-ключ/токен в ~/.secrets/
#
# Ввод скрыт (read -s) — значение не отображается на экране и не попадает
# в историю команд терминала. Права на файл выставляются автоматически (600).
#
# Использование:
#   bash add-secret.sh <имя_ключа>
#
# Пример:
#   bash add-secret.sh openai_api_key
#   → спросит значение скрыто, сохранит в ~/.secrets/openai_api_key

set -euo pipefail

if [ $# -ne 1 ]; then
  echo "Использование: $0 <имя_ключа>" >&2
  echo "Пример: $0 openai_api_key" >&2
  exit 1
fi

name="$1"
dir="$HOME/.secrets"
target="$dir/$name"

mkdir -p "$dir"
chmod 700 "$dir"

if [ -e "$target" ]; then
  read -rp "Файл '$target' уже существует. Перезаписать? [y/N]: " confirm
  case "$confirm" in
    y|Y) ;;
    *) echo "Отменено."; exit 1 ;;
  esac
fi

read -rs -p "Значение для '$name' (ввод скрыт): " value
echo

if [ -z "$value" ]; then
  echo "Пусто — ничего не сохранено." >&2
  exit 1
fi

printf '%s' "$value" > "$target"
chmod 600 "$target"

echo "Сохранено: $target ($(wc -c < "$target") байт)"
