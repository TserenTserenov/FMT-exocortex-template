#!/usr/bin/env bash
# issue #1039: update.sh may refresh only the Linux schedule owned by this install.
set -euo pipefail

template_dir="$(cd "$(dirname "$0")/.." && pwd)"
update_sh="${IWE_TEST_UPDATE_SH:-$template_dir/update.sh}"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/iwe-linux-scheduler.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT

extract_function() {
    awk -v name="$1" '$0 ~ "^" name "\\(\\) \\{" { copy=1 } copy { print } copy && /^}$/ { exit }' "$update_sh"
}
functions="$fixture/functions.sh"
for name in canonical_workspace_path linux_systemd_strategist_owned \
            linux_cron_strategist_owned reinstall_linux_strategist; do
    extract_function "$name" >> "$functions"
done
if ! grep -q '^reinstall_linux_strategist()' "$functions"; then
    echo "FAIL: Linux reinstall path missing from update.sh" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$functions"

export HOME="$fixture/home" IWE_TEST_LOG="$fixture/calls.log"
export IWE_TEST_CRON="$fixture/crontab" IWE_TEST_BUS=1
WORKSPACE_DIR="$HOME/IWE"
SCRIPT_DIR="$fixture/template"
# The extracted update.sh functions read these globals dynamically.
# shellcheck disable=SC2034
HOST_GLOBAL_OWNER_CONFLICT=false
# shellcheck disable=SC2034
HOST_GLOBAL_OWNER_CONFLICT_REASON=""
mkdir -p "$HOME/.config/systemd/user" "$WORKSPACE_DIR/.iwe-runtime" \
    "$SCRIPT_DIR/roles/strategist" "$fixture/bin"

effective_governance_repo() { printf '%s\n' DS-test; }

cat > "$fixture/bin/systemctl" <<'SYSTEMCTL'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "$IWE_TEST_LOG"
case "$*" in
    '--user list-timers --no-legend') [ "$IWE_TEST_BUS" = 1 ] ;;
    '--user is-enabled '*weekreview.timer) printf '%s\n' "${IWE_TEST_WEEK_STATE:-enabled}" ;;
    '--user is-enabled '*morning.timer) printf '%s\n' "${IWE_TEST_MORNING_STATE:-enabled}" ;;
    '--user is-enabled '*notereview.timer) printf '%s\n' "${IWE_TEST_NOTEREVIEW_STATE:-enabled}" ;;
    '--user is-active '*weekreview.timer) printf '%s\n' "${IWE_TEST_WEEK_ACTIVE:-active}" ;;
    '--user is-active '*morning.timer) printf '%s\n' "${IWE_TEST_MORNING_ACTIVE:-active}" ;;
    '--user is-active '*notereview.timer) printf '%s\n' "${IWE_TEST_NOTEREVIEW_ACTIVE:-active}" ;;
    *) exit 0 ;;
esac
SYSTEMCTL
cat > "$fixture/bin/crontab" <<'CRONTAB'
#!/usr/bin/env bash
case "${1:-}" in
    -l) if [ "${IWE_TEST_CRON_ERROR:-0}" = 1 ]; then echo 'permission denied' >&2; exit 1; fi
        if [ ! -f "$IWE_TEST_CRON" ]; then echo 'no crontab for test' >&2; exit 1; fi
        cat "$IWE_TEST_CRON" ;;
    -) cat > "$IWE_TEST_CRON" ;;
    *) exit 2 ;;
esac
CRONTAB
cat > "$fixture/bin/uname" <<'UNAME'
#!/usr/bin/env bash
printf 'Linux\n'
UNAME
cat > "$SCRIPT_DIR/roles/strategist/install.sh" <<'INSTALL'
#!/usr/bin/env bash
printf 'install %s\n' "$IWE_WORKSPACE" >> "$IWE_TEST_LOG"
if [ "$IWE_TEST_BUS" = 1 ]; then
    cp "$IWE_RUNTIME/roles/strategist/scripts/systemd/"* \
        "$HOME/.config/systemd/user/"
    systemctl --user daemon-reload
else
    # Use the real cron writer: it replaces only the marked role block.
    source "$IWE_TEMPLATE/roles/lib/scheduler-cron.sh"
    iwe_install_cron_fallback strategist \
        "5 8 * * * $(iwe_cron_env_prefix) $IWE_RUNTIME/roles/strategist/scripts/strategist.sh morning >> $HOME/logs/strategist/cron-morning.log 2>&1" \
        "0 0 * * 1 $(iwe_cron_env_prefix) $IWE_RUNTIME/roles/strategist/scripts/strategist.sh week-review >> $HOME/logs/strategist/cron-weekreview.log 2>&1" \
        "0 23 * * * $(iwe_cron_env_prefix) $IWE_RUNTIME/roles/strategist/scripts/strategist.sh note-review >> $HOME/logs/strategist/cron-notereview.log 2>&1"
