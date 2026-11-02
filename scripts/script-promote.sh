#!/usr/bin/env bash
# routing: utility  deterministic=true
# see DP.SC.159, DP.ROLE.059
# script-promote.sh -- promotion of a personal script (or all shared scripts) into the IWE platform template
#
# Flow: personal folder/<script> → substitutions → FMT/scripts/<script>
# Personal constants are replaced with environment parameters (env vars).
#
# Usage:
#   bash script-promote.sh <path-to-script> [--dry-run] [--force]
#   bash script-promote.sh --all [--dry-run] [--force]
#
# Examples:
#   bash script-promote.sh ~/IWE/DS-strategy/scripts/my-tool.sh --dry-run
#   bash script-promote.sh ~/IWE/DS-strategy/scripts/my-tool.sh
#   bash script-promote.sh ~/IWE/DS-strategy/scripts/my-tool.sh --force
#   bash script-promote.sh --all
#
# --force: skip the guard comparison with FMT HEAD (if FMT differs intentionally)
# --all: walk all scripts/*.sh|*.py shared by the personal copy and FMT -- without --force
#        each diverged file is SKIPPED (does not block the others), see WP-485:
#        manual copying bypassing this guard has already wiped out fixes made directly in FMT
#        (issue #220/#259, commit 238a5c1) -- --all exists so that bulk
#        synchronization henceforth goes through the same guard as promoting a single file.

set -uo pipefail

IWE="${IWE_WORKSPACE:-$HOME/IWE}"
FMT_DIR="${IWE_TEMPLATE:-$IWE/FMT-exocortex-template}"
GOV_REPO_AUTHOR="${IWE_GOVERNANCE_REPO:-DS-strategy}"
GOV_REPO_TMPL="DS-strategy"
VALIDATOR="$FMT_DIR/scripts/validate-fmt-scripts.sh"

SRC=""
dry_run=false
force=false
batch_all=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) dry_run=true ;;
        --force)   force=true ;;
        --all)     batch_all=true ;;
        --*)       echo "Неизвестный флаг: $arg" >&2; exit 1 ;;
        *)         if [[ -z "$SRC" ]]; then SRC="$arg"; else echo "Слишком много аргументов" >&2; exit 1; fi ;;
    esac
done

if ! $batch_all && [[ -z "$SRC" || ! -f "$SRC" ]]; then
    echo "Использование: $0 <путь-к-скрипту> [--dry-run] [--force]" >&2
    echo "        или:   $0 --all [--dry-run] [--force]" >&2
    echo "Пример: $0 ~/IWE/\$GOV_REPO/scripts/my-tool.sh" >&2
    exit 1
fi

