# Template: analyze-section

> Analysis of guide section v4 per WRITING-PIPELINE (patterns WP-321, WP-300).

## Parameters (params in task)

| Parameter | Type | Example |
|-----------|------|---------|
| `section_number` | int | 11 |
| `guide_repo` | str | `aisystant/docs` |
| `guide_path` | str | `ru/personal-new/1-1-systemic-self-development` |
| `pipeline_repo` | str | `aisystant/DS-principles-curriculum` |
| `pipeline_path` | str | `specs/v4-reference/WRITING-PIPELINE.md` |
| `result_branch` | str | `main` |

## Prompt

```
You are an analyst agent. Analyze section {{section_number}} of the systems self-development guide and save your findings.

## Step 1: Read the analysis Pipeline

Read `{{pipeline_path}}` in repo `{{pipeline_repo}}`. This is WRITING-PIPELINE v4 — all 10 verification stages.

## Step 2: Read section {{section_number}}

In repo `{{guide_repo}}`, find the file at path `{{guide_path}}/{{section_number:02d}}-*.md` (two-digit number with leading zero).

Read the file in full.

## Step 3: Analysis across all 10 WRITING-PIPELINE stages

For each stage:
- Marker: ✅ compliant / ⚠️ partial / ❌ violated
- A specific finding with a quote from the text

## Step 4: Create the result file

Path: `{{pipeline_repo}}/specs/v4-reference/Review/section-{{section_number:02d}}-findings.md`

Structure:
```
# Findings for section {{section_number:02d}}

**Analysis date:** YYYY-MM-DD
**Analyzed by:** CCR Agent (claude-opus-4-7)
**Section:** <title from file header>

## Stage-by-stage analysis

### Stage 1: <title>
[marker] [finding]

... (all 10 stages) ...

## Summary

N/10 stages: ✅ N, ⚠️ M, ❌ K

## Priority findings

1. [P0/P1/P2] <specific correction proposal>
2. ...
```

## Step 5: Commit + push to main

```bash
cd /path/to/{{pipeline_repo}}
git checkout {{result_branch}}
git pull origin {{result_branch}}
mkdir -p specs/v4-reference/Review
git add specs/v4-reference/Review/section-{{section_number:02d}}-findings.md
git commit -m "review(WP-321): analysis of section {{section_number:02d}} per WRITING-PIPELINE"
git push origin {{result_branch}}
```

## Failure modes (CRITICAL)

- If `git push origin {{result_branch}}` returns an error (branch protection, permission, etc.):
  - **Do NOT create a feature branch + PR via `gh pr create`** (this creates navigational noise — root cause F1 WP-324).
  - Instead: write the full push error + analysis content + status `status: failed: branch protection` to chat output.
  - The Dispatcher will see the failure → mark the task failed → the pilot will manually decide how to bypass the protection.

- If section `{{section_number:02d}}` is not found in `{{guide_repo}}` — `status: failed: section not found`.

## Acceptance

- File `Review/section-{{section_number:02d}}-findings.md` exists on `{{result_branch}}` in `{{pipeline_repo}}`.
- Contains exactly 10 sections "Stage N: ...".
- Summary score N/10 is present.
- At least 1 priority finding is listed.
```