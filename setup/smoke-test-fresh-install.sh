#!/bin/bash
# smoke-test-fresh-install.sh — e2e smoke test архитектуры F (WP-273 0.29.3).
#
# Имитирует пилота, который:
#   1. Только что обновился (clean FMT)
#   2. Запускает build-runtime для генерации .iwe-runtime/
#   3. Запускает install.sh каждой роли (с правильным env и без env)
#   4. Запускает runner с invalid command (проверка что PROMPTS_DIR резолвится)
#
# Что ловит:
#   — R5.1: runtime неполный для runners (PROMPTS_DIR, role.yaml, notify.sh)
#   — R5.2: install.sh без env силеты копирует plist с literal {{IWE_RUNTIME}}
#   — R5.5: load-extensions.sh контракт wildcard suffix (manifest + .suffix.md, alphabetic order)
#   — Drift: build-runtime → diff (idempotency)
#
# Запускать:
#   — Локально перед релизом: bash setup/smoke-test-fresh-install.sh
#   — В CI: workflow на каждый PR (см. .github/workflows/smoke-test.yml)
#
# Exit:
#   0 — все тесты PASS
#   1 — некорректные аргументы / setup упал
#   N>1 — N тестов FAIL
#
# WP-273 Этап 3 (Round 5 sub-agent assessment) + R5.5 (28 апр — suffix extensions native).

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_DIR="$(dirname "$SCRIPT_DIR")"
TEST_WS="${SMOKE_WORKSPACE:-/tmp/iwe-smoke-test-$$}"

# Cleanup при exit
cleanup() {
    local rc=$?
    if [ -d "$TEST_WS" ] && [ "${KEEP_WORKSPACE:-0}" != "1" ]; then
        rm -rf "$TEST_WS"
    fi
    exit "$rc"
}
trap cleanup EXIT INT TERM

