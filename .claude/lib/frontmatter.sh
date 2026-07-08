#!/bin/bash
# frontmatter.sh — shared YAML frontmatter field reader
# Extracted from scripts/memory-validate.sh (issue #229) so update.sh's
# repair_pass() can check owner:/horizon: without duplicating the awk.
# Usage: source "$SCRIPT_DIR/.claude/lib/frontmatter.sh"

[ -n "${_IWE_FRONTMATTER_SOURCED:-}" ] && return 0
_IWE_FRONTMATTER_SOURCED=1

# get_field <file> <field> — print the value of a top-level frontmatter field.
# Strips surrounding quotes and leading/trailing whitespace (incl. CR, so
# CRLF-saved files don't break exact-match callers like update.sh's owner:user
# guard — issue #229 review). Empty output if the file has no frontmatter,
# the field is absent, or f is not exactly 1 (field must be inside the FIRST
# --- ... --- block).
get_field() {
    local file="$1" field="$2"
    awk '/^---/{f++} f==1 && /^'"$field"':/{gsub(/^[^:]+: */,""); gsub(/["'"'"']/,""); gsub(/^[ \t]+|[ \t\r]+$/,""); print; exit}' "$file"
}
