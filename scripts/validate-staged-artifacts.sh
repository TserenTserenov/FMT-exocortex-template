#!/usr/bin/env bash
# routing: guard  deterministic=true
# validate-staged-artifacts.sh — the correctness boundary of pre-commit for
# protocol artifacts of the governance repo (issue #544).
#
# The PreToolUse hook protocol-artifact-validate.sh is an early fast-feedback
# layer, but it reads the index BEFORE the command runs, so on the chained form
# `git add … && git commit` it stays silent. This script is called by a REAL git
# pre-commit hook — it sees the index after any form of add (globs, -A/-u, chained
# commands) and reads the staged blob (`git show :path`), not the working tree:
# with partial staging exactly the content that will go into the
# commit is checked. ALL staged artifacts of each type are checked, not just the one
# lexicographically last.
#
# Run: from .githooks/pre-commit of the governance repo (cwd = repo root).
# All output goes to stderr: a git hook's stdout is not guaranteed to be visible to the user.
# Exit 0 — commit allowed; exit 1 — block with a human-readable breakdown.
set -uo pipefail

TMPDIR_OWN=$(mktemp -d "${TMPDIR:-/tmp}/staged-artifacts.XXXXXX")
trap 'rm -rf "$TMPDIR_OWN"' EXIT HUP INT TERM

WORKSPACE="${IWE_WORKSPACE:-${IWE_ROOT:-$(cd "$(git rev-parse --show-toplevel)/.." 2>/dev/null && pwd || true)}}"
GOV_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

ERRORS=()

# find-python3.sh resolver (issue #764): $WORKSPACE/scripts/lib/find-python3.sh
# never existed on any install — scripts/lib/ lives inside the template, not
# in the workspace root. Resolve via $IWE_SCRIPTS first (setup.sh's own var),
# then self-relative to this script's own governance-repo scripts/lib/.
resolve_find_python3() {
    local candidate
    if [ -n "${IWE_SCRIPTS:-}" ] && [ -f "$IWE_SCRIPTS/lib/find-python3.sh" ]; then
        printf '%s\n' "$IWE_SCRIPTS/lib/find-python3.sh"
        return 0
    fi
    candidate="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)/lib/find-python3.sh"
    if [ -f "$candidate" ]; then
        printf '%s\n' "$candidate"
        return 0
    fi
    return 1
}

err() { ERRORS+=("$1"); }

# staged_to_tmp <path> — staged blob to a temp file; prints the path.
staged_to_tmp() {
    local p="$1" tmp
    tmp=$(mktemp "$TMPDIR_OWN/blob.XXXXXX")
    if git show ":$p" > "$tmp" 2>/dev/null; then
        printf '%s\n' "$tmp"
    else
        rm -f "$tmp"
        return 1
    fi
}

validate_dayplan() { # <staged-path> <tmpfile>
    local rel="$1" f="$2"
    local section
    local SECTIONS=(
      "План на сегодня|Plan for Today|Today.s Plan"
      "Календарь|Calendar"
      "IWE за ночь|IWE Overnight"
      "Разбор заметок|Notes Review"
      "Итоги вчера|Yesterday"
    )
    for section in "${SECTIONS[@]}"; do
        grep -qE "$section" "$f" || err "DayPlan $rel: пропущена секция «${section}»"
    done

    local headings
    headings=$(grep -cE '^## |^[[:space:]]*<summary>' "$f" 2>/dev/null || true)
    if [ "${headings:-0}" -lt 3 ]; then
        err "DayPlan $rel: секций (## или <summary>) меньше 3 (найдено: ${headings:-0})"
    fi

    local calendar_lines
    calendar_lines=$(awk 'f && /^## /{exit} /Календарь|Calendar/{f=1} f' "$f" 2>/dev/null | wc -l | tr -d ' ')
    if [ "${calendar_lines:-0}" -lt 3 ]; then
        err "DayPlan $rel: секция «Календарь» пустая или слишком короткая (${calendar_lines:-0} строк)"
    fi

    if grep -q "Наработки Scout" "$f" 2>/dev/null; then
        if ! awk 'f && /^## /{exit} /Наработки Scout/{f=1} f' "$f" 2>/dev/null | grep -iqE 'наход|capture|статус|нет|find|disabled|not configured'; then
            err "DayPlan $rel: секция «Наработки Scout» пустая (допустимы маркеры 'нет находок', 'disabled', 'not configured')"
        fi
    fi

    if ! grep -qE "~[0-9]+[.,]?[0-9]*x" "$f" && ! grep -qiE "мультипликатор.*(не считаю|не наст)" "$f"; then
        err "DayPlan $rel: мультипликатор не найден — нужен '~N.Nx' в строке бюджета или явная оговорка «мультипликатор не считаю»"
    fi

    # Mandatory check — only if configured. The config exists but
    # is unreadable (broken YAML) OR python3 does not resolve — both equally
    # fail-closed (issue #765): a mandatory boundary has no right to silently
    # skip the check because of an infrastructure error, the python3 resolver
    # is no more reliable than the YAML itself.
    local config="$WORKSPACE/memory/day-rhythm-config.yaml"
    # issue #773 — I proposed my own resolver, but while this session was running
    # the same bug was independently closed by a parallel session as issue #764/#765
    # (PR #769): resolve_find_python3() below is the already merged version,
    # it additionally makes the mandatory check fail-closed (not a WARN-skip,
    # as I proposed). I take their version, I do not keep a duplicate implementation
    # of the same fact (OwnerIntegrity) — see the issue comment #773.
    local py="" py_resolver=""
    py_resolver=$(resolve_find_python3) || py_resolver=""
    if [ -n "$py_resolver" ]; then
        py=$("$py_resolver" 2>/dev/null) || py=""
    fi
    if [ -f "$config" ]; then
        if [ -z "$py" ]; then
            err "DayPlan $rel: day-rhythm-config.yaml есть, но python3 не резолвится (find-python3.sh не найден или не вернул интерпретатор) — mandatory-проверка невозможна, fail-closed"
        else
            # Codes: 0 = mandatory configured; 1 = valid config (map)
            # without mandatory; 2 = any error (no PyYAML, broken YAML, root
            # not a map, including an empty file/null) — fail-closed (review #544).
            local py_rc=0
            "$py" -c "
import sys
try:
    import yaml
    d = yaml.safe_load(open(sys.argv[1]))
except Exception:
    sys.exit(2)
if not isinstance(d, dict):
    sys.exit(2)
sys.exit(0 if d.get('mandatory_daily_wps') else 1)
" "$config" 2>/dev/null || py_rc=$?
            case "$py_rc" in
                0)
                    grep -qi "mandatory" "$f" || err "DayPlan $rel: mandatory check не найден (mandatory_daily_wps сконфигурирован)"
                    ;;
                1)
                    : # valid config without mandatory — the check is not required
                    ;;
                *)
                    # 2 — read/schema errors; other codes (126/127/signal) —
                    # also fail-closed: an unknown outcome of the check ≠ "not
                    # configured".
                    err "DayPlan $rel: day-rhythm-config.yaml существует, но не читается (нет PyYAML / битый или пустой YAML / корень не map / интерпретатор упал rc=$py_rc) — mandatory-проверка невозможна, fail-closed"
                    ;;
            esac
        fi
    fi

    if ! grep -qE "~[0-9]+[.,]?[0-9]* ?[hч] РП" "$f"; then
        err "DayPlan $rel: бюджет дня не в формате '~Xч РП / ~Yч физ'"
    fi

    # Carry-over: the previous DayPlan is looked up on disk (other files are not part of
    # the index, that is normal), the artifact itself was checked from the staged blob above.
    local prev
    prev=$(ls "$GOV_ROOT"/current/DayPlan\ *.md 2>/dev/null | sort | tail -2 | head -1)
    if [ -n "$prev" ] && [ "$prev" != "$GOV_ROOT/$rel" ]; then
        grep -qiE 'carry.over|carry_over' "$f" || \
            err "DayPlan $rel: carry-over из предыдущего Day Close отсутствует (предыдущий: $(basename "$prev"))"
    fi
}

