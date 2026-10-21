---
appendix: consent-check
title: Tracking Consent Verification (consent)
used_by:
- 05a
- 05c
- '04'
---

# Appendix: Tracking Consent Verification

> The single source of truth for consent is the `learning.tracking_consent` table (Neon). The WeekPlan/DayPlan frontmatter is **not** a consent source (drift). Before any tracking write or any read of digital twin (DT) derivatives, each step verifies consent here.

## When to Call

| Step | Reason |
|-----|-------|
| 04 (strategic alignment) | Before reading `context/session-context-*.md` (DT/Guide snapshot — data is derived from tracking) |
| 05a (caliber: measurement) | Before using mastery metrics from the DT |
| 05c (caliber: tracking) | Before **writing** to trackers / domain_event |

## Consent States

`learning.tracking_consent` for the pilot returns one of:

| State | Meaning | Step Behavior |
|-----------|----------|----------------|
| `granted` | Consent given | Full mode: read DT snapshot, write tracking, compute metrics |
| `denied` | Explicit refusal | **Degraded mode:** do not read DT, do not write tracking/domain_event. Session runs on pilot self-declaration |
| `null` / absent | Consent was never requested | Treat as `denied` (fail-safe). Offer `/consent` once — without pressure |

## Degraded Mode (denied / null)

1. **Do not read** `context/session-context-YYYY-MM-DD.md` (it is derived from tracking). If the file exists — skip it with the note "DT snapshot unavailable: no consent".
2. **Do not write** tracking-dependent fields in `Caliber-artifacts-tracker.md`; the caliber lens runs on pilot self-assessment, without writing domain_event.
3. **Do not compute** the multiplier/stage from the DT — ask the pilot directly.
4. **Notify the pilot once** (do not repeat within the same session):
   > "Tracking is off (no consent). Running the session on your words, without reading the digital twin. To enable tracking, use `/consent`."
5. The session is **not blocked** — strategizing and planning are fully available via self-declaration.

## Verification (how exactly)

- In Claude Code / VS Code: read `learning.tracking_consent` via MCP/script. No access to Neon → treat as `null` (degraded).
- In the browser channel: consent arrives in the onboarding context; absence → degraded.

**Invariant:** one consent state per session. Do not re-check between steps — lock it in at the start (step 00/04) and reuse it.
