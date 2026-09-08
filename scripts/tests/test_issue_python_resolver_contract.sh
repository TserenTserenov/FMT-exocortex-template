#!/usr/bin/env bash
# test_issue_python_resolver_contract.sh — WP-529 Ф9 (Evgenii 20.08).
#
# check-python-resolver-contract.sh is a baseline-ratchet: it must (1) pass
# clean on the real tree with its own baseline, (2) catch a genuinely NEW
# bare python3/python call on a repo-owned .py file, (3) NOT flag an
# already-baselined call as new, (4) NOT flag a call that goes through the
# resolver ($PYTHON3/$RESOLVED_PYTHON3), (5) cover dynamic script variables in
# .claude/hooks and .claude/skills, (6) cover the same bare call written
# inside a .md instruction file (SKILL.md-style, added 26.08 for issue #541
# hvost 3 — an agent executes a Markdown code-fence's bash line literally,
# same risk as a .sh file). Runs against an isolated copy of the scan
# perimeter (REPO_ROOT override), not the real tree — a mutation test that
# edits tracked files in place would be its own footgun.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
GATE="$ROOT/scripts/check-python-resolver-contract.sh"
TEST_ROOT="/tmp/iwe-wp529-python-resolver-contract-test-$$"

FAIL=0
fail() { echo "  ❌ FAIL: $*" >&2; FAIL=$((FAIL+1)); }
pass() { echo "  ✅ PASS: $*"; }
# Invoked indirectly by the trap below.
# shellcheck disable=SC2329
cleanup() { local rc=$?; [ "${KEEP:-0}" = "1" ] || rm -rf "$TEST_ROOT"; exit "$rc"; }
trap cleanup EXIT INT TERM

mkdir -p \
    "$TEST_ROOT/scripts/tests/fixtures" \
    "$TEST_ROOT/setup" \
    "$TEST_ROOT/roles" \
    "$TEST_ROOT/.claude/hooks" \
    "$TEST_ROOT/.claude/skills/example/scripts"
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

# --- Сценарий 5: dynamic *.py variable in both .claude shell perimeters ---
cat > "$TEST_ROOT/.claude/hooks/new-hook.sh" <<'EOF'
#!/bin/bash
python3 "$RESIDENCY_GATE_PY" check-activation example manifest.md
EOF
cat > "$TEST_ROOT/.claude/skills/example/scripts/run.sh" <<'EOF'
#!/bin/bash
python3 "$SKILL_PROGRAM" --check
EOF
if bash "$TEST_ROOT/scripts/check-python-resolver-contract.sh" >/tmp/scenario5-out-$$ 2>&1; then
    fail "сценарий 5: голые python3-вызовы через переменные в .claude периметре не пойманы"
else
    if grep -q '.claude/hooks/new-hook.sh' /tmp/scenario5-out-$$ \
        && grep -q '.claude/skills/example/scripts/run.sh' /tmp/scenario5-out-$$; then
        pass "сценарий 5: hooks/skills и dynamic script variables входят в ratchet"
    else
        fail "сценарий 5: гейт упал, но не назвал оба .claude нарушения (см. /tmp/scenario5-out-$$)"
    fi
fi
rm -f /tmp/scenario5-out-$$

# --- Сценарий 6 (issue #541 hvost 3, Evgenii 26.08): голый python3-вызов
# внутри .md (SKILL.md-стиль инструкции) тоже должен ловиться — агент читает
# Markdown и выполняет его bash-строки буквально, тот же риск, что и в .sh. ---
cat > "$TEST_ROOT/.claude/skills/example/SKILL.md" <<'EOF'
# Example Skill

```bash
python3 "scripts/example-target.py"
```
EOF
if bash "$TEST_ROOT/scripts/check-python-resolver-contract.sh" >/tmp/scenario6-out-$$ 2>&1; then
    fail "сценарий 6: голый python3-вызов внутри SKILL.md не пойман — .md вне периметра гейта"
else
    if grep -q "example-target.py" /tmp/scenario6-out-$$ && grep -q "SKILL.md" /tmp/scenario6-out-$$; then
        pass "сценарий 6: голый python3-вызов внутри SKILL.md пойман тем же гейтом, что и .sh"
    else
        fail "сценарий 6: гейт упал, но не назвал SKILL.md как источник (см. /tmp/scenario6-out-$$)"
    fi
fi
rm -f /tmp/scenario6-out-$$

if [ "$FAIL" -eq 0 ]; then
    echo "python-resolver-contract: все сценарии прошли"
    exit 0
else
    echo "python-resolver-contract: $FAIL сценариев провалено"
    exit 1
fi
