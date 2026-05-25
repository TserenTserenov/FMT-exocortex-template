#!/bin/bash
# routing: helper  skill=day-open  called-by=sonnet
# see DP.SC.159, DP.ROLE.059
# WP-316: Agent Fault Profile reminder wrapper
# Usage: bash scripts/agent_fault_remind.sh [open|close|work]

PROTOCOL="${1:-work}"
cd "$(dirname "$0")/.." || exit 1
python3 scripts/agent_fault_remind.py --protocol "$PROTOCOL"
