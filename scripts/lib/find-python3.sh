#!/usr/bin/env bash
# find-python3.sh — single Python resolver for template scripts (WP-529 F6,
# issues #453/#463, Evgenii 18.08).
#
# Contract (peer-session 2026-08-19-01, codex В1): standalone executable, not a
# sourced lib. stdout = path to a python3 whose `import yaml` succeeds, exit 0.
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

candidates=(
    python3
    /opt/homebrew/bin/python3
    /usr/local/bin/python3
    /usr/bin/python3
)

for cand in "${candidates[@]}"; do
    resolved=$(command -v "$cand" 2>/dev/null) || continue
    if "$resolved" -c "import yaml" >/dev/null 2>&1; then
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
        if "$cand" -c "import yaml" >/dev/null 2>&1; then
            printf '%s\n' "$cand"
            exit 0
        fi
    done < <(find /nix/store -maxdepth 3 -name python3 -path "*env*/bin/*" 2>/dev/null)
fi

{
    echo "ERROR: python3 с библиотекой PyYAML не найден (проверены: PATH, /opt/homebrew, /usr/local, /usr/bin, Nix)."
    echo "PyYAML — заявленная зависимость шаблона (requirements.txt). Установка:"
    echo "  - macOS (Homebrew): pip3 install pyyaml   (python3 из brew уже содержит pip3)"
    echo "  - Debian/Ubuntu:    sudo apt install python3-yaml"
    echo "  - универсально:     pip3 install pyyaml"
} >&2
exit 1
