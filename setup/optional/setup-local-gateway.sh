#!/bin/bash
# Local agent coordination gateway (iwe-local-gateway) — installation
#
# MCP MODULE DELIVERY RULE:
#   the module works with the pilot's LOCAL disk  -> local delivery (this script)
#   the module works with cloud data        -> mcp.aisystant.com, we do not clone
# iwe-local-gateway coordinates file-locks on disk -> it cannot be cloud-based.
#
# FMT-ONLY ARTIFACT: this file does not go through the author's synchronization pipeline
# of platform-space (template-sync.sh) — that pipeline would rewrite GATEWAY_REPO_URL
# to a random user's GitHub login and cut out the DS-MCP lines. Edits go
# directly in this repository.
#
# Usage:
#   bash setup/optional/setup-local-gateway.sh
#
set -euo pipefail

# Upstream constants. The URL deliberately points to the platform author's repository,
# not to the user's fork — it is a shared dependency of all installations.
# GATEWAY_SHA duplicates the tag: a tag can be moved by force-push, a SHA cannot;
# a mismatch = tag substitution, installation stops.
GATEWAY_REPO_URL="https://github.com/TserenTserenov/iwe-local-gateway.git"
GATEWAY_REF="v0.1.1"   # bump only together with a line in the template CHANGELOG
GATEWAY_SHA="e3f1697b59691e13108850a1277379a713594990"

# Workspace = root of the repository containing this script (setup/optional/../..) —
# the same technique as setup-calendar.sh; an env variable overrides.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_DIR="${IWE_WORKSPACE:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
GATEWAY_DIR="$WORKSPACE_DIR/DS-MCP/local-gateway"
MCP_JSON="$WORKSPACE_DIR/.mcp.json"
AGENT_ID="${IWE_AGENT_ID:-claude-code}"
SOCK="${IWE_GATEWAY_SOCKET:-$HOME/.iwe/gateway.sock}"
SOCK_DEFAULT="$HOME/.iwe/gateway.sock"
SOCK_DIR="$(dirname "$SOCK")"
DAEMON_LOG="$SOCK_DIR/gateway-daemon.log"
# Since v0.1.1 the pid file lives next to the socket (daemon-paths.ts: resolveDaemonPaths) —
# the same technique as SOCK_DIR; a custom IWE_GATEWAY_SOCKET no longer confuses the pid.
PID_FILE="$SOCK_DIR/gateway.pid"

echo "========================================"
echo "  Локальный шлюз координации агентов"
echo "========================================"
echo ""
echo "Workspace: $WORKSPACE_DIR"
echo "Версия: $GATEWAY_REF"
echo ""

command -v git  >/dev/null 2>&1 || { echo "ОШИБКА: нужен git."; exit 1; }
command -v node >/dev/null 2>&1 || { echo "ОШИБКА: нужен Node.js >= 18."; exit 1; }
node -e 'process.exit(parseInt(process.versions.node) >= 18 ? 0 : 1)' \
    || { echo "ОШИБКА: Node.js $(node --version) слишком старый — нужен >= 18."; exit 1; }

# macOS limits the Unix socket path to ~104 bytes — the daemon would die with EINVAL.
if [ "${#SOCK}" -ge 100 ]; then
    echo "ОШИБКА: путь сокета длиннее 100 символов (${#SOCK}): $SOCK"
    echo "Задайте более короткий через IWE_GATEWAY_SOCKET."
    exit 1
fi

verify_pin() {
    local actual
    actual=$(git -C "$GATEWAY_DIR" rev-parse "$GATEWAY_REF^{commit}")
    if [ "$actual" != "$GATEWAY_SHA" ]; then
        echo "СТОП: тег $GATEWAY_REF указывает на $actual, ожидался $GATEWAY_SHA."
        echo "Возможна подмена тега в upstream — не продолжаю. Сообщите автору шаблона."
        exit 1
    fi
}

# --- 1. Clone / update to the pin ---
NEEDS_BUILD=false
if [ ! -d "$GATEWAY_DIR/.git" ]; then
    mkdir -p "$(dirname "$GATEWAY_DIR")"
    # git may print "refs/tags/... is not a commit!" for annotated tags —
    # harmless git noise, the clone still resolves to the correct commit.
    git clone --branch "$GATEWAY_REF" "$GATEWAY_REPO_URL" "$GATEWAY_DIR"
    verify_pin
    echo "  ✓ Закреплено на $(git -C "$GATEWAY_DIR" rev-parse --short HEAD) ($GATEWAY_REF)"
    NEEDS_BUILD=true
else
    # Guard instead of the rollback gate of template-sync.sh: there the source and target are not
    # linked via VCS, here they are linked via origin — git itself protects others'
    # work. Our duty is not to check out over edits silently.
    if [ -n "$(git -C "$GATEWAY_DIR" status --porcelain)" ]; then
        echo "СТОП: в $GATEWAY_DIR есть незакоммиченные правки."
        echo "Закоммитьте или отмените их, затем перезапустите скрипт."
        exit 1
    fi

    git -C "$GATEWAY_DIR" fetch --tags origin
    verify_pin
    LOCAL_HEAD=$(git -C "$GATEWAY_DIR" rev-parse HEAD)

    if [ "$LOCAL_HEAD" != "$GATEWAY_SHA" ]; then
        if ! git -C "$GATEWAY_DIR" merge-base --is-ancestor "$LOCAL_HEAD" "$GATEWAY_SHA"; then
            echo "СТОП: в $GATEWAY_DIR есть свои коммиты, расходящиеся с $GATEWAY_REF."
            echo "Перенесите их в отдельную ветку (git branch my-changes) и перезапустите."
            exit 1
        fi
        git -C "$GATEWAY_DIR" checkout --detach "$GATEWAY_REF"
        NEEDS_BUILD=true
    elif [ ! -f "$GATEWAY_DIR/dist/proxy.js" ] \
      || [ ! -f "$GATEWAY_DIR/dist/daemon.js" ] \
      || [ ! -d "$GATEWAY_DIR/node_modules" ]; then
        # dist/ is incomplete or dependencies were removed — the previous build was interrupted
        NEEDS_BUILD=true
    fi
