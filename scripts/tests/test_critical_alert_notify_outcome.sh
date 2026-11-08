#!/usr/bin/env bash
# fmt-critical-alert.sh sends its Telegram alert through iwe-notify (WP-568
# Ф12 С4 stage 2, peer-session 2026-11-08-06) and, being a live source, exits
# 0 only when the message reached the phone: outcome sent or direct-sent.
# Digest, quarantine, transport failure, no credentials and a missing
# iwe-notify all exit 1. iwe-notify is called exactly once (no second send
# after a quarantine) and never by curl from the script itself.
# gh and iwe-notify are stubs; nothing leaves the host.
set -uo pipefail

SRC_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
# A copy of the script WITHOUT iwe-notify next to it: the real copy in the
# template would otherwise be found and could reach the real gateway or Telegram.
mkdir -p "$WORK/tpl/scripts/lib"
cp "$SRC_SCRIPTS/fmt-critical-alert.sh" "$WORK/tpl/scripts/"
cp "$SRC_SCRIPTS/lib/common.sh" "$WORK/tpl/scripts/lib/"
SCRIPT="$WORK/tpl/scripts/fmt-critical-alert.sh"
PASS=0; FAIL=0
ok()  { echo "  ✅ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ❌ $1 — fact: ${2:-no data}"; FAIL=$((FAIL + 1)); }

mkdir -p "$WORK/bin" "$WORK/home"
REAL_JQ=$(command -v jq)
printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$REAL_JQ" > "$WORK/bin/jq"
# curl must exist (dependency check), but the script itself must never call it.
printf '#!/usr/bin/env bash\necho "$*" >> "%s/curl.log"\nexit 7\n' "$WORK" > "$WORK/bin/curl"
cat > "$WORK/bin/gh" <<'EOF'
#!/usr/bin/env bash
[ "$1 $2" = "auth status" ] && exit 0
case "$*" in
  *"repos/test-owner/test-repo/issues?"*)
    printf '%s\n' '[{"number":7,"title":"Critical bug","labels":["critical"],"url":"https://example.invalid/7"}]' ;;
  *"repos/test-owner/test-repo"*)
    printf '%s\n' '{"fork":false,"parent":null,"has_issues":true}' ;;
  *) echo "unexpected gh call: $*" >&2; exit 97 ;;
esac
EOF
# iwe-notify stub: records its call, answers with $WORK/outcome.
cat > "$WORK/iwe-notify" <<EOF
#!/usr/bin/env bash
echo call >> "$WORK/calls.log"
printf '%s\n' "\$*" >> "$WORK/notify.log"
echo "iwe-notify: outcome=\$(cat "$WORK/outcome")"
EOF
chmod +x "$WORK/bin/"* "$WORK/iwe-notify"

# run_case <label> <outcome> <expected rc> [notify bin]
run_case() {
  local label="$1" outcome="$2" want="$3" bin="${4:-$WORK/iwe-notify}" rc
  rm -f "$WORK/notify.log" "$WORK/calls.log" "$WORK/curl.log"
  printf '%s' "$outcome" > "$WORK/outcome"
  # env -i: no real Telegram credentials, IWE root or gateway path from the
  # caller's environment can reach this run.
  env -i PATH="$WORK/bin:/usr/bin:/bin" HOME="$WORK/home" IWE_WORKSPACE="$WORK/home" IWE_FMT_REPO=test-owner/test-repo \
    IWE_NOTIFY_BIN="$bin" bash "$SCRIPT" > "$WORK/out" 2>&1
  rc=$?
  local calls=0
  [ -f "$WORK/calls.log" ] && calls=$(grep -c . "$WORK/calls.log")
  if [ "$rc" != "$want" ]; then
    bad "$label: exit $want" "rc=$rc out=$(tail -2 "$WORK/out")"
  elif [ -f "$WORK/curl.log" ]; then
    bad "$label: the script must not call curl itself" "$(cat "$WORK/curl.log")"
  elif [ "$bin" = "$WORK/iwe-notify" ] && [ "$calls" != 1 ]; then
    bad "$label: exactly one iwe-notify call" "calls=$calls"
  else
    ok "$label: exit $rc"
  fi
}

run_case "delivered by the gateway" sent 0
run_case "delivered by a direct send" direct-sent 0
run_case "kept for the digest" deferred 1
run_case "quarantined, no second send" quarantined 1
run_case "gateway transport failed" transport-failed 1
run_case "no credentials" not-sent 1
run_case "iwe-notify not found" sent 1 "$WORK/no-such-iwe-notify"

rm -f "$WORK/notify.log"
printf sent > "$WORK/outcome"
env -i PATH="$WORK/bin:/usr/bin:/bin" HOME="$WORK/home" IWE_WORKSPACE="$WORK/home" IWE_FMT_REPO=test-owner/test-repo \
  IWE_NOTIFY_BIN="$WORK/iwe-notify" bash "$SCRIPT" > /dev/null 2>&1
grep -q -- "--source fmt-critical-alert -- 🔴 FMT issues" "$WORK/notify.log" 2>/dev/null \
  && ok "source fmt-critical-alert, text after --" || bad "call form" "$(cat "$WORK/notify.log" 2>&1)"

echo "result: ✅ $PASS  ❌ $FAIL"
[ "$FAIL" -eq 0 ]
