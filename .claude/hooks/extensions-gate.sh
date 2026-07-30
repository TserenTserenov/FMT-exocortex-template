#!/bin/bash
# Extensions Gate Hook
# Event: PreToolUse (matcher: Edit, Write)
# Блокирует прямое редактирование .claude/skills/ и memory/protocol-*.md
#
# Исключения:
#   - FMT-exocortex-template (шаблон — всегда разрешён)
#   - author_mode: true в params.yaml (автор шаблона — source-of-truth в IWE,
#     пропагация в FMT через template-sync.sh)
#   - issue #311: новая директория .claude/skills/<name>/, которой нет в
#     update-manifest.json — свой навык, update.sh её не тронет. extend/SKILL.md
#     документирует ровно этот путь как штатный, гейт не должен его перекрывать.

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# Проверяем: это L1 файл?
if echo "$FILE_PATH" | grep -qE '\.claude/skills/|memory/protocol-'; then

  # Исключение 1: FMT-exocortex-template — всегда разрешён
  if echo "$FILE_PATH" | grep -q 'FMT-exocortex-template'; then
    exit 0
  fi

  WORKSPACE_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

  # Исключение 2: author_mode в params.yaml
  if [ -f "$WORKSPACE_DIR/params.yaml" ] && grep -qE '^author_mode:\s*true' "$WORKSPACE_DIR/params.yaml" 2>/dev/null; then
    exit 0
  fi

  # Исключение 3 (issue #311): свой навык — .claude/skills/<name>/ отсутствует
  # в манифесте платформы, update.sh его не затронет и не затрёт.
  # Требуем ИМЕННО поддиректорию (name/...) — плоский файл прямо в .claude/skills/
  # (напр. SKILL-INDEX.yaml, платформенный манифест-файл) НЕ подпадает под это
  # исключение и должен падать в блокировку ниже как раньше. Без этого якоря sed
  # на непарном пути не находит совпадения и молча пропускает FILE_PATH целиком —
  # такой SKILL_NAME никогда не совпадёт в манифесте → гейт открывался бы для
  # любого файла прямо в .claude/skills/ (найдено код-ревью).
  if echo "$FILE_PATH" | grep -qE '\.claude/skills/[^/]+/'; then
    SKILL_NAME=$(echo "$FILE_PATH" | sed -E 's#.*\.claude/skills/([^/]+)/.*#\1#')
    MANIFEST="$WORKSPACE_DIR/update-manifest.json"
    if [ -n "$SKILL_NAME" ] && [ -f "$MANIFEST" ]; then
      IN_MANIFEST=$(jq -r --arg prefix ".claude/skills/${SKILL_NAME}/" \
        '.files[]? | select(.path | startswith($prefix)) | .path' \
        "$MANIFEST" 2>/dev/null | head -1)
      if [ -z "$IN_MANIFEST" ]; then
        exit 0
      fi
    fi
  fi

  # Блокировать для обычных пользователей
  echo '{"decision": "block", "reason": "⛔ Extensions Gate: платформенные (L1) и пользовательские (L3) файлы — разные слои. Правило (CLAUDE.md §9): Авторская кастомизация → extensions/*.md. Платформенное изменение → FMT-exocortex-template → update.sh. Смешение слоёв = хрупкость при обновлении. Создай или обнови нужный файл в extensions/."}'
  exit 0
fi

# Разрешить редактирование обычных файлов
echo '{}'
exit 0