fi
INSTALL
mkdir -p "$SCRIPT_DIR/roles/lib"
cp "$template_dir/roles/lib/scheduler-cron.sh" "$SCRIPT_DIR/roles/lib/scheduler-cron.sh"
chmod +x "$fixture/bin/"* "$SCRIPT_DIR/roles/strategist/install.sh"
export PATH="$fixture/bin:$PATH"

unit_dir="$HOME/.config/systemd/user"
runtime_units="$WORKSPACE_DIR/.iwe-runtime/roles/strategist/scripts/systemd"
mkdir -p "$runtime_units"
write_units() {
    local owner="$1" unit mode
    for unit in iwe-strategist-morning iwe-strategist-weekreview iwe-strategist-notereview; do
        case "$unit" in
            iwe-strategist-morning) mode=morning ;;
            iwe-strategist-weekreview) mode=week-review ;;
            iwe-strategist-notereview) mode=note-review ;;
        esac
        printf '[Service]\nExecStart=%s/.iwe-runtime/roles/strategist/scripts/strategist.sh %s\nEnvironment=IWE_WORKSPACE=%s\n' \
            "$WORKSPACE_DIR" "$mode" "$owner" > "$unit_dir/$unit.service"
        printf '[Timer]\nOnCalendar=*-*-* 07:00:00\nUnit=%s.service\n' \
            "$unit" > "$unit_dir/$unit.timer"
        printf '[Service]\nExecStart=%s/.iwe-runtime/roles/strategist/scripts/strategist.sh %s\nEnvironment=IWE_WORKSPACE=%s\n' \
            "$WORKSPACE_DIR" "$mode" "$WORKSPACE_DIR" > "$runtime_units/$unit.service"
        printf '[Timer]\nOnCalendar=*-*-* 08:00:00\nUnit=%s.service\n' \
            "$unit" > "$runtime_units/$unit.timer"
    done
}
clear_units() { rm -f "$unit_dir"/iwe-strategist-*; }
write_cron_block() {
    local owner="$1" prefix
    # Same formatter as the real installer, with the requested owner in the
    # env prefix. The expected jobs are deliberately old schedules.
    source "$SCRIPT_DIR/roles/lib/scheduler-cron.sh"
    prefix=$(IWE_TEMPLATE="$SCRIPT_DIR" IWE_WORKSPACE="$owner" \
        IWE_RUNTIME="$WORKSPACE_DIR/.iwe-runtime" IWE_GOVERNANCE_REPO=DS-test \
        iwe_cron_env_prefix)
    printf '# BEGIN IWE-strategist (cron fallback, issue #454)\n' >> "$IWE_TEST_CRON"
    printf '0 7 * * * %s %s/.iwe-runtime/roles/strategist/scripts/strategist.sh morning >> %s/logs/strategist/cron-morning.log 2>&1\n' \
        "$prefix" "$WORKSPACE_DIR" "$HOME" >> "$IWE_TEST_CRON"
    printf '0 0 * * 1 %s %s/.iwe-runtime/roles/strategist/scripts/strategist.sh week-review >> %s/logs/strategist/cron-weekreview.log 2>&1\n' \
        "$prefix" "$WORKSPACE_DIR" "$HOME" >> "$IWE_TEST_CRON"
    printf '0 23 * * * %s %s/.iwe-runtime/roles/strategist/scripts/strategist.sh note-review >> %s/logs/strategist/cron-notereview.log 2>&1\n' \
        "$prefix" "$WORKSPACE_DIR" "$HOME" >> "$IWE_TEST_CRON"
    printf '# END IWE-strategist\n' >> "$IWE_TEST_CRON"
}
assert_no_install() {
    if grep -q '^install ' "$IWE_TEST_LOG"; then
        echo "FAIL: schedule installer ran without ownership proof" >&2
        exit 1
    fi
}

# Owned, active systemd timers receive the new unit and an actual restart.
write_units "$WORKSPACE_DIR"
: > "$IWE_TEST_LOG"
reinstall_linux_strategist > "$fixture/owned-systemd.log"
grep -q '08:00:00' "$unit_dir/iwe-strategist-morning.timer"
[ "$(grep -c '^systemctl --user restart ' "$IWE_TEST_LOG")" -eq 3 ]
echo 'PASS: owned systemd unit updated and both active timers restarted'

# A foreign service, a symlink, and a mixed backend cannot be rewritten.
write_units "$fixture/other-workspace"
: > "$IWE_TEST_LOG"
reinstall_linux_strategist > "$fixture/foreign-systemd.log"
assert_no_install
grep -q '07:00:00' "$unit_dir/iwe-strategist-morning.timer"
echo 'PASS: foreign systemd units preserved'

