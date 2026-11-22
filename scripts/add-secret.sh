#!/usr/bin/env bash
# routing: utility  deterministic=true
# add-secret.sh — a unified way to save any API-key/token in ~/.secrets/
#
# Input is hidden (read -s) — the value is not displayed on screen and does not get stored
# in the terminal command history. File permissions are set automatically (600).. File permissions are set automatically (600).
#
# Usage:
#   bash add-secret.sh <name_key>
#
# Example:
#   bash add-secret.sh openai_api_key
#   → will prompt for value hidden, will save to ~/.secrets/openai_api_key

set -euo pipefail

if [ $# -ne 1 ]; then
  echo "Usage: $0 <name_of key>" >&2
  echo "Example: $0 openai_api_key" >&2
  exit 1
fi

name="$1"
dir="$HOME/.secrets"
target="$dir/$name"

mkdir -p "$dir"
chmod 700 "$dir"

if [ -e "$target" ]; then
  read -rp "File '$target' already exists. Overwrite? [y/N]: " confirm
  case "$confirm" in
    y|Y) ;;
    *) echo "Cancelled."; exit 1 ;;
  esac
fi

read -rs -p "Value for '$name' (input hidden): " value
echo

if [ -z "$value" ]; then
  echo "Empty — nothing saved." >&2
  exit 1
fi

printf '%s' "$value" > "$target"
chmod 600 "$target"

echo "Saved: $target ($(wc -c < "$target") bytes)"