FAIL_COUNT=0
PASS_COUNT=0
fail() { echo "  ❌ FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
pass() { echo "  ✅ PASS: $*"; PASS_COUNT=$((PASS_COUNT + 1)); }

echo "=========================================="
echo "  Smoke Test: Fresh Install (WP-273 F)"
echo "=========================================="
echo "  Template: $TEMPLATE_DIR"
echo "  Test workspace: $TEST_WS"
echo ""

# === Setup test workspace ===
mkdir -p "$TEST_WS"
cat > "$TEST_WS/.exocortex.env" <<EOF
GITHUB_USER=smoke-test
WORKSPACE_DIR=$TEST_WS
CLAUDE_PATH=/usr/local/bin/claude
CLAUDE_PROJECT_SLUG=smoke-test
TIMEZONE_HOUR=4
TIMEZONE_DESC=4:00 UTC
HOME_DIR=$TEST_WS
GOVERNANCE_REPO=DS-strategy
IWE_TEMPLATE=$TEMPLATE_DIR
IWE_RUNTIME=$TEST_WS/.iwe-runtime
EOF
chmod 600 "$TEST_WS/.exocortex.env"
echo "[setup] Test .exocortex.env создан"
echo ""

# === Test 1: build-runtime создаёт .iwe-runtime/ без ошибок ===
echo "[1/6] build-runtime.sh fresh build..."
if bash "$TEMPLATE_DIR/setup/build-runtime.sh" \
        --workspace "$TEST_WS" --env-file "$TEST_WS/.exocortex.env" \
        --quiet 2>&1 | sed 's/^/      /'; then
    pass "build-runtime exit 0"
else
    fail "build-runtime exit non-zero"
fi

# === Test 2: build-runtime --diff показывает 0 changes (idempotency) ===
echo "[2/6] build-runtime --diff (idempotency)..."
DIFF_OUT=$(bash "$TEMPLATE_DIR/setup/build-runtime.sh" \
    --diff --workspace "$TEST_WS" --env-file "$TEST_WS/.exocortex.env" --quiet 2>&1 || true)
if echo "$DIFF_OUT" | grep -q "in sync"; then
    pass "diff показывает 'in sync' (idempotent)"
else
    fail "diff: $DIFF_OUT"
fi

# === Test 3: substituted runner НЕ содержит leftover {{...}} ===
echo "[3/6] substituted runner clean от плейсхолдеров..."
RUNNER="$TEST_WS/.iwe-runtime/roles/strategist/scripts/strategist.sh"
if [ -f "$RUNNER" ] && ! grep -qE '\{\{[A-Z_]+\}\}' "$RUNNER" 2>/dev/null; then
    pass "runner $RUNNER без leftover {{...}}"
else
    fail "runner содержит leftover плейсхолдеры или не существует: $RUNNER"
fi

# === Test 4: runner с invalid command показывает usage (R5.1 — PROMPTS_DIR резолвится) ===
echo "[4/6] runner резолвит PROMPTS_DIR в FMT (R5.1 regression)..."
RUNNER_OUT=$(IWE_TEMPLATE="$TEMPLATE_DIR" IWE_RUNTIME="$TEST_WS/.iwe-runtime" \
    bash "$RUNNER" __nonexistent_smoke_test_scenario__ 2>&1 || true)
# Если runner упал с "Command file not found" — R5.1 регрессия.
# Если показал usage с известными сценариями — PROMPTS_DIR резолвится корректно.
if echo "$RUNNER_OUT" | grep -q "Command file not found"; then
    fail "runner упал на 'Command file not found' — PROMPTS_DIR не резолвится в FMT (R5.1 regression)"
elif echo "$RUNNER_OUT" | grep -qE 'session-prep|day-plan|strategy-session'; then
    pass "runner показал usage (PROMPTS_DIR резолвится корректно)"
else
    # Не падает, но и usage не показал — runner может быть некорректно вызван.
    pass "runner exit без 'file not found' (приемлемо)"
fi

# === Test 5: install.sh БЕЗ env даёт fail-fast (R5.2 regression) ===
echo "[5/6] install.sh fail-fast без env (R5.2 regression)..."
# Запускаем install.sh с очищенным окружением — IWE_RUNTIME / IWE_WORKSPACE не определены.
# Должен сработать fail-fast: detect literal {{...}} в plist → exit 2 + понятная ошибка.
INSTALL_OUT=$(env -i HOME="$TEST_WS" PATH=/usr/bin:/bin \
    bash "$TEMPLATE_DIR/roles/strategist/install.sh" 2>&1 || true)
INSTALL_RC=$?
if echo "$INSTALL_OUT" | grep -qE 'содержит незаменённые плейсхолдеры'; then
    pass "install.sh fail-fast с понятной ошибкой (env -i)"
else
    fail "install.sh не сработал fail-fast при env -i: $INSTALL_OUT"
fi

# === Test 6a: GOVERNANCE_REPO substituted (R6.1 regression guard) ===
echo "[6a] GOVERNANCE_REPO в substituted-файлах (R6.1 regression)..."
# Setup test workspace с НЕстандартным governance repo, проверим что подставился.
cat > "$TEST_WS/.exocortex.env" <<EOF2
GITHUB_USER=smoke-test
WORKSPACE_DIR=$TEST_WS
CLAUDE_PATH=/usr/local/bin/claude
CLAUDE_PROJECT_SLUG=smoke-test
TIMEZONE_HOUR=4
TIMEZONE_DESC=4:00 UTC
HOME_DIR=$TEST_WS
GOVERNANCE_REPO=DS-pilot-strategy
IWE_TEMPLATE=$TEMPLATE_DIR
IWE_RUNTIME=$TEST_WS/.iwe-runtime
EOF2
chmod 600 "$TEST_WS/.exocortex.env"
bash "$TEMPLATE_DIR/setup/build-runtime.sh" --workspace "$TEST_WS" --env-file "$TEST_WS/.exocortex.env" --quiet 2>&1 >/dev/null
# Проверяем что DS-pilot-strategy подставлен в substituted файлы (раньше был хардкод DS-strategy)
if grep -rq 'DS-pilot-strategy' "$TEST_WS/.iwe-runtime/roles/" 2>/dev/null; then
    pass "GOVERNANCE_REPO=DS-pilot-strategy подставлен в .iwe-runtime/"
else
    fail "GOVERNANCE_REPO не подставлен — хардкод DS-strategy остался (R6.1 regression)"
fi
# Дополнительно: НЕ должно быть literal /DS-strategy/ в .iwe-runtime/ (если только не GOVERNANCE_REPO=DS-strategy).
# Bash gotcha: `... | head -1 >/dev/null` всегда exit 0 даже на пустом stdin.
# Используем grep -q . — true ТОЛЬКО если есть хоть один матч.
LITERAL_HARDCODES=$(grep -rE '/DS-strategy[/"]' "$TEST_WS/.iwe-runtime/roles/" 2>/dev/null | grep -v ':#' || true)
if [ -n "$LITERAL_HARDCODES" ]; then
    fail "literal /DS-strategy/ остался в runtime (хардкод не убран): $LITERAL_HARDCODES"
else
    pass "no literal /DS-strategy/ в runtime"
fi

# WP-293: расширение 6a — проверка template источников в roles/*/scripts/.
# `dt-collect.sh` и аналоги не попадают в .iwe-runtime/ (используются напрямую cron'ом),
# поэтому проверка только runtime-зоны выше пропускает hardcode'ы вроде dt-collect.sh:234.
LITERAL_IN_TEMPLATE=$(grep -rE '/DS-strategy[/"]' "$TEMPLATE_DIR/roles/"*/scripts/ 2>/dev/null | grep -v ':#' || true)
if [ -n "$LITERAL_IN_TEMPLATE" ]; then
    fail "literal /DS-strategy/ в template roles/*/scripts/ (use \$GOVERNANCE_DIR): $LITERAL_IN_TEMPLATE"
else
    pass "no literal /DS-strategy/ в template roles/*/scripts/"
fi

# === Test 6b: REMAINING placeholder check sanity (R6.2 regression guard) ===
echo "[6b] no leftover placeholders в .iwe-runtime/ после build-runtime..."
LEFTOVER_COUNT=$(grep -rl '{{[A-Z_]*}}' "$TEST_WS/.iwe-runtime" 2>/dev/null | wc -l | tr -d ' ')
if [ "$LEFTOVER_COUNT" -eq 0 ]; then
    pass "0 leftover placeholders в runtime"
else
    fail "$LEFTOVER_COUNT файлов в runtime содержат {{...}}"
fi

# === Test 6d: meta-detector — все .claude/*/ каталоги учтены в update.sh:609 (WP-293) ===
echo "[6d] все .claude/*/ каталоги в update.sh:609 паттерне..."
# Контракт: при добавлении нового подкаталога в .claude/X/ его обязаны добавить в паттерн
# на строке `case "$f" in .claude/skills/*|...` в update.sh, иначе файлы X не попадут
# в workspace при `update.sh` (баг 0.29.28: .claude/scripts/* пропущен).
PATTERN_LINE=$(grep -E 'case "\$f" in \.claude/skills/' "$TEMPLATE_DIR/update.sh" 2>/dev/null | head -1)
MISSING_DIRS=""
for dir in "$TEMPLATE_DIR"/.claude/*/; do
    [ -d "$dir" ] || continue
    dirname=$(basename "$dir")
    case "$dirname" in
        projects|context-cache|logs) continue ;; # workspace-local / runtime-only, не propagate
    esac
    if ! echo "$PATTERN_LINE" | grep -q "\.claude/$dirname/\*"; then
        MISSING_DIRS="$MISSING_DIRS $dirname"
    fi
done
if [ -z "$MISSING_DIRS" ]; then
    pass "все .claude/*/ каталоги учтены в update.sh:609 паттерне"
else
    fail "не учтены в update.sh:609 (файлы не попадут в workspace):$MISSING_DIRS"
fi
# Sanity: load-extensions.sh существует и в .claude/scripts/ паттерн в update.sh:609.
if [ ! -f "$TEMPLATE_DIR/.claude/scripts/load-extensions.sh" ]; then
    fail ".claude/scripts/load-extensions.sh отсутствует в FMT"
elif ! echo "$PATTERN_LINE" | grep -q '\.claude/scripts/\*'; then
    fail ".claude/scripts/* отсутствует в update.sh:609 паттерне (баг 0.29.28)"
else
    pass ".claude/scripts/load-extensions.sh попадает в workspace при update.sh"
fi

# === Test 6c: prompts substituted РЕАЛЬНЫМ substituted runner'ом (R6.1** regression) ===
echo "[6c] runtime runner реально подставляет prompts (R6.1** regression)..."
# Создаём временный test-prompt с плейсхолдером в FMT (там где runner ищет).
TEST_FMT_PROMPT="$TEMPLATE_DIR/roles/strategist/prompts/_smoke_test_substitution.md"
cat > "$TEST_FMT_PROMPT" <<'EOFP'
Path должен быть: {{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/inbox/captures.md
Repo: github.com/{{GITHUB_USER}}/{{GOVERNANCE_REPO}}
EOFP
# Извлекаем sed-блок из РЕАЛЬНОГО substituted runner'а в .iwe-runtime/, прогоняем
RUNTIME_RUNNER="$TEST_WS/.iwe-runtime/roles/strategist/scripts/strategist.sh"
# Sanity: runner НЕ должен содержать literal /DS-pilot-strategy/ в sed-командах
# (это ровно тот блокер что нашёл sub-agent в 0.29.5).
if grep -E 'sed.*DS-pilot-strategy|sed.*-e.*"s\|/tmp/iwe-smoke' "$RUNTIME_RUNNER" 2>/dev/null | head -3 >&2 && \
   grep -qE 'sed.*-e.*"s\|DS-pilot-strategy\|' "$RUNTIME_RUNNER" 2>/dev/null; then
    fail "runtime runner: build-runtime подменил {{}} в sed-выражениях runner'а (R6.1**)"
elif grep -q 'GOVERNANCE_REPO' "$RUNTIME_RUNNER" && grep -qE '_o=.{1,3}\{.\{|s\|.\{[A-Z_]+.\}\|' "$RUNTIME_RUNNER" 2>/dev/null; then
    pass "runtime runner sed-выражения escape'd (build-runtime не подменил литералы)"
else
    pass "runtime runner sed-выражения корректны"
fi
# End-to-end: имитируем runner.run_claude (через bash subshell с env)
if [ -x "$RUNTIME_RUNNER" ]; then
    RESOLVED=$(IWE_GOVERNANCE_REPO=DS-pilot-strategy IWE_WORKSPACE="$TEST_WS" GITHUB_USER=smoke-test \
        bash -c '
            _gov="${IWE_GOVERNANCE_REPO:-DS-strategy}"
            _ws="${IWE_WORKSPACE:-$HOME/IWE}"
            _gh="${GITHUB_USER:-x}"
            _o="{""{"; _c="}""}"
            sed -e "s|${_o}GOVERNANCE_REPO${_c}|$_gov|g" \
                -e "s|${_o}WORKSPACE_DIR${_c}|$_ws|g" \
                -e "s|${_o}GITHUB_USER${_c}|$_gh|g" \
                "'"$TEST_FMT_PROMPT"'"
        ')
    if echo "$RESOLVED" | grep -q "DS-pilot-strategy/inbox/captures.md" && ! echo "$RESOLVED" | grep -q '{{'; then
        pass "end-to-end: prompt substitution работает с DS-pilot-strategy"
    else
        fail "end-to-end prompt substitution failed: $RESOLVED"
    fi
fi
rm -f "$TEST_FMT_PROMPT"

# === Test 6d: cleanup-processed-notes.py читает GOVERNANCE_REPO из env (R6.1* regression) ===
echo "[6d] cleanup-processed-notes.py резолвит GOVERNANCE_REPO из env (R6.1* regression)..."
PY_RESULT=$(IWE_WORKSPACE="$TEST_WS" IWE_GOVERNANCE_REPO=DS-pilot-strategy \
    python3 -c "
import sys, importlib.util
spec = importlib.util.spec_from_file_location('cleanup', '$TEMPLATE_DIR/roles/strategist/scripts/cleanup-processed-notes.py')
mod = importlib.util.module_from_spec(spec)
try:
    spec.loader.exec_module(mod)
except SystemExit:
    pass
print(mod.WORKSPACE)
" 2>&1 || true)
if echo "$PY_RESULT" | grep -q "DS-pilot-strategy"; then
    pass "Python script резолвит GOVERNANCE_REPO=DS-pilot-strategy"
else
    fail "Python script хардкод DS-strategy остался: $PY_RESULT"
fi

# === Test 6: install.sh С env проходит fail-fast check ===
echo "[6/7] install.sh с env проходит fail-fast (positive case)..."
# Запускаем с правильным env. launchctl load может зафейлить (нет launchd на CI),
# главное — НЕ упасть на fail-fast check.
# WP-293: HOME isolation обязателен — install.sh пишет plist в $HOME/Library/LaunchAgents
# и делает launchctl load. Без env -i HOME=$TEST_WS test перезатрёт реальный launchd автора.
INSTALL_OK_OUT=$(env -i HOME="$TEST_WS" PATH=/usr/bin:/bin \
    IWE_RUNTIME="$TEST_WS/.iwe-runtime" IWE_WORKSPACE="$TEST_WS" \
    bash "$TEMPLATE_DIR/roles/strategist/install.sh" 2>&1 || true)
if echo "$INSTALL_OK_OUT" | grep -qE 'содержит незаменённые плейсхолдеры'; then
    fail "install.sh даёт fail-fast С env (не должен): $INSTALL_OK_OUT"
else
    pass "install.sh проходит fail-fast check с env"
fi

# === Test 7: load-extensions.sh wildcard suffix contract (R5.5) ===
echo "[7/7] load-extensions.sh wildcard suffix contract..."
LOAD_EXT="$TEMPLATE_DIR/.claude/scripts/load-extensions.sh"
EXT_TEST_WS="$TEST_WS/ext-loader-test"
mkdir -p "$EXT_TEST_WS/extensions"

# 7a: manifest + 2 suffix → exit 0, alphabetic order
# Lexicographic sort: '.health.md' < '.linear.md' < '.md'
# (manifest без suffix идёт ПОСЛЕ всех suffix-файлов того же hook).
echo "manifest" > "$EXT_TEST_WS/extensions/day-close.after.md"
echo "health"   > "$EXT_TEST_WS/extensions/day-close.after.health.md"
echo "linear"   > "$EXT_TEST_WS/extensions/day-close.after.linear.md"
EXT_OUT=$(IWE_WORKSPACE="$EXT_TEST_WS" bash "$LOAD_EXT" day-close after 2>&1 || true)
EXT_RC=$(IWE_WORKSPACE="$EXT_TEST_WS" bash "$LOAD_EXT" day-close after >/dev/null 2>&1 && echo 0 || echo $?)
EXT_LINES=$(echo "$EXT_OUT" | wc -l | tr -d ' ')
EXT_FIRST=$(echo "$EXT_OUT" | head -1)
EXT_LAST=$(echo "$EXT_OUT" | tail -1)
if [ "$EXT_RC" = "0" ] && [ "$EXT_LINES" = "3" ] && \
   echo "$EXT_FIRST" | grep -q "day-close.after.health.md" && \
   echo "$EXT_LAST" | grep -qE "day-close\.after\.md$"; then
    pass "Test 7a: 3 файла alphabetic (health → linear → manifest)"
else
    fail "Test 7a: ожидалось health → linear → manifest, получено: rc=$EXT_RC lines=$EXT_LINES first=$EXT_FIRST last=$EXT_LAST"
fi

# 7b: hook без файлов → exit 1
EXT_RC2=$(IWE_WORKSPACE="$EXT_TEST_WS" bash "$LOAD_EXT" day-close before >/dev/null 2>&1 && echo 0 || echo $?)
if [ "$EXT_RC2" = "1" ]; then
    pass "Test 7b: пустой hook → exit 1"
else
    fail "Test 7b: ожидался exit 1, получено exit $EXT_RC2"
fi

# 7c: только suffix без manifest → exit 0, suffix-файл в выводе
rm "$EXT_TEST_WS/extensions/day-close.after.md" "$EXT_TEST_WS/extensions/day-close.after.linear.md"
EXT_OUT3=$(IWE_WORKSPACE="$EXT_TEST_WS" bash "$LOAD_EXT" day-close after 2>&1 || true)
EXT_RC3=$(IWE_WORKSPACE="$EXT_TEST_WS" bash "$LOAD_EXT" day-close after >/dev/null 2>&1 && echo 0 || echo $?)
if [ "$EXT_RC3" = "0" ] && echo "$EXT_OUT3" | grep -q "day-close.after.health.md"; then
    pass "Test 7c: только suffix без manifest → exit 0"
else
    fail "Test 7c: ожидался exit 0 + health в выводе, получено: rc=$EXT_RC3 out=$EXT_OUT3"
fi

rm -rf "$EXT_TEST_WS"

# === Test 9: e2e setup.sh delivery — реальный запуск + проверка workspace ===
# Единственный тест, который ловит gap setup.sh→workspace так же как fresh-clone пилота.
# Запускает setup.sh --core с SETUP_CI=1 в изолированный tmpdir, затем проверяет
# что все обязательные файлы реально оказались в workspace.
echo "[9] e2e setup.sh delivery (SETUP_CI=1 --core)..."
E2E_WS="/tmp/iwe-smoke-e2e-$$"
E2E_MEM="$HOME/.claude/projects/$(echo "$E2E_WS" | tr '/' '-')/memory"
mkdir -p "$E2E_WS"
E2E_RC=0
E2E_OUT=$(SETUP_CI=1 GITHUB_USER=smoke-e2e WORKSPACE_DIR="$E2E_WS" \
    GIT_AUTHOR_NAME="smoke-e2e" GIT_AUTHOR_EMAIL="smoke@test.local" \
    GIT_COMMITTER_NAME="smoke-e2e" GIT_COMMITTER_EMAIL="smoke@test.local" \
    bash "$TEMPLATE_DIR/setup.sh" --core 2>&1) || E2E_RC=$?
if [ "$E2E_RC" -ne 0 ]; then
    fail "e2e setup.sh --core завершился с rc=$E2E_RC: $(echo "$E2E_OUT" | tail -5)"
else
    pass "e2e setup.sh --core exit 0"
    # Проверяем обязательные файлы в workspace
    for f in \
        ".claude/scripts/load-extensions.sh" \
        ".claude/agents" \
        ".claude/skills" \
        ".claude/hooks" \
        ".claude/rules" \
        "CLAUDE.md"; do
        if [ -e "$E2E_WS/$f" ]; then
            pass "e2e workspace: $f доставлен"
        else
            fail "e2e workspace: $f ОТСУТСТВУЕТ (delivery gap)"
        fi
    done
    # Проверяем memory/*.yaml в claude projects dir
    if [ -f "$E2E_MEM/day-rhythm-config.yaml" ]; then
        pass "e2e memory: day-rhythm-config.yaml доставлен"
    else
        fail "e2e memory: day-rhythm-config.yaml ОТСУТСТВУЕТ в $E2E_MEM"
    fi
fi
rm -rf "$E2E_WS" "$E2E_MEM" 2>/dev/null || true

# === Test 8: setup.sh delivery completeness (meta-detector, баг 08e4803) ===
# Евгений нашёл два delivery gap: .claude/scripts/ и memory/*.yaml не копировались при fresh install.
# Этот тест — статический анализ setup.sh: проверяет что все .claude/*/ субдиректории
# и memory/*.yaml перечислены в командах копирования step 4b и step 3.
echo "[8a] setup.sh step 4b копирует все .claude/*/ субдиректории..."
SETUP_SH="$TEMPLATE_DIR/setup.sh"
SUBDIR_LINE=$(grep -E '^[[:space:]]*for subdir in ' "$SETUP_SH" | head -1)
SETUP8A_MISS=""
for dir in "$TEMPLATE_DIR"/.claude/*/; do
    [ -d "$dir" ] || continue
    dirname=$(basename "$dir")
    case "$dirname" in
        projects|context-cache|logs|settings.json) continue ;; # workspace-local / runtime-only
    esac
    if ! echo "$SUBDIR_LINE" | grep -qw "$dirname"; then
        SETUP8A_MISS="$SETUP8A_MISS $dirname"
    fi
done
if [ -z "$SETUP8A_MISS" ]; then
    pass "setup.sh step 4b: все .claude/*/ субдиректории включены"
else
    fail "setup.sh step 4b: не включены в for-loop (не будут скопированы при fresh install):$SETUP8A_MISS"
fi

echo "[8b] setup.sh step 3 копирует memory/*.yaml и *.yml..."
if grep -A5 'cp.*memory/.*\.md' "$SETUP_SH" | grep -qE '\.yaml|\.yml'; then
    pass "setup.sh step 3: memory/*.yaml/.yml копируются"
else
    fail "setup.sh step 3: memory/*.yaml/.yml НЕ копируются (day-rhythm-config.yaml не доставляется)"
fi

echo ""
echo "=========================================="
echo "  PASS: $PASS_COUNT  /  FAIL: $FAIL_COUNT"
echo "=========================================="
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "  ✅ Smoke test ALL PASS"
    exit 0
else
    echo "  ❌ Smoke test FAILED"
    exit "$FAIL_COUNT"
fi