write_units "$WORKSPACE_DIR"
rm "$unit_dir/iwe-strategist-morning.service"
ln -s /dev/null "$unit_dir/iwe-strategist-morning.service"
: > "$IWE_TEST_LOG"
reinstall_linux_strategist > "$fixture/masked-systemd.log"
assert_no_install
echo 'PASS: masked/symlink systemd unit preserved'

write_units "$WORKSPACE_DIR"
mkdir "$unit_dir/iwe-strategist-morning.service.d"
: > "$IWE_TEST_LOG"
reinstall_linux_strategist > "$fixture/dropin-systemd.log"
assert_no_install
rmdir "$unit_dir/iwe-strategist-morning.service.d"
echo 'PASS: systemd drop-in prevents ownership claim'

write_units "$WORKSPACE_DIR"
printf 'EnvironmentFile=/tmp/foreign-env\n' >> "$unit_dir/iwe-strategist-morning.service"
: > "$IWE_TEST_LOG"
reinstall_linux_strategist > "$fixture/envfile-systemd.log"
assert_no_install
echo 'PASS: systemd EnvironmentFile prevents ownership claim'

write_units "$WORKSPACE_DIR"
sed 's/Unit=iwe-strategist-morning.service/Unit=other.service/' \
    "$unit_dir/iwe-strategist-morning.timer" > "$fixture/other.timer"
cp "$fixture/other.timer" "$unit_dir/iwe-strategist-morning.timer"
: > "$IWE_TEST_LOG"
reinstall_linux_strategist > "$fixture/custom-unit-systemd.log"
assert_no_install
echo 'PASS: custom systemd Unit target prevents ownership claim'

write_units "$WORKSPACE_DIR"
printf '0 7 * * * %s/.iwe-runtime/roles/strategist/scripts/strategist.sh morning\n' \
    "$fixture/other-workspace" > "$IWE_TEST_CRON"
: > "$IWE_TEST_LOG"
reinstall_linux_strategist > "$fixture/handrolled-cron.log"
assert_no_install
rm "$IWE_TEST_CRON"
echo 'PASS: hand-rolled cron outside sentinel blocks systemd reinstall'

export IWE_TEST_CRON_ERROR=1
: > "$IWE_TEST_LOG"
reinstall_linux_strategist > "$fixture/crontab-error.log"
assert_no_install
unset IWE_TEST_CRON_ERROR
echo 'PASS: crontab read error blocks systemd reinstall'

write_units "$WORKSPACE_DIR"
export IWE_TEST_MORNING_ACTIVE=inactive
: > "$IWE_TEST_LOG"
reinstall_linux_strategist > "$fixture/stopped-systemd.log"
assert_no_install
grep -q '07:00:00' "$unit_dir/iwe-strategist-morning.timer"
unset IWE_TEST_MORNING_ACTIVE
echo 'PASS: manually stopped systemd timer is not restarted'

export IWE_TEST_MORNING_STATE=disabled IWE_TEST_WEEK_STATE=masked
: > "$IWE_TEST_LOG"
reinstall_linux_strategist > "$fixture/disabled-systemd-preflight.log"
assert_no_install
unset IWE_TEST_MORNING_STATE IWE_TEST_WEEK_STATE
echo 'PASS: disabled and masked systemd timers are not reinstalled'

clear_units
export IWE_TEST_BUS=0
printf '# unrelated user job\n12 4 * * * user-job\n' > "$IWE_TEST_CRON"
write_cron_block "$WORKSPACE_DIR"
cp "$IWE_TEST_CRON" "$fixture/owned-cron.before"
: > "$IWE_TEST_LOG"
reinstall_linux_strategist > "$fixture/owned-cron.log"
grep -q '^5 8 \* \* \* ' "$IWE_TEST_CRON"
grep -q 'user-job' "$IWE_TEST_CRON"
if grep -q '^0 7 \* \* \* ' "$IWE_TEST_CRON"; then
    echo 'FAIL: old cron morning time survived the update' >&2; exit 1
fi
cron_backup=$(find "$HOME/.local/state/iwe/cron-backups" -type f -print -quit)
[ -n "$cron_backup" ] && cmp "$fixture/owned-cron.before" "$cron_backup"
echo 'PASS: owned cron block updated without touching user job'

: > "$IWE_TEST_CRON"
write_cron_block "$fixture/other-workspace"
cp "$IWE_TEST_CRON" "$fixture/foreign-cron.before"
: > "$IWE_TEST_LOG"
reinstall_linux_strategist > "$fixture/foreign-cron.log"
assert_no_install
cmp "$fixture/foreign-cron.before" "$IWE_TEST_CRON"
echo 'PASS: foreign cron block preserved byte for byte'

