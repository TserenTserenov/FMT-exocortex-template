---
name: check-secret
description: Check a text fragment for potential secrets (API keys, tokens, passwords) BEFORE sending to chat / committing / publishing. Second protection layer on top of the pre-commit hook — manual gate, user explicitly calls on potentially sensitive text.
argument-hint: "<text-or-file-path>"
version: 1.0.0
layer: L1
status: active
browser_safe: false
triggers:
  slash: [/check-secret]
  phrases: []
routing:
  executor: script
  deterministic: true
  script_path: ".claude/skills/check-secret/check.sh"
  optimization_priority: 2
---

# Check Secret — manual gate (WP-212)

> **Принцип (issue #410, актуализировано 2026-08-12):** в поставке реально работает один автоматический слой — pre-commit хук (`scripts/pre-commit-secret-scan.sh`), который проверяет только то, что попадает в git-коммит. Этот skill закрывает соседний gap — **проверка произвольного текста до публикации** (commit message, slack post, docs paragraph, чат-ответ), который никогда не пойдёт в коммит и потому мимо хука. B7.7a (блок Bash-команд с секретами) и B7.7b (PostToolUse redact tool output) в поставке не существуют — если появятся, вернуть формулировку «третий слой».
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

- **Слои защиты (issue #410, актуализировано 2026-08-12):** ровно два, не три — pre-commit хук (`scripts/pre-commit-secret-scan.sh`, автоматический) и этот скилл (ручной, до вставки в чат/публикацию). B7.7a (блок Bash) и B7.7b (PostToolUse redact) в поставке не существуют — если появятся, дописать сюда третьим слоем.
- **Правило поведения:** Правило 25 в `memory/feedback_behaviour.md` — secrets никогда в чат как плейнтекст.
- **Runbook:** `DP.RUNBOOK.003-cascade-secret-rotation.md` для процедуры reactive ротации.
- **Канон паттернов:** `$IWE_SCRIPTS/pre-commit-secret-scan.sh` — единая точка для regex-паттернов; check.sh использует тот же набор.

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
