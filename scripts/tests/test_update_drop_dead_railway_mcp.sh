#!/usr/bin/env bash
# test_update_drop_dead_railway_mcp.sh — миграция update.sh убирает из
# .mcp.json пользователя авторский ext-railway, если файла его запуска нет
# (WP-7, чистка шаблона 2026-11-01).
#
# Функция берётся из настоящего update.sh (блок BEGIN/END-TESTABLE), а не
# копией логики, и прогоняется в трёх режимах: через Python, через jq и без
# обоих инструментов.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0
pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; fail=1; }

BLOCK=$(awk '/# BEGIN-TESTABLE: drop-dead-railway-mcp$/{f=1; next} /# END-TESTABLE: drop-dead-railway-mcp$/{f=0} f' "$ROOT/update.sh")
if [ -z "$BLOCK" ]; then
    echo "setup failed: блок drop-dead-railway-mcp не найден в update.sh" >&2
    exit 1
fi
eval "$BLOCK"
declare -F drop_dead_railway_mcp >/dev/null || { echo "setup failed: функция не определилась" >&2; exit 1; }

# Шаг должен вызываться ПОСЛЕ подстановки домашней папки и ДО вливания
# extensions/mcp-user.json — иначе railway, описанный человеком сам, пропадёт,
# а неподставленная заготовка уйдёт в мёрж.
line_subst=$(grep -n "подставлен в уже существующем файле" "$ROOT/update.sh" | head -1 | cut -d: -f1)
line_call=$(grep -n '^drop_dead_railway_mcp "\$MCP_WORKSPACE"' "$ROOT/update.sh" | head -1 | cut -d: -f1)
line_merge=$(grep -n '^# Merge extensions/mcp-user.json into workspace .mcp.json' "$ROOT/update.sh" | head -1 | cut -d: -f1)
if [ -n "$line_subst" ] && [ -n "$line_call" ] && [ -n "$line_merge" ] \
   && [ "$line_subst" -lt "$line_call" ] && [ "$line_call" -lt "$line_merge" ]; then
    pass "шаг вызывается после подстановки домашней папки и до вливания mcp-user.json"
else
    fail "порядок шагов нарушен: подстановка=$line_subst вызов=$line_call мёрж=$line_merge"
fi

HOME_FAKE="$TMP/home"
mkdir -p "$HOME_FAKE"
WRAPPER_REL=".secrets/mcp-railway.sh"

# Служебная копия набора серверов: iwe-knowledge, сторонний сервер,
# railway и ещё один stdio-сервер — проверяем, что уходит ровно railway,
# а порядок и содержимое остальных не трогаются.
write_mcp() {
    local file="$1" railway_cmd="$2"
    cat > "$file" <<JSON
{
  "mcpServers": {
    "iwe-knowledge": {
      "type": "http",
      "url": "https://mcp.aisystant.com/mcp"
    },
    "ext-figma": {
      "type": "http",
      "url": "http://127.0.0.1:3845/mcp"
    },
    "ext-railway": {
      "command": "$railway_cmd",
      "args": []
    },
    "local-notes": {
      "command": "/usr/local/bin/notes-mcp",
      "args": ["--stdio"]
    }
  }
}
JSON
}

servers_of() {
    python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1], encoding="utf-8"))["mcpServers"]))' "$1"
}

