# Migration: Strategy.md / WeekPlan to v0.27.0

> Applies to users who installed the template **before v0.27.0** and have their own `DS-strategy/docs/Strategy.md` from a previous version.

## What Changed in v0.27.0

Three blocks were added to `seed/strategy/docs/Strategy.md` (see CHANGELOG `[0.27.0]`):

1. **"Monthly State — Strategic Position Phase"** — 4 phases (Growth / Chaos / Ceiling / Pivot), diagnosis by 5 signals, a playbook for each phase, and transition signals. Source: PD.FORM.078, WP-196 Ф12.1.
2. **"Personality Caliber"** — gap analysis across 3 dimensions (horizon / bus factor / visibility). Source: PD.CHR.007.
3. **Source line for the "NEP Triad"** placed before the R1-R{N} table.

The Strategy Session now begins with an explicit phase declaration and the corresponding playbook, rather than an arbitrary selection of work priorities.

The following were added to `memory/templates-dayplan.md`: work priority selection criteria, weekly Theory of Constraints focus, and time-boxing.

## What `update.sh` Does

`update.sh` **does not modify** your `DS-strategy/` directory (this is personal planning and is protected from overwrite). Therefore, the new v0.27.0 blocks **will not be added automatically** to your `Strategy.md`.

## How to Migrate (≤15 min)

1. Open `seed/strategy/docs/Strategy.md` in FMT-exocortex-template.
2. Open your `DS-strategy/docs/Strategy.md`.
3. Copy the missing blocks into the correct locations:
   - The "Monthly State" section — between "Vision" and "Goals on the Horizon".
   - The "Personality Caliber" section — after "Goals on the Horizon", before the NEP Triad.
   - The "NEP Triad" source line — above the R1-R{N} table.
4. At your next Strategy Session, explicitly declare your current phase (Growth / Chaos / Ceiling / Pivot) and select the corresponding playbook.

## Alternative — Ask Claude

Say: "Compare my `DS-strategy/docs/Strategy.md` with `~/IWE/FMT-exocortex-template/seed/strategy/docs/Strategy.md` and suggest which v0.27.0 blocks to add without breaking my existing content." Claude will produce a diff and propose targeted edits.

## What Does Not Require Migration

- `Dissatisfactions.md`, `Session Agenda.md`, `WP-REGISTRY.md` in `seed/` — these are empty templates and were not updated substantively in v0.27.0.
- WeekPlan — this is a dynamic file; new template blocks will be included at the next session-prep.