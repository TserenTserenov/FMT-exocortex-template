---
argument-hint: --repo <path> | . | --init --repo <path>
browser_safe: false
description: 'Audit repository documentation: detect drift between code and docs,
  report coverage by category. Run manually or on triggered drift critical.'
layer: L3
name: audit-docs
routing:
  deterministic: false
  executor: sonnet
status: active
triggers:
  phrases: []
  slash:
  - /audit-docs
version: 0.2.0
---

# Audit Docs (R24 Auditor)

> **Role:** R24 Auditor. Full description: `PACK-digital-platform/pack/digital-platform/02-domain-entities/DP.ROLE.024-auditor.md` (WP-224). Mapping: R24 = VR.R.002.
> **Method:** R24 coverage by category + R23 pair-diff between `code file ↔ docs file` pairs.
> **Report recipient:** the repository owner at a different point in time (category 3 — external project role). This is an Audit in the strict sense — not the code author, not the current agent.
> **Role type (DP.D.080):** R24 is a control role. Read-only access to audited Artifacts. The report is the output channel, not a change to the audited material.

Arguments: $ARGUMENTS

## What it does

Scans the specified repository and produces a **report** on drift between code and documentation. **Does not modify code or docs** — only produces the report.

## Parameters

- `--repo <path>` (required) or `.` (current directory).
- `--init --repo <path>` — guided Configuration preparation; does not run the Audit.

## Configuration ownership

| Responsibility | Accountable role |
|---|---|
| Decide that documentation coverage is required and approve the repository model | Repository owner |
| Define documentation categories and source ↔ documentation pairs | R5 Architect together with the owner |
| Materialize the approved YAML | Maintainer or agent executor |
| Consume the YAML and report on drift | R24 Auditor / `audit-docs` |
| Provide the template, schema, bootstrap, and ownership statement | Platform maintainer / FMT |

**Blocking rule:** the agent may create `docs/.audit-context.yaml` only after the owner has approved the categories and mappings. The R24 Auditor does not invent the semantic model — neither during the Audit nor before it.

## Bootstrap (`--init`)

1. Read `<repo>/CLAUDE.md`; identify the owner and the R5 Architect.
2. Show them the example `.claude/skills/audit-docs/.audit-context.yaml.example`.
3. Obtain explicit owner approval for the category list and each `source_patterns` ↔ `docs_patterns`/`file_naming` pair. Stop without approval.
4. Materialize the approved model in `<repo>/docs/.audit-context.yaml`; set `owner_approved: true`, `approved_by`, and the actual date.
5. Run the validation below. Only a valid file becomes the Audit input.

## Schema and validation

The root is a mapping with strict keys `schema_version: 1`, `owner_approved: true`, `approved_by`, `approved_at`, `categories`. `categories` is a non-empty list; each category contains a unique `id`, non-empty string lists `source_patterns` and `docs_patterns`, and a string `file_naming`; `drift_days` is an optional positive integer. Unknown keys and empty glob patterns are errors.

Run this validator before the Audit (requires PyYAML):

```bash
python3 - "$REPO/docs/.audit-context.yaml" <<'PY'
import datetime as dt
import sys
import yaml

path = sys.argv[1]
data = yaml.safe_load(open(path, encoding="utf-8"))
root_keys = {"schema_version", "owner_approved", "approved_by", "approved_at", "categories"}
category_keys = {"id", "source_patterns", "docs_patterns", "file_naming", "drift_days"}
assert isinstance(data, dict) and set(data) == root_keys, "invalid root keys"
assert data["schema_version"] == 1, "unsupported schema_version"
assert data["owner_approved"] is True and data["approved_by"], "owner approval missing"
assert isinstance(data["approved_at"], (str, dt.date)), "approved_at missing"
categories = data["categories"]
assert isinstance(categories, list) and categories, "categories must be non-empty"
ids = []
for category in categories:
    assert isinstance(category, dict) and set(category) <= category_keys, "invalid category keys"
    assert {"id", "source_patterns", "docs_patterns", "file_naming"} <= set(category), "category keys missing"
    ids.append(category["id"])
    for key in ("source_patterns", "docs_patterns"):
        assert isinstance(category[key], list) and category[key] and all(isinstance(v, str) and v.strip() for v in category[key]), key
    assert isinstance(category["file_naming"], str) and category["file_naming"].strip(), "file_naming"
    assert "drift_days" not in category or isinstance(category["drift_days"], int) and category["drift_days"] > 0, "drift_days"
assert len(ids) == len(set(ids)) and all(isinstance(v, str) and v.strip() for v in ids), "category ids"
print("audit-context: valid")
PY
```

