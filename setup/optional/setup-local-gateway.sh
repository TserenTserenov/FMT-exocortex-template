#!/bin/bash
# Локальный шлюз координации агентов (iwe-local-gateway) — установка
#
# ПРАВИЛО ДОСТАВКИ MCP-МОДУЛЕЙ:
#   модуль работает с ЛОКАЛЬНЫМ диском пилота  -> локальная доставка (этот скрипт)
#   модуль работает с облачными данными        -> mcp.aisystant.com, не клонируем
# iwe-local-gateway координирует file-locks на диске -> облачным быть не может.
#
# FMT-ONLY АРТЕФАКТ: этот файл не идёт через авторский конвейер синхронизации
# platform-space (template-sync.sh) — тот конвейер переписал бы GATEWAY_REPO_URL
# на GitHub-логин случайного пользователя и вырезал бы строки с DS-MCP. Правки —
# прямо в этом репозитории.
#
# Usage:
#   bash setup/optional/setup-local-gateway.sh
#
set -euo pipefail

# Upstream-константы. URL умышленно указывает на репозиторий автора платформы,
# а не на форк пользователя — это общая зависимость всех инсталляций.
# GATEWAY_SHA дублирует тег: тег можно передвинуть force-push'ем, SHA — нельзя;
# несовпадение = подмена тега, установка останавливается.
GATEWAY_REPO_URL="https://github.com/TserenTserenov/iwe-local-gateway.git"
GATEWAY_REF="v0.1.1"   # бамп только вместе со строкой в CHANGELOG шаблона
GATEWAY_SHA="e3f1697b59691e13108850a1277379a713594990"

# Workspace = корень репозитория, в котором лежит этот скрипт (setup/optional/../..) —
# тот же приём, что setup-calendar.sh; env-переменная переопределяет.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_DIR="${IWE_WORKSPACE:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
GATEWAY_DIR="$WORKSPACE_DIR/DS-MCP/local-gateway"
MCP_JSON="$WORKSPACE_DIR/.mcp.json"
AGENT_ID="${IWE_AGENT_ID:-claude-code}"
SOCK="${IWE_GATEWAY_SOCKET:-$HOME/.iwe/gateway.sock}"
SOCK_DEFAULT="$HOME/.iwe/gateway.sock"
SOCK_DIR="$(dirname "$SOCK")"
DAEMON_LOG="$SOCK_DIR/gateway-daemon.log"
# С v0.1.1 pid-файл живёт рядом с сокетом (daemon-paths.ts: resolveDaemonPaths) —
# тот же приём, что SOCK_DIR, кастомный IWE_GATEWAY_SOCKET больше не путает pid.
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

# macOS ограничивает путь Unix-сокета ~104 байтами — демон умрёт с EINVAL.
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

# --- 1. Клон / обновление до пина ---
NEEDS_BUILD=false
if [ ! -d "$GATEWAY_DIR/.git" ]; then
    mkdir -p "$(dirname "$GATEWAY_DIR")"
    # git может напечатать "refs/tags/... is not a commit!" для annotated-тегов —
    # безвредный шум git, клон при этом разрешается на правильный коммит.
    git clone --branch "$GATEWAY_REF" "$GATEWAY_REPO_URL" "$GATEWAY_DIR"
    verify_pin
    echo "  ✓ Закреплено на $(git -C "$GATEWAY_DIR" rev-parse --short HEAD) ($GATEWAY_REF)"
    NEEDS_BUILD=true
else
    # Guard вместо rollback-гейта template-sync.sh: там источник и приёмник не
    # связаны через VCS, здесь связаны через origin — git сам защищает чужую
    # работу. Наша обязанность — не делать checkout поверх правок молча.
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
        # dist/ неполный или зависимости снесены — прошлая сборка оборвалась
        NEEDS_BUILD=true
    fi
fi

# --- 2. Воспроизводимая сборка ---
if $NEEDS_BUILD; then
    echo "Собираю шлюз ($GATEWAY_REF)..."
    ( cd "$GATEWAY_DIR" && npm ci --no-audit --no-fund && npm run build )
    echo "  ✓ Собран."
fi

# --- 3. .mcp.json: не патчить программно, только показать блок для вставки ---
# Прецедент этого репозитория (setup-calendar.sh) — существующий .mcp.json
# не переписывается автоматически, чтобы не сломать формат чужих правок.
# env.IWE_AGENT_ID обязателен: без него proxy.ts подставляет случайный
# unknown-agent-<uuid> при каждом перезапуске — координация между агентами
# молча ломается (см. AGENT-VENDOR-SETUP.md).
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
        # нестандартный сокет обязан попасть и в env прокси — иначе прокси
        # возьмёт свой дефолт и получит ECONNREFUSED
        echo "        \"IWE_AGENT_ID\": \"$AGENT_ID\","
        echo "        \"IWE_GATEWAY_SOCKET\": \"$SOCK\""
    else
        echo "        \"IWE_AGENT_ID\": \"$AGENT_ID\""
    fi
    echo '      }'
    echo '    }'
    echo ""
fi

# --- 4. Демон: без него proxy падает ("Start daemon first") ---
mkdir -p "$SOCK_DIR"

# Сокет-файл переживает перезагрузку и kill -9 — наличие файла не означает
# живой демон. Единственная честная проверка — реальное подключение.
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
    rm -f "$SOCK"   # мёртвый сокет после ребута/kill -9 мешает bind
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
    # Lock: два одновременных запуска иначе стартуют два демона (split-brain
    # менеджеров блокировок) и портят pid-файл.
    LOCK_DIR="$SOCK_DIR/setup-local-gateway.lock"
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT
        # Перепроверка под локом: демон мог подняться, пока мы ждали
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
