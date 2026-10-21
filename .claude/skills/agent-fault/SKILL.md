---
agents: none
argument-hint: record --severity {critical|major|minor} --fault <description> --subject-kind
  {personality|runtime|system} --subject-id <stable-id>
browser_safe: false
description: Registers an agent fault in the WP-316 L1 tracking system. No LLM — deterministic
  script with no WP Gate.
gates_enforced: []
gates_rationale: deterministic script-executor; WP Gate and IntegrationGate not applicable
gates_required: []
interaction: one-shot
layer: L1
name: agent-fault
routing:
  deterministic: true
  executor: script
  script_path: scripts/agent-fault/iwe_checklist_memory.py
status: active
triggers:
  phrases: []
  slash:
  - /agent-fault
version: 0.2.0
---

# /agent-fault — agent fault registration

## When to use

When a recurring agent fault is detected — register it immediately via `/agent-fault`.
Examples: skipping WP Gate, ignoring a checklist, adding unnecessary yes/no questions, skipping Pull-on-Touch.
The Skill does not require an LLM and does not create a Work Product — it is a record in the WP-316 pattern database.

## Algorithm

Pass the fault to the unified agent-neutral CLI with a severity level, description, and explicit
fault subject. `subject-kind` defines the owner type (`personality`,
`runtime`, or `system`), and `subject-id` defines its stable identifier. Do
not infer the subject from the model's self-report.

```bash
: "${IWE_FAULT_SUBJECT_KIND:?set the actual personality, runtime, or system kind}"
: "${IWE_FAULT_SUBJECT_ID:?set the actual stable subject id}"
IWE_ROOT="${IWE_WORKSPACE:-${WORKSPACE_DIR:-$HOME/IWE}}"
IWE_DIR="$IWE_ROOT" \
IWE_EXECUTOR_CATALOG="$IWE_ROOT/${IWE_GOVERNANCE_REPO:-${GOVERNANCE_REPO:-DS-strategy}}/scripts/executor-catalog.yaml" \
bash "${IWE_SCRIPTS:-$IWE_ROOT/IWE/scripts}/route-task.sh" \
  --skill agent-fault \
  --args "record --severity major --fault agent skipped the checklist --subject-kind $IWE_FAULT_SUBJECT_KIND --subject-id $IWE_FAULT_SUBJECT_ID"
```

Allowed values for `--severity`: `critical` | `major` | `minor`.
The description after `--fault` may consist of multiple words: the CLI collects them up to
the next flag without shell-eval. To include an exact citation of the violated rule, add
`--source-citation <text>`.

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
