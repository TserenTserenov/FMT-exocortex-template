#!/usr/bin/env bash
# claude-hook: false — standalone wrapper called directly by peer adapter
# scripts (not a settings.json hook event); see check-orphan-hooks.sh.
# style-check-text.sh <agent> <text-file> — thin wrapper feeding one agent's
# reply text through the shared response-clarity-hook.sh core (РП-388 Ф17).
#
# One core, two wrappers: Kimi and Codex route through this instead of a
# separate per-agent reimplementation (the dead style-check-post-run.sh had
# its own log file and its own rule numbering — agregator couldn't see it).
#
# Builds a synthetic two-row JSONL transcript (same shape run_case() in
# tests/test-response-clarity-hook.sh already builds) and feeds it to the
# hook on stdin with STYLE_AGENT set, so the shared log carries the right
# agent column.
#
# Always exits 0 — this is a style nudge, never a gate.

set -uo pipefail

AGENT_NAME="${1:-}"
TEXT_FILE="${2:-}"

if [ -z "$AGENT_NAME" ] || [ -z "$TEXT_FILE" ] || [ ! -f "$TEXT_FILE" ]; then
  exit 0
fi

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HOOKS_DIR/response-clarity-hook.sh"

TMP_TRANSCRIPT=$(mktemp)
trap 'rm -f "$TMP_TRANSCRIPT"' EXIT

TEXT_FILE="$TEXT_FILE" python3 - "$TMP_TRANSCRIPT" <<'PY' 2>/dev/null || true
import json, os, sys
path = sys.argv[1]
with open(os.environ["TEXT_FILE"], encoding="utf-8") as f:
    reply = f.read()
rows = [
    {"type": "user", "message": {"content": [{"type": "text", "text": "ход напарника"}]}},
    {"type": "assistant", "message": {"content": [{"type": "text", "text": reply}]}},
]
with open(path, "w", encoding="utf-8") as fh:
    for r in rows:
        fh.write(json.dumps(r, ensure_ascii=False) + "\n")
PY

printf '{"transcript_path":"%s","session_id":"style-check-%s"}' "$TMP_TRANSCRIPT" "$AGENT_NAME" \
  | STYLE_AGENT="$AGENT_NAME" bash "$HOOK" >/dev/null 2>&1 || true

exit 0
