---
name: audit-installation
description: Аудит пользовательской инсталляции IWE. Запускает scripts/iwe-audit.sh + MCP healthcheck + smoke-test ритуала через sentinel-механику (контракт dry-run-contract.md), передаёт отчёт subagent'у в роли VR.R.002 Аудитор (context isolation) → verdict ✅/⚠️/❌ по 6 компонентам (Inventory, L1 drift, DS-strategy, L3 customizations, MCP, ритуал). Используй после restore из бэкапа, после update.sh, или при еженедельной сверке.
argument-hint: "[--skip-mcp] [--critical]"
---

# Аудит инсталляции IWE

> **Service Clause:** [VR.SC.005-installation-audit](https://github.com/{{GITHUB_USER}}/PACK-verification/blob/main/pack/verification/08-service-clauses/VR.SC.005-installation-audit.md)
> **Роль:** VR.R.002 Аудитор (PACK-verification) — субагент с context isolation
> **Принцип:** детектор отчитывается, оператор делает (см. `scripts/iwe-drift.sh:7-11`). Auto-fix не входит в обещание.

Аргументы: $ARGUMENTS

## Обещание

За ≤5 минут — markdown-отчёт ✅/⚠️/❌ по 6 компонентам инсталляции:
1. **Inventory** — все ли критичные L1-файлы (CLAUDE.md, скиллы, протоколы) на месте
2. **L1 drift** — расхождения с FMT-exocortex-template
3. **DS-strategy** — git status + diff с FMT-strategy-template
4. **L3 customizations** — extensions/, отличия params.yaml от skeleton, AUTHOR-ONLY зоны
5. **MCP healthcheck** — 4 tools отвечают (с уважением к подписочному гейтингу DP.SC.112)
6. **Ритуал smoke-test** — `/run-protocol close day` запускается под sentinel-защитой, доходит до write-шагов (см. `memory/dry-run-contract.md`)

Verdict выносит subagent в роли Аудитора, читая отчёт **без знаний о текущей сессии** (context isolation).

## Шаг 1. Детерминированные проверки (bash)

Найти и запустить `iwe-audit.sh` через fallback-цепочку (author-mode → workspace, user-mode → `$IWE_SCRIPTS` из `~/.iwe-paths`):

```bash
if [ -f "$HOME/IWE/scripts/iwe-audit.sh" ]; then
    AUDIT_SCRIPT="$HOME/IWE/scripts/iwe-audit.sh"
elif [ -n "${IWE_SCRIPTS:-}" ] && [ -f "$IWE_SCRIPTS/iwe-audit.sh" ]; then
    AUDIT_SCRIPT="$IWE_SCRIPTS/iwe-audit.sh"
else
    echo "iwe-audit.sh не найден. Если \$IWE_SCRIPTS не выставлен — выполни 'source \$HOME/.iwe-paths' (или перезапусти shell), затем повтори. Если файла .iwe-paths нет — запусти setup.sh из FMT-шаблона."
    exit 1
fi
bash "$AUDIT_SCRIPT" $([ "${ARGUMENTS:-}" = "--critical" ] && echo "--critical")
```

Сохранить вывод в переменную `bash_report`. Проверить exit code:
- 0 → bash-часть ✅
- 1 → warnings (отметить, продолжать)
- 2 → critical gaps в bash-проверках (отметить, продолжать — Аудитор оценит совокупно с MCP)

Скрипт покрывает разделы 1-3 отчёта (Inventory, L1 drift, DS-strategy).

## Шаг 2. MCP healthcheck (если не `--skip-mcp`)

Параллельно вызвать 4 MCP tool'а с минимальной нагрузкой, замерить латентность:

| Tool | Параметры | Уровень | Что считаем |
|------|-----------|---------|-------------|
| `mcp__claude_ai_IWE__knowledge_search` | `query: "test"`, `limit: 1` | бесплатный | ✅ если ответ <15s |
| `mcp__claude_ai_IWE__github_status` | (без параметров) | бесплатный | ✅ если ответ |
| `mcp__claude_ai_IWE__personal_search` | `query: "ping"`, `limit: 1` | **подписочный** | ✅ если ответ; **403/subscription_required → ⏸️** (не считать failure) |
| `mcp__claude_ai_IWE__dt_read_digital_twin` | `path: "1_declarative"` | **подписочный** | ✅ если ответ; **403/subscription_required → ⏸️** (не считать failure) |

**Подписочное гейтование (DP.SC.112).** `personal_*` и `dt_*` требуют активной БР в `subscription_grants`. Без подписки — это **не сбой инсталляции**, а ожидаемый отказ. Помечать как ⏸️ subscription_required, не ❌. Coverage считать только по доступным для пользователя tool'ам.

Сформировать markdown-секцию `## 4. MCP healthcheck`:

```markdown
## 4. MCP healthcheck

| Tool | Статус | Латентность | Примечание |
|------|--------|-------------|------------|
| personal_search | ✅/❌ | Nms | ... |
| knowledge_search | ✅/❌ | Nms | ... |
| github_status | ✅/❌ | Nms | ... |
| dt_read_digital_twin | ✅/❌ | Nms | ... |

Coverage: N/4
```

Если `--skip-mcp` → секция «⏸️ MCP healthcheck — пропущен по флагу».

## Шаг 2.5. Smoke-test ритуала (sentinel + subagent)

> **Контракт:** [memory/dry-run-contract.md](../../../memory/dry-run-contract.md). Защита через sentinel-файл + PreToolUse-хук `dry-run-gate.sh`.

### Алгоритм

1. **Получить SESSION_ID:**
   ```bash
   SID="${CLAUDE_SESSION_ID:-$(uuidgen 2>/dev/null || date +%s%N)}"
   ```
2. **Создать sentinel:**
   ```bash
   echo "{\"created_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"session_id\":\"$SID\",\"initiator\":\"audit-installation\"}" > /tmp/iwe-dry-run-${SID}.flag
   ```
3. **Запустить subagent** через Agent tool (subagent_type=general-purpose, модель Sonnet) с промптом:

   ```
   Запусти ритуал /run-protocol close day по обычной процедуре. Не изобретай — следуй SKILL.md как написано.

   ВАЖНО: в текущем окружении активен sentinel /tmp/iwe-dry-run-${SID}.flag — это означает dry-run mode.
   PreToolUse-хук dry-run-gate.sh заблокирует любой write-tool (Write/Edit/git-write/MCP-write).
   Это ожидаемо — твоя задача дойти максимально далеко, фиксируя на каком шаге упёрся.

   После прогона отчитайся в формате:
   ## Smoke-test /run-protocol close day
   - Шагов выполнено: N из M
   - Упёрлось на: <шаг>: <tool>: <причина блокировки>
   - Read-логика: ✅ работает / ❌ упало раньше write-шага
   - Заключение: ✅/⚠️/❌
   ```

4. **Дождаться завершения subagent'а.**
5. **Очистить sentinel:**
   ```bash
   rm -f /tmp/iwe-dry-run-${SID}.flag
   ```
6. **Сформировать секцию 6 отчёта:**
   ```markdown
   ## 6. Ритуал smoke-test (/run-protocol close day)

   <вывод subagent'а>

   **Интерпретация:**
   - Block на write-шаге после успешных read-шагов → ✅ (read-логика работает, это ожидаемое поведение smoke-теста)
   - Block на шаге 1-2 → ❌ (ритуал ломается рано — нет source-файла, MCP отвалился)
   - Все шаги без block → ⚠️ (подозрительно — ритуал должен иметь write-шаги)
   - Hook-error → ❌ (инфраструктура поломана)
   ```

### Защита от sticky-sentinel

Если subagent упал/завис → попытаться удалить sentinel явно (всегда). TTL 10 мин в самом хуке защищает от случаев, когда даже это не отработало (kill -9, краш CLI).

## Шаг 3. Сборка единого отчёта

```markdown
# IWE Installation Audit — YYYY-MM-DD HH:MM

[bash_report — секции 1-3]

[mcp_section — секция 4]

---
[передаётся Аудитору на шаг 4]
```

## Шаг 4. Запустить subagent в роли Аудитора (VR.R.002)

Использовать Agent tool с **context isolation** (subagent_type=general-purpose, модель Sonnet):

**⛔ Subagent НЕ получает:**
- Историю текущей сессии
- Знания о том, что пользователь чинил/восстанавливал
- Промежуточные рассуждения

**Subagent получает (промпт):**

```
Ты исполняешь роль VR.R.002 Аудитор (PACK-verification). Твоя задача — прочитать markdown-отчёт по аудиту инсталляции IWE и вынести verdict.

Эталон:
- VR.SC.005 (Service Clause): инсталляция должна иметь все критические L1-файлы, ритуалы должны загружаться, MCP должен отвечать, DS-strategy — быть git-репо.
- Gate-критерии (из WP-265 §Gate-критерии):
  - ✅ — 0 critical gaps, ≤2 warnings
  - ⚠️ — 1+ warning или ≥3 minor gaps; работоспособно
  - ❌ — ≥1 critical: L1 broken (>5 файлов drift), ритуал падает, MCP <2/4 отвечают

Принцип context isolation (VR.SOTA.002): не используй знания о том, как создавалась инсталляция. Оценивай ТОЛЬКО по отчёту.

Отчёт:
[вставить полный собранный отчёт]

Выдай verdict в формате:

## Verdict: [✅ / ⚠️ / ❌]

**Сводка по компонентам:**
- L1 (платформа): ✅/⚠️/❌ — короткое объяснение
- Ритуалы: ✅/⚠️/❌ — ...
- MCP: ✅/⚠️/❌ — ...
- DS-strategy: ✅/⚠️/❌ — ...

**Критичные gaps (если есть):**
- [список с указанием файла/компонента]

**Рекомендации:**
- Что чинить через `update.sh` (Синхронизатор)
- Что чинить руками (с конкретным шагом)
- Что отложить (некритично)

Не предлагай auto-fix. Не лезь в реализацию. Твоя роль — Аудитор, не Кодировщик.
```

## Шаг 5. Сохранить отчёт + показать пользователю

1. **Сохранить полный отчёт + verdict в файл:**
   ```bash
   # Приоритет: workspace/scripts/ → $IWE_SCRIPTS (FMT-template/scripts/ для user-mode) → $HOME/IWE
   if [ -d "$HOME/IWE/scripts" ]; then
       AUDIT_LOG_DIR="$HOME/IWE/scripts"
   elif [ -n "${IWE_SCRIPTS:-}" ] && [ -d "$IWE_SCRIPTS" ]; then
       AUDIT_LOG_DIR="$IWE_SCRIPTS"
   else
       AUDIT_LOG_DIR="$HOME/IWE"
   fi
   mkdir -p "$AUDIT_LOG_DIR"
   AUDIT_LOG="$AUDIT_LOG_DIR/iwe-audit-$(date +%Y%m%d-%H%M%S).log"
   # Записать конкатенацию: full_report + verdict
   ```
2. **Вывести пользователю:**
   - Полный markdown-отчёт (секции 1-6)
   - Verdict от Аудитора
   - Краткое резюме одной строкой: `Verdict: ⚠️ Работоспособно с N оговорками. Лог: <AUDIT_LOG>`

Пользователь сам решает, что чинить.

## Ограничения текущей реализации

- **Smoke-test покрывает один ритуал** (`/run-protocol close day`). Расширение на week-close / month-close — мини-РП, копия шага 2.5 с другими subcommand'ами.
- **DS-strategy diff** — работает только если существует `FMT-strategy-template/` (или `templates/strategy-skeleton/`). Если нет — секция пометится «N/A».
- **MCP healthcheck** — зависит от текущих доступных tools. Если набор изменится, обновить шаг 2.
- **Sentinel sticky-state** — защита: TTL 10 мин в хуке + Stop-cleanup. Edge case: если хук изменён и не читает sentinel → блокировки не будет (fail-open). Защита: периодический re-test `/audit-installation` ловит регрессию.
