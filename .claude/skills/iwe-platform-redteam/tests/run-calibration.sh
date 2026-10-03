#!/usr/bin/env bash
# see .claude/skills/iwe-platform-redteam/SKILL.md — step 0 Calibrate.
#
# Two legs:
#   1. boundary-guard behaviour — the safety-critical production code. Proves it
#      refuses real / non-disposable / workspace-nested targets, runs a command
#      under a disposable temp fixture, and redirects HOME/WORKSPACE_DIR (not
#      just IWE_ROOT) into the fixture so no env-derived path escapes.
#   2. environment smoke-test — that `shasum`/`cp -R` behave here and that the
#      manifest-integrity contract distinguishes a clean release from a tampered
#      one. This leg validates the ENVIRONMENT and the integrity contract, not
#      the LLM audit reasoning (that is runbook-driven and not executed here).
#
# Committed fixtures are never mutated: each is copied into a fresh mktemp first.
# Bash 3.2 compatible.

set -u

SKILL_DIR=$(cd "$(dirname "$0")/.." && pwd -P)
GUARD="$SKILL_DIR/boundary-guard.sh"
FIXTURES="$SKILL_DIR/fixtures"

fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

sha() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi; }

# Echo a fresh temp dir on stdout and return 0; return non-zero on failure so
# the caller's `x=$(mk) || halt` actually halts. A plain `exit` inside command
# substitution would only leave the subshell, letting the script continue with
# an empty path (and later `cp` into `/`) — so failure must travel via status.
mk() { d=$(mktemp -d 2>/dev/null) && [ -d "$d" ] && printf '%s' "$d"; }

# Deterministic integrity reflex: recompute each manifest hash, check the CI
# receipt, and return GO only when every delivered file matches and required
# checks passed. Returns a reason code on failure so a green result cannot hide
# the wrong cause.  `|| [ -n "$expected" ]` keeps a final line lacking a
# trailing newline (a real manifest could) from being silently skipped.
classify_release() {
  release_dir="$1"
  manifest="$release_dir/manifest.txt"
  receipt="$release_dir/ci-receipt.txt"
  [ -f "$manifest" ] || { echo BLOCKED_MANIFEST; return; }
  [ -f "$receipt" ]  || { echo BLOCKED_RECEIPT; return; }
  while read -r expected relpath || [ -n "$expected" ]; do
    [ -n "$expected" ] || continue
    target="$release_dir/$relpath"
    [ -f "$target" ] || { echo BLOCKED_MISSING; return; }
    [ "$(sha "$target")" = "$expected" ] || { echo BLOCKED_HASH; return; }
  done < "$manifest"
  grep -q '^required_checks: passed$' "$receipt" || { echo BLOCKED_RECEIPT; return; }
  grep -q '^status: green$' "$receipt" || { echo BLOCKED_RECEIPT; return; }
  echo GO
}

# --- guard: refuse a real workspace path --------------------------------------
if IWE_REDTEAM_FIXTURE_ROOT="$HOME/IWE" bash "$GUARD" -- true 2>/dev/null; then
  bad "guard should refuse a real IWE workspace path but ran the command"
else
  pass "guard refuses a real IWE workspace path"
fi

# --- guard: refuse a real, non-disposable path (real home) --------------------
if IWE_REDTEAM_FIXTURE_ROOT="$HOME" bash "$GUARD" -- true 2>/dev/null; then
  bad "guard should refuse a real non-temp path (\$HOME) but ran the command"
else
  pass "guard refuses a real non-disposable path"
fi

# --- guard: refuse a fixture nested inside a (temp-located) workspace ----------
# Exercises the defense-in-depth nesting branch: HOME points at a temp dir that
# contains an IWE/ subtree, and the fixture lives under it.
fakehome=$(mk) || { bad "mktemp -d failed"; exit 1; }
mkdir -p "$fakehome/IWE/sub"
if HOME="$fakehome" IWE_REDTEAM_FIXTURE_ROOT="$fakehome/IWE/sub" bash "$GUARD" -- true 2>/dev/null; then
  bad "guard should refuse a fixture nested inside the workspace root but ran it"
else
  pass "guard refuses a fixture nested inside the workspace root"
fi
rm -rf "$fakehome"

# --- guard: allow a disposable temp path and run the command ------------------
tmp_ok=$(mk) || { bad "mktemp -d failed"; exit 1; }
tmp_ok_abs=$(cd "$tmp_ok" && pwd -P)
out=$(IWE_REDTEAM_FIXTURE_ROOT="$tmp_ok" bash "$GUARD" -- sh -c 'printf ran' 2>/dev/null)
if [ "$out" = "ran" ]; then
  pass "guard runs the command under a disposable temp path"
