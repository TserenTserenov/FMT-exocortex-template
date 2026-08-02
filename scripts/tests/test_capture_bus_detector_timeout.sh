#!/usr/bin/env bash
# Regression test for bug #339: capture-bus.sh должен иметь timeout для детекторов.
# Проверка: зависший детектор выходит через timeout, не блокирует конвейер.

set -euo pipefail

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

cd "$TMPDIR"

# Создать фикстуру: config с одним детектором, который спит 60 сек (дольше дефолт 30с)
cat > capture-config.yaml <<'EOF'
detectors:
  - name: sleepy-detector
    path: ./sleepy.sh
    event_type: capture
    cost_class: free
    enabled: true
    triggers: []
EOF

# Детектор, который спит дольше таймаута
cat > sleepy.sh <<'EOF'
#!/bin/bash
sleep 60
echo "unreachable"
EOF
chmod +x sleepy.sh

# Создать скелет hook capture-bus.sh (скопировать из шаблона или создать минимальный)
CAPTURE_BUS="${IWE_TEMPLATE:-$HOME/IWE/FMT-exocortex-template}/.claude/hooks/capture-bus.sh"
if [ -f "$CAPTURE_BUS" ]; then
  cp "$CAPTURE_BUS" ./capture-bus.sh
else
  echo "ERROR: capture-bus.sh not found in template" >&2
  exit 1
fi

# Запустить hook с таймаутом 30 сек (дефолт для детектора)
export CAPTURE_DETECTOR_TIMEOUT_SECONDS=2  # Короткий таймаут для теста
export CAPTURE_CONFIG_FILE="./capture-config.yaml"
export IWE_SCRIPTS="${IWE_SCRIPTS:-$HOME/IWE/scripts}"

# Ожидаемое: hook завершится ~2 сек (timeout), не 60 сек
START=$(date +%s)
bash ./capture-bus.sh 2>&1 | head -20 || true
END=$(date +%s)
ELAPSED=$((END - START))

echo "Elapsed: ${ELAPSED}s"

# Проверка: если детектор выполнился полностью, это заняло бы 60+ сек; с таймаутом ~2-5 сек
if [ $ELAPSED -lt 10 ]; then
  echo "✓ Detector timed out correctly (${ELAPSED}s < 10s)"
else
  echo "FAIL: Detector did not timeout (elapsed ${ELAPSED}s)" >&2
  exit 1
fi
