#!/bin/bash
# test-update-f220-changelog-dry-run-strict.sh — regression test for WP-529
# Ф220 (variant Б): CHANGELOG.md diff+disclaimer on apply, and --dry-run-strict
# structural check of the delivery plan.
#
# Extracts the REAL blocks from update.sh between BEGIN-TESTABLE/END-TESTABLE
# sentinel comments and evals them in a sandbox — same philosophy as
# setup/test-update-issue-1143.sh, not a reimplementation of the logic.
#
# Usage: bash setup/test-update-f220-changelog-dry-run-strict.sh

set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SELF_DIR")"
UPDATE_SH_REAL="$REPO_ROOT/update.sh"
TEST_ROOT="${F220_WORKSPACE:-/tmp/iwe-f220-test-$$}"

FAIL_COUNT=0
PASS_COUNT=0
fail() { echo "  ❌ FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
pass() { echo "  ✅ PASS: $*"; PASS_COUNT=$((PASS_COUNT + 1)); }

cleanup() { local rc=$?; [ "${KEEP:-0}" = "1" ] || rm -rf "$TEST_ROOT"; exit "$rc"; }
trap cleanup EXIT INT TERM

mkdir -p "$TEST_ROOT"

extract_block() {
    local sentinel="$1" out="$2"
    sed -n "/# BEGIN-TESTABLE: $sentinel/,/# END-TESTABLE: $sentinel/p" "$UPDATE_SH_REAL" \
        | sed '1d;$d' > "$out"
    if [ ! -s "$out" ]; then
        echo "FATAL: sentinel '$sentinel' not found in $UPDATE_SH_REAL — update.sh moved or renamed the block" >&2
        exit 2
    fi
}

CHANGELOG_BLOCK="$TEST_ROOT/changelog-block.sh"
extract_block "changelog-diff-disclaimer" "$CHANGELOG_BLOCK"
STRICT_BLOCK="$TEST_ROOT/strict-block.sh"
extract_block "dry-run-strict-check" "$STRICT_BLOCK"

echo "=== CHANGELOG diff+disclaimer ==="

# Scenario 1: content unchanged — no diff/disclaimer emitted.
run_changelog_scenario() {
    local name="$1" before="$2" after="$3" expect_marker="$4"
    local scenario_dir="$TEST_ROOT/$name"
    rm -rf "$scenario_dir"; mkdir -p "$scenario_dir"
    if [ "$after" = "__REMOVED__" ]; then
        rm -f "$scenario_dir/CHANGELOG.md"
    elif [ -n "$after" ]; then
        printf '%s' "$after" > "$scenario_dir/CHANGELOG.md"
    fi
    OUTPUT=$(
        SCRIPT_DIR="$scenario_dir"
        CHANGELOG_SNAPSHOT="$before"
        set +u; set -e; set +o pipefail  # match update.sh's real shell options (cold-review Medium)
        source "$CHANGELOG_BLOCK"
    2>&1)
    if [ -n "$expect_marker" ]; then
        if printf '%s' "$OUTPUT" | grep -qF "$expect_marker"; then
            pass "$name: ожидаемый маркер найден"
        else
            fail "$name: маркер '$expect_marker' не найден в выводе: $OUTPUT"
        fi
    else
        if [ -z "$OUTPUT" ]; then
            pass "$name: вывод пуст (нет ложного срабатывания)"
        else
            fail "$name: ожидался пустой вывод, получено: $OUTPUT"
        fi
    fi
}

run_changelog_scenario "unchanged" "v1 content" "v1 content" ""
run_changelog_scenario "changed" "v1 content" "v2 content, new line" "⚠ Чистый --check/--dry-run"
run_changelog_scenario "new-file" "" "v1 content" "⚠ Чистый --check/--dry-run"
run_changelog_scenario "removed" "v1 content" "__REMOVED__" "⚠ CHANGELOG.md был удалён"
run_changelog_scenario "absent-both" "" "__REMOVED__" ""

# "Главное в этом обновлении" (слой "зачем", WP-529 Ф220 продолжение 2026-10-22):
# значимые пункты (не [optional]) впереди полного дифа.
run_highlight_scenario() {
    local name="$1" before="$2" after="$3" expect_header="$4" expect_content="$5"
    local scenario_dir="$TEST_ROOT/highlight-$name"
    rm -rf "$scenario_dir"; mkdir -p "$scenario_dir"
    printf '%s' "$after" > "$scenario_dir/CHANGELOG.md"
    OUTPUT=$(
        SCRIPT_DIR="$scenario_dir"
        CHANGELOG_SNAPSHOT="$before"
        set +u; set -e; set +o pipefail  # match update.sh's real shell options (cold-review Medium)
        source "$CHANGELOG_BLOCK"
    2>&1)
    local has_header=false
    printf '%s' "$OUTPUT" | grep -qF "Главное в этом обновлении" && has_header=true
    if [ "$expect_header" = "1" ]; then
        if $has_header && printf '%s' "$OUTPUT" | grep -qF "$expect_content"; then
            pass "highlight-$name: заголовок и содержимое найдены"
        else
            fail "highlight-$name: ожидался заголовок с '$expect_content', получено: $OUTPUT"
        fi
    else
        if ! $has_header; then
            pass "highlight-$name: заголовок отсутствует, как и ожидалось"
        else
            fail "highlight-$name: заголовок не должен появляться, получено: $OUTPUT"
        fi
    fi
}

run_highlight_scenario "optional-only" "" "- [optional] косметика" 0 ""
run_highlight_scenario "behavior-tagged" "" "- [behavior] важная правка" 1 "важная правка"
run_highlight_scenario "untagged" "" "- нет метки, но это пункт" 1 "нет метки"

# Чисто удаление (diff показывает только "<", ни одной "+") — cold-review нашёл,
# что до фикса здесь печаталась паразитная строка "  + " без содержимого.
run_pure_removal_scenario() {
    local scenario_dir="$TEST_ROOT/pure-removal"
    rm -rf "$scenario_dir"; mkdir -p "$scenario_dir"
    printf 'L1' > "$scenario_dir/CHANGELOG.md"
    OUTPUT=$(
        SCRIPT_DIR="$scenario_dir"
        CHANGELOG_SNAPSHOT=$'L1\nL2\nL3'
        set +u; set -e; set +o pipefail  # match update.sh's real shell options (cold-review Medium)
        source "$CHANGELOG_BLOCK"
    2>&1)
    if printf '%s\n' "$OUTPUT" | grep -qx '  + '; then
        fail "pure-removal: паразитная строка '  + ' без содержимого всё ещё есть"
    else
        pass "pure-removal: нет паразитной строки при отсутствии добавленных строк"
    fi
}
run_pure_removal_scenario

echo ""
echo "=== --dry-run-strict structural check ==="

run_strict_scenario() {
    local name="$1" expect_exit="$2"; shift 2
    local scenario_dir="$TEST_ROOT/strict-$name"
    rm -rf "$scenario_dir"
    mkdir -p "$scenario_dir/files"
    # Remaining args: pairs of "plan_path:source_exists(0|1)"
    local new_files=() updated_files=()
    local i=0
    for pair in "$@"; do
        local p="${pair%%:*}" exists="${pair##*:}"
        if [ "$exists" = "1" ]; then
            mkdir -p "$scenario_dir/files/$(dirname "$p")"
            echo "content" > "$scenario_dir/files/$p"
        fi
        if [ $((i % 2)) -eq 0 ]; then new_files+=("$p"); else updated_files+=("$p"); fi
        i=$((i + 1))
    done
    (
        TMPDIR_UPDATE="$scenario_dir"
        EXIT_RUNTIME=3
        NEW_FILES=("${new_files[@]}")
        UPDATED_FILES=("${updated_files[@]}")
        STRICT_CHECK=true
        set +u; set -e; set +o pipefail  # match update.sh's real shell options
        source "$STRICT_BLOCK"
    )
    local rc=$?
    if [ "$rc" = "$expect_exit" ]; then
        pass "strict-$name: exit=$rc (ожидалось $expect_exit)"
    else
        fail "strict-$name: exit=$rc, ожидалось $expect_exit"
    fi
}

run_strict_scenario "all-present" 0 "scripts/foo.sh:1" "CLAUDE.md:1"
run_strict_scenario "missing-source" 3 "scripts/foo.sh:1" "scripts/missing.sh:0"
run_strict_scenario "path-traversal" 3 "../etc/passwd:1"
run_strict_scenario "absolute-path" 3 "/etc/passwd:1"

echo ""
echo "=== Итог: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[ "$FAIL_COUNT" -eq 0 ]