else
  bad "guard should run under a temp path (got: '$out')"
fi

# --- guard: redirect HOME into the fixture (not the real home) ----------------
home_in=$(IWE_REDTEAM_FIXTURE_ROOT="$tmp_ok" bash "$GUARD" -- sh -c 'printf "%s" "$HOME"' 2>/dev/null)
if [ "$home_in" = "$tmp_ok_abs" ]; then
  pass "guard redirects HOME into the fixture"
else
  bad "guard should set HOME to the fixture (got: '$home_in', want: '$tmp_ok_abs')"
fi

# --- guard: redirect WORKSPACE_DIR into the fixture (Critical #1) --------------
ws_in=$(IWE_REDTEAM_FIXTURE_ROOT="$tmp_ok" WORKSPACE_DIR="/real/workspace" \
  bash "$GUARD" -- sh -c 'printf "%s" "$WORKSPACE_DIR"' 2>/dev/null)
if [ "$ws_in" = "$tmp_ok_abs" ]; then
  pass "guard redirects WORKSPACE_DIR into the fixture"
else
  bad "guard should override WORKSPACE_DIR to the fixture (got: '$ws_in', want: '$tmp_ok_abs')"
fi

# --- guard: strip inherited IWE_* variables -----------------------------------
leak=$(IWE_ROOT="/nonexistent/leaked-workspace/IWE" IWE_REDTEAM_FIXTURE_ROOT="$tmp_ok" \
  bash "$GUARD" -- sh -c 'printf "%s" "${IWE_ROOT:-clean}"' 2>/dev/null)
if [ "$leak" = "clean" ]; then
  pass "guard strips inherited IWE_ROOT from the command environment"
else
  bad "guard leaked IWE_ROOT into the command (got: '$leak')"
fi
ci_mode=$(IWE_REDTEAM_FIXTURE_ROOT="$tmp_ok" bash "$GUARD" -- sh -c 'printf "%s" "$SETUP_CI"' 2>/dev/null)
if [ "$ci_mode" = "1" ]; then
  pass "guard forces SETUP_CI=1 inside the disposable fixture"
else
  bad "guard did not prevent service activation through SETUP_CI (got: '$ci_mode')"
fi
IWE_REDTEAM_FIXTURE_ROOT="$tmp_ok" bash "$GUARD" -- sh -c 'exit 42' 2>/dev/null
child_rc=$?
if [ "$child_rc" -eq 42 ]; then
  pass "guard preserves an ordinary child failure without service calls"
else
  bad "guard changed an ordinary child failure (got: $child_rc, want: 42)"
fi
rm -rf "$tmp_ok"

# --- guard: service managers are denied, even when a child swallows failure ---
# The caller's PATH contains only test stubs for these names. A regression can
# reach the external-hit marker but can never reach a real host manager.
service_run=$(mk) || { bad "mktemp -d failed"; exit 1; }
service_abs=$(cd "$service_run" && pwd -P)
mkdir -p "$service_run/external-bin"
for manager in launchctl systemctl crontab; do
  # shellcheck disable=SC2016 # Variables expand in the test stub.
  printf '%s\n' \
    '#!/bin/sh' \
    'printf "%s\n" "$0" >> "$HOME/external-hit"' \
    'exit 97' > "$service_run/external-bin/$manager"
  chmod 700 "$service_run/external-bin/$manager"
done
service_path="$service_run/external-bin:$PATH"
if [ "$(PATH="$service_path" command -v launchctl)" != "$service_run/external-bin/launchctl" ] ||
   [ "$(PATH="$service_path" command -v systemctl)" != "$service_run/external-bin/systemctl" ] ||
   [ "$(PATH="$service_path" command -v crontab)" != "$service_run/external-bin/crontab" ]; then
  bad "test PATH does not resolve all service managers to disposable stubs"
  rm -rf "$service_run"
  exit 1
fi
for manager in launchctl systemctl crontab; do
  PATH="$service_path" IWE_REDTEAM_FIXTURE_ROOT="$service_run" \
    bash "$GUARD" -- "$manager" test > "$service_run/$manager.out" 2>&1
  rc=$?
  if [ "$rc" -eq 3 ] && grep -q 'boundary-guard: BLOCKED' "$service_run/$manager.out" &&
     grep -q "^$manager$" "$service_run"/.iwe-redteam-service-bin.*/blocked-calls &&
     [ ! -e "$service_run/external-hit" ]; then
    pass "guard denies direct $manager without reaching caller stub"
  else
    bad "guard direct $manager escaped or used wrong status (rc=$rc)"
  fi
done

