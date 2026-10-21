# {{repo_name}}

**Class:** {{repo_class}} <!-- Base | Pack | DS/instrument | DS/governance | DS/surface | PD-{{slug}} | MC-{{slug}} -->
**Purpose:** {{purpose}} <!-- one sentence in plain language: what lives here and why — not a service classification -->
**Created:** {{created_date}} via `/repo-new`

## Data Domains

<!-- One row per data type 2.1–2.4 residing in this repository. Remove unused rows. -->

| Type | Home | Sensitivity | Quarantine |
|------|------|-------------|------------|
| {{type}} | {{home}} | {{sensitivity}} | {{quarantine}} |

**Quarantine outside the axis (secrets, payment data, third-party PII):** {{outside_axis_note}}

## Writer / Owner / Readers

- **Writer:** {{writer}} <!-- pilot | agent | platform | system (CI) -->
- **Owner:** {{owner}}
- **Readers:** {{readers}}

## Gate receipt (Projection)

<!-- Copied from the gate receipt recorded at repository creation (repo-new SKILL.md, Step 6).
     This is a Projection, not the primary record — the original lives in the WP/Session referenced below.
     The full receipt also contains request_fingerprint and plan_fingerprint — these are intentionally
     not duplicated here. Find the full field set in the source WP/Session via wp_ref. -->

```yaml
approved_by: {{approved_by}}
approved_at: {{approved_at}}
approval_scope: {{approval_scope}}
wp_ref: {{wp_ref}}
```