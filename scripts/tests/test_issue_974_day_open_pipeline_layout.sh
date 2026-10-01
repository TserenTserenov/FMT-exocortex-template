#!/usr/bin/env bash
# Regression for issue #974: the Day Open pipeline took the directory it runs from for the
# governance repository.
#
# strategist.sh runs `$IWE_SCRIPTS/day-open-pipeline.sh`. On the layout setup.sh builds that is
# the copy inside the template (<workspace>/FMT-exocortex-template/scripts/), while the
# governance repository (DS-strategy by default, any name allowed) is a sibling directory.
# The script derived DS_STRATEGY and IWE_GOVERNANCE_REPO from its own location, so Scaffold
# died with "WeekPlan not found in .../FMT-exocortex-template/current" and every morning fell
# through to the free-form day-plan prompt; the forced IWE_GOVERNANCE_REPO export also
# overwrote a correct value from the environment (the children saw the template's name).
#
# This runs the REAL pipeline (`--probe --scaffold-only`: real preflight + scaffold, no LLM,
# no commit, no network) from a copy of this working tree placed the way setup.sh places it,
# inside a disposable workspace, under `env -i` with a throwaway HOME and stub claude/gh/curl
# in front of PATH. The copy is taken from the working tree on purpose (not `git archive HEAD`):
# the test must see uncommitted edits and must work from an extracted archive without .git.
#
# Cases:
#   A  non-standard governance name from the environment (a sibling DS-strategy must not exist,
#      otherwise the default would mask an incomplete fix)
#   B  standard name, nothing in the environment; the governance repo carries a stale seeded
#      scripts/ copy that must NOT be executed (executables come from the template copy)
#   C  non-standard name but no environment: fail loudly with an actionable message, never
#      guess and never touch the template
#   D  control: the copy promoted INTO the governance repo keeps deriving the repository from
#      its physical location (also against a stale inherited environment)
#   E  a template copy outside any workspace layout and without environment: the workspace
#      root cannot be determined, the pipeline refuses (no guessing a root either)
set -uo pipefail

case "${1:-}" in
    -h|--help)
        echo "usage: bash $0   (no arguments; runs the real pipeline in throwaway workspaces)"
        exit 0
        ;;
esac

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
# Explicit template: macOS mktemp without one ignores TMPDIR.
TMP=$(mktemp -d "${TMPDIR:-/tmp}/iwe-issue-974.XXXXXX")
TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
# Nothing below may read or write the real home or the real temp dir.
export HOME="$TMP/home"
export TMPDIR="$TMP/tmp"
export GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME" "$TMPDIR"

for tool in jq git tar; do
    command -v "$tool" >/dev/null 2>&1 || { echo "SKIP: $tool is not installed"; exit 0; }
done

DATE=2026-10-01   # a Thursday: not the default strategy day (monday), so the scaffold runs
STUBS="$TMP/stubs"
mkdir -p "$STUBS"
for stub in claude gh curl; do
    printf '#!/bin/sh\necho "stub %s: no network in this test" >&2\nexit 1\n' "$stub" > "$STUBS/$stub"
    chmod +x "$STUBS/$stub"
done

fail=0
ok()  { echo "  PASS: $1"; }
bad() { echo "  FAIL: $1"; fail=$((fail + 1)); }
has() { grep -qF -- "$2" "$1" 2>/dev/null; }   # <file> <literal text>

# A copy of this working tree, placed as <workspace>/FMT-exocortex-template.
copy_template() { # <dest>
    mkdir -p "$1"
    tar -C "$ROOT" --exclude=.git -cf - . | tar -C "$1" -xf -
}

# Governance repository the way a fresh install gets it: the seed (without its own scripts/
# unless asked), a git repo with core.hooksPath already wired, and the logs/ dir.
build_governance() { # <dir> <with-seed-scripts: yes|no>
    local dir="$1"
    mkdir -p "$dir"
    if [ "$2" = yes ]; then
        tar -C "$ROOT/seed/strategy" -cf - . | tar -C "$dir" -xf -
    else
        tar -C "$ROOT/seed/strategy" --exclude=./scripts -cf - . | tar -C "$dir" -xf -
    fi
    mkdir -p "$dir/logs"
    git -C "$dir" init -q 2>/dev/null
    git -C "$dir" config core.hooksPath .githooks
    git -C "$dir" -c user.name=fixture -c user.email=fixture@example.invalid \
        -c core.hooksPath=/dev/null commit -q --allow-empty -m "fixture: governance repo" 2>/dev/null
}

