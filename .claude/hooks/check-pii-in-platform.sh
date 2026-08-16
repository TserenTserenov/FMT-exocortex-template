#!/usr/bin/env bash
# PreToolUse: Edit|Write
# Blocks personal data (emails, real paths) from being written into platform files (L1).
# User-specific values must use {{PLACEHOLDER}} referencing params.yaml or day-rhythm-config.yaml.
# See CONTRIBUTING.md §Privacy & Placeholders.

set -euo pipefail

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# Only check platform files
if ! echo "$FILE_PATH" | grep -qE '\.claude/|FMT-exocortex-template/'; then
    echo '{}'
    exit 0
fi

# Get content being written (Edit uses new_string, Write uses content)
CONTENT=$(echo "$INPUT" | jq -r '.tool_input.new_string // .tool_input.content // empty')

[ -z "$CONTENT" ] && echo '{}' && exit 0

# Patterns that are explicitly safe: example domains, template placeholders, env var refs, doc annotations
SAFE_RE='example\.(com|org|net)|@domain\.|@host\.|{{[A-Z_]+}}|\$\{[A-Z_]+\}|your-email|user@example|admin@example|test@example|pii-exempt'

# Detect real email addresses
EMAILS=$(echo "$CONTENT" | grep -oE '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' \
    | grep -vE "$SAFE_RE" || true)

if [ -n "$EMAILS" ]; then
    FOUND=$(echo "$EMAILS" | head -3 | tr '\n' ' ' | sed 's/ $//')
    echo "{\"decision\": \"block\", \"reason\": \"⛔ PII Gate: email-адрес(а) в платформенном файле L1: [$FOUND]. Платформенные файлы используются всеми пользователями IWE — личные данные недопустимы. Замените на ключ конфига (например: day-rhythm-config.yaml → calendar_ids) или {{PLACEHOLDER}}. Подробнее: CONTRIBUTING.md §Privacy & Placeholders. Чтобы обойти для документации — добавьте # pii-exempt в ту же строку.\"}"
    exit 0
fi

echo '{}'
exit 0
