# collectors.d/ — dt-collect.sh plugins

Personal metric collectors for the digital twin. Each `*.sh` file loads automatically when `dt-collect.sh` starts.

## Plugin format

```bash
#!/bin/bash
# COLLECTOR: function_name
# TARGET: 2_7_iwe | 2_8_ecosystem | 2_9_knowledge
# Description: what this collector gathers

collect_function_name() {
    # Available: $WORKSPACE, log()
    # Must output JSON to stdout
    # On error or missing data — output {}
    echo '{"my_metric": 42}'
}
```

## Required fields

- `# COLLECTOR:` — function name (without the `collect_` prefix)
- `# TARGET:` — JSONB section in `digital_twins.data → 2_collected`:
  - `2_7_iwe` — IWE metrics (work turns, multiplier, scheduler)
  - `2_8_ecosystem` — ecosystem metrics (bot, publications)
  - `2_9_knowledge` — knowledge metrics (Pack, Scout, notes)

## Rules

1. A plugin **must** return `{}` when no data is available (file not found, service not configured).
2. A plugin **must not** exit with an error — stderr is redirected to the log.
3. Metric names must be unique within their TARGET section.
4. `update.sh` **does not touch** this directory — your plugins are preserved when the template updates.

## Examples

Personal collectors (L4) — for systems that not every user has:

- `scout.sh` — nightly scout (if DS-agent-workspace/scout/ is configured)
- `unsatisfied.sh` — bot QA (if DS-agent-workspace/scheduler/feedback-triage/ is configured)
- `publications.sh` — publications (if DS-Knowledge-Index-*/docs/ exists)