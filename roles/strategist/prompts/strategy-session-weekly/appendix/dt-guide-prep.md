---
appendix: dt-guide-prep
artifact: context/session-context-YYYY-MM-DD.md
consumed_by:
- '04'
- 05a
produced_by: session-prep
title: Digital Twin Snapshot and Guide Format for a Session (session-context)
---

# Appendix: Digital Twin Snapshot + Guide for a Session (session-context)

> The Artifact `context/session-context-YYYY-MM-DD.md` is prepared by the automated session-prep Step **before** the interactive Session and consumed by Steps 04 (strategic alignment) and 05a (calibration measurement). Its purpose is to give the Strategist an up-to-date digital twin snapshot and personal guide in a single file, without querying the database during the dialogue.

## Precondition

Prepared **only** when tracking consent is granted (`learning.tracking_consent = granted`, see [consent-check.md](consent-check.md)). When `denied` / `null`, the file is **not created**; Steps 04/05a run in degraded mode.

## Artifact Format

```markdown
---
generated_at: <ISO-8601 UTC>
generated_by: session-prep
pilot: <pilot identifier>
consent: granted
dt_snapshot_date: <YYYY-MM-DD — digital twin snapshot date>
schema_version: 1
---

# Session Snapshot <YYYY-MM-DD>

## 1. Digital Twin (derived aggregates)
- **Mastery stage (cp-profile):** cp.rhy / cp.wld / cp.skl / cp.iwe / cp.int / cp.agt — per FORM.089 §6.1
- **Bottleneck:** <slot with the minimum index>
- **Weekly multiplier:** <value + source: WakaTime/slot_logged>
- **Time invested over period:** <hours> (self-development only, unaccounted)
- **Phase:** Chaos / Ceiling / Turn / Development

## 2. Personal Guide Snapshot
- **Program:** LR / RR / IR
- **Current focus domain:** <from personal-guide>
- **Open recommendations:** <up to 3 items>

## 3. Signals for Strategic Planning
- Plan vs. actuals divergences for the period
- Stop-list triggers for the RP (if activated)
- Unclosed carry-overs from the previous week
```

## Rules

1. **Derived, not source.** The file is a snapshot. The source of truth for the digital twin is Neon (Memory.Derived). Do not edit manually during a Session.
2. **One file per date.** `session-context-YYYY-MM-DD.md`. Re-running session-prep on the same day overwrites the file.
3. **Expiry.** Older than 1 day → Step 04 marks the snapshot as stale and offers a re-prep or degraded mode.
4. **Missing file ≠ error.** No file → Steps 04/05a run on self-declaration (same as degraded mode). Do not block the Session.
5. **PII boundary.** The snapshot contains only Aggregates (numbers, Mastery stage, Phase) — not raw conversation or reflection content (B7.3).
