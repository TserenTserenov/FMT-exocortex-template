#!/bin/bash
# routing: migration  one-time=true
# see issue #305 (TserenTserenov/FMT-exocortex-template)
# migrate-nested-strategy.sh — flattens <governance-repo>/strategy/* up to <governance-repo>/.
#
# Что делает:
#   Переносит содержимое вложенной strategy/ (docs, inbox, current, archive,
#   decisions, drafts, personal, CLAUDE.md, REPO-TYPE.md) на верхний уровень
#   governance-репозитория (DS-strategy по умолчанию) через `git mv` —
#   история файлов сохраняется. Разбирает два известных конфликта слияния:
#     - scripts/ — переносит файлы по одному, падает при коллизии имён
#       (не перезаписывает существующий файл на верхнем уровне)
#     - exocortex/ — удаляет вложенную копию, ТОЛЬКО если та содержит
#       ровно один пустой .gitkeep; иначе падает, не трогая содержимое
#
# Когда нужен:
#   Установка получила вложенность <governance-repo>/strategy/... вместо
#   плоской <governance-repo>/... — сценарий из issue #305 (cp -r в
#   существующую non-git директорию при повторном запуске setup.sh после
#   сорванной первой установки). Коммит 16455c0 закрывает появление НОВОЙ
#   вложенности при переустановке — этот скрипт нужен только для уже
#   пострадавших установок, которых фикс 16455c0 не касается (см. issue).
#
# ИЗВЕСТНОЕ ОГРАНИЧЕНИЕ: проверен на одной подтверждённой пострадавшей
# установке (см. PR, воспроизведение до/после фикса 16455c0). Логика
# слияния scripts/ и exocortex/ рассчитана на конфликты, найденные именно
# там. При другой форме конфликта скрипт падает с понятной ошибкой вместо
# угадывания (данные не портит), но и не чинит автоматически — читай вывод
# и разбирайся вручную в этом случае.
#
# Usage:
#   bash scripts/migrate-nested-strategy.sh [--workspace PATH] [--repo NAME]
#
# Безопасность:
#   - Идемпотентен: повторный запуск при уже плоской структуре — no-op (exit 0)
#   - Требует чистое рабочее дерево (`git status --porcelain` пусто) — не
#     смешивает миграцию с несвязанными правками
#   - Все операции — git mv/git rm (стейджатся, не коммитятся): до коммита
#     откатить можно `git reset --hard HEAD` в governance-репозитории
#
# Exit codes:
#   0 — успех (перенесено, или уже нечего переносить)
#   1 — некорректные аргументы / репозиторий не найден / грязное дерево /
#       конфликт, который скрипт не умеет разобрать автоматически
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_DIR="$(dirname "$SCRIPT_DIR")"
DEFAULT_WORKSPACE="$(dirname "$TEMPLATE_DIR")"

WORKSPACE_DIR="$DEFAULT_WORKSPACE"
GOV_REPO="${IWE_GOVERNANCE_REPO:-DS-strategy}"

while [ $# -gt 0 ]; do
    case "$1" in
        --workspace) WORKSPACE_DIR="$2"; shift 2 ;;
        --repo)      GOV_REPO="$2"; shift 2 ;;
        --help|-h)
            grep '^#' "$0" | head -36
            exit 0
            ;;
        *)
            echo "ERROR: Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

WORKSPACE_DIR="${WORKSPACE_DIR/#\~/$HOME}"
REPO_ROOT="$WORKSPACE_DIR/$GOV_REPO"

if [ ! -d "$REPO_ROOT/.git" ]; then
  echo "ERROR: $REPO_ROOT — не git-репозиторий (.git не найден)." >&2
  exit 1
fi
cd "$REPO_ROOT"

if [ ! -d strategy ]; then
  echo "Нечего переносить: $REPO_ROOT/strategy/ не найдена — похоже, миграция уже выполнена или установка не затронута."
  exit 0
fi

if [ -n "$(git status --porcelain)" ]; then
  echo "ERROR: рабочее дерево $REPO_ROOT не чистое. Закоммить или отложи текущие изменения перед миграцией." >&2
  git status --short >&2
  exit 1
fi

echo "== Перенос содержимого strategy/ на верхний уровень $REPO_ROOT =="

PLAIN_ITEMS=(CLAUDE.md REPO-TYPE.md archive current decisions docs drafts inbox personal)
for item in "${PLAIN_ITEMS[@]}"; do
  if [ -e "strategy/$item" ]; then
    echo "  git mv strategy/$item -> $item"
    if ! git mv "strategy/$item" "$item" 2>/dev/null; then
      # git mv's only failure mode here is "no tracked content under this
      # dir yet" (e.g. an empty dir missing its .gitkeep) — nothing tracked
      # at the old path means there's nothing to stage a deletion for.
      mv "strategy/$item" "$item"
      git add -A -- "$item"
    fi
  fi
done

# scripts/: merge — governance repo root may already have its own scripts.
if [ -d strategy/scripts ]; then
  for f in strategy/scripts/*; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    if [ -e "scripts/$base" ]; then
      echo "ERROR: scripts/$base already exists at repo root — manual merge needed for $f." >&2
      exit 1
    fi
    echo "  git mv $f -> scripts/$base"
    git mv "$f" "scripts/$base"
  done
  rmdir strategy/scripts 2>/dev/null || true
fi

# exocortex/: only drop the nested copy if it's a placeholder-only seed
# (single empty .gitkeep). Anything else — stop, don't guess which copy
# of a possibly-real backup is the one to keep.
if [ -d strategy/exocortex ]; then
  ex_files="$(find strategy/exocortex -mindepth 1 2>/dev/null || true)"
  if [ "$ex_files" = "strategy/exocortex/.gitkeep" ] && [ ! -s strategy/exocortex/.gitkeep ]; then
    echo "  git rm strategy/exocortex/.gitkeep (пустой плейсхолдер)"
    git rm --quiet strategy/exocortex/.gitkeep
    rmdir strategy/exocortex 2>/dev/null || true
  else
    echo "ERROR: strategy/exocortex/ содержит не только пустой .gitkeep — известная логика слияния сюда не подходит." >&2
    echo "  Разберись вручную: что в strategy/exocortex/ vs $REPO_ROOT/exocortex/ — какая копия реальная." >&2
    find strategy/exocortex -type f >&2
    exit 1
  fi
fi

# git rm/mv already prune now-empty leading directories as a side effect,
# so strategy/ may be gone already by this point — that's success, not
# something to re-check or re-remove.
if [ -d strategy ]; then
  remaining="$(find strategy -mindepth 1 2>/dev/null || true)"
  if [ -n "$remaining" ]; then
    echo "ERROR: после переноса в strategy/ остались файлы — миграция неполная, разберись вручную:" >&2
    echo "$remaining" >&2
    exit 1
  fi
  rmdir strategy 2>/dev/null || true
fi

echo
echo "== Перенос завершён. Статус git (staged): =="
git status --short
echo
echo "Дальше: проверь работоспособность скриптов/валидаторов, затем закоммить перенос отдельным коммитом."