printf '# BEGIN IWE-strategist (cron fallback, issue #454)\n0 7 * * * IWE_WORKSPACE=%s echo foreign-job # IWE_WORKSPACE=%s %s/.iwe-runtime/roles/strategist/scripts/strategist.sh morning\n# END IWE-strategist\n' \
    "$fixture/other-workspace" "$WORKSPACE_DIR" "$WORKSPACE_DIR" > "$IWE_TEST_CRON"
cp "$IWE_TEST_CRON" "$fixture/spoof-cron.before"
: > "$IWE_TEST_LOG"
reinstall_linux_strategist > "$fixture/spoof-cron.log"
assert_no_install
cmp "$fixture/spoof-cron.before" "$IWE_TEST_CRON"
echo 'PASS: owner path in cron comment cannot spoof ownership'

: > "$IWE_TEST_CRON"
write_cron_block "$WORKSPACE_DIR"
sed '/ week-review >> /d' "$IWE_TEST_CRON" > "$fixture/morning-only"
cp "$fixture/morning-only" "$IWE_TEST_CRON"
: > "$IWE_TEST_LOG"
reinstall_linux_strategist > "$fixture/morning-only.log"
assert_no_install
echo 'PASS: removed week-review job is not recreated'

printf '# BEGIN IWE-strategist (cron fallback, issue #454)\n0 7 * * * echo '\'' IWE_WORKSPACE=%s %s/.iwe-runtime/roles/strategist/scripts/strategist.sh morning '\''\n# END IWE-strategist\n' \
    "$WORKSPACE_DIR" "$WORKSPACE_DIR" > "$IWE_TEST_CRON"
: > "$IWE_TEST_LOG"
reinstall_linux_strategist > "$fixture/echo-spoof.log"
assert_no_install
echo 'PASS: path inside cron echo command cannot spoof ownership'

printf '# BEGIN IWE-strategist (cron fallback, issue #454)\n# disabled by user\n# END IWE-strategist\n' > "$IWE_TEST_CRON"
: > "$IWE_TEST_LOG"
reinstall_linux_strategist > "$fixture/disabled-cron.log"
assert_no_install
echo 'PASS: disabled cron job stays disabled'

: > "$IWE_TEST_CRON"
write_cron_block "$WORKSPACE_DIR"
write_cron_block "$WORKSPACE_DIR"
: > "$IWE_TEST_LOG"
reinstall_linux_strategist > "$fixture/duplicate-cron.log"
assert_no_install
echo 'PASS: duplicate cron blocks are rejected'

write_units "$WORKSPACE_DIR"
: > "$IWE_TEST_CRON"
write_cron_block "$WORKSPACE_DIR"
: > "$IWE_TEST_LOG"
reinstall_linux_strategist > "$fixture/mixed.log"
assert_no_install
echo 'PASS: mixed systemd/cron backend requires manual decision'

# Exercise the real role installer too: disabled and masked timers remain
# untouched while an enabled timer receives the rebuilt runtime unit.
cp "$template_dir/roles/strategist/install.sh" \
    "$SCRIPT_DIR/roles/strategist/install.sh"
mkdir -p "$WORKSPACE_DIR/.iwe-runtime/roles/strategist/scripts/launchd"
for label in com.strategist.morning com.strategist.weekreview com.strategist.notereview; do
    printf '<plist>test</plist>\n' > \
        "$WORKSPACE_DIR/.iwe-runtime/roles/strategist/scripts/launchd/$label.plist"
done
write_units "$WORKSPACE_DIR"
rm -f "$IWE_TEST_CRON"
export IWE_TEST_BUS=1 IWE_TEST_MORNING_STATE=disabled IWE_TEST_WEEK_STATE=masked IWE_TEST_NOTEREVIEW_STATE=masked
: > "$IWE_TEST_LOG"
IWE_WORKSPACE="$WORKSPACE_DIR" IWE_RUNTIME="$WORKSPACE_DIR/.iwe-runtime" \
    IWE_TEMPLATE="$SCRIPT_DIR" bash "$SCRIPT_DIR/roles/strategist/install.sh" \
    > "$fixture/disabled-systemd.log"
grep -q '07:00:00' "$unit_dir/iwe-strategist-morning.timer"
grep -q '07:00:00' "$unit_dir/iwe-strategist-weekreview.timer"
if grep -q '^systemctl --user enable --now' "$IWE_TEST_LOG"; then
    echo 'FAIL: disabled or masked timer was activated' >&2; exit 1
fi
echo 'PASS: real installer preserves disabled and masked timers'

