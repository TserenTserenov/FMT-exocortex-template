#!/usr/bin/env bash
# connect.sh — one-time setup: connect Extractor to the operator's Claude subscription.
#
#   connect.sh          interactive: `claude setup-token` → paste token → save → verify
#   connect.sh --check  verify the already-saved token only (no browser login)
#
# WP-5 Ф46: for a regular template user (no personal server infra like the
# platform author's sops-nix setup) this must be one command + one interactive
# browser login, no manual system-file editing.
#
# Why the human pastes the token instead of the script capturing it: Anthropic's
# docs say `claude setup-token` "prints the token to the terminal without
# saving it" — there is no machine-readable output contract to parse, and
# piping its stdout would break its TTY-driven prompts (browser URL, paste-code
# step). So the command runs with an inherited terminal and the user pastes the
# printed value once. Format check before saving guards against pasting the
# wrong line.
#
# Read-only code without {{PLACEHOLDER}}s: run straight from $IWE_TEMPLATE
# (see .claude/runtime-overlay.yaml), it is not copied into .iwe-runtime/.
set -euo pipefail

SECRET_DIR="$HOME/.secrets"
SECRET_PATH="$SECRET_DIR/claude_code_oauth_token"
TOKEN_PREFIX="sk-ant-oat"   # documented long-lived token format: sk-ant-oat01-...
TOKEN_MIN_LENGTH=40
CLAUDE_PATH="$(command -v claude 2>/dev/null || true)"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

# One cheap end-to-end call with ONLY the given token in the environment.
# CLAUDE_CODE_OAUTH_TOKEN takes precedence over a keychain/file login
# (`claude auth status` reports authMethod=oauth_token when it is set), so a
# green result proves this token works, not the operator's interactive login.
verify_token() {
    local token="$1"
    local out
    out="$(mktemp)"
    echo "Проверяю подключение тестовым вызовом..."
    if CLAUDE_CODE_OAUTH_TOKEN="$token" "$CLAUDE_PATH" -p "Ответь одним словом: OK" \
        --allowedTools "" --no-session-persistence </dev/null >"$out" 2>&1; then
        rm -f "$out"
        return 0
    fi
    echo "Тестовый вызов не прошёл. Ответ Claude Code:" >&2
    sed 's/^/  /' "$out" >&2
    rm -f "$out"
    return 1
}

save_token() {
    local token="$1"
    mkdir -p "$SECRET_DIR"
    chmod 700 "$SECRET_DIR"
    # umask 077: the file is never world-readable, not even between create and chmod.
    ( umask 077 && printf '%s' "$token" > "$SECRET_PATH" )
    chmod 600 "$SECRET_PATH"
    echo "Сохранено: $SECRET_PATH"
}

read_token_interactively() {
    local token line
    read -rsp "Вставьте токен, напечатанный выше (ввод скрыт): " token
    echo >&2
    # A long token wraps across several terminal lines when the window is
    # narrow; pasting the whole block delivers all of them at once, so the
    # rest is already sitting in the input buffer right behind the first
    # line. Manual single-line entry leaves nothing queued, so the
    # non-blocking read below times out immediately and changes nothing.
    while IFS= read -rs -t 0.3 line; do
        [ -n "$line" ] || break
        token="${token}${line}"
    done
    # Paste often carries a trailing newline or surrounding spaces.
    token="$(printf '%s' "$token" | tr -d '[:space:]')"
    [ -n "$token" ] || die "пусто — ничего не сохранено."
    case "$token" in
        "$TOKEN_PREFIX"*) ;;
        *) die "строка не похожа на токен подписки (ожидался префикс '${TOKEN_PREFIX}…'). Ничего не сохранено — запустите скрипт заново и вставьте именно то, что напечатала 'claude setup-token'." ;;
    esac
    [ "${#token}" -ge "$TOKEN_MIN_LENGTH" ] || die "строка слишком короткая для токена (${#token} символов). Ничего не сохранено."
    printf '%s' "$token"
}

run_check_only() {
    [ -f "$SECRET_PATH" ] || die "сохранённого токена нет ($SECRET_PATH) — запустите без --check, чтобы подключиться."
    verify_token "$(<"$SECRET_PATH")" || exit 1
    echo "Токен рабочий — Экстрактор подключён."
}

run_full_setup() {
    [ -t 0 ] || die "нужен интерактивный терминал (скрипт открывает браузер и ждёт ввода)."

    echo "Подключение Экстрактора к вашей подписке Claude Code."
    echo "Требуется активная подписка Pro/Max/Team/Enterprise (не обычный API-ключ)."
    [ -f "$SECRET_PATH" ] && echo "Уже сохранённый токен ($SECRET_PATH) будет заменён новым."
    echo
    echo "Сейчас запустится 'claude setup-token' — откроется браузер для входа."
    echo "После входа команда напечатает в терминале строку вида ${TOKEN_PREFIX}01-…"
    echo "Её нужно будет скопировать и вставить сюда."
    echo
    read -rp "Продолжить? [Y/n]: " confirm
    case "${confirm:-Y}" in
        n|N) echo "Отменено."; exit 1 ;;
    esac

    echo
    "$CLAUDE_PATH" setup-token || die "'claude setup-token' завершилась с ошибкой (вход отменён или нет подписки). Ничего не сохранено."
    echo

    local token
    token="$(read_token_interactively)" || exit 1
    save_token "$token"
    echo
    verify_token "$token" || die "токен сохранён, но не работает. Повторная проверка без нового входа: bash $0 --check"

    echo "Готово — Экстрактор подключён к вашей подписке."
    echo "Следующий шаг (по желанию): автоматический inbox-check — bash \$IWE_TEMPLATE/roles/extractor/install.sh"
}

[ -n "$CLAUDE_PATH" ] || die "команда 'claude' не найдена в PATH — сначала установите Claude Code CLI."

case "${1:-}" in
    "")        run_full_setup ;;
    --check)   run_check_only ;;
    -h|--help) sed -n '2,5p' "$0"; exit 0 ;;
    *)         die "неизвестный аргумент '$1'. Использование: $0 [--check]" ;;
esac
