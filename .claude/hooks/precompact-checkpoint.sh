#!/bin/bash
# PreCompact Checkpoint Hook
# Event: PreCompact
# Перед компрессией контекста сохраняет checkpoint: что осталось сделать.
# Записывает в .claude/checkpoint.md (gitignored).
# issue #1183: для PreCompact НЕ существует канала, доставляющего текст агенту —
# в документации Claude Code hooks у PreCompact нет секции Decision Control,
# hookSpecificOutput для этого события невалиден, а stderr/stdout при exit 2
# до агента не доходят. systemMessage — общее верхнеуровневое поле, его видит
# только пользователь. Issue остаётся открытым: возможна смена назначения хука.

INPUT=$(cat)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
PROJECT_DIR="${CWD:-$(pwd)}"
CHECKPOINT_FILE="$PROJECT_DIR/.claude/checkpoint.md"

# Напоминание (его увидит пользователь, не агент) — сохранить контекст перед компрессией
CTX="⚠️ PRECOMPACT: Контекст будет сжат. Перед продолжением прочитай .claude/checkpoint.md если он есть. Запиши в него: (1) Над каким РП работаешь, (2) Что осталось сделать, (3) Какой протокол выполняешь и на каком шаге, (4) Незавершённые шаги протокола (включая верификацию)."
jq -n --arg ctx "$CTX" '{"systemMessage": $ctx}'
exit 0
