#!/bin/bash
# Install Strategist Agent launchd jobs
# WP-273 Этап 2: plists берутся из $IWE_RUNTIME (Generated runtime, F).
# Fallback на $SCRIPT_DIR/scripts/launchd/ — для старых установок до 0.29.0.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROLE_NAME="$(basename "$SCRIPT_DIR")"
TARGET_DIR="$HOME/Library/LaunchAgents"

# Resolve LAUNCHD source (Generated runtime → workspace fallback → FMT legacy)
if [ -n "${IWE_RUNTIME:-}" ] && [ -d "$IWE_RUNTIME/roles/$ROLE_NAME/scripts/launchd" ]; then
    LAUNCHD_DIR="$IWE_RUNTIME/roles/$ROLE_NAME/scripts/launchd"
    SCRIPT_TARGET="$IWE_RUNTIME/roles/$ROLE_NAME/scripts/strategist.sh"
elif [ -n "${IWE_WORKSPACE:-}" ] && [ -d "$IWE_WORKSPACE/.iwe-runtime/roles/$ROLE_NAME/scripts/launchd" ]; then
    LAUNCHD_DIR="$IWE_WORKSPACE/.iwe-runtime/roles/$ROLE_NAME/scripts/launchd"
    SCRIPT_TARGET="$IWE_WORKSPACE/.iwe-runtime/roles/$ROLE_NAME/scripts/strategist.sh"
else
    # Legacy: substituted FMT (до WP-273 Этап 2)
    LAUNCHD_DIR="$SCRIPT_DIR/scripts/launchd"
    SCRIPT_TARGET="$SCRIPT_DIR/scripts/strategist.sh"
    echo "  ⚠ Legacy mode: используются плейсхолдеры из FMT-substituted (запустите setup.sh ≥0.29.0 для архитектуры F)"
fi

# note-review remains manual by default (#961/#988). Preserve an existing
# optional job, but enable it on a fresh installation only when explicitly
# requested: install.sh morning weekreview notereview.
strategist_default_jobs() {
    printf '%s\n' morning weekreview
    if [[ "$(uname -s)" == Darwin ]]; then
        if [ -e "$TARGET_DIR/com.strategist.notereview.plist" ] ||
           [ -L "$TARGET_DIR/com.strategist.notereview.plist" ] ||
           [ -e "$TARGET_DIR/com.strategist.notereview.plist.disabled" ]; then
            printf '%s\n' notereview
        fi
    elif iwe_systemd_user_bus_ok; then
        if [ -e "$HOME/.config/systemd/user/iwe-strategist-notereview.service" ] ||
           [ -L "$HOME/.config/systemd/user/iwe-strategist-notereview.service" ] ||
           [ -e "$HOME/.config/systemd/user/iwe-strategist-notereview.timer" ] ||
           [ -L "$HOME/.config/systemd/user/iwe-strategist-notereview.timer" ]; then
            printf '%s\n' notereview
        fi
    elif command -v crontab >/dev/null 2>&1; then
        local installed_cron
        installed_cron=$(crontab -l 2>/dev/null) || return 0
        if printf '%s\n' "$installed_cron" | awk '
            /^# BEGIN IWE-strategist / { inside=1; next }
            /^# END IWE-strategist$/ { inside=0; next }
            inside && $0 !~ /^[[:space:]]*#/ { print }
        ' | grep -Fq "$(iwe_cron_env_prefix) $SCRIPT_TARGET note-review >> $HOME/logs/strategist/cron-notereview.log 2>&1"; then
            printf '%s\n' notereview
        fi
    fi
}

# The helpers only define functions; sourcing does not touch a scheduler.
source "$(cd "$SCRIPT_DIR/../lib" && pwd)/scheduler-cron.sh"
STRATEGIST_JOBS=()
if [ "$#" -eq 0 ]; then
    while IFS= read -r job; do STRATEGIST_JOBS+=("$job"); done < <(strategist_default_jobs)
    set -- "${STRATEGIST_JOBS[@]}"
fi
STRATEGIST_JOBS=()
for job in "$@"; do
    case "$job" in
        morning|weekreview|notereview) ;;
        *) echo "ERROR: unknown strategist job: $job" >&2; exit 2 ;;
    esac
    case " ${STRATEGIST_JOBS[*]} " in
        *" $job "*) echo "ERROR: duplicate strategist job: $job" >&2; exit 2 ;;
    esac
    STRATEGIST_JOBS+=("$job")
