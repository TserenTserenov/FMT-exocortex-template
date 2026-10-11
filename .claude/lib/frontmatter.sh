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
#
# issue #281: Claude Code's native auto-memory writes type/horizon/domains/
# status/valid_from/owner/schema_version NESTED under a `metadata:` key
# instead of top-level — a second, independently-evolving frontmatter dialect
# next to the flat one this reader was built for (issue #229/#217). Top-level
# match still wins when present (existing flat files keep working unchanged);
# only when no top-level match is found do we look inside `metadata:` (first
# line at column 0 that isn't blank closes the block).
#
# issue #1147: a columnar YAML list (`key:` with an empty value followed by
# `- item` lines) is now collected too — both top-level and nested one level
# under `metadata:` — and returned in the inline `[a, b]` format the codebase
# uses (memory-migrate.sh's infer_domains, spec §3 `domains: [тег1, тег2]`),
# so consumers (memory-validate.sh, memory-migrate.sh) see one consistent
# value regardless of which serialization the author wrote. When BOTH a
# scalar/inline value AND a columnar list exist for the same key (conflicting
# forms, in either location), a warning goes to stderr and the returned value
# is deterministic: the scalar/inline one wins, because flat is the canonical
# form (spec §3). Otherwise precedence is unchanged: top-level beats nested.
get_field() {
    local file="$1" field="$2"
    awk '
        function trim(s) { gsub(/^[ \t]+|[ \t\r]+$/, "", s); return s }
        /^---/{f++; next}
        f!=1{next}
        collect && /^[ \t]*-[ \t]+/{
            item=$0; gsub(/^[ \t]*-[ \t]+/, "", item); gsub(/["'"'"']/,"",item); item=trim(item)
            if (src=="top") top_items=(top_items=="" ? item : top_items ", " item)
            else            meta_items=(meta_items=="" ? item : meta_items ", " item)
            next
        }
        { collect=0 }
        /^metadata:[ \t\r]*$/{in_meta=1; next}
        in_meta && /^[^ \t]/{in_meta=0}
        in_meta && /^[ \t]+'"$field"':/{
            v=$0; gsub(/^[ \t]*[^:]+: */,"",v); gsub(/["'"'"']/,"",v); v=trim(v)
            if (v=="") { collect=1; src="meta" }
            else if (meta_scalar=="") meta_scalar=v
            next
        }
        /^'"$field"':/{
            v=$0; gsub(/^[^:]+: */,"",v); gsub(/["'"'"']/,"",v); v=trim(v)
            if (v=="") { collect=1; src="top" }
            else if (top_scalar=="") top_scalar=v
            next
        }
        END{
            if ((top_scalar!="" || meta_scalar!="") && (top_items!="" || meta_items!=""))
                printf "get_field: %s: key \"%s\" present both as scalar/inline value and columnar list; returning the scalar/inline value (canonical flat form, spec §3)\n", FILENAME, "'"$field"'" > "/dev/stderr"
            if (top_scalar!="")       print top_scalar
            else if (meta_scalar!="") print meta_scalar
            else if (top_items!="")   print "[" top_items "]"
            else if (meta_items!="")  print "[" meta_items "]"
        }
    ' "$file"
}
