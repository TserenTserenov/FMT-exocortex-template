---
name: transcribe
description: Transcribe audio/video files via MLX Whisper (Apple Silicon). Usage: /transcribe path/to/file.mp3
user_invocable: true
version: 1.0.0
layer: L1
status: active
browser_safe: false
triggers:
  slash: [/transcribe]
  phrases: []
routing:
  executor: script
  deterministic: true
  script_path: "scripts/iwe-transcribe.sh"
  optimization_priority: 2
---

# Audio/Video Transcription

Transcription via MLX Whisper on Apple Silicon. Runs locally, no cloud required.

## Locations

- **Local model (optional):** `~/.local/share/mlx-whisper/mlx_models/large-v3` — the Skill and its installation do not create this directory; it is used only when a model is present there (i.e., `config.json` exists)
- **Venv:** `~/.local/share/mlx-whisper/.venv-whisper/`
- **Model:** `large-v3` (high accuracy, ~3 GB). The script selects the source in the following order: (1) the environment variable `IWE_WHISPER_MODEL` (a directory path or Hugging Face repository ID), if set and non-empty (a whitespace-only value is treated as empty; the value is passed through without validation — this is an explicit user choice); (2) the local directory from the first line above, if a model is present there (`config.json` exists); (3) otherwise the Hugging Face repository `mlx-community/whisper-large-v3-mlx` — `mlx_whisper` downloads it on the first transcription run into `~/.cache/huggingface/hub/` (network required, ~3 GB) and uses the cache on subsequent runs

## Instructions for Claude

### Step 1: Check the venv

```bash
~/.local/share/mlx-whisper/.venv-whisper/bin/python -c "import mlx_whisper; print('ok')" 2>/dev/null
```

If this fails (broken or missing), recreate it:
```bash
rm -rf ~/.local/share/mlx-whisper/.venv-whisper
python3 -m venv ~/.local/share/mlx-whisper/.venv-whisper
~/.local/share/mlx-whisper/.venv-whisper/bin/pip install mlx-whisper
```

### Step 2: Determine the file and model

- The Skill argument is the path to the file. If not provided, ask the user.
- Use `large-v3`: the script selects the model source (see "Locations"). Only the user may override this via `IWE_WHISPER_MODEL` — do not change it on your own.

### Step 3: Transcription

```bash
bash "$IWE_SCRIPTS/route-task.sh" --skill transcribe --args "<path_to_file>"
```

If the language is not English, the user will specify it, or the script will detect it automatically.

### Step 4: Result

- Display the text to the user.
- If the user requests saving, write the output to a file alongside the source: `<filename>.txt`.
- For long files (>30 min), warn the user that transcription may take several minutes.

### Supported formats

mp3, m4a, wav, flac, ogg, mp4, mkv, webm — any format supported by ffmpeg.

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
