#!/usr/bin/env bash
# test_issue_957_iwe_scripts_marker.sh -- regression for issue #957.
#
# IWE_SCRIPTS was pointed at "$WORKSPACE/scripts" by a bare `-d` check. A
# workspace scripts/ holding only a README and audit logs, or a hybrid of
# personal scripts and symlinks into the template, then hijacked the variable:
# every hook, skill and scenario resolving platform scripts through it lost
# session-guard.sh, create-wp.sh, day-open-pipeline.sh, ... with no diagnostic
# and exit code 0 (two installations after 0.40.1 -> 0.40.2).
#
# The value is written in two places that must agree:
#   - setup/install-iwe-paths.sh        (generated .iwe-paths, redone by update.sh)
#   - .claude/lib/iwe-env-bootstrap.sh  (fallback when IWE_SCRIPTS is not set)
# Both now accept the workspace scripts/ only when it holds a REGULAR
# (non-symlink) session-guard.sh; otherwise IWE_SCRIPTS stays on the template's
# scripts/. Seven layouts run through BOTH writers. The marker is judged on the
# file itself: a scripts/ that is a symlink to a directory holding a real
# session-guard.sh still counts as a live checkout, a dangling one does not.
# A regenerated .iwe-paths also announces an IWE_SCRIPTS change even under
# --quiet, with the paths resolved intact for a workspace whose path holds a
# space and '&'.
#
# Known limit (not asserted): the marker proves "this is a live checkout", not
# that its file set is complete -- a partial live scripts/ still shadows the
# template for the scripts it lacks.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf -- "$TMP"' EXIT
# Neither writer may touch the real HOME (rc files, ~/.iwe-paths).
export HOME="$TMP/home" TMPDIR="$TMP/tmp"
mkdir -p "$HOME" "$TMPDIR"

fail=0
check() { # <desc> <expected> <actual>
    if [ "$2" = "$3" ]; then
        echo "PASS: $1"
    else
        echo "FAIL: $1 -- ожидалось [$2], получено [$3]"
        fail=$((fail + 1))
    fi
}
check_contains() { # <desc> <haystack> <needle>
    case "$2" in
        *"$3"*) echo "PASS: $1" ;;
        *) echo "FAIL: $1 -- нет строки [$3] в выводе [$2]"; fail=$((fail + 1)) ;;
    esac
}

stub_script() { # <path> -- a minimal script file
    printf '#!/bin/bash\n' > "$1"
}

# Workspace with a template that has the platform scripts the symlinks point at.
make_ws() { # <name> -> prints the workspace path
    local ws="$TMP/$1"
    mkdir -p "$ws/FMT-exocortex-template/scripts/lib" "$ws/FMT-exocortex-template/.claude/lib"
    stub_script "$ws/FMT-exocortex-template/scripts/session-guard.sh"
    stub_script "$ws/FMT-exocortex-template/scripts/day-open-scaffold.sh"
    stub_script "$ws/FMT-exocortex-template/scripts/lib/find-python3.sh"
    cp "$ROOT/.claude/lib/iwe-env-bootstrap.sh" "$ws/FMT-exocortex-template/.claude/lib/"
    printf '%s' "$ws"
}

layout_audit_logs_only() { # README + audit journals (first report)
    mkdir -p "$1/scripts"
    printf '# scripts\n' > "$1/scripts/README.md"
    printf 'audit\n' > "$1/scripts/iwe-audit-2026-09-17.log"
    printf 'audit\n' > "$1/scripts/iwe-audit-2026-09-24.log"
}
layout_hybrid_symlinks() { # personal files + symlinks into the template (second report)
    mkdir -p "$1/scripts"
    # Targets exist, so `-f` alone would say "regular file" -- only `! -L` rejects them.
    ln -s ../FMT-exocortex-template/scripts/lib "$1/scripts/lib"
    ln -s ../FMT-exocortex-template/scripts/session-guard.sh "$1/scripts/session-guard.sh"
    ln -s ../FMT-exocortex-template/scripts/day-open-scaffold.sh "$1/scripts/day-open-scaffold.sh"
    stub_script "$1/scripts/pomodoro-alert.sh"
    printf 'audit\n' > "$1/scripts/iwe-audit-2026-09-17.log"
}
layout_live_copy() { # a real checkout: regular session-guard.sh
    mkdir -p "$1/scripts"
    stub_script "$1/scripts/session-guard.sh"
    stub_script "$1/scripts/create-wp.sh"
}
layout_no_scripts() { # no workspace scripts/ at all
    :
}
layout_personal_name_clash() { # personal script named like a template one, no session-guard.sh
    mkdir -p "$1/scripts"
    stub_script "$1/scripts/day-open-preflight.sh"
}
layout_scripts_dir_symlink() { # scripts/ itself is a symlink to a directory with a real session-guard.sh
    mkdir -p "$1/live-scripts"
    stub_script "$1/live-scripts/session-guard.sh"
    ln -s live-scripts "$1/scripts"
}
layout_scripts_dangling_symlink() { # scripts/ is a symlink to a directory that does not exist
    ln -s no-such-dir "$1/scripts"
}

