#!/usr/bin/env bash
# test-check-changelog-entry.sh — сценарии гейта scripts/check-changelog-entry.sh
# на временном git-репозитории. Каждый сценарий проверяет наблюдаемый
# результат (код выхода и текст вердикта), не факт запуска скрипта.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$HERE/scripts/check-changelog-entry.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

git -C "$TMP" init -q -b main
git -C "$TMP" config user.email t@example.invalid
git -C "$TMP" config user.name t

BASE_CHANGELOG='# Changelog

## [Unreleased]

## [1.0.0] - 2026-01-01

### Fixed

- old entry (#1)
'
printf '%s' "$BASE_CHANGELOG" > "$TMP/CHANGELOG.md"
git -C "$TMP" add CHANGELOG.md
git -C "$TMP" commit -q -m base
BASE="$(git -C "$TMP" rev-parse HEAD)"

fail=0
# run_case <name> <expected-exit> <expected-text> <changelog-content> [pr-number]
run_case() {
    local name="$1" want_rc="$2" want_text="$3" content="$4" pr="${5:-42}"
    git -C "$TMP" checkout -q "$BASE" 2>/dev/null
    printf '%s' "$content" > "$TMP/CHANGELOG.md"
    git -C "$TMP" commit -q -am "case" --allow-empty
    local out rc
    out="$(cd "$TMP" && bash "$CHECK" "$BASE" HEAD "$pr")"; rc=$?
    if [[ "$rc" -ne "$want_rc" || "$out" != *"$want_text"* ]]; then
        echo "FAIL [$name]: rc=$rc (want $want_rc), out=$out"
        fail=1
    else
        echo "ok   [$name]"
    fi
}

run_case "entry with PR ref under subsection" 0 "PASS" '# Changelog

## [Unreleased]

### Fixed

- [behavior] fixed the thing (#42)

## [1.0.0] - 2026-01-01

### Fixed

- old entry (#1)
'

run_case "no CHANGELOG change" 1 "не добавил ни одного пункта" "$BASE_CHANGELOG"

run_case "entry without PR ref" 1 "не ссылается на этот PR" '# Changelog

## [Unreleased]

### Fixed

- fixed the thing without a number

## [1.0.0] - 2026-01-01

### Fixed

- old entry (#1)
'

run_case "entry references another PR number (#420 is not #42)" 1 "не ссылается на этот PR" '# Changelog

## [Unreleased]

### Fixed

- fixed the thing (#420)

## [1.0.0] - 2026-01-01

### Fixed

- old entry (#1)
'

run_case "entry added to a released section only" 1 "не добавил ни одного пункта" '# Changelog

## [Unreleased]

## [1.0.0] - 2026-01-01

### Fixed

- old entry (#1)
- cosmetic edit in a released section (#42)
'

run_case "entry outside any subsection" 1 "вне подраздела" '# Changelog

## [Unreleased]

- loose bullet (#42)

## [1.0.0] - 2026-01-01

### Fixed

- old entry (#1)
'

# Usage error: non-numeric PR number must exit 2.
out="$(cd "$TMP" && bash "$CHECK" "$BASE" HEAD abc 2>&1)"; rc=$?
if [[ "$rc" -eq 2 ]]; then echo "ok   [usage error exits 2]"; else echo "FAIL [usage error]: rc=$rc out=$out"; fail=1; fi

exit "$fail"
