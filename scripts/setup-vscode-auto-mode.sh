#!/usr/bin/env bash
# routing: utility  deterministic=true
# see DP.SC.159, DP.ROLE.059
# setup-vscode-auto-mode.sh — default the VS Code Claude Code extension to
# Auto permission mode for a fresh install (WP-406, VS Code onboarding track).
#
# Without this, every new VS Code window starts in Manual (ask before each
# edit) regardless of the mode a person picked in a previous window, because
# the extension's own default is Manual when the setting is unset.
#
# Only touches the person's own global VS Code settings.json:
#  - Skips silently if VS Code is not installed (no User settings directory)
#  - Adds claudeCode.initialPermissionMode only if the key is absent —
#    never overwrites a choice the person already made
#  - Backs up an existing file before writing; a file that fails to parse
#    as JSON (e.g. hand-written comments) is left untouched
#
# Usage:
#   bash scripts/setup-vscode-auto-mode.sh          # apply
#   bash scripts/setup-vscode-auto-mode.sh --check  # dry run, no changes

set -euo pipefail

MODE="${1:-apply}"

CANDIDATE_DIRS=(
    "$HOME/Library/Application Support/Code/User"  # macOS
    "$HOME/.config/Code/User"                       # Linux
)

for dir in "${CANDIDATE_DIRS[@]}"; do
    [ -d "$dir" ] || continue
    settings="$dir/settings.json"

    if [ "$MODE" = "--check" ]; then
        echo "  [vscode-auto-mode] [DRY RUN] Would ensure claudeCode.initialPermissionMode=auto in $settings"
        continue
    fi

    python3 - "$settings" <<'PYEOF'
import json
import os
import sys

path = sys.argv[1]
KEY = "claudeCode.initialPermissionMode"

if os.path.exists(path):
    with open(path, encoding="utf-8") as f:
        raw = f.read()
    try:
        data = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError:
        print(f"  [vscode-auto-mode] {path}: не распарсен как JSON (возможно, комментарии) — пропущено")
        sys.exit(0)
    if not isinstance(data, dict):
        print(f"  [vscode-auto-mode] {path}: верхний уровень не объект — пропущено")
        sys.exit(0)
    if KEY in data:
        print(f"  [vscode-auto-mode] {path}: {KEY} уже задан ({data[KEY]!r}) — не трогаем")
        sys.exit(0)
    with open(path + ".bak", "w", encoding="utf-8") as f:
        f.write(raw)
else:
    data = {}

data[KEY] = "auto"
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
print(f"  [vscode-auto-mode] {path}: {KEY}=auto")
PYEOF

done
