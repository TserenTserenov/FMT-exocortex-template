---
name: agent-fault
description: Регистрация косяка агента в системе учёта WP-316 L1. Без LLM — детерминированный скрипт без WP Gate.
argument-hint: "record --severity {critical|major|minor} --fault <description> --subject-kind {personality|runtime|system} --subject-id <stable-id>"
version: 0.2.0
status: active
browser_safe: false
layer: L1
agents: none
interaction: one-shot
triggers:
  slash: [/agent-fault]
  phrases: []
gates_required: []
gates_enforced: []
gates_rationale: "детерминированный script-executor; WP Gate и IntegrationGate не применимы"
routing:
  executor: script
  deterministic: true
  script_path: "scripts/agent-fault/iwe_checklist_memory.py"
---

# /agent-fault — регистрация косяка агента

## When to use

При обнаружении повторяющегося косяка агента — зарегистрировать немедленно через `/agent-fault`.
Примеры: пропуск WP Gate, игнорирование чеклиста, лишние yes/no вопросы, пропуск Pull-on-Touch.
Скилл не требует LLM и не создаёт РП — это запись в базу паттернов WP-316.

## Algorithm

Передать косяк в единый агент-нейтральный CLI с severity, описанием и явным
субъектом ошибки. `subject-kind` определяет тип владельца (`personality`,
`runtime` или `system`), а `subject-id` — его стабильный идентификатор. Не
угадывать субъект из самоотчёта модели.

```bash
: "${IWE_FAULT_SUBJECT_KIND:?set the actual personality, runtime, or system kind}"
: "${IWE_FAULT_SUBJECT_ID:?set the actual stable subject id}"
IWE_ROOT="${IWE_WORKSPACE:-${WORKSPACE_DIR:-$HOME/IWE}}"
IWE_DIR="$IWE_ROOT" \
IWE_EXECUTOR_CATALOG="$IWE_ROOT/${IWE_GOVERNANCE_REPO:-${GOVERNANCE_REPO:-DS-strategy}}/scripts/executor-catalog.yaml" \
bash "${IWE_SCRIPTS:-$IWE_ROOT/FMT-exocortex-template/scripts}/route-task.sh" \
  --skill agent-fault \
  --args "record --severity major --fault агент пропустил чеклист --subject-kind $IWE_FAULT_SUBJECT_KIND --subject-id $IWE_FAULT_SUBJECT_ID"
```

Допустимые значения `--severity`: `critical` | `major` | `minor`.
Описание после `--fault` может состоять из нескольких слов: CLI собирает их до
следующего флага без shell-eval. Для точной цитаты нарушенного правила добавить
`--source-citation <текст>`.

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
