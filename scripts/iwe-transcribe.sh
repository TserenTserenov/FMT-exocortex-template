#!/usr/bin/env bash
# iwe-transcribe.sh — транскрипция аудио/видео через MLX Whisper (Apple Silicon)
# routing: executor=script  deterministic=true  skill=transcribe  optimization_priority=2
# see DP.SC.159, DP.ROLE.059
#
# Usage: iwe-transcribe.sh <path/to/file.mp3|mp4|m4a|wav>

set -euo pipefail

VENV="$HOME/.local/share/mlx-whisper/.venv-whisper"
# Model, first match wins: $IWE_WHISPER_MODEL when it holds more than whitespace (a
# path or a Hugging Face repo id, passed on unchecked: it is the user's explicit
# choice); the local directory, when it holds a model (config.json); else the
# Hugging Face repo id, which mlx_whisper downloads into the HF cache on first use.
# The implicit default never points at something that is not there: mlx_whisper
# reads a path that does not exist as a repo id and fails with HFValidationError,
# and an empty or half-copied directory fails inside it (issue #973).
LOCAL_MODEL="$HOME/.local/share/mlx-whisper/mlx_models/large-v3"
HF_MODEL="mlx-community/whisper-large-v3-mlx"
USER_MODEL="${IWE_WHISPER_MODEL:-}"
if [[ -n "${USER_MODEL//[[:space:]]/}" ]]; then
  MODEL="$USER_MODEL"
elif [[ -f "$LOCAL_MODEL/config.json" ]]; then
  MODEL="$LOCAL_MODEL"
else
  MODEL="$HF_MODEL"
fi

if [[ $# -lt 1 ]]; then
  echo "Usage: iwe-transcribe.sh <audio-file>" >&2
  exit 1
fi

FILE="${*:-}"

if [[ ! -f "$FILE" ]]; then
  echo "ERROR: file not found: $FILE" >&2
  exit 1
fi

if ! "$VENV/bin/python" -c "import mlx_whisper" 2>/dev/null; then
  echo "ERROR: mlx_whisper not available in $VENV" >&2
  echo "Setup: python3 -m venv '$VENV' && '$VENV/bin/pip' install mlx-whisper" >&2
  exit 1
fi

"$VENV/bin/python" - "$FILE" "$MODEL" << 'EOF'
import sys, json
import mlx_whisper

file_path, model_path = sys.argv[1], sys.argv[2]
result = mlx_whisper.transcribe(
    file_path,
    path_or_hf_repo=model_path,
    language="ru",
    word_timestamps=True,
)
print(result["text"])
EOF