done
# cron replaces the complete role block. A partial selection would silently
# delete the unselected core jobs, unlike a partial systemd/launchd install.
for required_job in morning weekreview; do
    case " ${STRATEGIST_JOBS[*]} " in
        *" $required_job "*) ;;
        *) echo "ERROR: select both morning and weekreview; optionally add notereview" >&2; exit 2 ;;
    esac
done

# Resolve find-python3.sh for merge-launchd-schedule.py (issue #981) — same
# resolver contract as the rest of the template (WP-529 Ф6/Ф9, #453/#463):
# repo-owned .py files go through scripts/lib/find-python3.sh, not a bare
# python3, so a Windows MS-Store python3 stub or a missing interpreter fails
# loud instead of a silent domain error. --stdlib-only: the merge script only
# needs plistlib, the same idiom as git-sync-status.sh/extractor.sh.
if [ -n "${IWE_SCRIPTS:-}" ] && [ -f "$IWE_SCRIPTS/lib/find-python3.sh" ]; then
    PYTHON3_RESOLVER="$IWE_SCRIPTS/lib/find-python3.sh"
elif [ -n "${IWE_TEMPLATE:-}" ] && [ -f "$IWE_TEMPLATE/scripts/lib/find-python3.sh" ]; then
    PYTHON3_RESOLVER="$IWE_TEMPLATE/scripts/lib/find-python3.sh"
else
    # Legacy: roles/strategist is two levels under the template/repo root.
    PYTHON3_RESOLVER="$(dirname "$(dirname "$SCRIPT_DIR")")/scripts/lib/find-python3.sh"
fi
MERGE_PYTHON3=$(bash "$PYTHON3_RESOLVER" --stdlib-only 2>/dev/null) || MERGE_PYTHON3=""

echo "Installing Strategist Agent launchd jobs..."
echo "  LAUNCHD_DIR: $LAUNCHD_DIR"

# WP-273 R5 fix (Round 5 Евгения): fail-fast если выбранный plist содержит literal {{...}}.
# Это предотвращает копирование незаменённых плейсхолдеров в ~/Library/LaunchAgents/
# (если IWE_RUNTIME не expanded, fallback падает на FMT с placeholder'ами).
for job in "${STRATEGIST_JOBS[@]}"; do
    plist_check="$LAUNCHD_DIR/com.strategist.$job.plist"
    if [ -f "$plist_check" ] && grep -qE '\{\{[A-Z_]+\}\}' "$plist_check" 2>/dev/null; then
        echo "ERROR: $plist_check содержит незаменённые плейсхолдеры:" >&2
        grep -oE '\{\{[A-Z_]+\}\}' "$plist_check" | sort -u | sed 's/^/  /' >&2
        echo "" >&2
        echo "Возможные причины:" >&2
        echo "  1. IWE_RUNTIME не экспортирован → 'source ~/.zshenv' или 'source ~/.iwe-paths'" >&2
        echo "  2. .iwe-runtime/ ещё не создан → 'bash \$IWE_TEMPLATE/setup/build-runtime.sh'" >&2
        echo "  3. Старый clone до WP-273 Этап 2 → 'bash \$IWE_TEMPLATE/scripts/migrate-to-runtime-target.sh'" >&2
        exit 2
    fi
done