# "$BASH" is the interpreter running this test, so `/bin/bash test.sh` exercises
# both writers on bash 3.2 end to end (a bare `bash` could resolve to bash 5).
run_installer() { # <ws> -> stdout of a --quiet generation (stderr dropped)
    "$BASH" "$ROOT/setup/install-iwe-paths.sh" --workspace "$1" --governance DS-strategy \
        --skip-zshenv --quiet 2>/dev/null
}
iwe_scripts_after_sourcing() { # <file> -> IWE_SCRIPTS a clean child shell has after sourcing it
    # shellcheck disable=SC2016 # $1 and $IWE_SCRIPTS are for the child shell, not this one
    env -i HOME="$HOME" PATH="$PATH" "$BASH" -c '. "$1" && printf "%s" "$IWE_SCRIPTS"' _ "$1"
}
iwe_scripts_from_installer() { # <ws> -> the value in the freshly generated .iwe-paths
    run_installer "$1" >/dev/null || { printf 'INSTALLER-FAILED'; return 0; }
    iwe_scripts_after_sourcing "$1/.iwe-paths"
}
iwe_scripts_from_bootstrap() { # <ws> -> the value the fallback layer derives when IWE_SCRIPTS is unset
    iwe_scripts_after_sourcing "$1/FMT-exocortex-template/.claude/lib/iwe-env-bootstrap.sh"
}

run_layout() { # <name> <layout function> <expected: workspace|template>
    local name="$1" layout="$2" want="$3" ws expected
    ws=$(make_ws "$name")
    "$layout" "$ws"
    if [ "$want" = workspace ]; then
        expected="$ws/scripts"
    else
        expected="$ws/FMT-exocortex-template/scripts"
    fi
    check "$name: install-iwe-paths.sh -> scripts/ of the $want" "$expected" "$(iwe_scripts_from_installer "$ws")"
    check "$name: iwe-env-bootstrap.sh  -> scripts/ of the $want" "$expected" "$(iwe_scripts_from_bootstrap "$ws")"
}

echo "--- seven layouts, both writers of IWE_SCRIPTS ---"
run_layout audit-logs-only layout_audit_logs_only template
run_layout hybrid-symlinks layout_hybrid_symlinks template
run_layout live-copy layout_live_copy workspace
run_layout no-scripts layout_no_scripts template
run_layout personal-name-clash layout_personal_name_clash template
run_layout scripts-dir-symlink layout_scripts_dir_symlink workspace
run_layout scripts-dangling-symlink layout_scripts_dangling_symlink template

echo "--- regeneration announces an IWE_SCRIPTS change even under --quiet ---"
WS_A=$(make_ws announce)
TEMPLATE_SCRIPTS="$WS_A/FMT-exocortex-template/scripts"
layout_live_copy "$WS_A"
check "первая генерация: старого значения нет, вывод пуст" "" "$(run_installer "$WS_A")"
check "повторная генерация без изменений: вывод пуст" "" "$(run_installer "$WS_A")"

rm "$WS_A/scripts/session-guard.sh"
out=$(run_installer "$WS_A")
check_contains "маркер пропал: «старое → новое» напечатано при --quiet" \
    "$out" "IWE_SCRIPTS: $WS_A/scripts → $TEMPLATE_SCRIPTS"
check_contains "маркер пропал: сказано, что значение подхватят только новые оболочки" \
    "$out" "подхватят только новые оболочки и Claude Code после перезапуска"
check "маркер пропал: .iwe-paths указывает на шаблон" \
    "$TEMPLATE_SCRIPTS" "$(iwe_scripts_after_sourcing "$WS_A/.iwe-paths")"

stub_script "$WS_A/scripts/session-guard.sh"
out=$(run_installer "$WS_A")
check_contains "маркер вернулся: «старое → новое» напечатано при --quiet" \
    "$out" "IWE_SCRIPTS: $TEMPLATE_SCRIPTS → $WS_A/scripts"

# A hand-edited absolute path to the SAME directory is not a change: no false alarm.
WS_B=$(make_ws same-dir)
layout_no_scripts "$WS_B"
printf 'export IWE_SCRIPTS="%s"\n' "$WS_B/FMT-exocortex-template/scripts" > "$WS_B/.iwe-paths"
check "тот же каталог другой записью: вывод пуст" "" "$(run_installer "$WS_B")"

echo "--- workspace path with a space and '&' (bash 5.2+ patsub_replacement) ---"
# From bash 5.2 an '&' in the replacement of ${v//pat/rep} stands for the matched
# text. Resolving "$IWE_WORKSPACE" against such a path used to distort it: a false
# "old -> new" for the same directory and a mangled path in a real change.
WS_C=$(make_ws "ws a&b")
layout_live_copy "$WS_C"
check "путь с пробелом и «&»: install-iwe-paths.sh -> scripts/ рабочей копии" \
    "$WS_C/scripts" "$(iwe_scripts_from_installer "$WS_C")"
check "путь с пробелом и «&»: iwe-env-bootstrap.sh  -> scripts/ рабочей копии" \
    "$WS_C/scripts" "$(iwe_scripts_from_bootstrap "$WS_C")"
printf 'export IWE_SCRIPTS="%s"\n' "$WS_C/scripts" > "$WS_C/.iwe-paths"
check "путь с «&», тот же каталог другой записью: вывод пуст" "" "$(run_installer "$WS_C")"
rm "$WS_C/scripts/session-guard.sh"
out=$(run_installer "$WS_C")
check_contains "путь с «&»: смена показана без искажения пути" \
    "$out" "IWE_SCRIPTS: $WS_C/scripts → $WS_C/FMT-exocortex-template/scripts"

if [ "$fail" -gt 0 ]; then
    echo "FAIL: $fail проверок упало"
    exit 1
fi
echo "PASS: IWE_SCRIPTS is the workspace scripts/ only with a regular session-guard.sh (issue #957)"