fi

# --- 2. Reproducible build ---
if $NEEDS_BUILD; then
    echo "Собираю шлюз ($GATEWAY_REF)..."
    ( cd "$GATEWAY_DIR" && npm ci --no-audit --no-fund && npm run build )
    echo "  ✓ Собран."
fi

# --- 3. .mcp.json: do not patch programmatically, only show the block to paste ---
# This repository's precedent (setup-calendar.sh) — an existing .mcp.json
# is not rewritten automatically, so as not to break the format of others' edits.
# env.IWE_AGENT_ID is required: without it proxy.ts substitutes a random
# unknown-agent-<uuid> on every restart — coordination between agents
# silently breaks (see AGENT-VENDOR-SETUP.md).
if [ -f "$MCP_JSON" ] && grep -q '"iwe-local-gateway"' "$MCP_JSON" 2>/dev/null; then
    echo "  ✓ iwe-local-gateway уже в .mcp.json"
else
    echo ""
    echo "  ⚠ Добавьте iwe-local-gateway в $MCP_JSON вручную:"
    echo '    "iwe-local-gateway": {'
    echo '      "command": "node",'
    echo "      \"args\": [\"$GATEWAY_DIR/dist/proxy.js\"],"
    echo '      "env": {'
    if [ "$SOCK" != "$SOCK_DEFAULT" ]; then
        # a non-standard socket must also reach the proxy env — otherwise the proxy
        # takes its own default and gets ECONNREFUSED
        echo "        \"IWE_AGENT_ID\": \"$AGENT_ID\","
        echo "        \"IWE_GATEWAY_SOCKET\": \"$SOCK\""
    else
        echo "        \"IWE_AGENT_ID\": \"$AGENT_ID\""
    fi
    echo '      }'
    echo '    }'
    echo ""
fi

# --- 4. Daemon: without it the proxy fails ("Start daemon first") ---
mkdir -p "$SOCK_DIR"

# The socket file survives reboot and kill -9 — the presence of the file does not mean a
# live daemon. The only honest check is a real connection.
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
    echo "Запускаю демон..."
    rm -f "$SOCK"   # dead socket after reboot/kill -9 blocks bind
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
        echo "  ⚠ Шлюз обновлён до $GATEWAY_REF, но демон ещё старой версии."
        echo "    Проверить версию живого демона: вызовите gateway_status — поле gateway_version"
        echo "    должно быть \"${GATEWAY_REF#v}\", если меньше — демон точно старый."
        echo "    Убедившись, что агенты не держат блокировок (gateway_status пуст), перезапустите:"
        echo "    kill \"\$(cat \"$PID_FILE\")\" && bash \"$0\""
        echo "    Затем перезапустите всех подключённых агентов — их прокси тоже старой версии."
    else
        echo "  ✓ Демон уже работает (сокет: $SOCK)."
    fi
else
    # Lock: two simultaneous runs would otherwise start two daemons (split-brain
    # of the lock managers) and corrupt the pid file.
    LOCK_DIR="$SOCK_DIR/setup-local-gateway.lock"
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT
        # Re-check under the lock: the daemon could have come up while we waited
        if daemon_alive || start_daemon; then
            echo "  ✓ Демон запущен (сокет: $SOCK)."
        else
            echo "  ✗ Демон не поднял сокет за 5 секунд. Проверьте: $DAEMON_LOG"
            exit 1
        fi
    else
        echo "  Параллельный запуск скрипта уже стартует демон — жду..."
        for _ in $(seq 1 80); do
            daemon_alive && break
            sleep 0.1
        done
        if daemon_alive; then
            echo "  ✓ Демон запущен параллельным запуском (сокет: $SOCK)."
        else
            echo "  ✗ Демон так и не поднялся. Если лок завис — удалите $LOCK_DIR и перезапустите."
            exit 1
        fi
    fi
fi

echo ""
echo "========================================"
echo "  Готово: iwe-local-gateway $GATEWAY_REF"
echo "========================================"
echo ""
echo "Проверка:"
echo "  1. Убедитесь, что запись iwe-local-gateway есть в .mcp.json (шаг 3 выше)"
echo "  2. Перезапустите агента (чтобы MCP подхватился)"
echo "  3. Вызовите gateway_status — должен вернуть пустой список locks"
echo ""
echo "Остановить демон: kill \"\$(cat \"$PID_FILE\")\""
echo "Удалить полностью: остановить демон, удалить $GATEWAY_DIR,"
echo "  запись iwe-local-gateway из .mcp.json, сокет $SOCK, лог $DAEMON_LOG"
