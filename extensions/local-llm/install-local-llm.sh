#!/usr/bin/env bash
# see ADR-001-local-llm-stack.md (WP404, Phase3)
# Hardware-aware installer for the local LLM-stack (MLX) for the IWE template IWE.
# Provides the PROCESS of selection, not a fixed model (see. "Suit != Equipment").
# By default installs the recommended model, that fits in memory; --max — the heaviest one.
# Idempotent: re-running does not break what is already installed.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CATALOG="${IWE_LLM_CATALOG:-$HERE/model-catalog.yaml}"
DETECT="$HERE/detect-hardware.sh"
LLM_HOME="${IWE_LLM_HOME:-$HOME/.iwe-local-llm}"
VENV="$LLM_HOME/.venv"
PY="$VENV/bin/python"
LIFECYCLE="$HERE/model-lifecycle.py"
PYVER="${IWE_LLM_PYVER:-3.12}"

# By default the recommended model is installed (recommended: true), that fits in memory.
# --max picks the heaviest fitting candidate (higher quality, slower).
pick_mode="recommended"
[ "${1:-}" = "--max" ] && pick_mode="max"

die() { echo "error: $*" >&2; exit 1; }
log() { echo "[install-local-llm] $*"; }

[ "$(uname -s)" = "Darwin" ] || die "stack is designed for macOS (Apple Silicon, MLX)"
[ -f "$CATALOG" ] || die "model catalog not found: $CATALOG"
[ -x "$DETECT" ] || die "detection-script not found: $DETECT"

mkdir -p "$LLM_HOME"

# 1. Hardware
ram_gb=$("$DETECT" | awk -F= '/^ram_gb=/{print $2}')
[ -n "$ram_gb" ] || die "could not determine memory size"
log "memory: ${ram_gb} GB"

# 2. venv (idempotent)
if [ ! -x "$PY" ]; then
  if command -v uv >/dev/null 2>&1; then
    log "creating environment via uv (python $PYVER)"
    uv venv --python "$PYVER" "$VENV"
  else
    log "uv not found, creating environment via, creating environment via python$PYVER -m venv"
    command -v "python$PYVER" >/dev/null 2>&1 || die "no python$PYVER — install uv or python$PYVER"
    "python$PYVER" -m venv "$VENV"
  fi
else
  log "environment already exists, skipping"
fi

# 3. mlx-lm + ruamel.yaml (idempotent)
if ! "$PY" -c "import mlx_lm, ruamel.yaml" 2>/dev/null; then
  log "installing mlx-lm + ruamel.yaml"
  if command -v uv >/dev/null 2>&1; then uv pip install --python "$PY" mlx-lm "ruamel.yaml"
  else "$PY" -m pip install mlx-lm "ruamel.yaml"; fi
else
  log "dependencies already installed"
fi

# 4. Model selection for hardware (venv python with pyyaml — after installing mlx-lm)
model=$("$PY" - "$CATALOG" "$ram_gb" "$pick_mode" <<'PY'
import sys, yaml
catalog, ram, mode = sys.argv[1], int(sys.argv[2]), sys.argv[3]
with open(catalog, encoding="utf-8") as f:
    data = yaml.safe_load(f)
fit = [c for c in data.get("models", []) if c.get("min_ram_gb", 1e9) <= ram]
if not fit:
    sys.exit(f"no model found for {ram} GB in the catalog (models key is empty or min_ram_gb is too high) {ram} GB in the catalog (key models is empty or min_ram_gb is too high)")
if mode == "max":
    chosen = max(fit, key=lambda c: c.get("params_b", 0))         # heaviest among the ones that fit
else:
    recommended = [c for c in fit if c.get("recommended")]
    chosen = recommended[0] if recommended else max(fit, key=lambda c: c.get("params_b", 0))
print(chosen["id"])
PY
)
[ -n "$model" ] || die "failed to select a model"
log "selection mode: $pick_mode → model for ${ram_gb} GB: $model"

# 5. Download model into cache
log "downloading model (first time — several GB)"
"$PY" -m mlx_lm generate --model "$model" --max-tokens 1 --prompt "ok" >/dev/null

# 6. Set the model as active in the catalog (lifecycle, single source of truth)
"$PY" "$LIFECYCLE" use "$model"
log "active model in the catalog → $model"

# 7. Smoke: compatible interface on localhost
log "check: starting server + shim"
IWE_LLM_HOME="$LLM_HOME" bash "$HERE/iwe-local-llm.sh" start
shim=$(IWE_LLM_HOME="$LLM_HOME" bash "$HERE/iwe-local-llm.sh" test || true)
IWE_LLM_HOME="$LLM_HOME" bash "$HERE/iwe-local-llm.sh" stop
echo "$shim" | grep -q "SHIM_OK" || die "smoke failed: shim did not respond with SHIM_OK ($shim)"
log "done. Stack is installed, model $model, server on 127.0.0.1 is running."
echo ""
echo "Next: bash iwe-local-llm.sh start | status | use <model> | stop"
