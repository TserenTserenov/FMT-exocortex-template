#!/usr/bin/env bash
# routing: utility  deterministic=true
# add-secret.sh — a single way to save any API key/token to ~/.secrets/
#
# Input is hidden (read -s) — the value is not shown on screen and does not end up
# in the terminal command history. File permissions are set automatically (600).
#
# Usage:
#   bash add-secret.sh <key_name>
#
# Example:
#   bash add-secret.sh openai_api_key
#   → will ask for the value silently, save to ~/.secrets/openai_api_key

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
