#!/usr/bin/env bash
# SessionStart — idempotent, best-effort activation of .githooks/ (WP-559 Ф2).
#
# GitHub's "generate from template" API copies repository files but not
# .git/config — so a repository forked through fork_platform_template ships
# .githooks/ present on disk but inactive until core.hooksPath points at it.
# This hook closes that gap the first time the repo is opened in Claude Code.
#
# Safety contract (round-loop design, Codex + Kimi, ArchGate passed 2026-08-30):
#   - never overwrite an already-configured core.hooksPath (could be the
#     user's own hooks, or another tool's);
#   - read the EFFECTIVE value (`git config --get`, not just --local) so a
#     global/worktree setting is respected too;
#   - best-effort only — any failure (read-only .git/config, sandboxed
#     checkout, no git repo at all) prints a note and exits 0, never blocks
#     SessionStart;
#   - visible outcome always: success, conflict, and failure all print a line.
set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0

GITHOOKS_DIR="$REPO_ROOT/.githooks"
[ -d "$GITHOOKS_DIR" ] || exit 0

CURRENT_HOOKSPATH=$(git config --get core.hooksPath 2>/dev/null || true)

if [ "$CURRENT_HOOKSPATH" = ".githooks" ]; then
  exit 0
fi

if [ -n "$CURRENT_HOOKSPATH" ]; then
  # Braces are required here, not stylistic: on this bash/locale combination,
  # a bare $VAR immediately followed by a non-ASCII byte (» below) gets
  # misparsed as part of the variable name — "unbound variable" under set -u
  # instead of the intended message (found by direct testing, WP-559 Ф2).
  echo "⚠️ [hooks-bootstrap] core.hooksPath уже установлен в «${CURRENT_HOOKSPATH}» — не переопределяю. Чтобы включить .githooks/ этого репозитория вручную: git config --local core.hooksPath .githooks" >&2
  exit 0
fi

if git config --local core.hooksPath .githooks 2>/dev/null; then
  echo "✅ [hooks-bootstrap] core.hooksPath настроен на .githooks — проверки перед коммитом активны."
  exit 0
fi

echo "⚠️ [hooks-bootstrap] не удалось настроить core.hooksPath (только чтение .git/config?). Вручную: git config --local core.hooksPath .githooks" >&2
exit 0
