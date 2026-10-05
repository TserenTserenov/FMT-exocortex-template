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
| `timeout N cmd` | GNU coreutils/Homebrew-only — `command not found` на стоковой macOS без Homebrew (issue #1108) | `iwe_timeout` (`lib/common.sh`) — делегирует реальному `timeout`, иначе perl-полифил |
| `md5sum` | GNU-only, без macOS-замены (issue #1108) | `iwe_md5` (`lib/common.sh`) — делегирует `md5sum`, иначе BSD `md5` |
| `sha256sum` | GNU-only; есть в `/sbin` только на macOS 26+, на более старых версиях отсутствует (issue #1108) | `iwe_sha256` (`lib/common.sh`) — делегирует `sha256sum`, иначе `shasum -a 256` |
| `flock -n/-x/-s ...` | util-linux/Homebrew-only, отсутствует на стоковой macOS — голый вызов падает `command not found`, что код ошибочно принимал за «лок уже занят» (issue #1108) | `command -v flock` guard + mkdir-fallback lock (образец: `scripts/ledger-append.sh`, `scripts/wp-pool-cascade.sh`) |
| `${var,,}` / `${var^^}` | bash 4+ (lowercase/uppercase expansion) — `bad substitution` на bash 3.2, дефолтный `/bin/bash` стоковой macOS (issue #1108) | `$(printf '%s' "$var" \| tr '[:upper:]' '[:lower:]')` |

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

### portable_lowercase (замена `${var,,}`)

```bash
# не copy-paste функция — однострочная замена на месте использования
lower=$(printf '%s' "$var" | tr '[:upper:]' '[:lower:]')
```

### timeout / md5 / sha256 — через lib/common.sh, не copy-paste

В отличие от обёрток выше (локальные, без внешних зависимостей), эти три
достаточно сложны (perl-полифил `timeout`, GNU/BSD-ветвление) и уже
централизованы в `scripts/lib/common.sh` — не дублировать inline:

```bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
iwe_timeout 30 some_cmd   # вместо bare `timeout 30 some_cmd`
iwe_sha256 < "$FILE"      # вместо bare `sha256sum`
echo -n "$x" | iwe_md5    # вместо bare `md5sum`
```

Путь к `lib/common.sh` относительно вызывающего скрипта (`scripts/*.sh` →
`lib/common.sh`; вне `scripts/` — see `.claude/lib/capture_writer.sh` для
примера относительного пути из другой директории).

### flock — guard + mkdir-fallback, не copy-paste

`flock(1)` отсутствует на стоковой macOS, а голый `command not found` легко
принять за «лок уже занят» (issue #1108). Готового `iwe_*`-хелпера нет — лок
завязан на конкретный `$LOCK_FILE` и семантику блокирующего/неблокирующего
ожидания вызывающего скрипта, поэтому шаблон не параметризован в
`lib/common.sh`. Эталонные реализации (копировать и адаптировать, не
изобретать заново): `scripts/ledger-append.sh` (блокирующий `-w 10`, с
reclaim мёртвых локов по PID+hostname) и `scripts/wp-pool-cascade.sh`
(неблокирующий `-n`, та же reclaim-логика, без retry-цикла).

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
grep -rn "\btimeout [\"\$0-9]" --include="*.sh" .
grep -rn "\bsha256sum\b\|\bmd5sum\b" --include="*.sh" .
grep -rnE '\bflock -[a-zA-Z]' --include="*.sh" .
grep -rnE '\$\{[A-Za-z_][A-Za-z0-9_]*(,,?|\^\^?)\}' --include="*.sh" .
```

Либо напрямую: `bash scripts/check-platform-compat.sh` — тот же чеклист как CI-гейт (`check_guarded`/`check_forbidden` по каждой строке таблицы выше), а не только список для ручной проверки.

---

*Последнее обновление: 2026-10-05 (issue #1108: timeout/md5sum/sha256sum/flock/bash4-isms)*
