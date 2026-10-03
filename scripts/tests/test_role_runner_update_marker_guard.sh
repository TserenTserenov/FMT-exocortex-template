#!/usr/bin/env bash
# test_role_runner_update_marker_guard.sh — WP-529 F6 (Evgenii post-update
# defect #1, 18.08): update.sh reinstalls auto-roles while .update-incomplete
# is still present (the transaction closes at the very end), and RunAtLoad in
# the strategist plists fires the agent right at launchctl load — a mutating
# run started mid-update at 22:38. Issue #1029: a successful skip made the
# scheduler mark Day Open done. The runner must defer without mutation, and
# the scheduler must retry after the marker disappears.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/template" "$TMP/ws" "$TMP/home"
touch "$TMP/template/.update-incomplete"

echo "--- with marker: runner must skip before any mutation ---"
set +e
OUT=$(HOME="$TMP/home" IWE_TEMPLATE="$TMP/template" IWE_WORKSPACE="$TMP/ws" \
      bash "$ROOT/roles/strategist/scripts/strategist.sh" morning 2>&1)
RC=$?
set -e

if [ "$RC" -ne 75 ]; then
    echo "❌ FAIL: expected temporary failure (exit 75), got $RC"
    echo "$OUT"
    exit 1
fi
if ! echo "$OUT" | grep -q "template update incomplete"; then
    echo "❌ FAIL: actionable update-incomplete message not printed"
    echo "$OUT"
    exit 1
fi
if [ -d "$TMP/home/logs/strategist" ]; then
    echo "❌ FAIL: log/lock dirs created — runner went past the guard"
    exit 1
fi
echo "✅ PASS: strategist.sh defers without mutation while .update-incomplete is present"

echo "--- without marker: guard must NOT short-circuit the runner ---"
rm "$TMP/template/.update-incomplete"
set +e
OUT2=$(HOME="$TMP/home" IWE_TEMPLATE="$TMP/template" IWE_WORKSPACE="$TMP/ws" \
       PATH="/usr/bin:/bin" bash "$ROOT/roles/strategist/scripts/strategist.sh" morning 2>&1)
RC2=$?
set -e

# Without claude CLI in PATH the runner proceeds past the guard and fails
# later (exit 127 at the CLAUDE_PATH check, or otherwise non-zero). A clean
# exit 0 with the update-skip message would mean the guard fires spuriously.
if [ "$RC2" -eq 0 ] && echo "$OUT2" | grep -q "template update incomplete"; then
    echo "❌ FAIL: guard fired without a marker"
    echo "$OUT2"
    exit 1
fi
echo "✅ PASS: without the marker the guard does not short-circuit (rc=$RC2)"

echo "--- scheduler: blocked morning must remain retryable ---"
DATE_FIXED=2026-10-06
STATE_DIR="$TMP/home/.local/state/exocortex"
SCHEDULER_LOG="$TMP/home/logs/synchronizer/scheduler-$DATE_FIXED.log"
RUNNER="$TMP/runtime/roles/strategist/scripts/strategist.sh"
mkdir -p "$TMP/bin" "$TMP/template/roles/strategist" "$(dirname "$RUNNER")" "$STATE_DIR" "$TMP/ws"
cp "$ROOT/roles/strategist/role.yaml" "$TMP/template/roles/strategist/role.yaml"
cp "$ROOT/roles/strategist/scripts/strategist.sh" "$RUNNER"
chmod +x "$RUNNER"
touch "$TMP/template/.update-incomplete" "$STATE_DIR/synchronizer-code-scan-$DATE_FIXED" \
      "$STATE_DIR/synchronizer-daily-report-$DATE_FIXED" "$STATE_DIR/pmset-check-$DATE_FIXED"
printf '1000000\n' > "$STATE_DIR/extractor-inbox-check-last"
cat > "$TMP/bin/date" <<'SH'
#!/bin/sh
case "${1:-}" in
    +%H) echo 08 ;;
    +%u) echo 2 ;;
    +%Y-%m-%d) echo 2026-10-06 ;;
    +%V) echo 41 ;;
    +%s) echo 1000000 ;;
    *) /bin/date "$@" ;;
esac
SH
cat > "$TMP/bin/uname" <<'SH'
#!/bin/sh
echo FixtureOS
SH
cat > "$TMP/bin/systemd-inhibit" <<'SH'
#!/bin/sh
exec /bin/sleep 120
SH
chmod +x "$TMP/bin/date" "$TMP/bin/uname" "$TMP/bin/systemd-inhibit"
mkdir -p "$TMP/template/roles/synchronizer/scripts"
cat > "$TMP/template/roles/synchronizer/scripts/notify.sh" <<'SH'
#!/bin/sh
printf '%s %s %s %s\n' "$1" "$2" "$DAY_OPEN_FAILED_REASON" "$DAY_OPEN_FAILED_RC" \
    >> "$IWE_WORKSPACE/notify-attempts"
