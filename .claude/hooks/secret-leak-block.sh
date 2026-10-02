#!/bin/bash
# Secret Leak Block Hook (B7.7a, WP-212 / WP-544 D6.3-D6.8)
# Event: PreToolUse (matcher: Bash)
#
# Blocks literal secret values, direct reads of sensitive files and known
# literal upload forms before Bash executes. The hook deliberately does not
# claim to stop a path assembled entirely at runtime, a renamed temporary file
# or an unknown uploader; those cases require filesystem/network sandboxing.
#
# Temporary global bypass:
#   CC_ALLOW_SECRETS_INPUT=1
#   CC_ALLOW_SECRETS_INPUT_UNTIL=<unix-time, no more than 900s ahead>
# Every use needs a durable private audit record and visible user alert.

set -uo pipefail
umask 077
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

security_failure() {
  # This is the guard failing, not the command being refused, and it blocks
  # EVERY Bash call in the session -- including the one that would repair it
  # (06.09: a stray quote character inside secret-bypass-lib.sh took Bash,
  # Read, Edit and MCP down at once, and the message named none of that).
  # So the text names the actual stage that failed and the way out.
  printf '%s\n' "Secret PreToolUse guard failed (${1:-причина не названа}); the Bash call is blocked." >&2
  printf '%s\n' 'This is the guard itself failing, not a verdict on the command. Two known causes: .claude/hooks/secret-bypass-lib.sh does not parse (check with bash -n), or this hook and that library are from different versions. While it lasts, every tool call of this agent is blocked, so the repair has to come from a shell outside the agent.' >&2
  exit 2
}

HOOK_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[ -r "$HOOK_DIR/secret-bypass-lib.sh" ] || security_failure "библиотека стражей не читается"
# shellcheck source=secret-bypass-lib.sh
# shellcheck disable=SC1091
. "$HOOK_DIR/secret-bypass-lib.sh" || security_failure "библиотека стражей не разбирается"
[ -x "$SECRET_BYPASS_JQ" ] && [ -x "$SECRET_BYPASS_PYTHON" ] || security_failure "jq или python3 недоступны"

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
LOG_FILE="$IWE_ROOT/.claude/logs/secret-leak-block.jsonl"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
SESSION_ID=""
COMMAND_LENGTH=0

log_decision() {
  # Data minimization: never store command text or a content-derived digest.
  local decision="$1" pattern="$2" ts bucket record
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  bucket=$(date -u +"%Y-%m-%dT%H:00:00Z")
  # The jq program references jq variables.
  # shellcheck disable=SC2016
  record=$("$SECRET_BYPASS_JQ" -nc \
    --arg ts "$ts" \
    --arg bucket "$bucket" \
    --arg sid "$SESSION_ID" \
    --arg dec "$decision" \
    --arg pat "$pattern" \
    --argjson command_length "$COMMAND_LENGTH" \
    '{ts:$ts, time_bucket:$bucket, hook:"secret-leak-block", session_id:$sid, decision:$dec, pattern:$pat, command_length:$command_length}') || return 1
  secret_bypass_audit_append "$LOG_FILE" "$record"
}

input=$(cat) || security_failure "не удалось прочитать ввод"
analysis=$(printf '%s' "$input" | secret_pattern_process analyze-bash 2>/dev/null) || security_failure "анализатор не отработал"
# Только поля, которые есть у анализатора любой версии. Новые поля читаются
# ниже со значением по умолчанию: жёсткое требование в этой проверке означало
# бы, что рассинхрон хука и библиотеки (обычное дело, когда их правят
# параллельные сессии) кладёт ВСЮ работу агента, а не одну проверку
# (WP-545, 06.09 — ровно этот отказ случился дважды за день).
printf '%s' "$analysis" | "$SECRET_BYPASS_JQ" -e '
  type == "object"
  and (.applicable | type == "boolean")
  and (.session_id | type == "string")
  and (.tool_name | type == "string")
  and ((.applicable == false) or (
    (.command_length | type == "number")
    and (.pattern_ids | type == "array")
    and (.direct_sensitive_read | type == "boolean")
    and (.direct_sensitive_upload | type == "boolean")
  ))' >/dev/null 2>&1 || security_failure "ответ анализатора не прошёл проверку формы"

applicable=$(printf '%s' "$analysis" | "$SECRET_BYPASS_JQ" -r '.applicable')
[ "$applicable" = "true" ] || exit 0
SESSION_ID=$(printf '%s' "$analysis" | "$SECRET_BYPASS_JQ" -r '.session_id')
COMMAND_LENGTH=$(printf '%s' "$analysis" | "$SECRET_BYPASS_JQ" -r '.command_length')
pattern_ids=$(printf '%s' "$analysis" | "$SECRET_BYPASS_JQ" -r '.pattern_ids | join(",")')
direct_read=$(printf '%s' "$analysis" | "$SECRET_BYPASS_JQ" -r '.direct_sensitive_read')
direct_upload=$(printf '%s' "$analysis" | "$SECRET_BYPASS_JQ" -r '.direct_sensitive_upload')
bulk_enumeration=$(printf '%s' "$analysis" | "$SECRET_BYPASS_JQ" -r '.bulk_secret_enumeration // false')
shell_model=$(printf '%s' "$analysis" | "$SECRET_BYPASS_JQ" -r '.shell_model // "unreported"')

