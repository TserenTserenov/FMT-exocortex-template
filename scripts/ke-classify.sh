#!/bin/bash
# ke-classify.sh — classifier captures-report for auto-batch
# see: peer-session 2026-05-30-07-gap-list-day-open sub-step 5
# see: WP-356 «Pipeline Day Open: auto-run checks»
#
# Purpose: determine, whether the report can be accepted automatically (Haiku/trivial)
#             or human review is required human-review.
#
# Algorithm (peer-consensus):
# 1. Primary: frontmatter `domain:` tag.
#    - domain not specified → auto-reject (pending-review, no tag).
#    - domain ∈ {system, infrastructure, meta-skill} → block auto-accept.
#    - domain ∈ {course-content, personal-notes, bot-conversation} → check Secondary.
#    - other domain → pending-review (unknown category).
# 2. Secondary (for allowed domain):
#    - Body size (without frontmatter) ≤30 lines
#    - No regex-regex matches on paths: `.claude/`, `scripts/`, `extensions/`, `memory/feedback_*.md`
#    Both conditions → auto-accept. Otherwise → pending-review.
#
# Output stdout as a single line:
#   AUTO_ACCEPT
#   PENDING_REVIEW: <reason>
#
# Usage:
#   bash ke-classify.sh <path-to-capture.md>
#
# Exit code:
#   0 — auto-accept
#   1 — pending-review (with reason in stdout)
#   2 — error (file not found / not readable)

set -uo pipefail

FILE="${1:-}"
if [ -z "$FILE" ] || [ ! -f "$FILE" ]; then
  echo "PENDING_REVIEW: file not found or not specified"
  exit 2
fi

# Extract domain tag from frontmatter
DOMAIN=$(awk '/^---$/{p++; next} p==1 && /^domain:/ {sub(/^domain:[[:space:]]*/, ""); gsub(/^["'"'"'[:space:]]+|["'"'"'[:space:]]+$/, ""); print; exit}' "$FILE" 2>/dev/null)

if [ -z "$DOMAIN" ]; then
  echo "PENDING_REVIEW: no domain tag in frontmatter"
  exit 1
fi

case "$DOMAIN" in
  system|infrastructure|meta-skill)
    echo "PENDING_REVIEW: domain=$DOMAIN (system/meta-skill never auto-accept)"
    exit 1
    ;;
  course-content|personal-notes|bot-conversation)
    # Allowed domain — continue checks
    ;;
  *)
    echo "PENDING_REVIEW: unknown domain=$DOMAIN"
    exit 1
    ;;
esac

# Body size (after frontmatter)
BODY_LINES=$(awk 'BEGIN{p=0} /^---$/{p++; next} p>=2 {print}' "$FILE" | wc -l | tr -d ' ')
if [ "$BODY_LINES" -gt 30 ]; then
  echo "PENDING_REVIEW: body too long ($BODY_LINES lines > 30)"
  exit 1
fi

# Regex regex on paths to code/feedback
if grep -qE '\.claude/|scripts/|extensions/|memory/feedback_' "$FILE"; then
  MATCHES=$(grep -oE '\.claude/[^[:space:]]*|scripts/[^[:space:]]*|extensions/[^[:space:]]*|memory/feedback_[^[:space:]]*' "$FILE" | head -2 | tr '\n' ' ')
  echo "PENDING_REVIEW: contains code/feedback paths ($MATCHES)"
  exit 1
fi

echo "AUTO_ACCEPT"
exit 0