export IWE_TEST_MORNING_STATE=enabled IWE_TEST_WEEK_STATE=enabled IWE_TEST_NOTEREVIEW_STATE=enabled
: > "$IWE_TEST_LOG"
IWE_WORKSPACE="$WORKSPACE_DIR" IWE_RUNTIME="$WORKSPACE_DIR/.iwe-runtime" \
    IWE_TEMPLATE="$SCRIPT_DIR" bash "$SCRIPT_DIR/roles/strategist/install.sh" \
    > "$fixture/enabled-systemd.log"
grep -q '08:00:00' "$unit_dir/iwe-strategist-morning.timer"
grep -q '08:00:00' "$unit_dir/iwe-strategist-weekreview.timer"
[ "$(grep -c '^systemctl --user enable --now ' "$IWE_TEST_LOG")" -eq 3 ]
backup=$(find "$unit_dir" -maxdepth 1 -name 'iwe-strategist-morning.timer.bak-*' -print -quit)
[ -n "$backup" ] && grep -q '07:00:00' "$backup"
echo 'PASS: real installer loads rebuilt enabled timers'

# The pre-notereview layout must keep receiving updates. Use the real
# installer here: a stub that copies all runtime units hides re-creation bugs.
write_units "$WORKSPACE_DIR"
rm "$unit_dir/iwe-strategist-notereview.service" "$unit_dir/iwe-strategist-notereview.timer"
export IWE_TEST_NOTEREVIEW_STATE=not-found
: > "$IWE_TEST_LOG"
reinstall_linux_strategist > "$fixture/legacy-systemd.log"
grep -q '08:00:00' "$unit_dir/iwe-strategist-morning.timer"
grep -q '08:00:00' "$unit_dir/iwe-strategist-weekreview.timer"
[ "$(grep -c '^systemctl --user restart ' "$IWE_TEST_LOG")" -eq 2 ]
[ ! -e "$unit_dir/iwe-strategist-notereview.service" ]
[ ! -e "$unit_dir/iwe-strategist-notereview.timer" ]
! grep -q 'notereview' "$IWE_TEST_LOG"
echo 'PASS: legacy systemd updates two existing jobs without enabling a new job'

# A partial optional unit, a dangling mask or a drop-in cannot masquerade as
# the legacy layout. Keep the entire schedule unchanged without owner proof.
for artifact in partial dangling-mask dropin; do
    write_units "$WORKSPACE_DIR"
    rm "$unit_dir/iwe-strategist-notereview.service" "$unit_dir/iwe-strategist-notereview.timer"
    case "$artifact" in
        partial) cp "$runtime_units/iwe-strategist-notereview.service" "$unit_dir/" ;;
        dangling-mask) ln -s "$fixture/missing-mask" "$unit_dir/iwe-strategist-notereview.timer" ;;
        dropin) mkdir "$unit_dir/iwe-strategist-notereview.service.d" ;;
    esac
    : > "$IWE_TEST_LOG"
    reinstall_linux_strategist > "$fixture/optional-$artifact.log"
    grep -q '07:00:00' "$unit_dir/iwe-strategist-morning.timer"
    ! grep -q '^systemctl --user enable\|^systemctl --user restart' "$IWE_TEST_LOG"
    rm -f "$unit_dir/iwe-strategist-notereview.service" "$unit_dir/iwe-strategist-notereview.timer"
    if [ "$artifact" = dropin ]; then rmdir "$unit_dir/iwe-strategist-notereview.service.d"; fi
done
echo 'PASS: incomplete optional units, dangling masks and drop-ins block update'

write_units "$WORKSPACE_DIR"
rm "$unit_dir/iwe-strategist-notereview.service" "$unit_dir/iwe-strategist-notereview.timer"
export IWE_TEST_MORNING_STATE=disabled IWE_TEST_WEEK_STATE=masked
: > "$IWE_TEST_LOG"
reinstall_linux_strategist > "$fixture/legacy-disabled.log"
grep -q '07:00:00' "$unit_dir/iwe-strategist-morning.timer"
! grep -q '^systemctl --user enable\|^systemctl --user restart' "$IWE_TEST_LOG"
[ ! -e "$unit_dir/iwe-strategist-notereview.timer" ]
echo 'PASS: disabled legacy jobs stay disabled and do not enable notereview'
export IWE_TEST_MORNING_STATE=enabled IWE_TEST_WEEK_STATE=enabled IWE_TEST_NOTEREVIEW_STATE=enabled

clear_units
export IWE_TEST_BUS=0
printf '# unrelated user job\n12 4 * * * user-job\n' > "$IWE_TEST_CRON"
write_cron_block "$WORKSPACE_DIR"
sed '/ note-review /d' "$IWE_TEST_CRON" > "$fixture/legacy-cron"
cp "$fixture/legacy-cron" "$IWE_TEST_CRON"
# A comment mentioning the missing job must not select it for installation.
printf '# %s/.iwe-runtime/roles/strategist/scripts/strategist.sh note-review >> %s/logs/strategist/cron-notereview.log 2>&1\n' \
    "$WORKSPACE_DIR" "$HOME" >> "$IWE_TEST_CRON"
