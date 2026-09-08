## Agent Fault Profile (WP-316)

Перед началом работы — напомнить себе о паттернах косяков:

```bash
IWE_ROOT="${IWE_WORKSPACE:-${WORKSPACE_DIR:-$HOME/IWE}}"
IWE_PLATFORM_SCRIPTS="${IWE_SCRIPTS:-${IWE_TEMPLATE:-$IWE_ROOT/FMT-exocortex-template}/scripts}"
python3 "$IWE_PLATFORM_SCRIPTS/agent-fault/iwe_checklist_memory.py" remind \
  --protocol work --limit 3 \
  --subject-kind "$IWE_FAULT_SUBJECT_KIND" \
  --subject-id "$IWE_FAULT_SUBJECT_ID"
```

`IWE_FAULT_SUBJECT_KIND` и `IWE_FAULT_SUBJECT_ID` обязательны: напоминание
читает только активные ошибки ровно этого субъекта. 🔴-пункты держать в уме на
протяжении сессии.

> Не нужно каждый раз — только если сессия содержательная (>15 мин) или продолжение после перерыва.