if secret_bypass_check INPUT; then
  bypass_pattern="${pattern_ids:-policy-path}"
  if secret_bypass_authorize INPUT log_decision "bypass-env-temporary" "$bypass_pattern"; then
    exit 0
  fi
  [ "$SECRET_BYPASS_STATE" = "rejected" ] || {
    SECRET_BYPASS_STATE="rejected"
    SECRET_BYPASS_REASON="authorization helper unavailable"
  }
  BYPASS_NOTICE=$(secret_bypass_rejected_message INPUT)
elif [ "$SECRET_BYPASS_STATE" = "rejected" ]; then
  log_decision "bypass-env-rejected" "$SECRET_BYPASS_REASON" || true
  BYPASS_NOTICE=$(secret_bypass_rejected_message INPUT)
fi

deny_command() {
  local decision="$1" pattern="$2" reason="$3"
  log_decision "$decision" "$pattern" || true
  # The jq program references jq variables.
  # shellcheck disable=SC2016
  if ! "$SECRET_BYPASS_JQ" -n \
    --arg reason "$reason" \
    --arg message "${BYPASS_NOTICE:-}" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}
     + (if $message == "" then {} else {systemMessage:$message} end)'; then
    security_failure "не удалось сформировать отказ"
  fi
  exit 0
}

if [ "$direct_upload" = "true" ]; then
  deny_command "deny-bash-upload" "direct-sensitive-upload" \
    "Прямая отправка чувствительного файла через Bash заблокирована до выполнения. Hook покрывает только буквальные пути и известные upload-команды; вычисленные пути требуют системной песочницы. Используй сервисный wrapper, который передаёт значение без чтения файла агентом."
fi

if [ "$direct_read" = "true" ]; then
  deny_command "deny-bash-read" "direct-sensitive-read" \
    "Чтение чувствительного файла через Bash заблокировано до попадания значения в контекст. Не называй файл в команде: используй имеющийся scripts/with-aist-env.sh <команда> (он подгружает окружение внутри, путь не виден в команде), а программа читает переменные через os.environ/\$VAR. Через обёртку нельзя запускать то, что печатает окружение (env, printenv, отладочные дампы). Блок хука ≠ «доступа нет» — см. lessons_blocked_probe_is_not_verification.md."
fi

if [ "$bulk_enumeration" = "true" ]; then
  deny_command "deny-bash-bulk-enumeration" "bulk-secret-enumeration" \
    "Команда печатает все секреты сразу открытым текстом (env/printenv без имени переменной или railway variables/variable) — заблокирована до выполнения, независимо от формы значений: их не распознаёт сигнатурный анализ вывода. Нужна одна конкретная переменная — используй scripts/with-aist-env.sh <команда> (значение остаётся внутри процесса, не печатается) или printenv <ИМЯ_ПЕРЕМЕННОЙ>. Разовый обход требует CC_ALLOW_SECRETS_INPUT=1 и срока CC_ALLOW_SECRETS_INPUT_UNTIL не более 15 минут — вывод всё равно останется защищён редактирующим PostToolUse-хуком, но однократный факт печати уже не отменить."
fi

if [ -n "$pattern_ids" ]; then
  deny_command "deny" "$pattern_ids" \
    "В Bash-команде найден возможный секрет (классы: $pattern_ids). Не передавай его аргументом; используй \$VAR/env или wrapper. Разовый обход требует CC_ALLOW_SECRETS_INPUT=1 и срока CC_ALLOW_SECRETS_INPUT_UNTIL не более 15 минут; вывод отдельно остаётся защищённым."
fi

# Команда — валидный Bash, грамматику которого модель переменных не покрывает
# (elif, незакрытый if, ветвление внутри цикла/группы/функции). Проверки, не
# требующие разбора, выше уже отработали на этой же команде; потеряна только
# половина анализа путей по переменным, и это повод для видимой пометки, а не
# для отказа выполнять вызов (WP-545, 06.09: «unsupported shell conditional»
# доезжал до агента как «страж не смог проверить ввод» и останавливал сессию).
case "$shell_model" in
  complete)
    log_decision "allow" "" || true
    ;;
  unreported)
    # Библиотека старше этого хука: поля нет вовсе. Работать не мешаем, но
    # говорим вслух — иначе рассинхрон versions живёт молча.
    log_decision "allow-shell-model-unreported" "" || true
    DEGRADED_NOTICE="Страж секретов и его библиотека из разных версий: библиотека не сообщает полноту разбора команды. Проверки отработали, но полагаться на них как на полные нельзя."
    ;;
  *)
    log_decision "allow-shell-model-$shell_model" "" || true
    DEGRADED_NOTICE="Страж секретов разобрал эту команду не полностью (конструкция вне модели: elif, незакрытый if, ветвление внутри цикла, группы или функции). Проверки, не требующие разбора, отработали и ничего не нашли; анализа путей по переменным для неё не было."
    ;;
esac
ALLOW_NOTICE="${BYPASS_NOTICE:-}"
if [ -n "${DEGRADED_NOTICE:-}" ]; then
  if [ -n "$ALLOW_NOTICE" ]; then
    ALLOW_NOTICE="$ALLOW_NOTICE"$'\n'"$DEGRADED_NOTICE"
  else
    ALLOW_NOTICE="$DEGRADED_NOTICE"
  fi
fi
# The jq program references jq variables.
# shellcheck disable=SC2016
if [ -n "$ALLOW_NOTICE" ] \
  && ! "$SECRET_BYPASS_JQ" -n --arg message "$ALLOW_NOTICE" '{systemMessage:$message}'; then
  security_failure "не удалось сформировать уведомление"
fi
exit 0