reinstall_linux_strategist > "$fixture/legacy-cron.log"
grep -q '^0 8 \* \* \* ' "$IWE_TEST_CRON"
grep -q 'user-job' "$IWE_TEST_CRON"
[ "$(grep -v '^#' "$IWE_TEST_CRON" | grep -c 'strategist.sh')" -eq 2 ]
! grep -v '^#' "$IWE_TEST_CRON" | grep -q 'note-review'
echo 'PASS: legacy cron updates only existing jobs and ignores comments'

: > "$IWE_TEST_CRON"
write_cron_block "$WORKSPACE_DIR"
awk '/ note-review / { print } { print }' "$IWE_TEST_CRON" > "$fixture/duplicate-note-cron"
cp "$fixture/duplicate-note-cron" "$IWE_TEST_CRON"
reinstall_linux_strategist > "$fixture/duplicate-note.log"
cmp "$fixture/duplicate-note-cron" "$IWE_TEST_CRON"
echo 'PASS: duplicate optional cron job is not accepted as owned'

# A fresh installation keeps note-review manual; the full three-job selection
# is explicit. Subsequent default installs preserve an already selected job.
rm -f "$IWE_TEST_CRON"
clear_units
export IWE_TEST_BUS=1 IWE_TEST_NOTEREVIEW_STATE=not-found
: > "$IWE_TEST_LOG"
IWE_WORKSPACE="$WORKSPACE_DIR" IWE_RUNTIME="$WORKSPACE_DIR/.iwe-runtime" \
    IWE_TEMPLATE="$SCRIPT_DIR" bash "$SCRIPT_DIR/roles/strategist/install.sh" > "$fixture/fresh-default.log"
[ ! -e "$unit_dir/iwe-strategist-notereview.timer" ]
[ "$(grep -c '^systemctl --user enable --now ' "$IWE_TEST_LOG")" -eq 2 ]
IWE_WORKSPACE="$WORKSPACE_DIR" IWE_RUNTIME="$WORKSPACE_DIR/.iwe-runtime" \
    IWE_TEMPLATE="$SCRIPT_DIR" bash "$SCRIPT_DIR/roles/strategist/install.sh" \
    morning weekreview notereview > "$fixture/fresh-explicit.log"
[ -f "$unit_dir/iwe-strategist-notereview.timer" ]
echo 'PASS: fresh systemd keeps note-review manual until explicitly selected'

clear_units
export IWE_TEST_BUS=0
rm -f "$IWE_TEST_CRON"
IWE_WORKSPACE="$WORKSPACE_DIR" IWE_RUNTIME="$WORKSPACE_DIR/.iwe-runtime" \
    IWE_TEMPLATE="$SCRIPT_DIR" bash "$SCRIPT_DIR/roles/strategist/install.sh" > "$fixture/fresh-cron.log"
[ "$(grep -c 'strategist.sh' "$IWE_TEST_CRON")" -eq 2 ]
IWE_WORKSPACE="$WORKSPACE_DIR" IWE_RUNTIME="$WORKSPACE_DIR/.iwe-runtime" \
    IWE_TEMPLATE="$SCRIPT_DIR" bash "$SCRIPT_DIR/roles/strategist/install.sh" \
    morning weekreview notereview > "$fixture/explicit-cron.log"
[ "$(grep -c 'strategist.sh' "$IWE_TEST_CRON")" -eq 3 ]
IWE_WORKSPACE="$WORKSPACE_DIR" IWE_RUNTIME="$WORKSPACE_DIR/.iwe-runtime" \
    IWE_TEMPLATE="$SCRIPT_DIR" bash "$SCRIPT_DIR/roles/strategist/install.sh" > "$fixture/preserve-cron.log"
[ "$(grep -c 'strategist.sh' "$IWE_TEST_CRON")" -eq 3 ]
cp "$IWE_TEST_CRON" "$fixture/selection-before"
for selection in notereview morning 'morning weekreview notereview notereview' unknown; do
    # Intentional splitting: these fixed strings exercise the argv contract.
    # shellcheck disable=SC2086
    if IWE_WORKSPACE="$WORKSPACE_DIR" IWE_RUNTIME="$WORKSPACE_DIR/.iwe-runtime" \
       IWE_TEMPLATE="$SCRIPT_DIR" bash "$SCRIPT_DIR/roles/strategist/install.sh" $selection \
       > "$fixture/invalid-selection.log" 2>&1; then
        echo 'FAIL: invalid/partial job selection accepted' >&2; exit 1
    fi
    cmp "$fixture/selection-before" "$IWE_TEST_CRON"