# build_workspace <dir> <governance name> <with-seed-scripts: yes|no>
# The before-hook records the identity every child process of the pipeline inherits.
build_workspace() {
    local ws="$1"
    copy_template "$ws/FMT-exocortex-template"
    build_governance "$ws/$2" "$3"
    mkdir -p "$ws/extensions"
    printf 'calendar_source: none\n' > "$ws/params.yaml"
    cat > "$ws/extensions/day-open.before.md" <<EOF
\`\`\`bash
printf '%s|%s\n' "\${IWE_GOVERNANCE_REPO:-unset}" "\${IWE_ROOT:-unset}" > "$ws/child-identity.txt"
\`\`\`
EOF
}

# run_pipeline <workspace> <pipeline script> <output file> [VAR=value ...]
# Mirrors what the strategist job provides: IWE_SCRIPTS pointing into the template.
run_pipeline() {
    local ws="$1" script="$2" out="$3"
    shift 3
    env -i HOME="$HOME" PATH="$STUBS:$PATH" TMPDIR="$TMPDIR" PYTHONDONTWRITEBYTECODE=1 \
        DAY_OPEN_LOCK_FILE="$ws/day-open.lock" \
        IWE_SCRIPTS="$ws/FMT-exocortex-template/scripts" \
        "$@" "$BASH" "$script" --probe --scaffold-only --date "$DATE" > "$out" 2>&1
}

snapshot_tree() { # <dir> <out>
    find "$1" | LC_ALL=C sort > "$2"
}

# Assertions shared by the three cases where the pipeline must reach Scaffold.
expect_scaffold_in_governance() { # <label> <workspace> <governance> <output> <rc>
    local label="$1" ws="$2" gov="$3" out="$4" rc="$5"
    if has "$out" "=== 3. Scaffold ===" && ! has "$out" "WeekPlan not found"; then
        ok "$label: Scaffold проходит, «WeekPlan not found» нет"
    else
        bad "$label: Scaffold не пройден (rc=$rc): $(grep -F 'WeekPlan not found' "$out" | head -1)"
    fi
    if has "$out" "Scaffold OK: $ws/$gov/current/DayPlan $DATE (probe).md"; then
        ok "$label: скелет DayPlan собран в governance-репозитории $gov"
    else
        bad "$label: нет строки «Scaffold OK» с путём в $ws/$gov/current (см. вывод: $(grep -F '=== 3. Scaffold' -A1 "$out" | tail -1))"
    fi
    if [ "$(cat "$ws/child-identity.txt" 2>/dev/null)" = "$gov|$ws" ]; then
        ok "$label: дочерние процессы получили IWE_GOVERNANCE_REPO=$gov и IWE_ROOT=$ws"
    else
        bad "$label: дочерние процессы получили «$(cat "$ws/child-identity.txt" 2>/dev/null)», ожидалось «${gov}|${ws}»"
    fi
    if has "$out" "install-hooks.sh failed"; then
        bad "$label: шаг 1.2 пытался чинить хуки не в том репозитории"
    else
        ok "$label: шаг 1.2 не трогает чужой репозиторий"
    fi
    # The strategist falls back to the free-form prompt on any non-zero exit, so the whole
    # probe run (every later step is started from the directory the copy runs from) must end green.
    if [ "$rc" -eq 0 ] && has "$out" "verdict=🟢 green"; then
        ok "$label: прогон дошёл до конца, код возврата 0, вердикт green"
    else
        bad "$label: прогон не завершился успешно (rc=$rc): $(grep -F 'PROBE SUMMARY' -A1 "$out" | tail -1)"
    fi
}

expect_template_untouched() { # <label> <workspace> <before snapshot>
    local label="$1" ws="$2" before="$3"
    snapshot_tree "$ws/FMT-exocortex-template" "$before.after"
    if cmp -s "$before" "$before.after"; then
        ok "$label: в каталоге шаблона ничего не создано и не удалено"
    else
        bad "$label: каталог шаблона изменился: $(diff "$before" "$before.after" | head -3 | tr '\n' ' ')"
    fi
}

# ---------------------------------------------------------------- case A
echo "== A: governance с нестандартным именем, имя задано окружением"
A="$TMP/a"; GOV_A=DS-custom-gov
build_workspace "$A/ws" "$GOV_A" no
snapshot_tree "$A/ws/FMT-exocortex-template" "$A/before.txt"
run_pipeline "$A/ws" "$A/ws/FMT-exocortex-template/scripts/day-open-pipeline.sh" "$A/out.txt" \
    IWE_GOVERNANCE_REPO="$GOV_A"
rc=$?
expect_scaffold_in_governance "A" "$A/ws" "$GOV_A" "$A/out.txt" "$rc"
expect_template_untouched "A" "$A/ws" "$A/before.txt"
if [ -e "$A/ws/DS-strategy" ]; then
    bad "A: появился каталог DS-strategy — конвейер откатился на имя по умолчанию"
else
    ok "A: имя по умолчанию DS-strategy не подставлялось"
fi

# ---------------------------------------------------------------- case B
echo "== B: стандартное имя DS-strategy, окружение пустое; в governance устаревшая копия scripts/"
B="$TMP/b"
build_workspace "$B/ws" DS-strategy no
mkdir -p "$B/ws/DS-strategy/scripts"
cat > "$B/ws/DS-strategy/scripts/day-open-hooks-runner.sh" <<EOF
#!/bin/sh
echo executed > "$B/stale-runner-was-executed"
exit 1
EOF
chmod +x "$B/ws/DS-strategy/scripts/day-open-hooks-runner.sh"
snapshot_tree "$B/ws/FMT-exocortex-template" "$B/before.txt"
run_pipeline "$B/ws" "$B/ws/FMT-exocortex-template/scripts/day-open-pipeline.sh" "$B/out.txt"
rc=$?
expect_scaffold_in_governance "B" "$B/ws" DS-strategy "$B/out.txt" "$rc"
expect_template_untouched "B" "$B/ws" "$B/before.txt"
if [ -e "$B/stale-runner-was-executed" ]; then
    bad "B: выполнена копия скрипта из governance-репозитория, а не из шаблона"
else
    ok "B: исполняемые файлы берутся рядом с конвейером (из шаблона), не из governance"
fi

# ---------------------------------------------------------------- case C
echo "== C: нестандартное имя, окружения нет — громкий отказ без догадок"
C="$TMP/c"
build_workspace "$C/ws" DS-custom-gov no
snapshot_tree "$C/ws/FMT-exocortex-template" "$C/before.txt"
run_pipeline "$C/ws" "$C/ws/FMT-exocortex-template/scripts/day-open-pipeline.sh" "$C/out.txt"
rc=$?
if [ "$rc" -ne 0 ] && has "$C/out.txt" "Governance-репозиторий не найден: $C/ws/DS-strategy" \
   && has "$C/out.txt" "IWE_GOVERNANCE_REPO"; then
    ok "C: отказ с понятным текстом и подсказкой про IWE_GOVERNANCE_REPO (rc=$rc)"
else
    bad "C: нет понятного отказа (rc=$rc): $(head -3 "$C/out.txt" | tr '\n' ' ')"
fi
if has "$C/out.txt" "=== 3. Scaffold ==="; then
    bad "C: конвейер дошёл до Scaffold, хотя governance-репозиторий не определён"
else
    ok "C: до Scaffold дело не дошло"
fi
expect_template_untouched "C" "$C/ws" "$C/before.txt"

# ---------------------------------------------------------------- case D
echo "== D: контроль — копия, промотированная в governance-репозиторий, при устаревшем окружении"
D="$TMP/d"; GOV_D=DS-promoted-gov
build_workspace "$D/ws" "$GOV_D" yes
run_pipeline "$D/ws" "$D/ws/$GOV_D/scripts/day-open-pipeline.sh" "$D/out.txt" \
    IWE_ROOT="$D/stale-workspace" IWE_GOVERNANCE_REPO=stale-governance
rc=$?
expect_scaffold_in_governance "D" "$D/ws" "$GOV_D" "$D/out.txt" "$rc"

# ---------------------------------------------------------------- case E
echo "== E: копия шаблона вне раскладки рабочего пространства, окружения нет — корень не определить"
E="$TMP/e"
copy_template "$E/loose-template"
run_pipeline "$E" "$E/loose-template/scripts/day-open-pipeline.sh" "$E/out.txt" \
    IWE_SCRIPTS="$E/loose-template/scripts"
rc=$?
if [ "$rc" -ne 0 ] && has "$E/out.txt" "cannot determine workspace root"; then
    ok "E: отказ с названием причины (rc=$rc)"
else
    bad "E: нет отказа про корень рабочего пространства (rc=$rc): $(head -3 "$E/out.txt" | tr '\n' ' ')"
fi
if has "$E/out.txt" "=== 1.5."; then
    bad "E: конвейер продолжил работу без корня рабочего пространства"
else
    ok "E: ни один шаг конвейера не запускался"
fi

echo
if [ "$fail" -eq 0 ]; then
    echo "PASS: issue #974 — конвейер находит governance-репозиторий по окружению, а не по расположению"
else
    echo "FAIL: issue #974 — провалено проверок: $fail"
    exit 1
fi
