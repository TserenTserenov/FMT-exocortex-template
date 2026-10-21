Run before checks — to avoid missing steps with a skip history:

```bash
IWE_ROOT="${IWE_WORKSPACE:-${WORKSPACE_DIR:-$HOME/IWE}}"
IWE_PLATFORM_SCRIPTS="${IWE_SCRIPTS:-${IWE_TEMPLATE:-$IWE_ROOT/IWE}/scripts}"
python3 "$IWE_PLATFORM_SCRIPTS/agent-fault/iwe_checklist_memory.py" remind \
  --protocol close \
  --subject-kind "$IWE_FAULT_SUBJECT_KIND" \
  --subject-id "$IWE_FAULT_SUBJECT_ID"
```

🔴 items = steps frequently skipped during Close. Apply immediately to remaining steps.

> If a new fault pattern is detected in this Session — add a feedback file to `memory/`, then:
> ```bash
> IWE_ROOT="${IWE_WORKSPACE:-${WORKSPACE_DIR:-$HOME/IWE}}"
> IWE_PLATFORM_SCRIPTS="${IWE_SCRIPTS:-${IWE_TEMPLATE:-$IWE_ROOT/IWE}/scripts}"
> python3 "$IWE_PLATFORM_SCRIPTS/sync_feedback_to_memory.py"
> ```

The import assigns legacy feedback rules to the system subject
`system:feedback-import`; there is no direct second writer for SQLite.