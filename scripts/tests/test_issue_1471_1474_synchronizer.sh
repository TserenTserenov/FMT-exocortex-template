#!/bin/bash
# test_issue_1471_1474_synchronizer.sh -- regression guards for #1471 and #1474.
# #1471: code-scan.sh with no downstream DS-* repos must not scan a phantom empty
#        entry (bash >= 4.4) or hit "repos[@]: unbound variable" (bash 3.2), and
#        must say so in the log.
# #1474: synchronizer/install.sh unloads only loaded Strategist agents and renames
#        their plists to <label>.plist.disabled, the marker strategist/install.sh
#        honours; launchctl is stubbed, so this runs on Linux too.
# scripts/tests/run-issue-tests.sh picks up test_issue_*.sh by existence.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$(cd "$SCRIPT_DIR/../.." && pwd)"
FAILURES=0
check() { if [ "$2" = ok ]; then echo "PASS: $1"; else echo "FAIL: $1"; FAILURES=$((FAILURES+1)); fi; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# --- #1471
mkdir -p "$TMP/ws/DS-strategy/.git" "$TMP/home"
out=$(env -i PATH="$PATH" HOME="$TMP/home" IWE_WORKSPACE="$TMP/ws" IWE_GOVERNANCE_REPO=DS-strategy \
      bash "$TEMPLATE/roles/synchronizer/scripts/code-scan.sh" --dry-run 2>&1); rc=$?
[ "$rc" -eq 0 ] && check "#1471 empty set: exit 0" ok || check "#1471 empty set: exit 0 (rc=$rc)" bad
grep -q 'Нет репозиториев для сканирования' <<<"$out" && check "#1471 empty set: said in the log" ok || check "#1471 empty set: said in the log" bad
grep -qE 'SKIP: +—|unbound variable' <<<"$out" && check "#1471 empty set: no phantom repo, no unbound error" bad || check "#1471 empty set: no phantom repo, no unbound error" ok

# --- #1474: run the legacy-agent block of the installer against a stub launchctl
LA="$TMP/home/Library/LaunchAgents"; mkdir -p "$LA" "$TMP/bin"
touch "$LA/com.strategist.morning.plist" "$LA/com.strategist.weekreview.plist"
cat > "$TMP/bin/launchctl" <<EOF
#!/bin/bash
echo "\$*" >> "$TMP/calls"
# only the morning agent is loaded
[ "\$1" = list ] && { [ "\$2" = com.strategist.morning ]; exit; }
exit 0
EOF
chmod +x "$TMP/bin/launchctl"
awk '/for label in com.strategist.morning com.strategist.weekreview; do/,/^    done/' \
  "$TEMPLATE/roles/synchronizer/install.sh" > "$TMP/block.sh"
[ -s "$TMP/block.sh" ] && check "#1474 installer block found" ok || check "#1474 installer block found" bad
HOME="$TMP/home" PATH="$TMP/bin:$PATH" bash "$TMP/block.sh" >/dev/null 2>&1
for label in com.strategist.morning com.strategist.weekreview; do
  [ -f "$LA/$label.plist.disabled" ] && [ ! -e "$LA/$label.plist" ] \
    && check "#1474 $label renamed to .plist.disabled" ok || check "#1474 $label renamed to .plist.disabled" bad
done
grep -qx "unload $LA/com.strategist.morning.plist" "$TMP/calls" && check "#1474 loaded agent unloaded" ok || check "#1474 loaded agent unloaded" bad
grep -q "unload $LA/com.strategist.weekreview.plist" "$TMP/calls" && check "#1474 not-loaded agent not unloaded" bad || check "#1474 not-loaded agent not unloaded" ok
grep -q 'plist.disabled' "$TEMPLATE/roles/strategist/install.sh" && check "#1474 strategist installer honours the marker" ok || check "#1474 strategist installer honours the marker" bad

[ "$FAILURES" -eq 0 ] && { echo "OK: all checks passed"; exit 0; }
echo "FAILED: $FAILURES"; exit 1