if [ "$(wc -l < "$IWE_WORKSPACE/notify-attempts")" -eq 1 ]; then
    # Real notify.sh also exits 0 when Telegram rejects the request.
    echo 'Telegram send FAILED: strategist/day-open-failed'
    exit 0
fi
echo 'Telegram notification sent: strategist/day-open-failed'
SH
chmod +x "$TMP/template/roles/synchronizer/scripts/notify.sh"

run_dispatch() {
    local tool_path="${1:-$TMP/bin:/usr/bin:/bin}"
    HOME="$TMP/home" IWE_TEMPLATE="$TMP/template" IWE_WORKSPACE="$TMP/ws" \
        IWE_RUNTIME="$TMP/runtime" PATH="$tool_path" \
        bash "$ROOT/roles/synchronizer/scripts/scheduler.sh" dispatch > "$TMP/dispatch.out" 2>&1 || {
            cat "$TMP/dispatch.out"
            return 1
        }
}

run_dispatch
if [ -e "$STATE_DIR/strategist-morning-update-alert-$DATE_FIXED" ]; then
    echo "❌ FAIL: rejected notification was marked as delivered"
    exit 1
fi
run_dispatch
run_dispatch
if [ -e "$STATE_DIR/strategist-morning-$DATE_FIXED" ]; then
    echo "❌ FAIL: scheduler marked Day Open done while update marker exists"
    exit 1
fi
if [ "$(grep -cF '→ strategist morning' "$SCHEDULER_LOG")" -ne 3 ]; then
    echo "❌ FAIL: scheduler did not retry blocked morning on the next dispatch"
    exit 1
fi
if ! grep -qF 'ALARM: strategist morning deferred' "$SCHEDULER_LOG"; then
    echo "❌ FAIL: scheduler did not record a visible update-blocked alarm"
    exit 1
fi
if [ ! -f "$TMP/ws/notify-attempts" ] || \
   [ "$(wc -l < "$TMP/ws/notify-attempts")" -ne 2 ] || \
   [ "$(tail -1 "$TMP/ws/notify-attempts")" != 'strategist day-open-failed update-incomplete 75' ] || \
   [ ! -f "$STATE_DIR/strategist-morning-update-alert-$DATE_FIXED" ]; then
    echo "❌ FAIL: rejected notification was not retried and accepted notification not deduplicated"
    exit 1
fi

MESSAGE=$(HOME="$TMP/home" DAY_OPEN_FAILED_REASON=update-incomplete DAY_OPEN_FAILED_RC=75 \
    bash -c 'source "$1"; build_message day-open-failed' _ \
    "$ROOT/roles/synchronizer/scripts/templates/strategist.sh")
if ! printf '%s\n' "$MESSAGE" | grep -qF 'Обновление шаблона не завершено'; then
    echo "❌ FAIL: delivered notification does not explain the incomplete update"
    exit 1
fi

rm "$TMP/template/.update-incomplete"
cat > "$RUNNER" <<'SH'
#!/bin/sh
printf '%s\n' "$1" >> "$IWE_WORKSPACE/day-open-attempts"
exit 0
SH
chmod +x "$RUNNER"
run_dispatch
run_dispatch
if [ ! -f "$STATE_DIR/strategist-morning-$DATE_FIXED" ] || \
   [ "$(cat "$TMP/ws/day-open-attempts")" != morning ]; then
    echo "❌ FAIL: recovered morning did not run exactly once and mark completion"
    exit 1
fi
echo "✅ PASS: scheduler retries failed notice, deduplicates delivery, and completes after recovery"

echo "--- hung notifier must not hold scheduler dispatch ---"
rm "$STATE_DIR/strategist-morning-$DATE_FIXED" \
   "$STATE_DIR/strategist-morning-update-alert-$DATE_FIXED"
touch "$TMP/template/.update-incomplete"
cp "$ROOT/roles/strategist/scripts/strategist.sh" "$RUNNER"
chmod +x "$RUNNER"
cat > "$TMP/template/roles/synchronizer/scripts/notify.sh" <<'SH'
#!/bin/sh
exec /bin/sleep 18
SH
chmod +x "$TMP/template/roles/synchronizer/scripts/notify.sh"
started=$SECONDS
run_dispatch
elapsed=$((SECONDS - started))
if [ "$elapsed" -ge 18 ] || \
   [ -e "$STATE_DIR/strategist-morning-$DATE_FIXED" ] || \
   [ -e "$STATE_DIR/strategist-morning-update-alert-$DATE_FIXED" ]; then
    echo "❌ FAIL: hung notifier blocked dispatch or falsely marked success (elapsed=${elapsed}s)"
    exit 1