# promote_one SRC -- promotes one file. Returns: 0 promoted/equivalent,
# 2 skipped by the guard (FMT moved ahead), 1 other error (validation/smoke-test).
promote_one() {
    local src="$1" fname dest result head_version tmp_dir tmp_file smoke_result
    fname=$(basename "$src")
    dest="$FMT_DIR/scripts/$fname"

    echo "🔄 Промоция: $fname"
    echo "   Откуда: $src"
    echo "   Куда:   $dest"
    echo ""

    # Substitutions: personal constants → environment parameters
    # Order matters: first the long path ($HOME/IWE), then the short one ($HOME)
    result=$(sed \
        -e "s|$HOME/IWE|\${IWE:-\$HOME/IWE}|g" \
        -e "s|$HOME|\$HOME|g" \
        -e "s|$GOV_REPO_AUTHOR|\${IWE_GOVERNANCE_REPO:-$GOV_REPO_TMPL}|g" \
        "$src")

    # Guard: does FMT HEAD contain a newer version? Also checked in --dry-run --
    # otherwise `--all --dry-run` reports "everything gets promoted", although some files
    # diverged and the real run will skip them (WP-485).
    # Compare $result (after substitutions) with HEAD:scripts/$fname -- not with the working tree.
    # Goal: catch the case when the runtime copy is stale and overwrites fixes already pushed to FMT.
    # New file (not in HEAD) → guard is silent. FMT is not a git repo → guard is silent.
    if ! $force && git -C "$FMT_DIR" rev-parse HEAD >/dev/null 2>&1; then
        head_version=$(git -C "$FMT_DIR" show "HEAD:scripts/$fname" 2>/dev/null || true)
        if [[ -n "$head_version" ]]; then
            if ! diff -q <(printf '%s\n' "$result") <(printf '%s\n' "$head_version") >/dev/null 2>&1; then
                echo "⚠️  ПРОПУЩЕН: FMT HEAD содержит другую версию $fname" >&2
                echo "   Вероятно, в FMT уже есть фиксы, которых нет в вашей копии." >&2
                echo "   Промоция перетрёт эти изменения." >&2
                echo "" >&2
                echo "   Текущая версия в FMT HEAD:" >&2
                echo "     git -C \"$FMT_DIR\" show HEAD:scripts/$fname" >&2
                echo "   Что будет промотировано (после подстановок):" >&2
                echo "     bash \"$0\" \"$src\" --dry-run" >&2
                echo "" >&2
                echo "   Продолжить (если разница намеренная):" >&2
                echo "     $0 \"$src\" --force" >&2
                return 2
            fi
        fi
    fi

    if $dry_run; then
        echo "--- dry-run: результат после подстановок (guard пройден) ---"
        printf '%s\n' "$result"
        echo "--- конец ---"
        return 0
    fi

    # Validate the result via a temporary file
    tmp_dir=$(mktemp -d)
    tmp_file="$tmp_dir/$fname"
    printf '%s\n' "$result" > "$tmp_file"
    chmod +x "$tmp_file"

    if [[ -f "$VALIDATOR" ]]; then
        if ! bash "$VALIDATOR" "$tmp_dir" 2>&1; then
            rm -rf "$tmp_dir"
            echo "" >&2
            echo "❌ После подстановок остались личные хардкоды." >&2
            echo "   Используй --dry-run для просмотра и исправь вручную." >&2
            return 1
        fi
    fi

    # Smoke test: run in an isolated env with template variables
    # Goal: make sure the script does not fail with exit 1 in a foreign environment
    # We use --help or an empty run -- we expect exit 0 or exit 1 only from validation
    # 5s alarm (perl, portable -- the same trick as in kimi-peer-adapter.sh): daemon scripts
    # (while true; do ...; done without --help handling) otherwise hang here forever --
    # found on kimi-session-watchdog.sh, script-promote.sh hung on the smoke test.
    echo "   smoke-test с шаблонным окружением..."
    smoke_result=0
    # PATH inherited from the caller's own environment, not a hardcoded macOS list
    # (WP-484, 2026-07-28): the previous "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
    # has no `date`, `git`, or `which` on NixOS (a pilot's remote server) — any promotion run from
    # that host hit exit 127 here regardless of the script being promoted, live-
    # reproduced blocking a WP-484 fix. env -i still clears everything else, so
    # the smoke test's own environment isolation is unchanged, only PATH now comes
    # from wherever script-promote.sh itself is actually running.
    env -i \
        HOME="/tmp/iwe-smoke-user" \
        IWE="/tmp/iwe-smoke-user/IWE" \
        IWE_GOVERNANCE_REPO="DS-strategy" \
        PATH="$PATH" \
        perl -e 'alarm 5; exec @ARGV' -- bash "$tmp_file" --help > /dev/null 2>&1 || smoke_result=$?

    # exit 0 = OK, exit 1 = validation error (acceptable -- the script without arguments)
    # exit 127 = command not found (dependency broken) -- blocker
    # exit 142 = SIGALRM (perl alarm) — the script did not finish in 5s, looks like a daemon
    # with a while true loop; this is not a dependency bug, just skip it.
    if [[ $smoke_result -eq 127 ]]; then
        rm -rf "$tmp_dir"
        echo "❌ Smoke-тест: exit 127 — скрипт не может запуститься в чужом окружении." >&2
        echo "   Проверь зависимости (python3, jq, и т.п.) и абсолютные пути." >&2
        return 1
    fi
    if [[ $smoke_result -eq 142 ]]; then
        echo "   smoke-test: таймаут 5с (похоже на демон с бесконечным циклом, не блокер)"
    else
        echo "   smoke-test: OK (exit $smoke_result)"
    fi

    # Copy to FMT
    cp "$tmp_file" "$dest"
    chmod +x "$dest"
    rm -rf "$tmp_dir"

    echo ""
    echo "✅ Промотирован: FMT/scripts/$fname"
    return 0
}

finalize() {
    local changelog_script="$FMT_DIR/scripts/changelog-append.sh"
    [[ -f "$changelog_script" ]] && IWE_TEMPLATE="$FMT_DIR" bash "$changelog_script"

    local manifest_script="$FMT_DIR/generate-manifest.sh"
    if [[ -f "$manifest_script" ]]; then
        echo "🔄 Пересборка update-manifest.json..."
        bash "$manifest_script" 2>&1
    else
        echo "⚠️  generate-manifest.sh не найден — обнови update-manifest.json вручную"
    fi
}

if $batch_all; then
    total=0 synced=0 skipped=0 failed=0
    for f in "$IWE"/scripts/*.sh "$IWE"/scripts/*.py; do
        [[ -f "$f" ]] || continue
        fname=$(basename "$f")
        [[ -f "$FMT_DIR/scripts/$fname" ]] || continue  # only shared files — do not add new ones here automatically
        total=$((total + 1))
        promote_one "$f"; rc=$?
        case "$rc" in
            0) synced=$((synced + 1)) ;;
            2) skipped=$((skipped + 1)) ;;
            *) failed=$((failed + 1)) ;;
        esac
        echo ""
    done

    echo "Итог --all: $total общих файлов · $synced промотировано · $skipped пропущено (разошлись — нужен ручной разбор + --force) · $failed ошибок"

    if $dry_run; then
        exit 0
    fi
    if [[ $synced -gt 0 ]]; then
        finalize
        echo "Следующий шаг:"
        echo "  cd $FMT_DIR && git status && git add scripts/ CHANGELOG.md update-manifest.json && git commit -m 'feat: promote scripts to platform (--all)'"
    fi
    [[ $skipped -eq 0 && $failed -eq 0 ]]
    exit $?
fi

promote_one "$SRC"
rc=$?
if [[ $rc -eq 0 ]] && ! $dry_run; then
    finalize
    echo "Следующий шаг:"
    echo "  cd $FMT_DIR && git add scripts/$(basename "$SRC") CHANGELOG.md update-manifest.json && git commit -m 'feat: promote $(basename "$SRC") to platform'"
fi
exit $rc
