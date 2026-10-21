#!/bin/bash
# Local agent coordination gateway (iwe-local-gateway) — installation
#
# DELIVERY RULE MCP-MODULES:
#   module works with the LOCAL disk of the pilot  -> local delivery (this script)
#   module works with cloud data        -> mcp.aisystant.com, do not clone
# iwe-local-gateway coordinates file-locks on disk -> cannot be cloud-based.
#
# FMT-ONLY ARTIFACT: this file does not go through the author synchronization pipeline
# platform-space (template-sync.sh) — that pipeline would overwrite GATEWAY_REPO_URL
# to GitHub-the GitHub login of a random user and would strip lines containing DS-MCP. Edits —
# directly in this repository.
#
# Usage:
#   bash setup/optional/setup-local-gateway.sh
#
set -euo pipefail

# Upstream-constants. URL intentionally points to the repository of the platform author,
# not to a user fork — this is a shared dependency of all installations.
# GATEWAY_SHA duplicates the tag: a tag can be moved force-push'with a force push, SHA — SHA cannot;
# mismatch = tag substitution, installation stops.
GATEWAY_REPO_URL="https://github.com/TserenTserenov/iwe-local-gateway.git"
GATEWAY_REF="v0.1.1"   # bump only together with the entry in CHANGELOG template
GATEWAY_SHA="e3f1697b59691e13108850a1277379a713594990"

# Workspace = repository root, which contains this script (setup/optional/../..) —
# the same approach, as setup-calendar.sh; env-variable overrides.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_DIR="${IWE_WORKSPACE:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
GATEWAY_DIR="$WORKSPACE_DIR/DS-MCP/local-gateway"
MCP_JSON="$WORKSPACE_DIR/.mcp.json"
AGENT_ID="${IWE_AGENT_ID:-claude-code}"
SOCK="${IWE_GATEWAY_SOCKET:-$HOME/.iwe/gateway.sock}"
SOCK_DEFAULT="$HOME/.iwe/gateway.sock"
SOCK_DIR="$(dirname "$SOCK")"
DAEMON_LOG="$SOCK_DIR/gateway-daemon.log"
# Since v0.1.1 pid-file lives alongside the socket (daemon-paths.ts: resolveDaemonPaths) —
# the same approach, as SOCK_DIR, a custom IWE_GATEWAY_SOCKET no longer confuses pid.
PID_FILE="$SOCK_DIR/gateway.pid"

echo "========================================"
echo "  Local agent coordination gateway"
echo "========================================"
echo ""
echo "Workspace: $WORKSPACE_DIR"
echo "Version: $GATEWAY_REF"
echo ""

command -v git  >/dev/null 2>&1 || { echo "ERROR: requires git."; exit 1; }
command -v node >/dev/null 2>&1 || { echo "ERROR: requires Node.js >= 18."; exit 1; }
node -e 'process.exit(parseInt(process.versions.node) >= 18 ? 0 : 1)' \
    || { echo "ERROR: Node.js $(node --version) too old — requires >= 18."; exit 1; }

# macOS limits the path Unix-socket ~104 bytes — the daemon will fail with EINVAL.
if [ "${#SOCK}" -ge 100 ]; then
    echo "ERROR: socket path is longer than 100 characters (${#SOCK}): $SOCK"
    echo "Set a shorter one via IWE_GATEWAY_SOCKET."
    exit 1
fi

verify_pin() {
    local actual
    actual=$(git -C "$GATEWAY_DIR" rev-parse "$GATEWAY_REF^{commit}")
    if [ "$actual" != "$GATEWAY_SHA" ]; then
        echo "STOP: tag $GATEWAY_REF points to $actual, expected $GATEWAY_SHA."
        echo "Possible tag substitution in upstream — not continuing. Please notify the template author."
        exit 1
    fi
}

# --- 1. Clone / update to pinned ref ---
NEEDS_BUILD=false
if [ ! -d "$GATEWAY_DIR/.git" ]; then
    mkdir -p "$(dirname "$GATEWAY_DIR")"
    # git may print "refs/tags/... is not a commit!" for annotated-tags —
    # harmless noise from git, the clone still resolves to the correct commit git, the clone still resolves to the correct commit.
    git clone --branch "$GATEWAY_REF" "$GATEWAY_REPO_URL" "$GATEWAY_DIR"
    verify_pin
    echo "  ✓ Pinned to $(git -C "$GATEWAY_DIR" rev-parse --short HEAD) ($GATEWAY_REF)"
    NEEDS_BUILD=true
else
    # Guard instead of rollback-gate template-sync.sh: there the source and destination are not
    # linked via VCS, here linked via origin — git protects the other
    # work. Our responsibility — do not perform checkout over edits silently.
    if [ -n "$(git -C "$GATEWAY_DIR" status --porcelain)" ]; then
        echo "STOP: in $GATEWAY_DIR has uncommitted changes."
        echo "Commit or revert them, then restart the script."
        exit 1
    fi

    git -C "$GATEWAY_DIR" fetch --tags origin
    verify_pin
    LOCAL_HEAD=$(git -C "$GATEWAY_DIR" rev-parse HEAD)

    if [ "$LOCAL_HEAD" != "$GATEWAY_SHA" ]; then
        if ! git -C "$GATEWAY_DIR" merge-base --is-ancestor "$LOCAL_HEAD" "$GATEWAY_SHA"; then
            echo "STOP: in $GATEWAY_DIR has local commits, diverging from $GATEWAY_REF."
            echo "Move them to a separate branch (git branch my-changes) and restart."
            exit 1
        fi
        git -C "$GATEWAY_DIR" checkout --detach "$GATEWAY_REF"
        NEEDS_BUILD=true
    elif [ ! -f "$GATEWAY_DIR/dist/proxy.js" ] \
      || [ ! -f "$GATEWAY_DIR/dist/daemon.js" ] \
      || [ ! -d "$GATEWAY_DIR/node_modules" ]; then
        # dist/ incomplete or dependencies removed — previous build was interrupted
        NEEDS_BUILD=true
    fi