PATH="$service_path" IWE_REDTEAM_FIXTURE_ROOT="$service_run" \
  bash "$GUARD" -- bash -c \
    'launchctl unload "$HOME/test.plist" >/dev/null 2>&1 || true; printf child-ok' \
  > "$service_run/swallowed.out" 2> "$service_run/swallowed.err"
rc=$?
if [ "$rc" -eq 3 ] && [ "$(cat "$service_run/swallowed.out")" = "child-ok" ] &&
   grep -q 'boundary-guard: BLOCKED' "$service_run/swallowed.err" &&
   [ ! -e "$service_run/external-hit" ]; then
  pass "guard reports a swallowed nested launchctl call"
else
  bad "guard lost a swallowed nested launchctl call (rc=$rc)"
fi

PATH="$service_path" IWE_REDTEAM_FIXTURE_ROOT="$service_run" \
  bash "$GUARD" -- bash -c \
    'env -i PATH="$PATH" HOME="$HOME" sh -c "systemctl --user list-timers >/dev/null 2>&1 || true; crontab -l >/dev/null 2>&1 || true"; printf child-ok' \
  > "$service_run/env-i.out" 2> "$service_run/env-i.err"
rc=$?
if [ "$rc" -eq 3 ] && [ "$(cat "$service_run/env-i.out")" = "child-ok" ] &&
   grep -q 'boundary-guard: BLOCKED' "$service_run/env-i.err" &&
   [ ! -e "$service_run/external-hit" ]; then
  pass "guard keeps deny shims through nested env -i with PATH propagation"
else
  bad "guard lost service calls through nested env -i (rc=$rc)"
fi

PATH="$service_path" IWE_REDTEAM_FIXTURE_ROOT="$service_run" \
  bash "$GUARD" -- bash -c \
    'launchctl unload "$HOME/test.plist" >/dev/null 2>&1 || true; rm -f "$IWE_REDTEAM_SERVICE_BIN/blocked-calls"; printf child-ok' \
  > "$service_run/removed-record.out" 2> "$service_run/removed-record.err"
rc=$?
if [ "$rc" -eq 3 ] && [ "$(cat "$service_run/removed-record.out")" = "child-ok" ] &&
   grep -q 'audit protection disappeared' "$service_run/removed-record.err" &&
   [ ! -e "$service_run/external-hit" ]; then
  pass "guard fails closed when a child removes a used audit record"
else
  bad "guard allowed a child to hide a call by removing its audit record (rc=$rc)"
fi

PATH="$service_path" IWE_REDTEAM_FIXTURE_ROOT="$service_run" \
  bash "$GUARD" -- bash -c 'rm -rf "$IWE_REDTEAM_SERVICE_BIN"; printf child-ok' \
  > "$service_run/removed-bin.out" 2> "$service_run/removed-bin.err"
rc=$?
if [ "$rc" -eq 3 ] && [ "$(cat "$service_run/removed-bin.out")" = "child-ok" ] &&
   grep -q 'audit protection disappeared' "$service_run/removed-bin.err" &&
   [ ! -e "$service_run/external-hit" ]; then
  pass "guard fails closed when a child removes the deny directory"
else
  bad "guard allowed a child to remove the deny directory (rc=$rc)"
fi

PATH="$service_path" IWE_REDTEAM_FIXTURE_ROOT="$service_run" \
  bash "$GUARD" -- bash -c 'rm -f "$IWE_REDTEAM_SERVICE_BIN/launchctl"; printf child-ok' \
  > "$service_run/removed-shim.out" 2> "$service_run/removed-shim.err"
rc=$?
if [ "$rc" -eq 3 ] && [ "$(cat "$service_run/removed-shim.out")" = "child-ok" ] &&
   grep -q 'deny shim disappeared' "$service_run/removed-shim.err" &&
   [ ! -e "$service_run/external-hit" ]; then
  pass "guard fails closed when a child removes a deny shim"
else
  bad "guard allowed a child to remove a deny shim (rc=$rc)"
fi

# The three macOS role installers previously unloaded jobs even with SETUP_CI.
# Use a fake uname and synthetic plists, then require file delivery with zero
# service calls. The guard's launchctl shim would expose any missed unload.
printf '%s\n' '#!/bin/sh' 'printf "Darwin\n"' > "$service_run/external-bin/uname"
chmod 700 "$service_run/external-bin/uname"
repo_root=$(cd "$SKILL_DIR/../../.." && pwd -P)
for role in strategist synchronizer extractor; do
  mkdir -p "$service_run/runtime/roles/$role/scripts/launchd"
done
for label in com.strategist.morning com.strategist.weekreview; do
  printf '<plist>synthetic</plist>\n' > "$service_run/runtime/roles/strategist/scripts/launchd/$label.plist"