validate_weekplan() { # <staged-path> <tmpfile>
    local rel="$1" f="$2"
    local lines headings
    lines=$(wc -l < "$f" | tr -d ' ')
    headings=$(grep -cE '^## |^[[:space:]]*<summary>' "$f" 2>/dev/null || true)
    if [ "${lines:-0}" -gt 80 ] && [ "${headings:-0}" -lt 3 ]; then
        err "WeekPlan $rel: больше 80 строк ($lines), но секций (## или <summary>) меньше 3 (${headings:-0}) — структурируй через ## или <details><summary>"
    fi
}

validate_weekreport() { # <staged-path> <tmpfile>
    local rel="$1" f="$2"
    grep -q "Итоги" "$f" || err "WeekReport $rel: нет секции «Итоги»"
}

# Walk ALL staged artifacts of each type (not a single sort|tail -1):
# a commit with two WeekPlans must not hide an invalid one behind a valid one.
# -z + --diff-filter=ACMRT: names with spaces/unicode do not break parsing;
# deleted files are not checked (nothing to check), type-change (a file became
# a symlink) — is checked. Index enumeration is fail-closed: could not
# read the index → block, not a silent skip (review #544, round 2).
STAGED_FILE="$TMPDIR_OWN/staged.list"
if ! git diff --cached --name-only -z --diff-filter=ACMRT > "$STAGED_FILE" 2>"$TMPDIR_OWN/staged.err"; then
    echo "⛔ Не удалось перечислить индекс (git diff --cached) — коммит заблокирован (fail-closed):" >&2
    sed 's/^/  /' "$TMPDIR_OWN/staged.err" >&2
    exit 1
fi
while IFS= read -r -d '' rel; do
    case "$rel" in
        current/DayPlan*.md)    kind=dayplan ;;
        current/WeekPlan*.md)   kind=weekplan ;;
        current/WeekReport*.md) kind=weekreport ;;
        *) continue ;;
    esac
    tmp=$(staged_to_tmp "$rel") || {
        echo "⛔ Не удалось прочитать staged blob $rel — коммит заблокирован (fail-closed)." >&2
        exit 1
    }
    case "$kind" in
        dayplan)    validate_dayplan "$rel" "$tmp" ;;
        weekplan)   validate_weekplan "$rel" "$tmp" ;;
        weekreport) validate_weekreport "$rel" "$tmp" ;;
    esac
    rm -f "$tmp"
done < "$STAGED_FILE"

if [ ${#ERRORS[@]} -gt 0 ]; then
    echo "⛔ PROTOCOL ARTIFACT VALIDATION FAILED (pre-commit, staged blob):" >&2
    printf '  - %s\n' "${ERRORS[@]}" >&2
    echo "Проверяется содержимое ИНДЕКСА (git show :path), не рабочего дерева —" >&2
    echo "после правки файла повтори git add." >&2
    exit 1
fi
exit 0
