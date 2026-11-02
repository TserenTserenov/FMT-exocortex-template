#!/usr/bin/env bash
# see ADR-001-local-llm-stack.md (WP-404, Phase 3)
# Hardware-aware installer of the local LLM stack (MLX) for the IWE template.
# Distributes the selection PROCESS, not a fixed model (see "Костюм != Оснащение").
# By default installs the recommended model that fits in memory; --max — the heaviest one.
# Idempotent: a rerun does not break what is already installed.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CATALOG="${IWE_LLM_CATALOG:-$HERE/model-catalog.yaml}"
DETECT="$HERE/detect-hardware.sh"
LLM_HOME="${IWE_LLM_HOME:-$HOME/.iwe-local-llm}"
VENV="$LLM_HOME/.venv"
PY="$VENV/bin/python"
LIFECYCLE="$HERE/model-lifecycle.py"
PYVER="${IWE_LLM_PYVER:-3.12}"

# By default the recommended model (recommended: true) that fits in memory is installed.
# --max takes the heaviest fitting candidate (higher quality, slower).
pick_mode="recommended"
[ "${1:-}" = "--max" ] && pick_mode="max"

die() { echo "error: $*" >&2; exit 1; }
log() { echo "[install-local-llm] $*"; }

[ "$(uname -s)" = "Darwin" ] || die "стек рассчитан на macOS (Apple Silicon, MLX)"
[ -f "$CATALOG" ] || die "каталог моделей не найден: $CATALOG"
[ -x "$DETECT" ] || die "детект-скрипт не найден: $DETECT"

mkdir -p "$LLM_HOME"

# 1. Hardware
ram_gb=$("$DETECT" | awk -F= '/^ram_gb=/{print $2}')
[ -n "$ram_gb" ] || die "не удалось определить объём памяти"
log "память: ${ram_gb} GB"

# 2. venv (idempotent)
if [ ! -x "$PY" ]; then
  if command -v uv >/dev/null 2>&1; then
    log "создаю окружение через uv (python $PYVER)"
    uv venv --python "$PYVER" "$VENV"
  else
    log "uv не найден, создаю окружение через python$PYVER -m venv"
    command -v "python$PYVER" >/dev/null 2>&1 || die "нет python$PYVER — поставь uv или python$PYVER"
    "python$PYVER" -m venv "$VENV"
  fi
else
  log "окружение уже есть, пропускаю"
fi

# 3. mlx-lm + ruamel.yaml (idempotent)
if ! "$PY" -c "import mlx_lm, ruamel.yaml" 2>/dev/null; then
  log "ставлю mlx-lm + ruamel.yaml"
  if command -v uv >/dev/null 2>&1; then uv pip install --python "$PY" mlx-lm "ruamel.yaml"
  else "$PY" -m pip install mlx-lm "ruamel.yaml"; fi
else
  log "зависимости уже установлены"
fi

# 4. Model selection for the hardware (venv python with pyyaml — after installing mlx-lm)
model=$("$PY" - "$CATALOG" "$ram_gb" "$pick_mode" <<'PY'
import sys, yaml
catalog, ram, mode = sys.argv[1], int(sys.argv[2]), sys.argv[3]
with open(catalog, encoding="utf-8") as f:
    data = yaml.safe_load(f)
fit = [c for c in data.get("models", []) if c.get("min_ram_gb", 1e9) <= ram]
if not fit:
    sys.exit(f"нет модели под {ram} GB в каталоге (ключ models пуст или min_ram_gb выше)")
if mode == "max":
    chosen = max(fit, key=lambda c: c.get("params_b", 0))         # тяжёлый из влезающих
else:
    recommended = [c for c in fit if c.get("recommended")]
    chosen = recommended[0] if recommended else max(fit, key=lambda c: c.get("params_b", 0))
print(chosen["id"])
PY
)
[ -n "$model" ] || die "не удалось выбрать модель"
log "режим выбора: $pick_mode → модель под ${ram_gb} GB: $model"

# 5. Download the model into the cache
log "скачиваю модель (первый раз — несколько ГБ)"
"$PY" -m mlx_lm generate --model "$model" --max-tokens 1 --prompt "ok" >/dev/null

# 6. Make the model active in the catalog (lifecycle, single source)
"$PY" "$LIFECYCLE" use "$model"
log "активная модель в каталоге → $model"

# 7. Smoke: compatible interface on localhost
log "проверка: запуск сервера + shim"
IWE_LLM_HOME="$LLM_HOME" bash "$HERE/iwe-local-llm.sh" start
shim=$(IWE_LLM_HOME="$LLM_HOME" bash "$HERE/iwe-local-llm.sh" test || true)
IWE_LLM_HOME="$LLM_HOME" bash "$HERE/iwe-local-llm.sh" stop
echo "$shim" | grep -q "SHIM_OK" || die "smoke провалился: shim не ответил SHIM_OK ($shim)"
log "готово. Стек установлен, модель $model, сервер на 127.0.0.1 работает."
echo ""
echo "Дальше: bash iwe-local-llm.sh start | status | use <model> | stop"