fi
if ! grep -qF 'notification not confirmed' "$SCHEDULER_LOG"; then
    echo "❌ FAIL: timeout left no visible notification failure"
    exit 1
fi
cat > "$TMP/template/roles/synchronizer/scripts/notify.sh" <<'SH'
#!/bin/sh
echo 'Telegram notification sent: strategist/day-open-failed'
SH
chmod +x "$TMP/template/roles/synchronizer/scripts/notify.sh"
run_dispatch
if [ ! -f "$STATE_DIR/strategist-morning-update-alert-$DATE_FIXED" ] || \
   [ -e "$STATE_DIR/strategist-morning-$DATE_FIXED" ]; then
    echo "❌ FAIL: next dispatch did not retry notification after timeout"
    exit 1
fi

echo "--- macOS fallback must stop a notifier's non-exec child ---"
mkdir -p "$TMP/fallback-bin"
for tool in awk bash dirname find grep mkdir perl sed tee tr; do
    ln -s "$(command -v "$tool")" "$TMP/fallback-bin/$tool"
done
for tool in date uname systemd-inhibit; do
    ln -s "$TMP/bin/$tool" "$TMP/fallback-bin/$tool"
done
if PATH="$TMP/fallback-bin" command -v timeout >/dev/null 2>&1; then
    echo "❌ FAIL: fallback test unexpectedly found GNU timeout"
    exit 1
fi
rm "$STATE_DIR/strategist-morning-update-alert-$DATE_FIXED"
cat > "$TMP/template/roles/synchronizer/scripts/notify.sh" <<'SH'
#!/bin/sh
/bin/sleep 18
printf 'completed-too-late\n' >> "$IWE_WORKSPACE/late-notifier"
SH
chmod +x "$TMP/template/roles/synchronizer/scripts/notify.sh"
started=$SECONDS
run_dispatch "$TMP/fallback-bin"
elapsed=$((SECONDS - started))
if [ "$elapsed" -ge 18 ] || \
   [ -e "$TMP/ws/late-notifier" ] || \
   [ -e "$STATE_DIR/strategist-morning-$DATE_FIXED" ] || \
   [ -e "$STATE_DIR/strategist-morning-update-alert-$DATE_FIXED" ]; then
    echo "❌ FAIL: fallback left notifier child running or blocked dispatch (elapsed=${elapsed}s)"
    exit 1
fi
cat > "$TMP/template/roles/synchronizer/scripts/notify.sh" <<'SH'
#!/bin/sh
echo 'Telegram notification sent: strategist/day-open-failed'
SH
chmod +x "$TMP/template/roles/synchronizer/scripts/notify.sh"
run_dispatch "$TMP/fallback-bin"
if [ ! -f "$STATE_DIR/strategist-morning-update-alert-$DATE_FIXED" ] || \
   [ -e "$STATE_DIR/strategist-morning-$DATE_FIXED" ]; then
    echo "❌ FAIL: fallback did not retry notification after child timeout"
    exit 1
fi

echo "--- real notifier must bound its Telegram curl ---"
cat > "$TMP/bin/curl" <<'SH'
#!/bin/sh
printf '%s\n' "$@" > "$IWE_WORKSPACE/curl-args"
printf '{"ok":true}\n'
SH
chmod +x "$TMP/bin/curl"
HOME="$TMP/home" IWE_WORKSPACE="$TMP/ws" \
    TEMPLATES_DIR="$ROOT/roles/synchronizer/scripts/templates" \
    TELEGRAM_BOT_TOKEN=test-token TELEGRAM_CHAT_ID=test-chat \
    DAY_OPEN_FAILED_REASON=update-incomplete DAY_OPEN_FAILED_RC=75 \
    PATH="$TMP/bin:/usr/bin:/bin" \
    bash "$ROOT/roles/synchronizer/scripts/notify.sh" strategist day-open-failed \
    > "$TMP/real-notify.out" 2>&1
if ! awk '$0 == "--connect-timeout" { getline; found = ($0 == "5") } END { exit !found }' "$TMP/ws/curl-args" || \
   ! awk '$0 == "--max-time" { getline; found = ($0 == "10") } END { exit !found }' "$TMP/ws/curl-args" || \
   ! grep -qF 'Telegram notification sent: strategist/day-open-failed' "$TMP/real-notify.out"; then
    echo "❌ FAIL: real notifier lacks bounded curl or did not acknowledge stubbed send"
    exit 1
fi
echo "✅ PASS: hung notifier times out, retry succeeds, Telegram curl has limits"
