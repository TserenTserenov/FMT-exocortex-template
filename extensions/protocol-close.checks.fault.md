## Agent Fault Profile (WP-316)

Запустить перед проверками — чтобы не пропустить шаги с историей пропусков:

```bash
IWE_ROOT="${IWE_WORKSPACE:-${WORKSPACE_DIR:-$HOME/IWE}}"
IWE_PLATFORM_SCRIPTS="${IWE_SCRIPTS:-${IWE_TEMPLATE:-$IWE_ROOT/FMT-exocortex-template}/scripts}"
python3 "$IWE_PLATFORM_SCRIPTS/agent-fault/iwe_checklist_memory.py" remind \
  --protocol close \
  --subject-kind "$IWE_FAULT_SUBJECT_KIND" \
  --subject-id "$IWE_FAULT_SUBJECT_ID"
```

🔴-пункты = часто пропускаемые именно при Close. Применить немедленно к оставшимся шагам.

> Если в этой сессии обнаружен новый паттерн косяка — добавить feedback-файл в `memory/`, затем:
> ```bash
> IWE_ROOT="${IWE_WORKSPACE:-${WORKSPACE_DIR:-$HOME/IWE}}"
> IWE_PLATFORM_SCRIPTS="${IWE_SCRIPTS:-${IWE_TEMPLATE:-$IWE_ROOT/FMT-exocortex-template}/scripts}"
> python3 "$IWE_PLATFORM_SCRIPTS/sync_feedback_to_memory.py"
> ```

Импорт назначает старые feedback-правила системному субъекту
`system:feedback-import`; прямого второго writer для SQLite нет.
