#!/usr/bin/env bash
# Resolve the user-owned input required by /platform-bottleneck. Never create
# or ship its contents from the public template (issue #1061).
set -euo pipefail

TEMPLATE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# setup.sh keeps this script in workspace/IWE/scripts,
# while it copies the skills and user memory to workspace/.claude and memory.
workspace="${IWE_WORKSPACE:-}"
if [ -z "$workspace" ]; then
    case "$TEMPLATE_ROOT" in
        */IWE) workspace="${TEMPLATE_ROOT%/IWE}" ;;
        *)
            echo 'platform-bottleneck: workspace is not defined; load .iwe-paths and retry the check.' >&2
            exit 2
            ;;
    esac
fi
if [ ! -d "$workspace" ]; then
    echo 'platform-bottleneck: workspace is not accessible; check IWE_WORKSPACE in .iwe-paths.' >&2
    exit 2
fi
workspace="$(cd "$workspace" && pwd -P)"
DEFAULT_MAP="$workspace/memory/project_iwe_systems_map.md"

if [ "$#" -eq 0 ]; then
    map_path="$DEFAULT_MAP"
elif [ "$#" -eq 2 ] && [ "$1" = "--map" ] && [ -n "$2" ]; then
    map_path="$2"
    case "$map_path" in
        /*) ;;
        *) map_path="$workspace/$map_path" ;;
    esac
else
    echo 'platform-bottleneck: usage: check-platform-systems-map.sh [--map <path>]' >&2
    exit 2
fi

if [ ! -f "$map_path" ] || [ ! -r "$map_path" ] || [ ! -s "$map_path" ] ||
   ! grep -q '[^[:space:]]' "$map_path"; then
    cat >&2 <<'MESSAGE'
platform-bottleneck: custom systems map is missing, empty or inaccessible — platform analysis halted.
Create your own Markdown-map of subsystems C2 and their relationships in the private working directory and invoke /platform-bottleneck --systems-map <path>.
For direct /bottleneck-pick --layer platform use the same --systems-map <path>.
Without the parameter the map is expected in memory/project_iwe_systems_map.md of the installed workspace. Do not add your personal map to the public template.
MESSAGE
    exit 2
fi

printf '%s\n' "$map_path"