fi

# --- 2. Reproducible build ---
if $NEEDS_BUILD; then
    echo "Building gateway ($GATEWAY_REF)..."
    ( cd "$GATEWAY_DIR" && npm ci --no-audit --no-fund && npm run build )
    echo "  ✓ Built."
fi

# --- 3. .mcp.json: do not patch programmatically, only show the block for insertion ---
# Precedent of this repository (setup-calendar.sh) — existing .mcp.json
# is not rewritten automatically, to avoid breaking the format of others edits.
# env.IWE_AGENT_ID is required: without it proxy.ts substitutes a random
# unknown-agent-<uuid> on every restart — coordination between agents
# breaks silently (see. AGENT-VENDOR-SETUP.md).
if [ -f "$MCP_JSON" ] && grep -q '"iwe-local-gateway"' "$MCP_JSON" 2>/dev/null; then
    echo "  ✓ iwe-local-gateway already in .mcp.json"
else
    echo ""
    echo "  ⚠ Add iwe-local-gateway to $MCP_JSON manually:"
    echo '    "iwe-local-gateway": {'
    echo '      "command": "node",'
    echo "      \"args\": [\"$GATEWAY_DIR/dist/proxy.js\"],"
    echo '      "env": {'
    if [ "$SOCK" != "$SOCK_DEFAULT" ]; then
        # a non-default socket must also be included in the proxy env env proxy — otherwise the proxy
        # will use its own default and receive ECONNREFUSED ECONNREFUSED
        echo "        \"IWE_AGENT_ID\": \"$AGENT_ID\","
        echo "        \"IWE_GATEWAY_SOCKET\": \"$SOCK\""
    else
        echo "        \"IWE_AGENT_ID\": \"$AGENT_ID\""
    fi
    echo '      }'
    echo '    }'
    echo ""
fi

# --- 4. Daemon: without it proxy crashes ("Start daemon first") ---
mkdir -p "$SOCK_DIR"

# Socket-file survives reboot and kill -9 — presence of the file does not mean
# a live daemon. The only reliable check — an actual connection.
daemon_alive() {
    [ -S "$SOCK" ] || return 1
    node -e '
const s = require("net").connect(process.argv[1]);
s.on("connect", () => { s.destroy(); process.exit(0); });
s.on("error", () => process.exit(1));
setTimeout(() => process.exit(1), 2000);
' "$SOCK" 2>/dev/null
}

start_daemon() {
    echo "Starting daemon..."
    rm -f "$SOCK"   # stale socket after reboot or kill -9 prevents bind/kill -9 interferes with bind
    IWE_GATEWAY_SOCKET="$SOCK" nohup node "$GATEWAY_DIR/dist/daemon.js" >>"$DAEMON_LOG" 2>&1 &
    for _ in $(seq 1 50); do
        daemon_alive && return 0
        sleep 0.1
    done
    return 1
}

if daemon_alive; then
    if $NEEDS_BUILD; then
        echo ""
        echo "  ⚠ Gateway updated to $GATEWAY_REF, but the daemon is still the old version."
        echo "    Check the version of the running daemon: call gateway_status — field gateway_version"
        echo "    should be \"${GATEWAY_REF#v}\", if lower — the daemon is definitely old."
        echo "    After confirming, that agents do not hold any locks (gateway_status is empty), restart:"
        echo "    kill \"\$(cat \"$PID_FILE\")\" && bash \"$0\""
        echo "    Then restart all connected agents — their proxy is also the old version."
    else
        echo "  ✓ Daemon is already running (socket: $SOCK)."
    fi
else
    # Lock: two simultaneous launches would otherwise start two daemons (split-brain
    # lock managers) and corrupt pid-file.
    LOCK_DIR="$SOCK_DIR/setup-local-gateway.lock"
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT
        # Re-check under lock: the daemon may have started, while we were waiting
        if daemon_alive || start_daemon; then
            echo "  ✓ Daemon started (socket: $SOCK)."
        else
            echo "  ✗ Daemon did not bring up the socket within 5 seconds. Check: $DAEMON_LOG"
            exit 1
        fi
    else
        echo "  A parallel script launch is already starting the daemon — waiting..."
        for _ in $(seq 1 80); do
            daemon_alive && break
            sleep 0.1
        done
        if daemon_alive; then
            echo "  ✓ Daemon started by a parallel launch (socket: $SOCK)."
        else
            echo "  ✗ Daemon did not come up. If the lock is stuck — remove $LOCK_DIR and restart."
            exit 1
        fi
    fi
fi

echo ""
echo "========================================"
echo "  Done: iwe-local-gateway $GATEWAY_REF"
echo "========================================"
echo ""
echo "Verification:"
echo "  1. Make sure, that the iwe-local-gateway entry is iwe-local-gateway is present in .mcp.json (step 3 above)"
echo "  2. Restart the agent (so that MCP is picked up)"
echo "  3. Call gateway_status — should return an empty list of locks"
echo ""
echo "Stop the daemon: kill \"\$(cat \"$PID_FILE\")\""
echo "Remove completely: stop the daemon, remove $GATEWAY_DIR,"
echo "  entry iwe-local-gateway from .mcp.json, socket $SOCK, log $DAEMON_LOG"
