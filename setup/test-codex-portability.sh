#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

python3 -c 'import json, pathlib; json.loads(pathlib.Path(".codex/hooks.json").read_text())' \
  2>/dev/null || { echo "FAIL: invalid .codex/hooks.json" >&2; exit 1; }
python3 -c 'import pathlib, tomllib; tomllib.loads(pathlib.Path(".codex/config.toml").read_text())' \
  2>/dev/null || { echo "FAIL: invalid .codex/config.toml" >&2; exit 1; }

IWE_ROOT="$REPO_ROOT" bash "$REPO_ROOT/scripts/sync-agent-instructions.sh" --check >/dev/null
bash "$REPO_ROOT/scripts/sync-codex-skills.sh" --check >/dev/null
bash -n "$REPO_ROOT/scripts/codex-headless-adapter.sh"
bash -n "$REPO_ROOT/scripts/install-codex-runtime.sh"

install_target="$(mktemp -d)"
trap 'rm -rf "$install_target"' EXIT
bash "$REPO_ROOT/scripts/install-codex-runtime.sh" "$install_target" >/dev/null
[ -f "$install_target/AGENTS.md" ]
[ -f "$install_target/.agents/skills/day-open/SKILL.md" ]
[ -f "$install_target/.codex/config.toml" ]
[ -f "$install_target/.codex/hooks/iwe-hook-adapter.py" ]
# Existing user config is seed-only and must survive a refresh.
printf '# user config\n' > "$install_target/.codex/config.toml"
bash "$REPO_ROOT/scripts/install-codex-runtime.sh" "$install_target" >/dev/null
grep -q '^# user config$' "$install_target/.codex/config.toml"

source_skill_count="$(find "$REPO_ROOT/.claude/skills" -mindepth 1 -maxdepth 1 -type d | wc -l)"
codex_skill_count="$(find "$REPO_ROOT/.agents/skills" -mindepth 1 -maxdepth 1 -type d | wc -l)"
if [ "$source_skill_count" -ne "$codex_skill_count" ]; then
  echo "FAIL: Codex skill inventory differs from canonical inventory" >&2
  exit 1
fi

if rg -n '^  executor: (opus|sonnet|haiku)$|^  model: (opus|sonnet|haiku)$' \
  "$REPO_ROOT/.agents/skills" --glob 'SKILL.md' >/dev/null; then
  echo "FAIL: generated skills contain provider-specific execution metadata" >&2
  exit 1
fi

if printf '%s\n' '{"tool_input":{"command":"git reset --hard HEAD"}}' \
  | bash "$REPO_ROOT/.claude/hooks/destructive-guard.sh" >/dev/null 2>&1; then
  echo "FAIL: destructive guard allowed git reset --hard" >&2
  exit 1
fi

printf '%s\n' '{"tool_input":{"command":"git status --short"}}' \
  | bash "$REPO_ROOT/.claude/hooks/destructive-guard.sh" >/dev/null

echo "PASS: Codex config, generated skills, adapter, and safety hook"
