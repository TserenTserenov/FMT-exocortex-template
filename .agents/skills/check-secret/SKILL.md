---
name: check-secret
description: Check a text fragment for potential secrets (API keys, tokens, passwords) BEFORE sending to chat / committing / publishing. Third protection layer on top of pre-commit hook (B7.7a) and PostToolUse redact (B7.7b). Manual gate — user explicitly calls on potentially sensitive text.
argument-hint: "<text-or-file-path>"
version: 1.0.0
layer: L1
status: active
triggers:
  slash: [/check-secret]
  phrases: []
routing:
  executor: script
  deterministic: true
  script_path: ".agents/skills/check-secret/check.sh"
  optimization_priority: 2
---

# Check Secret — manual gate (B7.7c, WP-212)

> **Принцип:** B7.7a блокирует Bash-команды с секретами; B7.7b редактирует tool output; этот skill закрывает третий gap — **проверка произвольного текста** который пользователь готовится опубликовать (commit message, slack post, docs paragraph, чат-ответ).
>
> **Покрывает паттерны:** Better Stack `ust_`, Telegram bot token, hex secret в env, Neon `napi_`, DATABASE_URL с user:pass, Anthropic `sk-ant-api`, GitHub `ghp_/gho_/ghs_/ghr_/ghu_`, AWS `AKIA`, generic 40+ char API token.
>
> **Архитектурное ограничение** (см. B7.7 в WP-212): не покрывает Claude-generated text без tool-use — для этого нужен внешний wrapper над Claude Code.

## Шаг 1. Получить вход

Аргумент `$ARGUMENTS` — это **либо**:
- (а) **путь к файлу** (если `$ARGUMENTS` существует как файл) — прочитать содержимое;
- (б) **сам текст** (inline) — взять как есть.

Если нет аргумента — попросить пользователя вставить текст.

## Шаг 2. Запустить проверку

```bash
bash "$IWE_SCRIPTS/route-task.sh" --skill check-secret --args "$ARGUMENTS"
```

Скрипт принимает либо путь либо текст. Возвращает:
- exit 0 + `OK: no secrets detected` — если ничего не найдено;
- exit 1 + список найденных паттернов с line numbers — если найдены потенциальные секреты.

## Шаг 3. Интерпретировать результат

**Если OK:** сообщить «✅ Текст безопасен для публикации» — пользователь может коммитить / постить.

**Если найдены секреты:**
1. Перечислить найденные паттерны (с метками: Neon API key, GitHub token, и т.д.).
2. Для каждого — рекомендация:
   - Если плейсхолдер/тест/документация — добавить маркер `# secret-ok` в строку или `[REDACTED]` placeholder.
   - Если реальный секрет — НЕ публиковать; запустить cascade rotation (см. `DP.RUNBOOK.003-cascade-secret-rotation.md`); см. правило 25 в `feedback_behaviour.md`.
3. После redaction — повторить проверку.

## Шаг 4. Лог

Каждое использование скилла логируется в `~/IWE/.claude/logs/check-secret.jsonl` (только metadata: timestamp, hash аргумента, decision; **не сами секреты**).

## Связи

- **Расширение:** B7.7a (`secret-leak-block.sh`) и B7.7b (`secret-leak-redact.sh`) — три-слойная защита.
- **Правило поведения:** Правило 25 в `memory/feedback_behaviour.md` — secrets никогда в чат как плейнтекст.
- **Runbook:** `DP.RUNBOOK.003-cascade-secret-rotation.md` для процедуры reactive ротации.
- **Канон паттернов:** `$IWE_SCRIPTS/pre-commit-secret-scan.sh` — единая точка для regex-паттернов; check.sh использует тот же набор.

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
