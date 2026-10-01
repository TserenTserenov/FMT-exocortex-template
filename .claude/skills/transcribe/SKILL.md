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

# Транскрипция аудио/видео

Транскрипция через MLX Whisper на Apple Silicon. Работает локально, без облака.

## Расположение

- **Локальная модель (необязательна):** `~/.local/share/mlx-whisper/mlx_models/large-v3` — скилл и установка этот каталог не создают; используется, только если в нём лежит модель (есть `config.json`)
- **Venv:** `~/.local/share/mlx-whisper/.venv-whisper/`
- **Модель:** `large-v3` (точная, ~3 ГБ). Источник выбирает скрипт, по порядку: (1) переменная окружения `IWE_WHISPER_MODEL` (путь к каталогу или id репозитория Hugging Face), если задана и непуста (значение из одних пробелов считается пустым; значение передаётся без проверки, это явный выбор пользователя); (2) локальный каталог из первой строки, если в нём лежит модель (есть `config.json`); (3) иначе репозиторий Hugging Face `mlx-community/whisper-large-v3-mlx` — `mlx_whisper` скачивает его при первой расшифровке в кэш `~/.cache/huggingface/hub/` (нужна сеть, ~3 ГБ), дальше берёт из кэша

## Инструкция для Claude

### Шаг 1: Проверка venv

```bash
~/.local/share/mlx-whisper/.venv-whisper/bin/python -c "import mlx_whisper; print('ok')" 2>/dev/null
```

Если ошибка (сломан или отсутствует) — пересоздать:
```bash
rm -rf ~/.local/share/mlx-whisper/.venv-whisper
python3 -m venv ~/.local/share/mlx-whisper/.venv-whisper
~/.local/share/mlx-whisper/.venv-whisper/bin/pip install mlx-whisper
```

### Шаг 2: Определить файл и модель

- Аргумент скилла = путь к файлу. Если не указан — спросить пользователя.
- Использовать `large-v3`: источник модели выбирает скрипт (см. «Расположение»). Другую модель подставляет только пользователь через `IWE_WHISPER_MODEL`, самому её не менять.

### Шаг 3: Транскрипция

```bash
bash "$IWE_SCRIPTS/route-task.sh" --skill transcribe --args "<путь_к_файлу>"
```

Если язык не русский — пользователь укажет, или скрипт автоматически детектирует.

### Шаг 4: Результат

- Показать текст пользователю.
- Если пользователь просит сохранить — записать в файл рядом с исходным: `<имя_файла>.txt`.
- Для длинных файлов (>30 мин) предупредить, что может занять несколько минут.

### Поддерживаемые форматы

mp3, m4a, wav, flac, ogg, mp4, mkv, webm — любые, которые поддерживает ffmpeg.

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
