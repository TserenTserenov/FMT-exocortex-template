#!/bin/bash
# Install Strategist Agent launchd jobs
# WP-273 Stage 2: plists are taken from $IWE_RUNTIME (Generated runtime, F).
# Fallback to $SCRIPT_DIR/scripts/launchd/ — for old installs before 0.29.0.
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
    # Legacy: substituted FMT (before WP-273 Stage 2)
    LAUNCHD_DIR="$SCRIPT_DIR/scripts/launchd"
    SCRIPT_TARGET="$SCRIPT_DIR/scripts/strategist.sh"
    echo "  ⚠ Legacy mode: используются плейсхолдеры из FMT-substituted (запустите setup.sh ≥0.29.0 для архитектуры F)"
fi

# Resolve find-python3.sh for merge-launchd-schedule.py (issue #981) — same
# resolver contract as the rest of the template (WP-529 Phase 6/Phase 9, #453/#463):
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

# WP-273 R5 fix (Evgenii Round 5): fail-fast if the chosen plist contains a literal {{...}}.
# This prevents copying unreplaced placeholders into ~/Library/LaunchAgents/
# (if IWE_RUNTIME is not expanded, the fallback falls onto FMT with placeholders).
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

        # issue #285 (same class of bug, Linux equivalent): the user could explicitly
        # disable the timer (`systemctl --user disable iwe-strategist-morning.timer`)
        # — `systemctl --user is-enabled` then returns "disabled" (not "not-found",
        # this distinguishes «disabled» from «not installed yet»). An unconditional re-enable
        # on every role update would silently cancel the user's choice.
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

# Repair only an existing note-review configuration, including .plist.disabled.
# This helper never creates a job or calls launchctl; manual mode stays default.
if [ -e "$TARGET_DIR/com.strategist.notereview.plist" ] ||
   [ -L "$TARGET_DIR/com.strategist.notereview.plist" ] ||
   [ -e "$TARGET_DIR/com.strategist.notereview.plist.disabled" ] ||
   [ -L "$TARGET_DIR/com.strategist.notereview.plist.disabled" ]; then
    if [ -z "$MERGE_PYTHON3" ] || [ -z "${IWE_WORKSPACE:-}" ]; then
        echo "ERROR: note-review migration requires Python 3 and IWE_WORKSPACE; plist unchanged" >&2
        exit 1
    fi
    "$MERGE_PYTHON3" "$SCRIPT_DIR/migrate-notereview-launchd.py" \
        "$LAUNCHD_DIR/com.strategist.notereview.plist" "$TARGET_DIR" \
        "$IWE_WORKSPACE" "$SCRIPT_TARGET"
fi

# issue #285: the user disables the agent in the documented way
# (launchctl unload + rename to <label>.plist.disabled — a convention
# described in the issue by the pilot on his installation for com.strategist.scout;
# in this repo the scout plist is not shipped, the convention is applied here
# first). update.sh reacts
# to changes in roles/ and unconditionally restarts install.sh of every auto-role —
# without this check the .disabled marker was silently ignored, the disabled agent
# came back and was reloaded on every template update.
for label in com.strategist.morning com.strategist.weekreview; do
    if [ -f "$TARGET_DIR/$label.plist.disabled" ]; then
        echo "  ⊘ $label — disabled by user (найден $label.plist.disabled), пропускаю"
        continue
    fi
    if [ -z "${SETUP_CI:-}" ]; then
        launchctl unload "$TARGET_DIR/$label.plist" 2>/dev/null || true
    fi
    # issue #725: an unconditional cp erased the user's manual edit (for example,
    # a Weekday restriction) without warning or backup on every update.sh —
    # backup+warn was chosen over skip-if-diverged (peer session with Codex,
    # 2026-09-09): skip would freeze upstream plist fixes forever for those
    # who edited it once for an unrelated reason. The backup remains
    # a safeguard in case the merge below fails (issue #981).
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
