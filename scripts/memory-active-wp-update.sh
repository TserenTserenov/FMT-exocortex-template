#!/usr/bin/env bash
# routing: helper  skill=day-close,week-close  called-by=haiku
# see DP.SC.159, DP.ROLE.059
# memory-active-wp-update.sh — update the "Current WPs" section in MEMORY.md
# from the results of active-wp-sweep.sh.
# see WP-283 Phase 8 (DS-strategy/inbox/WP-283-server-day-open-crossplatform.md)
#
# Usage:
#   bash memory-active-wp-update.sh [IWE_ROOT]
#
# Looks for markers <!-- ACTIVE-WP-START --> and <!-- ACTIVE-WP-END --> in MEMORY.md,
# replaces the content between them with fresh sweep-output.
# Idempotent: a repeated run does not change the file if the state has not changed.
#
# Compatibility: bash 3.2+ (macOS), bash 4+ (Linux/NixOS)

set -uo pipefail

IWE="${1:-${IWE_ROOT:-$HOME/IWE}}"
GOV_REPO="${IWE_GOVERNANCE_REPO:-DS-strategy}"
MEMORY_FILE="$IWE/memory/MEMORY.md"
SWEEP_SCRIPT="$IWE/scripts/active-wp-sweep.sh"
# Fallback: template checked out as a nested subdir (author-mode-style layout)
# instead of being delivered to workspace root by update.sh/setup.sh (#242).
[ -f "$SWEEP_SCRIPT" ] || SWEEP_SCRIPT="$IWE/FMT-exocortex-template/scripts/active-wp-sweep.sh"
INBOX_DIR="$IWE/$GOV_REPO/inbox"

START_MARKER="<!-- ACTIVE-WP-START -->"
END_MARKER="<!-- ACTIVE-WP-END -->"

# --- Checks ---
if [[ ! -f "$MEMORY_FILE" ]]; then
  echo "ERROR: MEMORY.md не найден: $MEMORY_FILE" >&2
  exit 1
fi

if [[ ! -f "$SWEEP_SCRIPT" ]]; then
  echo "ERROR: active-wp-sweep.sh не найден: $SWEEP_SCRIPT" >&2
  exit 1
fi

if ! grep -qF "$START_MARKER" "$MEMORY_FILE"; then
  echo "INFO: маркер $START_MARKER не найден в MEMORY.md — пропускаю (добавь маркеры вручную)" >&2
  exit 0
fi

# --- Run sweep ---
SWEEP_OUT=$(bash "$SWEEP_SCRIPT" "$INBOX_DIR" "$IWE" 2>/dev/null) || true

if [[ -z "$SWEEP_OUT" ]]; then
  SWEEP_OUT="<!-- active-wp-sweep: нет активных РП или python3+yaml не найден -->"
fi

# --- Build the new block ---
TIMESTAMP=$(date +"%Y-%m-%d %H:%M" 2>/dev/null || echo "?")
NEW_BLOCK="${START_MARKER}
${SWEEP_OUT}
> _Обновлено: ${TIMESTAMP} (memory-active-wp-update.sh)_
${END_MARKER}"

# --- Idempotency check: compare the current block with the new one ---
CURRENT_BLOCK=$(awk "/$START_MARKER/{found=1} found{print} /$END_MARKER/{found=0}" "$MEMORY_FILE" 2>/dev/null)

if [[ "$CURRENT_BLOCK" == *"${SWEEP_OUT}"* ]]; then
  echo "INFO: MEMORY.md уже актуален — изменений нет" >&2
  exit 0
fi

# --- Replace the block via Python (safe multi-line replacement) ---
# Pass data via env-vars with a quoted heredoc <<'PYEOF' — bash does NOT expand
# special characters (`backticks`, $(...), \n, """) inside NEW_BLOCK. Protects against
# heredoc injection on odd WP titles (Opus review WP-283 #1).
export MEMORY_PATH="$MEMORY_FILE"
export START_MARKER_ENV="$START_MARKER"
export END_MARKER_ENV="$END_MARKER"
export NEW_BLOCK_ENV="$NEW_BLOCK"

python3 - <<'PYEOF'
import os, re, sys

memory_path = os.environ['MEMORY_PATH']
start = os.environ['START_MARKER_ENV']
end = os.environ['END_MARKER_ENV']
new_block = os.environ['NEW_BLOCK_ENV']

try:
    # Если runtime memory read-only — fallback на exocortex source-of-truth
    exocortex_path = os.environ.get('EXOCORTEX_MEMORY', memory_path)
    target_path = memory_path
    if not os.access(memory_path, os.W_OK):
        if os.path.exists(exocortex_path) and os.access(exocortex_path, os.W_OK):
            target_path = exocortex_path
            print(f"INFO: runtime memory read-only, using exocortex: {target_path}", file=sys.stderr)
        else:
            print(f"ERROR: neither runtime nor exocortex MEMORY.md is writable", file=sys.stderr)
            sys.exit(1)

    with open(target_path, 'r', encoding='utf-8') as f:
        content = f.read()

    pattern = re.escape(start) + r'.*?' + re.escape(end)
    # Backslashes в new_block мог бы ломать re.sub (трактуются как backreferences).
    # Используем callable replacement для буквальной подстановки.
    new_content = re.sub(pattern, lambda m: new_block, content, flags=re.DOTALL)

    if new_content == content:
        print("INFO: нет изменений", file=sys.stderr)
        sys.exit(0)

    with open(target_path, 'w', encoding='utf-8') as f:
        f.write(new_content)

    print("OK: MEMORY.md обновлён", file=sys.stderr)

except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
