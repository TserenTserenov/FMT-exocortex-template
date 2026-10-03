#!/usr/bin/env bash
# Resolve the user-owned input required by /platform-bottleneck. Never create
# or ship its contents from the public template (issue #1061).
set -euo pipefail

TEMPLATE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# setup.sh keeps this script in workspace/FMT-exocortex-template/scripts,
# while it copies the skills and user memory to workspace/.claude and memory.
workspace="${IWE_WORKSPACE:-}"
if [ -z "$workspace" ]; then
    case "$TEMPLATE_ROOT" in
        */FMT-exocortex-template) workspace="${TEMPLATE_ROOT%/FMT-exocortex-template}" ;;
        *)
            echo 'platform-bottleneck: не определена рабочая область; загрузите .iwe-paths и повторите проверку.' >&2
            exit 2
            ;;
    esac
fi
if [ ! -d "$workspace" ]; then
    echo 'platform-bottleneck: рабочая область недоступна; проверьте IWE_WORKSPACE в .iwe-paths.' >&2
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
    echo 'platform-bottleneck: вызов: check-platform-systems-map.sh [--map <путь>]' >&2
    exit 2
fi

if [ ! -f "$map_path" ] || [ ! -r "$map_path" ] || [ ! -s "$map_path" ] ||
   ! grep -q '[^[:space:]]' "$map_path"; then
    cat >&2 <<'MESSAGE'
platform-bottleneck: пользовательская карта систем отсутствует, пуста или недоступна — платформенный анализ остановлен.
Создайте собственную Markdown-карту подсистем C2 и их связей в закрытом рабочем каталоге и вызовите /platform-bottleneck --systems-map <путь>.
Для прямого /bottleneck-pick --layer platform используйте тот же --systems-map <путь>.
Без параметра карта ожидается в memory/project_iwe_systems_map.md установленного рабочего пространства. Не добавляйте личную карту в публичный шаблон.
MESSAGE
    exit 2
fi

printf '%s\n' "$map_path"
