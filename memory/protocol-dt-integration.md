---
description: DT Guide Prep + Consent Check for steps 04/05a of the strategic session
domains:
- platform
- personal-profile
horizon: warm
name: Digital Twin Integration Protocol
owner: platform
schema_version: 1
status: active
type: protocol
valid_from: 2026-06-02
---

# Digital Twin Integration Protocol

> Applies at steps 04 (dt-guide-prep) and 05a (consent-check) of the step-by-step strategic session.
> Source of truth for consent: `learning.tracking_consent` (Neon).

---

## DT Guide Prep

### Artifact

`context/session-context-YYYY-MM-DD.md` — file created before the strategy session.

### Format

```markdown
---
date: YYYY-MM-DD
session_type: weekly | monthly
source: dt_read_digital_twin
generated_by: session-prep
---

# Session Context YYYY-MM-DD

## Indicators (from DT)

| Indicator | Value | Trend |
|-----------|-------|-------|
| ... | ... | ↑ ↓ → |

## Active NEPs

| Code | Statement | Age | Movement |
|------|-----------|-----|----------|
| ... | ... | Nd | +/- |

## Tailor Recommendations

- ...

## Carry-over from Previous Session

- ...
```

### Rules

1. **Source:** use only `dt_read_digital_twin` (Neon). Do not duplicate manually.
2. **TTL:** the file is valid for 24h. Check `mtime` before use:
   - If `> 24h` → regenerate via `dt_read_digital_twin` → write a new `context/session-context-*.md`
   - If `≤ 24h` → use the existing file
   - If the file does not exist → create it via `dt_read_digital_twin`
3. **RLS:** the file contains personal data → store in a private repo; do not commit to a public Pack.

---

## Consent Check

### Scenarios

| Scenario | Condition | Action |
|----------|-----------|--------|
| **Granted** | `learning.tracking_consent = true` | Proceed: read DT, generate `session-context`, use Tailor |
| **Denied** | `learning.tracking_consent = false` | Skip DT integration. Run session without Tailor and DT. Offer `/consent opt-in` at the end. |
| **Null** | `learning.tracking_consent IS NULL` | Request consent before starting DT integration. Show: what is collected, why, who can see it. |

### Behavior When Null

1. **Inform** the pilot:
   - What is collected: activity_log, indicators, assessments
   - Why: Tailor personalization, session calibration
   - Who can see it: pilot and Platform Admin only (RLS)
2. **Request:** "Do you consent to tracking for personalization? Yes / No / Later"
3. **Record:** on "Yes" → `learning.tracking_consent = true`; on "No" → `false`; on "Later" → `null`, skip DT

### Behavior When Denied

- Do not read `dt_read_digital_twin`
- Do not generate `session-context`
- Do not use Tailor recommendations
- At the end of the session: soft reminder — "To enable personalization, use /consent opt-in"

---

## Connections

- Role Strategist (R1): uses this Protocol at steps 04/05a
- Tailor (tailor-mcp): source of recommendations when granted
- R28 Diagnostician: updates `learning.cp_assessments`, affects context
