#!/usr/bin/env bash
# Count unsubstituted placeholders only in files declared by runtime-overlay.
# .iwe-runtime also carries old session data and isolated Git worktrees; those
# are not part of the generated runtime and must not affect upgrade status.
set -euo pipefail

if [ "$#" -ne 2 ] || [ ! -f "$1" ] || [ ! -d "$2" ]; then
    echo "usage: runtime-placeholder-count.sh <runtime-overlay.yaml> <runtime-dir>" >&2
    exit 2
fi

overlay_file="$1"
runtime_dir="$2"
if ! paths=$(awk '
    /^substituted:/ { in_section = 1; found = 1; next }
    in_section && /^[a-z_]+:/ { in_section = 0 }
    in_section && /^[[:space:]]+-[[:space:]]/ {
        sub(/^[[:space:]]+-[[:space:]]+/, "")
        sub(/[[:space:]]*#.*/, "")
        sub(/[[:space:]]+$/, "")
        if (length($0) > 0) print
    }
    END { if (!found) exit 2 }
' "$overlay_file"); then
    echo "runtime overlay has no substituted section: $overlay_file" >&2
    exit 2
fi
if [ -z "$paths" ]; then
    echo "runtime overlay has no substituted files: $overlay_file" >&2
    exit 2
fi

remaining=0
while IFS= read -r relative_path; do
    case "$relative_path" in
        /*|../*|*/../*|*/..)
            echo "runtime overlay path escapes runtime: $relative_path" >&2
            exit 2 ;;
    esac
    runtime_file="$runtime_dir/$relative_path"
    if [ -L "$runtime_file" ]; then
        echo "runtime overlay target is a symlink: $relative_path" >&2
        exit 2
    fi
    if [ ! -f "$runtime_file" ]; then
        echo "runtime overlay target is missing: $relative_path" >&2
        exit 2
    fi
    if grep -qE '\{\{[A-Z_]+\}\}' "$runtime_file"; then
        remaining=$((remaining + 1))
    fi
done <<< "$paths"

printf '%s\n' "$remaining"
