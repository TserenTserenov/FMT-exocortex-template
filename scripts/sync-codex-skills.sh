#!/usr/bin/env bash
# Generate Codex project skills from the canonical IWE skills.
#
# .claude/skills remains the source of truth until the repository adopts an
# agent-neutral source directory. Files under .agents/skills are generated and
# must not be edited directly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_DIR="$REPO_ROOT/.claude/skills"
TARGET_DIR="$REPO_ROOT/.agents/skills"
MODE="${1:---check}"

usage() {
  echo "Usage: $0 [--check|--force]"
}

case "$MODE" in
  --check|--force) ;;
  --help|-h) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

if [ ! -d "$SOURCE_DIR" ]; then
  echo "[ERROR] Missing canonical skills directory: $SOURCE_DIR" >&2
  exit 1
fi

# Keep transformations deterministic and deliberately narrow. Product names
# that describe an actual integration (for example a Kimi/Claude peer adapter
# or an Anthropic key detector) remain untouched: changing those would remove
# functionality. Only paths into the skill tree, tool vocabulary, and model-
# specific execution hints are made portable.
render_file() {
  local source="$1"
  sed -E \
    -e 's#\.claude/skills/#.agents/skills/#g' \
    -e 's#TodoWrite#update_plan#g' \
    -e 's#^([[:space:]]*)executor: (sonnet|haiku|opus)$#\1executor: agent#' \
    -e 's#^([[:space:]]*)model: (sonnet|haiku|opus)$#\1model: default#' \
    -e 's#Claude Opus#агент с высоким уровнем рассуждений#g' \
    -e 's#Claude Sonnet#агент со средним уровнем рассуждений#g' \
    -e 's#Claude Haiku#лёгкий агент#g' \
    -e 's#Sub-agent Haiku#Лёгкий субагент#g' \
    -e 's#sub-agent Haiku#лёгкий субагент#g' \
    -e 's#Субагент Haiku#Лёгкий субагент#g' \
    -e 's#субагент Haiku#лёгкий субагент#g' \
    -e 's#Haiku R23#лёгкий субагент R23#g' \
    -e 's#Модель sub-agent'"'"'а: Sonnet#Уровень рассуждений субагента: средний#g' \
    -e 's#Модель sub-agent'"'"'а: Opus#Уровень рассуждений субагента: высокий#g' \
    -e 's#Модель: Opus#Уровень рассуждений: высокий#g' \
    -e 's#Модель: Sonnet#Уровень рассуждений: средний#g' \
    -e 's#Модель: Haiku#Уровень рассуждений: низкий#g' \
    -e 's#Claude видит#Агент обнаруживает#g' \
    -e 's#Claude должен#Агент должен#g' \
    -e 's#[[:space:]]+$##' \
    "$source" | perl -0pe 's/\n+\z/\n/'
}

source_files() {
  find "$SOURCE_DIR" -type f -printf '%P\n' | LC_ALL=C sort
}

target_files() {
  [ -d "$TARGET_DIR" ] || return 0
  find "$TARGET_DIR" -type f -printf '%P\n' | LC_ALL=C sort
}

check_all() {
  local relative target failed=0

  while IFS= read -r relative; do
    [ -n "$relative" ] || continue
    target="$TARGET_DIR/$relative"
    if [ ! -f "$target" ] || ! diff -q <(render_file "$SOURCE_DIR/$relative") "$target" >/dev/null 2>&1; then
      echo "[DRIFT] .agents/skills/$relative" >&2
      failed=1
    fi
  done < <(source_files)

  # Exact inventory comparison catches stale generated files after an upstream
  # skill is renamed or removed, not merely changed/missing content.
  while IFS= read -r relative; do
    [ -n "$relative" ] || continue
    if [ ! -f "$SOURCE_DIR/$relative" ]; then
      echo "[EXTRA] .agents/skills/$relative" >&2
      failed=1
    fi
  done < <(target_files)

  return "$failed"
}

write_all() {
  local relative source target
  mkdir -p "$TARGET_DIR"

  # Remove only stale generated files; source skills and user data are never
  # touched. Empty directories are cleaned after generation.
  while IFS= read -r relative; do
    [ -n "$relative" ] || continue
    [ -f "$SOURCE_DIR/$relative" ] || rm -f "$TARGET_DIR/$relative"
  done < <(target_files)

  while IFS= read -r relative; do
    [ -n "$relative" ] || continue
    source="$SOURCE_DIR/$relative"
    target="$TARGET_DIR/$relative"
    mkdir -p "$(dirname "$target")"
    render_file "$source" > "$target"
    chmod --reference="$source" "$target"
  done < <(source_files)

  find "$TARGET_DIR" -depth -type d -empty -delete
}

if [ "$MODE" = "--force" ]; then
  write_all
  count="$(source_files | wc -l | tr -d ' ')"
  skills="$(find "$SOURCE_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
  echo "Codex skills generated: $skills skills, $count files"
else
  check_all
  echo "Codex skills: OK"
fi