run_cases() {
    local mode="$1"
    local dir="$TMP/$mode"
    mkdir -p "$dir"
    rm -f "$HOME_FAKE/$WRAPPER_REL"

    # 1. Путь подставлен, файла нет → railway убран, остальные на месте и по порядку.
    write_mcp "$dir/a.json" "$HOME_FAKE/$WRAPPER_REL"
    drop_dead_railway_mcp "$dir/a.json" "$HOME_FAKE" >/dev/null
    if [ "$(servers_of "$dir/a.json")" = "iwe-knowledge ext-figma local-notes" ]; then
        pass "$mode: подставленный путь без файла — railway убран, три других сервера целы и в том же порядке"
    else
        fail "$mode: подставленный путь без файла — осталось: $(servers_of "$dir/a.json")"
    fi
    if python3 -c 'import json,sys; s=json.load(open(sys.argv[1], encoding="utf-8"))["mcpServers"]; assert s["local-notes"]["args"]==["--stdio"] and s["ext-figma"]["url"].endswith("/mcp")' "$dir/a.json" 2>/dev/null; then
        pass "$mode: содержимое оставшихся серверов не изменилось"
    else
        fail "$mode: содержимое оставшихся серверов повреждено"
    fi

    # 2. Заготовка не подставлена, файла нет → railway убран.
    write_mcp "$dir/b.json" "{{HOME_DIR}}/$WRAPPER_REL"
    drop_dead_railway_mcp "$dir/b.json" "$HOME_FAKE" >/dev/null
    if [ "$(servers_of "$dir/b.json")" = "iwe-knowledge ext-figma local-notes" ]; then
        pass "$mode: неподставленная заготовка без файла — railway убран"
    else
        fail "$mode: неподставленная заготовка без файла — осталось: $(servers_of "$dir/b.json")"
    fi

    # 3. Файл запуска есть → запись остаётся (и с путём, и с заготовкой), файл не тронут.
    mkdir -p "$HOME_FAKE/.secrets"
    printf '#!/bin/sh\n' > "$HOME_FAKE/$WRAPPER_REL"
    write_mcp "$dir/c.json" "$HOME_FAKE/$WRAPPER_REL"
    cp "$dir/c.json" "$dir/c.orig"
    write_mcp "$dir/c2.json" "{{HOME_DIR}}/$WRAPPER_REL"
    cp "$dir/c2.json" "$dir/c2.orig"
    drop_dead_railway_mcp "$dir/c.json" "$HOME_FAKE" >/dev/null
    drop_dead_railway_mcp "$dir/c2.json" "$HOME_FAKE/" >/dev/null
    if cmp -s "$dir/c.json" "$dir/c.orig" && cmp -s "$dir/c2.json" "$dir/c2.orig"; then
        pass "$mode: файл запуска есть — записи railway оставлены, .mcp.json не изменён"
    else
        fail "$mode: файл запуска есть, но .mcp.json изменён"
    fi
    rm -f "$HOME_FAKE/$WRAPPER_REL"

    # 4. Записи railway нет → файл побайтово тот же.
    cat > "$dir/d.json" <<'JSON'
{"mcpServers": {"iwe-knowledge": {"type": "http", "url": "https://mcp.aisystant.com/mcp"}}}
JSON
    cp "$dir/d.json" "$dir/d.orig"
    drop_dead_railway_mcp "$dir/d.json" "$HOME_FAKE" >/dev/null
    if cmp -s "$dir/d.json" "$dir/d.orig"; then
        pass "$mode: записи railway нет — файл не тронут"
    else
        fail "$mode: записи railway нет, а файл изменён"
    fi

    # 5. Railway с чужой командой (человек подключил свой) → не трогаем.
    write_mcp "$dir/e.json" "/opt/railway/bin/mcp-railway.sh"
    cp "$dir/e.json" "$dir/e.orig"
    drop_dead_railway_mcp "$dir/e.json" "$HOME_FAKE" >/dev/null
    if cmp -s "$dir/e.json" "$dir/e.orig"; then
        pass "$mode: railway со своей командой вне домашней папки — не тронут"
    else
        fail "$mode: railway со своей командой удалён"
    fi

    # 6. Временные файлы не остаются рядом с .mcp.json.
    if ls "$dir"/*.railway.* >/dev/null 2>&1; then
        fail "$mode: рядом с .mcp.json остались временные файлы"
    else
        pass "$mode: временных файлов не осталось"
    fi
}

echo "--- через Python ---"
PY_BIN=python3
py_available() { [ -n "$PY_BIN" ]; }
run_cases python

if command -v jq >/dev/null 2>&1; then
    echo "--- через jq (Python недоступен) ---"
    PY_BIN=""
    run_cases jq
else
    echo "  ○ jq не установлен — ветка jq не проверена на этой машине"
fi

echo "--- без Python и jq ---"
PY_BIN=""
NOTOOLS="$TMP/notools-bin"
mkdir -p "$NOTOOLS"
for tool in grep mktemp mv rm; do
    ln -s "$(command -v "$tool")" "$NOTOOLS/$tool"
done
mkdir -p "$TMP/none"
write_mcp "$TMP/none/f.json" "$HOME_FAKE/$WRAPPER_REL"
cp "$TMP/none/f.json" "$TMP/none/f.orig"
out=$(PATH="$NOTOOLS" drop_dead_railway_mcp "$TMP/none/f.json" "$HOME_FAKE")
if cmp -s "$TMP/none/f.json" "$TMP/none/f.orig" && printf '%s' "$out" | grep -q 'нет ни python3, ни jq'; then
    pass "без Python и jq — шаг пропущен с сообщением, файл не тронут"
else
    fail "без Python и jq — ожидался пропуск с сообщением; вывод: $out"
fi
if ls "$TMP/none"/*.railway.* >/dev/null 2>&1; then
    fail "без Python и jq — остался временный файл"
fi

# 7. Шаблон больше не поставляет railway, образец лежит отдельно и не вливается.
if grep -q 'mcp-railway' "$ROOT/.mcp.json"; then
    fail "шаблонный .mcp.json всё ещё содержит railway"
else
    pass "шаблонный .mcp.json не содержит railway"
fi
if [ -f "$ROOT/extensions/mcp-railway.json.sample" ] && ! grep -q 'railway' "$ROOT/extensions/mcp-user.json"; then
    pass "образец railway лежит отдельным файлом, mcp-user.json шаблона пуст"
else
    fail "образец railway отсутствует или попал в mcp-user.json"
fi

exit "$fail"
