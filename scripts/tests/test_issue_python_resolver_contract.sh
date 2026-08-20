#!/usr/bin/env bash
# test_issue_python_resolver_contract.sh — WP-529 Ф9 (Evgenii 20.08).
#
# check-python-resolver-contract.sh is a baseline-ratchet: it must (1) pass
# clean on the real tree with its own baseline, (2) catch a genuinely NEW
# bare python3/python call on a repo-owned .py file, (3) NOT flag an
# already-baselined call as new, (4) NOT flag a call that goes through the
# resolver ($PYTHON3/$RESOLVED_PYTHON3). Runs against an isolated copy of
# scripts/setup/roles (REPO_ROOT override), not the real tree — a mutation
# test that edits tracked files in place would be its own footgun.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
GATE="$ROOT/scripts/check-python-resolver-contract.sh"
TEST_ROOT="/tmp/iwe-wp529-python-resolver-contract-test-$$"

FAIL=0
fail() { echo "  ❌ FAIL: $*" >&2; FAIL=$((FAIL+1)); }
pass() { echo "  ✅ PASS: $*"; }
cleanup() { local rc=$?; [ "${KEEP:-0}" = "1" ] || rm -rf "$TEST_ROOT"; exit "$rc"; }
trap cleanup EXIT INT TERM

mkdir -p "$TEST_ROOT/scripts/tests/fixtures" "$TEST_ROOT/setup" "$TEST_ROOT/roles"
cp "$GATE" "$TEST_ROOT/scripts/check-python-resolver-contract.sh"
chmod +x "$TEST_ROOT/scripts/check-python-resolver-contract.sh"

cat > "$TEST_ROOT/scripts/legacy-caller.sh" <<'EOF'
#!/bin/bash
python3 "scripts/legacy-target.py"
EOF

export REPO_ROOT="$TEST_ROOT"

# --- Сценарий 1: пустой baseline → legacy-caller.sh считается новым нарушением ---
: > "$TEST_ROOT/scripts/tests/fixtures/python-resolver-baseline.txt"
if bash "$TEST_ROOT/scripts/check-python-resolver-contract.sh" >/tmp/scenario1-out-$$ 2>&1; then
    fail "сценарий 1: пустой baseline должен провалить голый python3-вызов, гейт прошёл зелёным"
else
    if grep -q "legacy-caller.sh" /tmp/scenario1-out-$$; then
        pass "сценарий 1: голый вызов без baseline корректно провалил гейт"
    else
        fail "сценарий 1: гейт упал, но не назвал legacy-caller.sh как причину"
    fi
fi
rm -f /tmp/scenario1-out-$$

# --- Сценарий 2: --update-baseline фиксирует текущее состояние, повторный check зелёный ---
bash "$TEST_ROOT/scripts/check-python-resolver-contract.sh" --update-baseline >/dev/null 2>&1
if bash "$TEST_ROOT/scripts/check-python-resolver-contract.sh" >/dev/null 2>&1; then
    pass "сценарий 2: после --update-baseline тот же легаси-вызов больше не блокирует"
else
    fail "сценарий 2: --update-baseline не снял блокировку с уже занесённого вызова"
fi

# --- Сценарий 3: baseline зафиксирован, добавляем ВТОРОЙ голый вызов → должен упасть ---
cat >> "$TEST_ROOT/scripts/legacy-caller.sh" <<'EOF'
python3 "scripts/another-new-target.py"
EOF
if bash "$TEST_ROOT/scripts/check-python-resolver-contract.sh" >/tmp/scenario3-out-$$ 2>&1; then
    fail "сценарий 3: новый вызов рядом с уже занесённым в baseline не пойман — мутационная проверка провалена"
else
    if grep -q "another-new-target.py" /tmp/scenario3-out-$$ && ! grep -q "legacy-target.py" /tmp/scenario3-out-$$; then
        pass "сценарий 3: новый вызов пойман, старый (уже в baseline) не переспрошен — ratchet работает по дельте, не по файлу целиком"
    else
        fail "сценарий 3: вывод гейта не соответствует ожиданию (см. /tmp/scenario3-out-$$)"
    fi
fi
rm -f /tmp/scenario3-out-$$

# --- Сценарий 4: вызов через резолвер не считается нарушением ---
cat > "$TEST_ROOT/scripts/resolver-caller.sh" <<'EOF'
#!/bin/bash
PYTHON3="$(scripts/lib/find-python3.sh)" || exit 1
"$PYTHON3" "scripts/resolver-target.py"
EOF
bash "$TEST_ROOT/scripts/check-python-resolver-contract.sh" --update-baseline >/dev/null 2>&1
if bash "$TEST_ROOT/scripts/check-python-resolver-contract.sh" >/tmp/scenario4-out-$$ 2>&1; then
    if grep -q "resolver-caller.sh" /tmp/scenario4-out-$$; then
        fail "сценарий 4: вызов через \$PYTHON3-резолвер ложно помечен как голый python3"
    else
        pass "сценарий 4: вызов через резолвер не триггерит гейт"
    fi
else
    fail "сценарий 4: гейт неожиданно упал после легитимного резолвер-вызова (см. /tmp/scenario4-out-$$)"
fi
rm -f /tmp/scenario4-out-$$

if [ "$FAIL" -eq 0 ]; then
    echo "python-resolver-contract: все сценарии прошли"
    exit 0
else
    echo "python-resolver-contract: $FAIL сценариев провалено"
    exit 1
fi
