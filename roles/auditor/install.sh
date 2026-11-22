#!/bin/bash
# Install Auditor role
# No launchd — auditor is invoked on-demand or via Day Open / strategy session
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Auditor role installed (on-demand, no scheduled jobs)."
echo "  Auto:  Day Open → plan consistency check"
echo "  Auto:  Strategy session → full WP audit"
echo "  Usage: 'check coverage of X' or 'audit plans'"
echo "  Prompts: $SCRIPT_DIR/prompts/"