## Step 0. Load context

At startup, read the following:

1. `<repo>/CLAUDE.md` in full — as any agent in this repository would. In particular, § 10 "Known traps/invariants" (if present).
2. `<repo>/docs/.audit-context.yaml` — docs categories, source patterns, file_naming. If the file is absent, report the need for `--init` and stop; creating the model independently is prohibited. If the file exists, run the schema validator above — an error blocks the Audit.
3. `${IWE_ROOT:-$HOME/IWE}/.claude/sync-manifest.yaml` — find pairs where `source` or `derived` intersect this repository. Use these as an additional source of code ↔ docs relationships.

## Step 1. R24 coverage by category

For each category in `.audit-context.yaml`:

1. List all source files (by `source_patterns`).
2. For each source file, find the associated docs file using `file_naming` or a heuristic.
3. Calculate: `coverage % = docs_files / source_files`.
4. Record **gaps** (source without docs) and **orphans** (docs without source).

## Step 2. R23 pair-diff (drift detection)

For each existing `source ↔ docs` pair:

1. Compare mtime — if docs is older than source by more than N days (threshold from the Manifest or default 7), mark as an update candidate.
2. If git history is available, check recent commits to source and verify whether the affected entities (functions, tables, endpoints) are mentioned in docs.
3. Record `drift_candidates` with priority (critical / warn / ok).

## Step 3. Link to CLAUDE.md § 10

For each trap/invariant in CLAUDE.md § 10, check whether it is mentioned in docs. If not, add it to the "Non-obvious items" section.

## Step 4. Generate the report

Write the report to `<repo>/docs/audit-reports/audit-YYYY-MM-DD.md` with the following structure:

```markdown
# Audit report — <repo> — <YYYY-MM-DD>

## Coverage by category
| Category | Source files | Docs files | Coverage % | Status |
|----------|--------------|------------|------------|--------|

## Gaps (source without docs)
- ...

## Orphans (docs without source)
- ...

## Drift candidates (pair-diff)
| Source | Docs | mtime lag | Priority |
|--------|------|-----------|----------|

## Non-obvious items (§ 10 CLAUDE.md, not covered by docs)
- ...

## Summary
- Total coverage: X%
- Drift critical: N
- Drift warn: N
- Gaps: N
- Orphans: N
```

## What it does NOT do

- Does NOT modify code.
- Does NOT modify docs.
- Does NOT create a draft PR with suggestions (that is the next step — `/auto-docs`).
- Does NOT make decisions about docs categories (a new category is an architectural decision, not an Audit).

## Relationship to other skills

- `/verify` — verifies an Artifact against the Pack reference (VR.R.001). `/audit-docs` — cross-repository coverage Audit (R24/VR.R.002). Different roles, different methods.
- `iwe-drift.sh` — detects drift between pairs in `sync-manifest.yaml` (S-class). `/audit-docs` — in-depth docs/ Audit within a single repository. The drift → "run `/audit-docs`" decision is a standard workflow.

## Relationship to SC.024.∞

This skill implements Variant C (manual baseline) from the `SC.024.∞ — Auto-update docs/` design. After 2 weeks of operation and accuracy calibration, transition to Variant A (post-merge GitHub webhook). See the adjacent README.md.
