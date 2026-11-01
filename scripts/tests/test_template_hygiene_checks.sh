#!/usr/bin/env bash
# test_template_hygiene_checks.sh — проверки check-copy-pairs.sh и
# check-shipped-config-secrets.sh ловят то, ради чего написаны
# (WP-7, чистка шаблона 2026-11-01).
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0
pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; fail=1; }

expect() {
    local label="$1" want_rc="$2" want_text="$3"; shift 3
    local out rc
    out=$("$@" 2>&1); rc=$?
    if [ "$rc" -eq "$want_rc" ] && printf '%s' "$out" | grep -qF -- "$want_text"; then
        pass "$label"
    else
        fail "$label (код $rc, ожидался $want_rc; вывод: $out)"
    fi
}

echo "--- check-copy-pairs.sh ---"
expect "настоящий шаблон: все пары совпадают" 0 "PASS:" \
    bash "$ROOT/scripts/check-copy-pairs.sh" "$ROOT"

# Минимальная копия шаблона: только файлы из списка пар.
FMT="$TMP/fmt"
pairs=$(awk '/^PAIRS=\(/{f=1; next} f && /^\)/{exit} f' "$ROOT/scripts/check-copy-pairs.sh" | tr -d ' "')
while IFS='|' read -r orig copy; do
    [ -z "$orig" ] && continue
    mkdir -p "$FMT/$(dirname "$orig")" "$FMT/$(dirname "$copy")"
    cp "$ROOT/$orig" "$FMT/$orig"
    cp "$ROOT/$copy" "$FMT/$copy"
done <<< "$pairs"
expect "копия шаблона: пары совпадают" 0 "PASS:" \
    bash "$ROOT/scripts/check-copy-pairs.sh" "$FMT"

printf '\n# local edit\n' >> "$FMT/seed/strategy/scripts/isolate-push.sh"
expect "разошедшаяся копия без пометки SNAPSHOT поймана" 1 "seed/strategy/scripts/isolate-push.sh разошёлся" \
    bash "$ROOT/scripts/check-copy-pairs.sh" "$FMT"
cp "$ROOT/scripts/isolate-push.sh" "$FMT/seed/strategy/scripts/isolate-push.sh"

rm "$FMT/.claude/lib/find-python3.sh"
expect "пропавший файл пары пойман" 1 "одного из файлов нет" \
    bash "$ROOT/scripts/check-copy-pairs.sh" "$FMT"
cp "$ROOT/.claude/lib/find-python3.sh" "$FMT/.claude/lib/find-python3.sh"

mkdir -p "$FMT/roles/demo"
cp "$ROOT/scripts/install-hooks.sh" "$FMT/roles/demo/install-hooks.sh"
expect "новая незарегистрированная копия поймана" 1 "roles/demo/install-hooks.sh побайтово совпадает" \
    bash "$ROOT/scripts/check-copy-pairs.sh" "$FMT"
rm -r "$FMT/roles/demo"

mkdir -p "$FMT/scripts/tests"
cp "$ROOT/scripts/install-hooks.sh" "$FMT/scripts/tests/fixture-copy.sh"
expect "одинаковые файлы в тестах не считаются копиями" 0 "PASS:" \
    bash "$ROOT/scripts/check-copy-pairs.sh" "$FMT"

echo "--- check-shipped-config-secrets.sh ---"
expect "настоящий шаблон: настройки чистые" 0 "PASS:" \
    bash "$ROOT/scripts/check-shipped-config-secrets.sh" "$ROOT"

CFG="$TMP/cfg"
mkdir -p "$CFG/extensions" "$CFG/.claude"
printf '{"mcpServers": {"iwe-knowledge": {"type": "http", "url": "https://mcp.aisystant.com/mcp"}}}\n' > "$CFG/.mcp.json"
printf '{"mcpServers": {}}\n' > "$CFG/extensions/mcp-user.json"
printf '{"hooks": {}}\n' > "$CFG/.claude/settings.json"
expect "чистые настройки проходят" 0 "PASS: 3 файл" \
    bash "$ROOT/scripts/check-shipped-config-secrets.sh" "$CFG"

cp "$CFG/.mcp.json" "$CFG/.mcp.json.clean"
printf '{"mcpServers": {"ext-railway": {"command": "{{HOME_DIR}}/.secrets/mcp-railway.sh"}}}\n' > "$CFG/.mcp.json"
expect "заготовка пути к секретам в .mcp.json поймана (прежний railway)" 1 "FAIL: .mcp.json" \
    bash "$ROOT/scripts/check-shipped-config-secrets.sh" "$CFG"
mv "$CFG/.mcp.json.clean" "$CFG/.mcp.json"

printf '{"mcpServers": {"x": {"command": "/home/someone/bin/x.sh"}}}\n' > "$CFG/extensions/extra.json"
expect "личная папка в extensions/*.json поймана" 1 "FAIL: extensions/extra.json" \
    bash "$ROOT/scripts/check-shipped-config-secrets.sh" "$CFG"
rm "$CFG/extensions/extra.json"

printf '{"mcpServers": {"x": {"command": "{{HOME_DIR}}/.secrets/x.sh"}}}\n' > "$CFG/extensions/mcp-x.json.sample"
expect "образцы *.sample не проверяются" 0 "PASS:" \
    bash "$ROOT/scripts/check-shipped-config-secrets.sh" "$CFG"

exit "$fail"
