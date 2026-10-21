#!/bin/bash
# iwe-bug-report.sh — wrapper for the skill /iwe-bug-report
# Usage: ./iwe-bug-report.sh "problem description"

set -e

PROBLEM="$*"

if [ -z "$PROBLEM" ]; then
  echo "Usage: $0 \"problem description\""
  exit 1
fi

# Path to FMT-template
FMT_PATH="${IWE_FMT_PATH:-$HOME/IWE/IWE}"
if [ ! -d "$FMT_PATH" ]; then
  echo "Error: FMT not found. Set IWE_FMT_PATH or check ~/IWE/IWE"
  exit 1
fi

# Checking gh CLI
if ! command -v gh &> /dev/null; then
  echo "Error: gh CLI is not installed. Install: brew install gh && gh auth login"
  exit 1
fi

if ! gh auth status &> /dev/null; then
  echo "Error: gh is not authenticated. Run: gh auth login"
  exit 1
fi

# Get IWE version IWE
IWE_VERSION=$(cd "$FMT_PATH" && git log -1 --format="%h %ad" --date=short 2>/dev/null || echo "unknown")

# Categories (simple detection by keywords)
CATEGORY="enhancement"  # default
if echo "$PROBLEM" | grep -iq "error\|crashes\|crashed\|does not work"; then
  CATEGORY="bug"
elif echo "$PROBLEM" | grep -iq "documentation\|description\|readme"; then
  CATEGORY="docs"
fi

# Title (first 80 characters including the category prefix)
PREFIX="[$CATEGORY] "
MAX_LEN=$((80 - ${#PREFIX}))
TITLE="${PREFIX}${PROBLEM:0:$MAX_LEN}"

# Date
DATE=$(date +%Y-%m-%d)

# Create issue
echo "📝 Creating issue in IWE..."

BODY=$(cat <<BODY
## What happened

$PROBLEM

## Context

- Date: $DATE
- IWE commit: $IWE_VERSION
BODY
)

if OUTPUT=$(gh issue create \
  --repo iwesys/IWE \
  --title "$TITLE" \
  --label "$CATEGORY" \
  --body "$BODY" 2>&1); then
  echo "✅ Issue created:"
  echo "$OUTPUT"
else
  echo "❌ Error while creating issue:"
  echo "$OUTPUT"
  exit 1
fi
