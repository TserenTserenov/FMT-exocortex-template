#!/bin/bash
# Install Verifier role
# No launchd — verifier is invoked on-demand (/verify) or via protocol-close
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Verifier role installed (on-demand, no scheduled jobs)."
echo "  Usage: /verify [artifact] — verify artifact against Pack reference"
echo "  Auto:  Session Close → Verification Gate (open-loop/problem-framing)"
echo "  Prompts: $SCRIPT_DIR/prompts/"