# Linux must take the systemd/cron path even if a launchctl binary happens to
# be present on PATH (for example in a shared tooling image).
if [[ "$(uname -s)" == "Linux" ]] || ! command -v launchctl >/dev/null 2>&1; then
    if [[ "$(uname -s)" == "Linux" ]]; then
        if [ -n "${SETUP_CI:-}" ]; then
            echo "  ⊠ SETUP_CI: systemd activation skipped for $ROLE_NAME"
            exit 0
        fi

        if [ -n "${IWE_RUNTIME:-}" ] && [ -d "$IWE_RUNTIME/roles/$ROLE_NAME/scripts/systemd" ]; then
            SYSTEMD_SRC="$IWE_RUNTIME/roles/$ROLE_NAME/scripts/systemd"
        elif [ -n "${IWE_WORKSPACE:-}" ] && [ -d "$IWE_WORKSPACE/.iwe-runtime/roles/$ROLE_NAME/scripts/systemd" ]; then
            SYSTEMD_SRC="$IWE_WORKSPACE/.iwe-runtime/roles/$ROLE_NAME/scripts/systemd"
        else
            echo "ERROR: systemd units not found. Run setup.sh first." >&2
            exit 1
        fi

        if grep -qrE '\{\{[A-Z_]+\}\}' "$SYSTEMD_SRC" 2>/dev/null; then
            echo "ERROR: systemd units contain unsubstituted placeholders" >&2
            exit 2
        fi

        mkdir -p "$HOME/logs/strategist"

        # issue #454: same functional bus probe as synchronizer/install.sh —
        # `command -v systemctl` alone can't tell WSL2/container hosts without a
        # session bus from a real systemd apart, and `enable --now` on those just
        # fails silently for the pilot.
        if ! iwe_systemd_user_bus_ok; then
            echo "  ⚠ systemd --user недоступен (нет пользовательской сессионной шины — типично для WSL2/контейнера/сервера без активного логина)"
            echo "  Installing $ROLE_NAME via cron fallback (issue #454)..."
            # Convert every selected timer before changing crontab. One invalid
            # timer must not leave a partial schedule installed.
            cron_lines=()
            for job in "${STRATEGIST_JOBS[@]}"; do
                case "$job" in
                    morning) mode=morning ;;
                    weekreview) mode=week-review ;;
                    notereview) mode=note-review ;;
                esac
                if ! job_lines=$(iwe_timer_to_cron_lines \
                    "$SYSTEMD_SRC/iwe-strategist-$job.timer" \
                    "$(iwe_cron_env_prefix) $SCRIPT_TARGET $mode >> $HOME/logs/strategist/cron-$job.log 2>&1"); then
                    echo "ERROR: cron-расписание $mode не собрано; crontab не изменён" >&2
                    exit 2
                fi
                cron_lines+=("$job_lines")
            done
            iwe_install_cron_fallback "strategist" "${cron_lines[@]}"
            echo "  ✓ Installed via crontab. Verify: crontab -l | grep strategist.sh"
            echo "  ✓ Logs: ~/logs/strategist/"
            exit 0
        fi

        echo "Installing $ROLE_NAME systemd user services (Linux)..."
        SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
        mkdir -p "$SYSTEMD_USER_DIR"

        # issue #285 (same class of bug, Linux equivalent): пользователь мог явно
        # выключить таймер (`systemctl --user disable iwe-strategist-morning.timer`)
        # — `systemctl --user is-enabled` тогда вернёт "disabled" (не "not-found",
        # это отличает «выключено» от «ещё не установлено»). Безусловный re-enable
        # при каждом апдейте роли отменял бы выбор пользователя молча.
        for job in "${STRATEGIST_JOBS[@]}"; do
            unit="iwe-strategist-$job"
            # A mask may be a symlink to /dev/null; never copy through it or
            # reactivate a timer the user deliberately stopped.
            if [ -L "$SYSTEMD_USER_DIR/$unit.service" ] || [ -L "$SYSTEMD_USER_DIR/$unit.timer" ]; then
                echo "  ⊘ $unit.timer — unit is a symlink, пропускаю"
                continue
            fi
            case "$(systemctl --user is-enabled "$unit.timer" 2>/dev/null || true)" in
                disabled|masked|masked-runtime)
                    echo "  ⊘ $unit.timer — disabled or masked by user, пропускаю (systemctl --user enable --now $unit.timer, чтобы включить обратно)"
                    continue
                    ;;
            esac
            for unit_file in "$unit.service" "$unit.timer"; do
                if [ -f "$SYSTEMD_USER_DIR/$unit_file" ] &&
                   ! cmp -s "$SYSTEMD_USER_DIR/$unit_file" "$SYSTEMD_SRC/$unit_file"; then
                    backup="$SYSTEMD_USER_DIR/$unit_file.bak-$(date +%Y%m%dT%H%M%S)"
                    cp -p "$SYSTEMD_USER_DIR/$unit_file" "$backup"
                    echo "  ⚠ $unit_file отличается от шаблона — старая версия сохранена в $(basename "$backup")"
                fi
            done
            cp "$SYSTEMD_SRC/$unit.service" "$SYSTEMD_SRC/$unit.timer" "$SYSTEMD_USER_DIR/"
            systemctl --user daemon-reload
            systemctl --user enable --now "$unit.timer"
            echo "  ✓ Installed: $unit.timer"
        done
        echo "  ✓ Logs: ~/logs/strategist/"
        echo ""
        echo "Verify: systemctl --user list-timers | grep strategist"
        exit 0
    fi
    echo "  ⊠ launchctl not available (non-macOS/Linux), skipping $ROLE_NAME install"
    exit 0