done
printf '<plist>synthetic</plist>\n' > "$service_run/runtime/roles/synchronizer/scripts/launchd/com.exocortex.scheduler.plist"
printf '<plist>synthetic</plist>\n' > "$service_run/runtime/roles/extractor/scripts/launchd/com.extractor.inbox-check.plist"
PATH="$service_path" IWE_REDTEAM_FIXTURE_ROOT="$service_run" \
  bash "$GUARD" -- bash -c \
    'export IWE_RUNTIME="$HOME/runtime" SETUP_CI=1; for script in "$@"; do bash "$script" || exit; done' \
    _ "$repo_root/roles/strategist/install.sh" \
      "$repo_root/roles/synchronizer/install.sh" \
      "$repo_root/roles/extractor/install.sh" \
  > "$service_run/installers.out" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$service_run/external-hit" ] &&
   [ -f "$service_abs/Library/LaunchAgents/com.strategist.morning.plist" ] &&
   [ -f "$service_abs/Library/LaunchAgents/com.strategist.weekreview.plist" ] &&
   [ -f "$service_abs/Library/LaunchAgents/com.exocortex.scheduler.plist" ] &&
   [ -f "$service_abs/Library/LaunchAgents/com.extractor.inbox-check.plist" ]; then
  pass "SETUP_CI installs all role plists without unloading host jobs"
else
  bad "SETUP_CI role installation called a service manager or missed a plist (rc=$rc)"
fi

# The smoke script used to replace PATH with /usr/bin:/bin. Probe its actual
# early PATH calculation without executing setup or any service-manager call.
PATH="$service_path" IWE_REDTEAM_FIXTURE_ROOT="$service_run" \
  bash "$GUARD" -- bash -c \
    'SMOKE_GUARD_PATH_PROBE=1 bash "$1"' \
    _ "$repo_root/setup/smoke-test-fresh-install.sh" \
  > "$service_run/smoke-path.out" 2> "$service_run/smoke-path.err"
rc=$?
smoke_path=$(sed -n 's/^SMOKE_GUARDED_PATH=//p' "$service_run/smoke-path.out")
smoke_ws=$(sed -n 's/^SMOKE_GUARDED_WORKSPACE=//p' "$service_run/smoke-path.out")
shim_prefix=${smoke_path%%:*}
case "$smoke_path" in
  "$service_abs"/.iwe-redteam-service-bin.*:*) guarded_smoke_path=1 ;;
  *) guarded_smoke_path=0 ;;
esac
if [ "$rc" -eq 77 ] && [ "$guarded_smoke_path" -eq 1 ] &&
   [ "${smoke_ws#"$service_abs"/}" != "$smoke_ws" ] &&
   [ -x "$shim_prefix/launchctl" ] && [ -x "$shim_prefix/systemctl" ] &&
   [ -x "$shim_prefix/crontab" ] && [ ! -e "$service_run/external-hit" ]; then
  pass "smoke clean PATH keeps guard-owned deny shims first"
else
  bad "smoke clean PATH bypassed or lost deny shims (rc=$rc, path=$smoke_path)"
fi
rm -rf "$service_run"

# --- integrity contract: known-good -> GO -------------------------------------
good_run=$(mk) || { bad "mktemp -d failed"; exit 1; }
cp -R "$FIXTURES/known-good-release/." "$good_run/"
verdict_good=$(classify_release "$good_run")
if [ "$verdict_good" = "GO" ]; then
  pass "known-good release classified GO"
else
  bad "known-good release must be GO (got: $verdict_good)"
fi
rm -rf "$good_run"

# --- integrity contract: known-bad -> BLOCKED_HASH (planted mismatch) ---------
# The bad fixture differs from good ONLY in one manifest hash line, so the hash
# mismatch is the sole cause — assert that specific reason, not just "blocked".
bad_run=$(mk) || { bad "mktemp -d failed"; exit 1; }
cp -R "$FIXTURES/known-bad-release/." "$bad_run/"
verdict_bad=$(classify_release "$bad_run")
if [ "$verdict_bad" = "BLOCKED_HASH" ]; then
  pass "known-bad release BLOCKED by the planted manifest hash mismatch"
else
  bad "known-bad release must be BLOCKED_HASH (got: $verdict_bad) — false-green or wrong cause"
fi
rm -rf "$bad_run"

if [ "$fail" -eq 0 ]; then
  printf '\ncalibration OK — guard containment and integrity contract behave as required\n'
  exit 0
fi
printf '\ncalibration FAILED — do not trust a real audit verdict in this environment\n' >&2
exit 1
