# ResidencyGate — How to Use the Data Access Consent Mechanism

## Overview

ResidencyGate is a universal mechanism for features that work with personal data of types 2.1–2.4. A feature declares what data it needs, and ResidencyGate guarantees:

1. **Point A (activation-time):** when the feature is enabled → pilot consent check
2. **Point B (lazy):** when data is actually requested → interactive check if consent is absent

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
- `name`: unique need name (for logging)
- `schema_version` (optional): schema version (default: 1)

### For a bash hook

```bash
#!/bin/bash
# --- data-needs
# type: 2.2, flow_direction: inbound, name: daily-summary, schema_version: 1
# ---

# Your hook code
```

---

## Step 2. Integrate Point A Into Startup

**A Skill invoked via the Claude Code adapter (Skill tool) — no integration required.** From 09.08.2026, the `residency-gate-skill-adapter.sh` hook (PreToolUse, matcher `Skill`) checks `data_needs` from `SKILL.md` automatically, before the Skill code runs — declaring the block in Step 1 is sufficient. Previously this check was cognitive (the author could forget to insert `source`); now it is mechanical. The clean-install test is `scripts/tests/test_residency_gate_skill_adapter.py`.

If a feature runs **outside Claude Code** (a day-open Pipeline on launchd, a bot handler, or any process that Claude Code does not launch) — Claude Code does not see its startup, there is no automatic check, and you must integrate manually:

```bash
#!/bin/bash

# At the start of the script: consent check
source ~/.claude/hooks/residency-gate-init.sh "day-open" "$HOME/.claude/skills/day-open/SKILL.md"

# If consent is granted — continue
# If not — the script returns 1 and prints the reason
```

---

## Step 3. Integrate Point B Into the Data-Access Code

If the feature is **interactive** or requires consent at a specific moment:

```bash
#!/bin/bash

# When attempting to read data:
bash ~/.claude/hooks/residency-gate-lazy.sh "render-guides" "2.1" "inbound" "digital-twin"

# If exit code = 0 → access granted
# If exit code = 1 → access denied
```

---

## Step 4. Consent Management (for the Pilot)

### Grant Consent

```bash
python3 ~/.claude/skills/residency-gate/residency-gate.py grant \
  <function_id> <type> <flow_direction> <name>
```

Example:
```bash
python3 ~/.claude/skills/residency-gate/residency-gate.py grant \
  day-open 2.2 inbound daily-summary
```

### Revoke Consent

```bash
python3 ~/.claude/skills/residency-gate/residency-gate.py revoke \
  <function_id> <type> <flow_direction> <name> "reason"
```

### List All Consents

```bash
python3 ~/.claude/skills/residency-gate/residency-gate.py list
```

### For a Specific Feature

```bash
python3 ~/.claude/skills/residency-gate/residency-gate.py list day-open
```

---

## Consent State

Consent is stored locally, outside Git and the workspace:
`${IWE_STATE_HOME:-$HOME/.iwe/state}/data-residency.yaml`. The directory is
accessible only to the owner (`0700`); the file is `0600`.

On first run, ResidencyGate migrates the previous
`<IWE workspace>/current/data-residency.yaml` (the workspace is resolved from
`IWE_WORKSPACE`, then `IWE_ROOT`/`IWE`, otherwise `$HOME/IWE`) to the new
location and stores an exact recoverable copy at
`migration-backups/data-residency.yaml.legacy`. Subsequent runs are idempotent.
If the old and new files differ, or either is corrupted, automatic merging is
prohibited: the gate stops and both source files remain unchanged.

During the atomic transfer, the old file receives a quarantine name inside the
private `IWE_STATE_HOME`, not inside the Git repository. If the old and new
stores reside on different filesystems, automatic migration stops: an atomic
rename between them is not possible. Symbolic links below the old workspace root
and files with multiple hard links are also rejected, so that consent cannot be
read or modified through an alternative path. Every read re-checks the old
address: a late-starting old version cannot silently restore revoked consent.

The primary file and the migration copy are intentionally excluded from Git and
from IWE automatic Backups. To transfer or back them up, copy them explicitly
to a secure local or encrypted store and preserve `0600` permissions. The `list`
command is for Audit purposes and is not a recoverable Backup. Note that the
state may contain user-supplied denial reasons (`denied_reason`).

Example content:

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

# If we reach this point — consent is granted, continue
# ...rest of day-open logic...
```

### Example 2: Personal Guide with Point B

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

If the need's schema changes (new fields, different format), increment `schema_version` in the declaration. ResidencyGate automatically:

1. Detects the version incompatibility
2. Resets the consent status for the feature (returns it to `not_asked`)
3. Requires new consent on the next run

---

## Consent Mode Selection

| Scenario | Use |
|----------|-----|
| Feature is autonomous, no pilot in the loop | Point A (activation-time) |
| Feature is interactive or involves a one-time request | Point B (lazy) |
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
- [ ] Test the denied-consent case
- [ ] Document needs in the feature README
- [ ] On release — the pilot runs `grant` or `deny` for each need

