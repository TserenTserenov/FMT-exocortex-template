#!/usr/bin/env bash
# Issue #1625: canon-reconcile-published.sh must not call the standard
# IWE_RUNTIME="$IWE_WORKSPACE/.iwe-runtime" (exported by .iwe-paths) a legacy
# caller, and must keep warning for any other absolute directory.
set -uo pipefail
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/canon-reconcile-published.sh"
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
WARNING="IWE_RUNTIME used as a directory (legacy caller)"
fails=0

git init -q --bare -b main "$SANDBOX/origin.git"
git clone -q "$SANDBOX/origin.git" "$SANDBOX/canon" 2>/dev/null
git -C "$SANDBOX/canon" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m base
git -C "$SANDBOX/canon" push -q origin HEAD:main
mkdir -p "$SANDBOX/ws/.iwe-runtime/sessions" "$SANDBOX/other-runtime/sessions"
chmod 700 "$SANDBOX/ws/.iwe-runtime" "$SANDBOX/other-runtime"

check() {  # <name> <IWE_RUNTIME value> <expect: warn|quiet>
  local stderr rc
  stderr=$(env -u IWE_RUNTIME_DIR IWE_WORKSPACE="$SANDBOX/ws" IWE_RUNTIME="$2" \
    bash "$SCRIPT" "$SANDBOX/canon" main 2>&1 >/dev/null)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "  FAIL $1: exit $rc (want 0, nothing to reconcile): $stderr"
    fails=$((fails + 1))
    return
  fi
  case "$3:$stderr" in
    warn:*"$WARNING"*) echo "  ok   $1: warns" ;;
    quiet:*"$WARNING"*) echo "  FAIL $1: unexpected legacy warning"; fails=$((fails + 1)) ;;
    quiet:*) echo "  ok   $1: no warning" ;;
    warn:*) echo "  FAIL $1: legacy warning missing"; fails=$((fails + 1)) ;;
  esac
}

check "standard runtime from .iwe-paths" "$SANDBOX/ws/.iwe-runtime" quiet
check "standard runtime with trailing slash" "$SANDBOX/ws/.iwe-runtime/" quiet
check "other absolute directory" "$SANDBOX/other-runtime" warn

if [ "$fails" -eq 0 ]; then
  echo "PASS: issue #1625 (3 checks)"
else
  echo "FAILED: $fails"
  exit 1
fi
