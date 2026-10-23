#!/usr/bin/env bash
# issue #1303 (Linux-половина #984, macOS-плист чинили в PR #1022): systemd
# --user не наследует login-shell окружение, поэтому extractor.sh резолвит
# session-guard.sh по дефолту $HOME/IWE/scripts, которого в типичной
# установке нет -- git-diff-feed находит кандидатов, но не может их сохранить.
# Этот тест реально генерирует unit-файл Linux-веткой setup-extractor-feeders.sh
# (platform подменена через uname-стаб в PATH) и проверяет, что все 5
# Environment= строк присутствуют и несут непустые значения конкретной установки,
# а не grep по шаблону текста.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
FEEDERS="$ROOT/scripts/setup-extractor-feeders.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/home" "$TMP/workspace/.iwe-runtime/roles/extractor/scripts"
printf '#!/usr/bin/env bash\necho Linux\n' > "$TMP/bin/uname"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/claude"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/workspace/.iwe-runtime/roles/extractor/scripts/extractor.sh"
chmod +x "$TMP/bin/uname" "$TMP/bin/claude" "$TMP/workspace/.iwe-runtime/roles/extractor/scripts/extractor.sh"

# unset: a real IWE host sets these for its own install -- the test must not
# silently inherit them and mask a script that stopped computing its own values.
env -u IWE_RUNTIME -u IWE_SCRIPTS -u IWE_TEMPLATE \
HOME="$TMP/home" \
IWE_WORKSPACE="$TMP/workspace" \
IWE_GOVERNANCE_REPO="DS-strategy" \
SETUP_CI=1 \
PATH="$TMP/bin:$PATH" \
bash "$FEEDERS" --schedule-only >"$TMP/out.log" 2>&1

UNIT="$TMP/home/.config/systemd/user/extractor-git-diff-feed.service"
if [ ! -f "$UNIT" ]; then
    echo "systemd unit не создан: $UNIT" >&2
    cat "$TMP/out.log" >&2
    exit 1
fi

EXPECTED_TEMPLATE="$ROOT"
EXPECTED_WORKSPACE="$TMP/workspace"
EXPECTED_RUNTIME="$TMP/workspace/.iwe-runtime"

declare -A EXPECTED=(
    [IWE_TEMPLATE]="$EXPECTED_TEMPLATE"
    [IWE_WORKSPACE]="$EXPECTED_WORKSPACE"
    [IWE_GOVERNANCE_REPO]="DS-strategy"
    [IWE_RUNTIME]="$EXPECTED_RUNTIME"
)

for key in "${!EXPECTED[@]}"; do
    line=$(grep "^Environment=$key=" "$UNIT" || true)
    if [ -z "$line" ]; then
        echo "unit не содержит Environment=$key=... (issue #1303)" >&2
        cat "$UNIT" >&2
        exit 1
    fi
    value="${line#Environment="$key"=}"
    if [ "$value" != "${EXPECTED[$key]}" ]; then
        echo "Environment=$key имеет значение '$value', ожидалось '${EXPECTED[$key]}'" >&2
        exit 1
    fi
done

# IWE_SCRIPTS не подчиняется простому ожиданию (resolve_tool_path сам даёт
# дефолт $IWE_TEMPLATE/scripts) -- достаточно, что строка есть и непуста.
scripts_line=$(grep "^Environment=IWE_SCRIPTS=" "$UNIT" || true)
if [ -z "$scripts_line" ] || [ "$scripts_line" = "Environment=IWE_SCRIPTS=" ]; then
    echo "unit не содержит непустой Environment=IWE_SCRIPTS=... (issue #1303)" >&2
    cat "$UNIT" >&2
    exit 1
fi

if ! grep -q "^Environment=HOME=$TMP/home\$" "$UNIT"; then
    echo "unit не содержит Environment=HOME=... (issue #1303)" >&2
    exit 1
fi

echo 'PASS: Linux systemd git-diff-feed unit несёт все переменные окружения IWE (issue #1303)'
