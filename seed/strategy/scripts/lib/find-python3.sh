#!/usr/bin/env bash
# SNAPSHOT — synced manually via script-promote.sh from FMT-exocortex-template/scripts/. Do not edit here directly.
# find-python3.sh — single Python resolver for template scripts (WP-529 F6,
# issues #453/#463, Evgenii 18.08).
#
# Contract (peer-session 2026-08-19-01, codex В1): standalone executable, not a
# sourced lib. By default stdout = path to a python3 whose `import yaml`
# succeeds, exit 0. `--stdlib-only` keeps the same candidate resolution but
# requires only the Python standard library; callers that do not import PyYAML
# must use it rather than acquiring an unrelated optional dependency.
# No candidate → exit 1 with actionable diagnostics on stderr. Callers use
# command substitution and MUST check the exit code, failing with an explicit
# dependency error instead of a misleading domain error ("calendar_ids не
# найдены" while the real cause was a missing PyYAML).
#
# Before this file the same _find_python3() lived in three diverging copies
# (server-calendar.sh, server-news.sh, active-wp-sweep.sh); none knew
# /opt/homebrew/bin/python3, so stock macOS Apple Silicon always fell through
# to a yaml-less interpreter.
set -u

stdlib_only=false
case "${1:-}" in
    --stdlib-only) stdlib_only=true; shift ;;
    "") ;;
    *) echo "ERROR: unknown find-python3.sh argument: $1" >&2; exit 2 ;;
esac
[ "$#" -eq 0 ] || { echo "ERROR: find-python3.sh accepts only --stdlib-only" >&2; exit 2; }

candidates=(
    python3
    /opt/homebrew/bin/python3
    /usr/local/bin/python3
    /usr/bin/python3
)

# issue #864: Python 3.10+ is required for union syntax (`str | None`) used in
# core scripts (artifactor.py, session-dispatcher-tsekh.py). Reject 3.9 early
# with a clear message instead of a cryptic TypeError at use time.
MIN_PYTHON_VERSION="3.10"
python_meets_version() {
    local py="$1"
    "$py" -c "import sys; v=sys.version_info; sys.exit(0 if (v.major, v.minor) >= (3, 10) else 1)" >/dev/null 2>&1
}

for cand in "${candidates[@]}"; do
    resolved=$(command -v "$cand" 2>/dev/null) || continue
    if ! python_meets_version "$resolved"; then
        continue
    fi
    if $stdlib_only || "$resolved" -c "import yaml" >/dev/null 2>&1; then
        printf '%s\n' "$resolved"
        exit 0
    fi
done

# Nix: no hardcoded /nix/store hash (they rot on every nixos-rebuild), scan is
# the last resort. NOTE: no `find | while` pipeline here — the loop would run
# in a subshell and `exit` would not terminate the script (the historical bug
# that made this branch dead code in server-calendar.sh).
if [ -d /nix/store ]; then
    while IFS= read -r cand; do
        if ! python_meets_version "$cand"; then
            continue
        fi
        if $stdlib_only || "$cand" -c "import yaml" >/dev/null 2>&1; then
            printf '%s\n' "$cand"
            exit 0
        fi
    done < <(find /nix/store -maxdepth 3 -name python3 -path "*env*/bin/*" 2>/dev/null)
fi

if $stdlib_only; then
    echo "ERROR: python3 >= ${MIN_PYTHON_VERSION} не найден (проверены: PATH, /opt/homebrew, /usr/local, /usr/bin, Nix)." >&2
    exit 1
fi

{
    echo "ERROR: python3 >= ${MIN_PYTHON_VERSION} с библиотекой PyYAML не найден (проверены: PATH, /opt/homebrew, /usr/local, /usr/bin, Nix)."
    echo "Python 3.10+ требуется для синтаксиса union types (|) в core-скриптах шаблона. PyYAML — заявленная зависимость (requirements.txt). Установка:"
    echo "  - macOS (Homebrew): brew install python3 && pip3 install pyyaml"
    echo "  - Debian/Ubuntu:    sudo apt install python3-yaml   (или python3.10 + pip3 install pyyaml)"
    echo "  - универсально:     установи Python 3.10+, затем pip3 install pyyaml"
} >&2
exit 1