done
echo 'PASS: fresh cron requires explicit note-review and rejects partial selections'

# The same default is required for macOS: update.sh invokes install.sh with
# no arguments. SETUP_CI suppresses all service actions in this fixture.
printf '#!/usr/bin/env bash\nprintf "Darwin\\n"\n' > "$fixture/bin/uname"
printf '#!/usr/bin/env bash\necho "unexpected launchctl" >&2\nexit 99\n' > "$fixture/bin/launchctl"
chmod +x "$fixture/bin/launchctl"
IWE_WORKSPACE="$WORKSPACE_DIR" IWE_RUNTIME="$WORKSPACE_DIR/.iwe-runtime" \
    IWE_TEMPLATE="$SCRIPT_DIR" SETUP_CI=1 bash "$SCRIPT_DIR/roles/strategist/install.sh" > "$fixture/mac-default.log"
mac_plists="$HOME/Library/LaunchAgents"
[ -f "$mac_plists/com.strategist.morning.plist" ]
[ ! -e "$mac_plists/com.strategist.notereview.plist" ]
IWE_WORKSPACE="$WORKSPACE_DIR" IWE_RUNTIME="$WORKSPACE_DIR/.iwe-runtime" \
    IWE_TEMPLATE="$SCRIPT_DIR" SETUP_CI=1 bash "$SCRIPT_DIR/roles/strategist/install.sh" \
    morning weekreview notereview > "$fixture/mac-explicit.log" 2>&1
[ -f "$mac_plists/com.strategist.notereview.plist" ]
printf '<plist>new-note</plist>\n' > "$WORKSPACE_DIR/.iwe-runtime/roles/strategist/scripts/launchd/com.strategist.notereview.plist"
IWE_WORKSPACE="$WORKSPACE_DIR" IWE_RUNTIME="$WORKSPACE_DIR/.iwe-runtime" \
    IWE_TEMPLATE="$SCRIPT_DIR" SETUP_CI=1 bash "$SCRIPT_DIR/roles/strategist/install.sh" > "$fixture/mac-existing.log" 2>&1
grep -q 'new-note' "$mac_plists/com.strategist.notereview.plist"
mv "$mac_plists/com.strategist.notereview.plist" "$mac_plists/com.strategist.notereview.plist.disabled"
IWE_WORKSPACE="$WORKSPACE_DIR" IWE_RUNTIME="$WORKSPACE_DIR/.iwe-runtime" \
    IWE_TEMPLATE="$SCRIPT_DIR" SETUP_CI=1 bash "$SCRIPT_DIR/roles/strategist/install.sh" > "$fixture/mac-disabled.log" 2>&1
[ ! -e "$mac_plists/com.strategist.notereview.plist" ]
[ -f "$mac_plists/com.strategist.notereview.plist.disabled" ]
echo 'PASS: macOS default preserves manual mode, existing opt-in and disabled marker'
printf '#!/usr/bin/env bash\nprintf "Linux\\n"\n' > "$fixture/bin/uname"

# A one-digit timezone hour is produced by setup.sh (TIMEZONE_HOUR=4). Invalid
# or partial calendars must fail without emitting a partial cron schedule.
source "$template_dir/roles/lib/scheduler-cron.sh"
timer="$fixture/calendar.timer"
printf '[Timer]\nOnCalendar=*-*-* 4:00:00\n' > "$timer"
[ "$(iwe_timer_to_cron_lines "$timer" 'run-morning')" = '0 4 * * *  run-morning' ]
printf '[Timer]\nOnCalendar=Mon *-*-* 0:00:00\n' > "$timer"
[ "$(iwe_timer_to_cron_lines "$timer" 'run-week')" = '0 0 * * 1 run-week' ]
for spec in '*-*-* 24:00:00' '*-*-* 4:60:00' '*-*-* unsupported'; do
    printf '[Timer]\nOnCalendar=*-*-* 4:00:00\nOnCalendar=%s\n' "$spec" > "$timer"
    if output=$(iwe_timer_to_cron_lines "$timer" 'run-morning' 2>/dev/null); then
        echo "FAIL: invalid calendar accepted: $spec" >&2; exit 1
    fi
    [ -z "$output" ]
done
printf '[Timer]\nOnCalendar=*-*-* 4:00:00\nOnCalendar=unsupported' > "$timer"
if output=$(iwe_timer_to_cron_lines "$timer" 'run-morning' 2>/dev/null); then
    echo 'FAIL: invalid final calendar without newline accepted' >&2; exit 1
