# Platform Compatibility Checklist

> Шаблон должен работать на macOS и Linux. Перед коммитом проверяй этот чеклист.

## Windows

| Способ запуска | Статус | Комментарий |
|---|---|---|
| WSL2 | Полная поддержка | Это Linux — тот же путь, что и обычный Linux-чеклист ниже |
| Git Bash | Best-effort, без гарантий | Гибридная среда: `bash`/GNU-утилиты из MSYS, но `python3` обычно резолвится в нативный Windows-интерпретатор, не понимающий MSYS-пути (например, `/c/Users/.../IWE`) — известное ограничение (issue #799), чинить точечно не будем |
| Нативный Windows (cmd/PowerShell без Git Bash) | Не поддерживается | Скрипты — bash, альтернативы нет |

Известная проблема: `update.sh` падает в Git Bash на шаге, где `python3` получает MSYS-путь (issue #799). Обход: используй WSL2 для запуска `update.sh` и других скриптов шаблона, даже если редактируешь файлы через Git Bash/VS Code на Windows.

## Запрещённые конструкции (без обёртки)

| Конструкция | Проблема | Замена |
|-------------|----------|--------|
| `sed -i '' ...` | GNU sed не принимает `''` | `sed_inplace` (определена в setup.sh, update.sh) |
| `date -v-Nd` | BSD-only (macOS) | `portable_date_offset N` (определена в скриптах ролей) |
| `osascript` | macOS-only | `osascript \|\| notify-send \|\| true` |
| `launchctl` | macOS-only | Оборачивать в `command -v launchctl` guard |
| `readlink -f` | BSD readlink не поддерживает `-f` | `cd "$(dirname "$0")" && pwd` |
| `grep -P` | GNU-only (Perl regex) | `grep -E` (Extended regex) |
| `stat -c` / `stat -f` | GNU vs BSD | Избегать; использовать `wc`, `ls -l`, `find` |
| `mktemp -d -t` | Разное поведение | `mktemp -d` (без шаблона) |

## Обёртки (copy-paste в начало скрипта)

### sed_inplace

```bash
if sed --version >/dev/null 2>&1; then
    sed_inplace() { sed -i "$@"; }
else
    sed_inplace() { sed -i '' "$@"; }
fi
```

### portable_date_offset

```bash
# portable_date_offset <days_back> [format]
portable_date_offset() {
    local days="$1"
    local fmt="${2:-%Y-%m-%d}"
    date -v-${days}d +"$fmt" 2>/dev/null || date -d "$days days ago" +"$fmt" 2>/dev/null
}
```

### notify (desktop)

```bash
notify() {
    local title="$1" message="$2"
    printf 'display notification "%s" with title "%s"' "$message" "$title" | osascript 2>/dev/null \
        || notify-send "$title" "$message" 2>/dev/null \
        || true
}
```

## Архитектурные ограничения

- **launchd / .plist** — macOS-only. На Linux нужен cron или systemd timer. Setup.sh пропускает шаг 5 на Linux.
- **~/Library/LaunchAgents** — macOS path. Install-скрипты ролей пока macOS-only.
- **/opt/homebrew/bin** — Apple Silicon macOS. В plist PATH — подставляется шаблоном, но не универсален.
- **Предотвращение сна** — скрипты определяют ОС автоматически: `caffeinate -diu` (macOS) / `systemd-inhibit` (Linux). На macOS **не используется** флаг `-s` — он игнорируется когда Optimized Battery Charging переключает профиль питания на батарею.
- **Пробуждение ноутбука** — macOS: `pmset repeat wakeorpoweron`, Linux: `rtcwake` / systemd timer `WakeSystem=true`, Windows: Task Scheduler. Для macOS-ноутбуков рекомендуется `pmset -b sleep 0` (запрет idle sleep на батарейном профиле).
- **`scripts/kimi-whisper-safe.sh`** — опциональные зависимости `ffmpeg` + `openai-whisper` (Python-пакет), не входят в базовую установку шаблона. Скрипт сам проверяет `ffprobe`/`whisper` в PATH и завершается с понятной ошибкой, если их нет — устанавливать по необходимости.

## Как проверить

```bash
# Найти все потенциальные проблемы:
grep -rn "sed -i ''" --include="*.sh" .
grep -rn "date -v" --include="*.sh" .
grep -rn "osascript" --include="*.sh" .
grep -rn "launchctl" --include="*.sh" .
grep -rn "readlink -f" --include="*.sh" .
grep -rn "grep -P" --include="*.sh" .
```

---

*Последнее обновление: 2026-03-16*
