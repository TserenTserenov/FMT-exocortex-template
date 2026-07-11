#!/bin/bash
# Еженедельный запуск QA-агента
#
# Cron: 0 3 * * 0  (воскресенье 03:00)
# Или: launchd (macOS), см. scripts/launchd/
#
# Адаптировать:
#   BOT_DIR — путь к тестируемому DS-instrument
#   AGENT_DIR — путь к этой папке
#   WORKSPACE_DIR — путь к DS-agent-workspace/tester

set -uo pipefail

if [ -f "$HOME/.env" ]; then
    set -a
    source "$HOME/.env"
    set +a
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="$SCRIPT_DIR"
BOT_DIR="${BOT_DIR:?BOT_DIR not set. Set it in .env or pass as environment variable, e.g.: BOT_DIR=\$HOME/IWE/your-bot-repo}"
WORKSPACE_DIR="${WORKSPACE_DIR:-$HOME/IWE/DS-agent-workspace/tester}"
DATE=$(date +%Y-%m-%d)
REPORT="$WORKSPACE_DIR/weekly-$DATE.md"

mkdir -p "$WORKSPACE_DIR"

echo "=== QA Agent: Weekly Run ($DATE) ==="

# --- L1+L2: Smoke/Regression ---
echo "--- L1+L2: pytest ---"
cd "$BOT_DIR"
if [ -d ".venv" ]; then
    .venv/bin/python -m pytest tests/smoke/ -v --tb=short 2>&1 | tee "$WORKSPACE_DIR/pytest-$DATE.log"
    PYTEST_STATUS=$?
else
    echo "WARN: .venv not found, skipping pytest"
    PYTEST_STATUS=-1
fi

# --- L3: AI Quality (LLM-as-Judge) ---
echo "--- L3: LLM-as-Judge ---"
cd "$AGENT_DIR"
if [ -f "deepeval/eval_runner.py" ] && [ -n "${DATABASE_URL:-}" ]; then
    "$BOT_DIR/.venv/bin/python" deepeval/eval_runner.py --period 7 --sample 50 --output "$WORKSPACE_DIR/deepeval-$DATE.md" 2>&1
    DEEPEVAL_STATUS=$?
else
    echo "WARN: DATABASE_URL not set or eval_runner.py missing, skipping"
    DEEPEVAL_STATUS=-1
fi

# --- L4: Promptfoo Red Team ---
echo "--- L4: Promptfoo ---"
if command -v npx &> /dev/null && [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    cd "$AGENT_DIR/promptfoo"
    npx promptfoo eval --config promptfoo.yaml --output "$WORKSPACE_DIR/redteam-$DATE.json" 2>&1
    PROMPTFOO_STATUS=$?
else
    echo "WARN: npx or ANTHROPIC_API_KEY not available, skipping"
    PROMPTFOO_STATUS=-1
fi

# --- L6: Synthetic Conversation Testing ---
echo "--- L6: Synthetic Conversations ---"
cd "$BOT_DIR"
if [ -d ".venv" ] && [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    BOT_ROOT="$BOT_DIR" .venv/bin/python -m pytest \
        "$AGENT_DIR/synthetic/test_synthetic.py" \
        --rootdir="$BOT_DIR" \
        -v --tb=short --timeout=600 \
        --junitxml="$WORKSPACE_DIR/synthetic-$DATE.xml" 2>&1 \
        | tee "$WORKSPACE_DIR/synthetic-$DATE.log"
    SYNTHETIC_STATUS=$?
else
    echo "WARN: .venv or ANTHROPIC_API_KEY not available, skipping"
    SYNTHETIC_STATUS=-1
fi

# --- Report ---
echo "--- Generating report ---"
cat > "$REPORT" << EOF
# QA Weekly Report -- $DATE

## Status

| Level | Status |
|-------|--------|
| L1+L2 pytest | $([ $PYTEST_STATUS -eq 0 ] && echo "PASS" || echo "FAIL ($PYTEST_STATUS)") |
| L3 LLM-as-Judge | $([ $DEEPEVAL_STATUS -eq 0 ] && echo "PASS" || echo "SKIP ($DEEPEVAL_STATUS)") |
| L4 Promptfoo | $([ $PROMPTFOO_STATUS -eq 0 ] && echo "PASS" || echo "SKIP ($PROMPTFOO_STATUS)") |
| L6 Synthetic | $([ $SYNTHETIC_STATUS -eq 0 ] && echo "PASS" || echo "SKIP ($SYNTHETIC_STATUS)") |
EOF

echo "=== Report saved to $REPORT ==="
