#!/bin/bash
# llm-proxy-launcher.sh — wrapper for launching llm-proxy.py with OpenRouter secrets (WP-366 Phase4.A)
set -euo pipefail

OPENROUTER_ENV="$HOME/.secrets/openrouter_key.env"
if [ -f "$OPENROUTER_ENV" ]; then
  set -a
  source "$OPENROUTER_ENV"
  set +a
fi

if [ -z "${OPENROUTER_API_KEY:-}" ]; then
  echo "ERROR: OPENROUTER_API_KEY not set" >&2
  exit 1
fi

PORT="${1:-18765}"
exec python3 "$HOME/IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/llm-proxy.py" --port "$PORT"
