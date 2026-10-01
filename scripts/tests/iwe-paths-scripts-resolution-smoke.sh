#!/bin/bash
# iwe-paths-scripts-resolution-smoke.sh -- WP-7 F161, peer session
# 2026-09-21-04-wp537-wp7-fmt-decisions-followup (Claude+Codex).
#
# `$IWE_SCRIPTS` used to default straight to the template's own (trimmed,
# WP-546) copy of scripts/ -- in both the generated `.iwe-paths` file
# (install-iwe-paths.sh) and the fallback bootstrap
# (.claude/lib/iwe-env-bootstrap.sh) -- even on a workspace that has a live
# `scripts/` checkout agents actually commit fixes into. Every interactive
# shell (and any agent launched from one) then worked off the stale copy.
# Both now prefer the live workspace scripts/ when it exists.
#
# Issue #957: "exists" means a live checkout, recognised by a REGULAR
# (non-symlink) session-guard.sh inside it; a bare directory does not count.
# The fixture below therefore builds the live scripts/ with that marker (an empty
# directory used to pass here and pinned the defect). The marker rule itself is
# covered layout by layout in test_issue_957_iwe_scripts_marker.sh.
set -uo pipefail

INSTALL_SCRIPT="${INSTALL_IWE_PATHS_SCRIPT:-${IWE_ROOT:-$HOME/IWE}/FMT-exocortex-template/setup/install-iwe-paths.sh}"
BOOTSTRAP_SCRIPT="${IWE_ENV_BOOTSTRAP_SCRIPT:-${IWE_ROOT:-$HOME/IWE}/FMT-exocortex-template/.claude/lib/iwe-env-bootstrap.sh}"
[ -f "$INSTALL_SCRIPT" ] || { echo "FAIL: $INSTALL_SCRIPT not found"; exit 1; }
[ -f "$BOOTSTRAP_SCRIPT" ] || { echo "FAIL: $BOOTSTRAP_SCRIPT not found"; exit 1; }

FAILURES=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

check() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "OK: $desc"
  else
    echo "FAIL: $desc (ожидалось '$expected', получено '$actual')"
    FAILURES=$((FAILURES + 1))
  fi
}

make_workspace() {  # <path> <with-live-scripts: yes|no>
  local ws="$1" with_live="$2"
  mkdir -p "$ws/FMT-exocortex-template/scripts"
  if [ "$with_live" = "yes" ]; then
    mkdir -p "$ws/scripts"
    # The marker of a live checkout (#957): a regular session-guard.sh.
    printf '#!/bin/bash\n' > "$ws/scripts/session-guard.sh"
  fi
}

# --- install-iwe-paths.sh: generated .iwe-paths must resolve IWE_SCRIPTS
# to the live workspace scripts/ when present, template scripts/ otherwise. ---
WS_LIVE="$T/ws-live"
make_workspace "$WS_LIVE" yes
bash "$INSTALL_SCRIPT" --workspace "$WS_LIVE" --governance DS-strategy --skip-zshenv --quiet >/dev/null 2>&1
check ".iwe-paths сгенерирован (живой scripts/ есть)" "yes" "$([ -f "$WS_LIVE/.iwe-paths" ] && echo yes || echo no)"
RESOLVED_LIVE=$(bash -c ". '$WS_LIVE/.iwe-paths'; echo \$IWE_SCRIPTS")
check "IWE_SCRIPTS резолвится в живую копию, когда она есть" "$WS_LIVE/scripts" "$RESOLVED_LIVE"

WS_NOLIVE="$T/ws-nolive"
make_workspace "$WS_NOLIVE" no
bash "$INSTALL_SCRIPT" --workspace "$WS_NOLIVE" --governance DS-strategy --skip-zshenv --quiet >/dev/null 2>&1
RESOLVED_NOLIVE=$(bash -c ". '$WS_NOLIVE/.iwe-paths'; echo \$IWE_SCRIPTS")
check "IWE_SCRIPTS падает на копию шаблона, когда живой нет" "$WS_NOLIVE/FMT-exocortex-template/scripts" "$RESOLVED_NOLIVE"

# --- iwe-env-bootstrap.sh: same contract when IWE_SCRIPTS isn't already set. ---
BOOTSTRAP_IN_LIVE="$WS_LIVE/FMT-exocortex-template/.claude/lib/iwe-env-bootstrap.sh"
mkdir -p "$(dirname "$BOOTSTRAP_IN_LIVE")"
cp "$BOOTSTRAP_SCRIPT" "$BOOTSTRAP_IN_LIVE"
RESOLVED_BOOTSTRAP_LIVE=$(env -u IWE_SCRIPTS -u WORKSPACE_DIR bash -c ". '$BOOTSTRAP_IN_LIVE'; echo \$IWE_SCRIPTS")
check "bootstrap: IWE_SCRIPTS резолвится в живую копию, когда она есть" "$WS_LIVE/scripts" "$RESOLVED_BOOTSTRAP_LIVE"

BOOTSTRAP_IN_NOLIVE="$WS_NOLIVE/FMT-exocortex-template/.claude/lib/iwe-env-bootstrap.sh"
mkdir -p "$(dirname "$BOOTSTRAP_IN_NOLIVE")"
cp "$BOOTSTRAP_SCRIPT" "$BOOTSTRAP_IN_NOLIVE"
RESOLVED_BOOTSTRAP_NOLIVE=$(env -u IWE_SCRIPTS -u WORKSPACE_DIR bash -c ". '$BOOTSTRAP_IN_NOLIVE'; echo \$IWE_SCRIPTS")
check "bootstrap: IWE_SCRIPTS падает на копию шаблона, когда живой нет" \
  "$WS_NOLIVE/FMT-exocortex-template/scripts" "$RESOLVED_BOOTSTRAP_NOLIVE"

# --- Sanity: iwe-env-bootstrap.sh (a fallback layer, unlike .iwe-paths --
# which is the primary source sourced once from .bashrc and unconditionally
# sets every IWE_* var, same as its untouched siblings IWE_WORKSPACE/
# IWE_ROOT/IWE_TEMPLATE) must still respect an already-set IWE_SCRIPTS. ---
RESOLVED_BOOTSTRAP_OVERRIDE=$(IWE_SCRIPTS="/explicit/override" bash -c ". '$BOOTSTRAP_IN_LIVE'; echo \$IWE_SCRIPTS")
check "bootstrap не перебивает уже заданный IWE_SCRIPTS" "/explicit/override" "$RESOLVED_BOOTSTRAP_OVERRIDE"

echo ""
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL PASS"
  exit 0
else
  echo "=== $FAILURES ПРОВЕРОК FAILED ==="
  exit 1
fi
