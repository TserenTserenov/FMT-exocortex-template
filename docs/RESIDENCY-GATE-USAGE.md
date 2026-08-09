# ResidencyGate — How to Use the Data Access Consent Mechanism

## Overview

ResidencyGate is a universal mechanism for features that work with personal data of types 2.1–2.4. A feature declares what data it needs, and ResidencyGate ensures:

1. **Point A (activation-time):** when a feature is enabled → pilot consent check
2. **Point B (lazy):** when data is actually requested → interactive check if consent is missing

---

## Step 1. Declare Data Needs

### For SKILL.md

Add the following block to the frontmatter or body:

```yaml
data_needs:
  - type: 2.1, flow: inbound, name: digital-twin
  - type: 2.2, flow: outbound, name: health-export, schema_version: 1
```

**Fields:**
- `type`: one of types 2.1/2.2/2.3/2.4 (from WP-475)
- `flow`: `inbound` (platform → IWE) or `outbound` (IWE → platform)
- `name`: unique name for the need (used for logging)
- `schema_version` (optional): schema version (default: 1)

### For bash hooks

```bash
#!/bin/bash
# --- data-needs
# type: 2.2, flow_direction: inbound, name: daily-summary, schema_version: 1
# ---

# Your hook code
```

---

## Step 2. Integrate Point A Into Startup

**Skills invoked via Claude Code (Skill tool) — no manual integration required.** From 09.08.2026, the `residency-gate-skill-adapter.sh` hook (PreToolUse, matcher `Skill`) automatically checks `data_needs` from `SKILL.md` before the skill code runs — declaring the block in Step 1 is sufficient. Previously this check was cognitive (the author could forget to insert `source`); now it is mechanical. Clean installation test: `scripts/tests/test_residency_gate_skill_adapter.py`.

If a feature runs **outside Claude Code** (day-open pipeline on launchd, a bot handler, or any process Claude Code does not launch) — Claude Code does not observe its start, there is no automatic check, and you must integrate manually:

```bash
#!/bin/bash

# At the start of the script: consent check
source ~/.claude/hooks/residency-gate-init.sh "day-open" "$HOME/.claude/skills/day-open/SKILL.md"

# If consent is granted — continue
# If not — the script returns 1 and prints the reason
```

---

## Step 3. Integrate Point B Into Data Access Code

If a feature is **interactive** or requires consent at a specific moment:

```bash
#!/bin/bash

# On attempting to read data:
bash ~/.claude/hooks/residency-gate-lazy.sh "render-guides" "2.1" "inbound" "digital-twin"

# If exit code = 0 → access granted
# If exit code = 1 → access denied
```

---

## Step 4. Consent Management (for the pilot)

### Grant consent

```bash
python3 ~/.claude/skills/residency-gate/residency-gate.py grant \
  <function_id> <type> <flow_direction> <name>
```

Example:
```bash
python3 ~/.claude/skills/residency-gate/residency-gate.py grant \
  day-open 2.2 inbound daily-summary
```

### Revoke consent

```bash
python3 ~/.claude/skills/residency-gate/residency-gate.py revoke \
  <function_id> <type> <flow_direction> <name> "reason"
```

### List all consents

```bash
python3 ~/.claude/skills/residency-gate/residency-gate.py list
```

### For a specific feature

```bash
python3 ~/.claude/skills/residency-gate/residency-gate.py list day-open
```

---

## Consent State

Consent is stored in the **gitignored** file `~/IWE/current/data-residency.yaml`:

```yaml
functions:
  day-open: 
    2.2_inbound_daily-summary: {status: granted, granted_at: 2026-07-11T12:00:00Z}
    2.1_inbound_digital-twin: {status: denied, denied_reason: user denied, denied_at: 2026-07-11T12:05:00Z}
```

---

## Examples

### Example 1: Day Open with Point A

```bash
#!/bin/bash
# ~/.claude/hooks/day-open-main.sh

source ~/.claude/hooks/residency-gate-init.sh "day-open" "$HOME/.claude/skills/day-open/SKILL.md"

# If execution reaches this point — consent is granted, continue
# ...rest of day-open logic...
```

### Example 2: Personal guide rendering with Point B

```python
# render-pilot-guides.py

def get_digital_twin():
    """Fetch user's digital twin from platform (with lazy consent check)."""
    import subprocess
    
    result = subprocess.run([
        "bash", 
        "~/.claude/hooks/residency-gate-lazy.sh",
        "render-guides", "2.1", "inbound", "digital-twin"
    ], capture_output=True)
    
    if result.returncode != 0:
        logger.info("User denied access to digital twin")
        return None
    
    # Access granted, fetch data
    return fetch_from_platform()
```

---

## Versioning (schema_version)

If a data need's schema changes (new fields, different format), increment `schema_version` in the declaration. ResidencyGate will automatically:

1. Detect the version incompatibility
2. Reset the consent status for the feature (revert to `not_asked`)
3. Require new consent on the next run

---

## Consent Mode Selection

| Scenario | Use |
|----------|-----|
| Feature is autonomous, no pilot in the loop | Point A (activation-time) |
| Feature is interactive or makes a one-time request | Point B (lazy) |
| Both needs apply (rare) | Both mechanisms |

---

## Audit and Transparency

Full consent history:

```bash
python3 ~/.claude/skills/residency-gate/residency-gate.py list render-guides | jq .
```

Returns:
```json
{
  "2.1_inbound_digital-twin": {
    "status": "granted",
    "granted_at": "2026-07-11T12:00:00Z"
  },
  "2.2_outbound_health-export": {
    "status": "denied",
    "denied_reason": "user denied export",
    "denied_at": "2026-07-11T12:05:00Z"
  }
}
```

---

## Integrating a New Feature: Checklist

- [ ] Declare `data_needs` in SKILL.md or bash frontmatter
- [ ] Add Point A (activation) OR Point B (lazy) depending on the feature type
- [ ] Test the denied consent case
- [ ] Document data needs in the feature README
- [ ] At release — the pilot runs `grant` or `deny` for each need