fi

mkdir -p "$TARGET_DIR"

# Make script executable (runtime path)
if [ -f "$SCRIPT_TARGET" ]; then
    chmod +x "$SCRIPT_TARGET"
fi

# issue #285: пользователь отключает агента документированным способом
# (launchctl unload + переименование в <label>.plist.disabled — конвенция,
# описанная в issue пилотом на его инсталляции для com.strategist.scout;
# в этом репо scout-плист не поставляется, конвенция применяется здесь
# первым делом). update.sh реагирует
# на изменения в roles/ и безусловно перезапускает install.sh каждой auto-роли —
# без этой проверки .disabled-маркер молча игнорировался, отключённый агент
# возвращался и перезагружался при каждом апдейте шаблона.
for job in "${STRATEGIST_JOBS[@]}"; do
    label="com.strategist.$job"
    if [ -L "$TARGET_DIR/$label.plist" ] || [ -L "$TARGET_DIR/$label.plist.disabled" ]; then
        echo "  ⊘ $label — plist is a symlink, пропускаю"
        continue
    fi
    if [ -f "$TARGET_DIR/$label.plist.disabled" ]; then
        echo "  ⊘ $label — disabled by user (найден $label.plist.disabled), пропускаю"
        continue
    fi
    if [ -z "${SETUP_CI:-}" ]; then
        launchctl unload "$TARGET_DIR/$label.plist" 2>/dev/null || true
    fi
    # issue #725: безусловный cp стирал ручную правку пользователя (например,
    # ограничение Weekday) без предупреждения и бэкапа при каждом update.sh —
    # backup+warn выбран вместо skip-if-diverged (пир-сессия с Codex,
    # 2026-09-09): skip навсегда заморозил бы апстрим-фиксы плиста для тех,
    # кто его один раз отредактировал по несвязанной причине. Бэкап остаётся
    # защитой на случай сбоя слияния ниже (issue #981).
    if [ -f "$TARGET_DIR/$label.plist" ] && ! cmp -s "$TARGET_DIR/$label.plist" "$LAUNCHD_DIR/$label.plist"; then
        BACKUP="$TARGET_DIR/$label.plist.bak-$(date +%Y%m%dT%H%M%S)"
        cp "$TARGET_DIR/$label.plist" "$BACKUP"
        echo "  ⚠ $label.plist отличается от шаблона — старая версия сохранена в $(basename "$BACKUP") перед перезаписью"
        # issue #981: backup+overwrite reinstated the template schedule
        # (Weekday/RunAtLoad) on every update, undoing a user's edit. Merge
        # keeps the installed copy's schedule keys, template provides the
        # rest (paths/env/labels), so upstream fixes still land.
        if [ -n "$MERGE_PYTHON3" ] && "$MERGE_PYTHON3" "$SCRIPT_DIR/merge-launchd-schedule.py" \
            "$LAUNCHD_DIR/$label.plist" "$BACKUP" "$TARGET_DIR/$label.plist.merged" 2>/dev/null; then
            mv "$TARGET_DIR/$label.plist.merged" "$TARGET_DIR/$label.plist"
            echo "  ↳ расписание из старой версии сохранено в новом $label.plist"
        else
            rm -f "$TARGET_DIR/$label.plist.merged"
            echo "  ⚠ слияние расписания не удалось — установлен шаблон без сохранённого расписания" >&2
            cp "$LAUNCHD_DIR/$label.plist" "$TARGET_DIR/"
        fi
    else
        cp "$LAUNCHD_DIR/$label.plist" "$TARGET_DIR/"
    fi
    if [ -z "${SETUP_CI:-}" ]; then
        launchctl load "$TARGET_DIR/$label.plist"
    fi
done

if [ -n "${SETUP_CI:-}" ]; then
    echo "Done. SETUP_CI: plists copied, launchctl activation skipped."
else
    echo "Done. Agents loaded:"
    launchctl list | grep strategist
fi