fi
[ -z "$output" ]
printf '[Timer]\nOnCalendar=*-*-* 4:00:00' > "$timer"
[ "$(iwe_timer_to_cron_lines "$timer" 'run-morning')" = '0 4 * * *  run-morning' ]
printf '[Timer]\nOnUnitActiveSec=3h\n' > "$timer"
if iwe_timer_to_cron_lines "$timer" 'run' >/dev/null 2>&1; then
    echo 'FAIL: missing OnCalendar accepted' >&2; exit 1
fi
if iwe_timer_to_cron_lines "$fixture/missing.timer" 'run' >/dev/null 2>&1; then
    echo 'FAIL: missing timer accepted' >&2; exit 1
fi
echo 'PASS: calendar conversion handles one-digit hours and fails atomically'

printf '12 4 * * * user-job\n' > "$IWE_TEST_CRON"
cp "$IWE_TEST_CRON" "$fixture/crontab-before-error"
export IWE_TEST_CRON_ERROR=1
if iwe_install_cron_fallback strategist '0 4 * * * run' >/dev/null 2>&1; then
    echo 'FAIL: crontab read error accepted' >&2; exit 1
fi
unset IWE_TEST_CRON_ERROR
cmp "$fixture/crontab-before-error" "$IWE_TEST_CRON"
printf '# BEGIN IWE-strategist (cron fallback, issue #454)\n12 4 * * * user-job\n' > "$IWE_TEST_CRON"
cp "$IWE_TEST_CRON" "$fixture/crontab-malformed"
if iwe_install_cron_fallback strategist '0 4 * * * run' >/dev/null 2>&1; then
    echo 'FAIL: malformed cron block accepted' >&2; exit 1
fi
cmp "$fixture/crontab-malformed" "$IWE_TEST_CRON"
echo 'PASS: cron writer preserves crontab on read errors and malformed markers'

export IWE_TEST_BUS=0
printf '12 4 * * * user-job\n' > "$IWE_TEST_CRON"
cp "$IWE_TEST_CRON" "$fixture/crontab-before-install"
printf '[Timer]\nOnCalendar=unsupported\n' > "$runtime_units/iwe-strategist-morning.timer"
printf '[Timer]\nOnCalendar=Mon *-*-* 0:00:00\n' > "$runtime_units/iwe-strategist-weekreview.timer"
if IWE_WORKSPACE="$WORKSPACE_DIR" IWE_RUNTIME="$WORKSPACE_DIR/.iwe-runtime" \
   IWE_TEMPLATE="$SCRIPT_DIR" bash "$SCRIPT_DIR/roles/strategist/install.sh" \
   > "$fixture/invalid-strategist.log" 2>&1; then
    echo 'FAIL: strategist accepted an invalid morning timer' >&2; exit 1
fi
cmp "$fixture/crontab-before-install" "$IWE_TEST_CRON"
echo 'PASS: strategist leaves cron untouched when one timer cannot convert'

mkdir -p "$SCRIPT_DIR/roles/synchronizer" \
    "$WORKSPACE_DIR/.iwe-runtime/roles/synchronizer/scripts/launchd" \
    "$WORKSPACE_DIR/.iwe-runtime/roles/synchronizer/scripts/systemd"
cp "$template_dir/roles/synchronizer/install.sh" "$SCRIPT_DIR/roles/synchronizer/install.sh"
printf '<plist>test</plist>\n' > \
    "$WORKSPACE_DIR/.iwe-runtime/roles/synchronizer/scripts/launchd/com.exocortex.scheduler.plist"
sync_timer="$WORKSPACE_DIR/.iwe-runtime/roles/synchronizer/scripts/systemd/iwe-exocortex-scheduler.timer"
printf '[Timer]\nOnCalendar=unsupported\n' > "$sync_timer"
if IWE_WORKSPACE="$WORKSPACE_DIR" IWE_RUNTIME="$WORKSPACE_DIR/.iwe-runtime" \
   IWE_TEMPLATE="$SCRIPT_DIR" bash "$SCRIPT_DIR/roles/synchronizer/install.sh" \
   > "$fixture/invalid-synchronizer.log" 2>&1; then
    echo 'FAIL: synchronizer accepted an invalid timer' >&2; exit 1
fi
cmp "$fixture/crontab-before-install" "$IWE_TEST_CRON"
printf '[Timer]\nOnCalendar=*-*-* 4:00:00\n' > "$sync_timer"
IWE_WORKSPACE="$WORKSPACE_DIR" IWE_RUNTIME="$WORKSPACE_DIR/.iwe-runtime" \
    IWE_TEMPLATE="$SCRIPT_DIR" bash "$SCRIPT_DIR/roles/synchronizer/install.sh" \
    > "$fixture/valid-synchronizer.log" 2>&1
grep -q 'scheduler.sh dispatch' "$IWE_TEST_CRON"
grep -q 'user-job' "$IWE_TEST_CRON"
echo 'PASS: synchronizer rejects invalid and installs valid one-digit-hour timer'
