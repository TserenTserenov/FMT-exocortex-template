Before starting work — remind yourself of fault patterns:

```bash
IWE_ROOT="${IWE_WORKSPACE:-${WORKSPACE_DIR:-$HOME/IWE}}"
IWE_PLATFORM_SCRIPTS="${IWE_SCRIPTS:-${IWE_TEMPLATE:-$IWE_ROOT/IWE}/scripts}"
python3 "$IWE_PLATFORM_SCRIPTS/agent-fault/iwe_checklist_memory.py" remind \
  --protocol work --limit 3 \
  --subject-kind "$IWE_FAULT_SUBJECT_KIND" \
  --subject-id "$IWE_FAULT_SUBJECT_ID"
```

`IWE_FAULT_SUBJECT_KIND` and `IWE_FAULT_SUBJECT_ID` are required: the reminder reads only active faults for exactly that subject. Keep 🔴 items in mind throughout the Session.

> Not required every time — only when the Session is substantive (>15 min) or resuming after a break.