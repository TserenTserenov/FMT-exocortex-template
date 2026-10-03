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

echo "Installing Strategist Agent launchd jobs..."
echo "  LAUNCHD_DIR: $LAUNCHD_DIR"

# WP-273 R5 fix (Round 5 Евгения): fail-fast если выбранный plist содержит literal {{...}}.
# Это предотвращает копирование незаменённых плейсхолдеров в ~/Library/LaunchAgents/
# (если IWE_RUNTIME не expanded, fallback падает на FMT с placeholder'ами).
for plist_check in "$LAUNCHD_DIR/com.strategist.morning.plist" "$LAUNCHD_DIR/com.strategist.weekreview.plist"; do
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

        source "$(cd "$SCRIPT_DIR/../lib" && pwd)/scheduler-cron.sh"

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
            # Command substitution preserves each conversion's exit status;
            # process substitution used here before #1039 hid parser failures
            # and could install only one of the two required jobs.
            if ! morning_lines=$(iwe_timer_to_cron_lines \
                "$SYSTEMD_SRC/iwe-strategist-morning.timer" \
                "$(iwe_cron_env_prefix) $SCRIPT_TARGET morning >> $HOME/logs/strategist/cron-morning.log 2>&1"); then
                echo "ERROR: утреннее cron-расписание не собрано; crontab не изменён" >&2
                exit 2
            fi
            if ! week_lines=$(iwe_timer_to_cron_lines \
                "$SYSTEMD_SRC/iwe-strategist-weekreview.timer" \
                "$(iwe_cron_env_prefix) $SCRIPT_TARGET week-review >> $HOME/logs/strategist/cron-weekreview.log 2>&1"); then
                echo "ERROR: недельное cron-расписание не собрано; crontab не изменён" >&2
                exit 2
            fi
            iwe_install_cron_fallback "strategist" "$morning_lines" "$week_lines"
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
        for unit in iwe-strategist-morning iwe-strategist-weekreview; do
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
for label in com.strategist.morning com.strategist.weekreview; do
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
    # кто его один раз отредактировал по несвязанной причине.
    if [ -f "$TARGET_DIR/$label.plist" ] && ! cmp -s "$TARGET_DIR/$label.plist" "$LAUNCHD_DIR/$label.plist"; then
        BACKUP="$TARGET_DIR/$label.plist.bak-$(date +%Y%m%dT%H%M%S)"
        cp "$TARGET_DIR/$label.plist" "$BACKUP"
        echo "  ⚠ $label.plist отличается от шаблона — старая версия сохранена в $(basename "$BACKUP") перед перезаписью"
    fi
    cp "$LAUNCHD_DIR/$label.plist" "$TARGET_DIR/"
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
