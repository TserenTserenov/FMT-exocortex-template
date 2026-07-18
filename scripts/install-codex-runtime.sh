#!/usr/bin/env bash
# Install or refresh the Codex runtime in an existing IWE workspace.
# Platform files are refreshed; user-owned config.toml/hooks.json are seed-only.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE_DIR="${1:-${IWE_WORKSPACE:-$HOME/IWE}}"

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  echo "Usage: scripts/install-codex-runtime.sh [WORKSPACE_DIR]"
  exit 0
fi

[ -d "$WORKSPACE_DIR" ] || { echo "ERROR: workspace not found: $WORKSPACE_DIR" >&2; exit 2; }
[ -f "$TEMPLATE_DIR/AGENTS.md" ] || { echo "ERROR: template AGENTS.md missing" >&2; exit 2; }

mkdir -p "$WORKSPACE_DIR/.agents/skills" "$WORKSPACE_DIR/.codex/hooks"

# Generated platform content: exact refresh is safe because personal additions
# belong in USER-SPACE/extensions, not inside generated skill files.
cp -R "$TEMPLATE_DIR/.agents/skills/." "$WORKSPACE_DIR/.agents/skills/"
cp -R "$TEMPLATE_DIR/.codex/hooks/." "$WORKSPACE_DIR/.codex/hooks/"

# Aggregate Codex configuration can contain local MCP servers, approvals and
# secret environment references. Seed it, never overwrite it.
for file in config.toml hooks.json; do
  if [ ! -f "$WORKSPACE_DIR/.codex/$file" ]; then
    cp "$TEMPLATE_DIR/.codex/$file" "$WORKSPACE_DIR/.codex/$file"
    echo "  ✓ .codex/$file (seeded)"
  else
    echo "  ○ .codex/$file preserved"
  fi
done

# Install the generated instruction adapter and resolve standard placeholders.
cp "$TEMPLATE_DIR/AGENTS.md" "$WORKSPACE_DIR/AGENTS.md"
python3 - "$WORKSPACE_DIR/AGENTS.md" "$WORKSPACE_DIR" "$HOME" "$TEMPLATE_DIR" <<'PY'
from pathlib import Path
import sys

path, workspace, home, template = map(Path, sys.argv[1:])
text = path.read_text(encoding="utf-8")
replacements = {
    "{{WORKSPACE_DIR}}": str(workspace),
    "{{HOME_DIR}}": str(home),
    "{{IWE_TEMPLATE}}": str(template),
    "{{IWE_RUNTIME}}": str(workspace / ".iwe-runtime"),
}
for key, value in replacements.items():
    text = text.replace(key, value)
path.write_text(text, encoding="utf-8")
PY

echo "  ✓ AGENTS.md"
echo "  ✓ .agents/skills ($(find "$WORKSPACE_DIR/.agents/skills" -type f | wc -l | tr -d ' ') files)"
echo "  ✓ .codex/hooks"
echo "Codex runtime installed in $WORKSPACE_DIR"
