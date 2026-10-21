---
agents: single
argument-hint: <query or topic>
browser_safe: true
description: Load applicable principles for a task from the Pack → SPF → FPF hierarchy.
  Use when you need to find relevant principles before making a decision.
gates_enforced: []
gates_rationale: operational skill; WP Gate applicable only when creating a new WP,
  not for operational calls
gates_required: []
interaction: multi-step
layer: L1
name: fpf
routing:
  deterministic: false
  executor: haiku
status: active
triggers:
  phrases: []
  slash:
  - /fpf
version: 1.0.0
---

# Loading Principles

Request: $ARGUMENTS

## When to use

Load applicable principles for a task from the Pack → SPF → FPF hierarchy. Use when you need to find relevant principles before making a decision.

## Fallback Chain

```
Pack (domain-specific) → SPF (correctness) → FPF (first principles)
```

## Modes (determine from request context)

| Mode | Trigger | Action |
|-------|---------|-----------|
| **lookup** | Request contains a pattern code (A.7, B.5, F.18) or a specific term | Grep through FPF → exact section. Explain in engineering language (see `memory/fpf-reference.md` § Translation) |
| **review** | "Check", "verify against FPF", artifact submitted for review | Load artifact + relevant principles → point-by-point verification → findings |
| **design** | "Design", "how to do this per FPF", design task | Select applicable patterns (A.1 boundaries, A.6 composition, A.7 distinctions, B.5 ADI) → concrete recommendations |
| **characterize** | "Compare", "evaluate options", "how to choose" | A.17-A.19 (Lawful Comparison): criteria → indicators → evaluate options on a common scale |
| **teach** | "explain FPF", "what is FPF", "from scratch", "introduction" | Give an FPF overview: what it is, why it matters, key blocks (distinctions, patterns, first principles) → explain in engineering language without jargon |
| **diagnose** | "which principles am I violating", "what is wrong", "find the problem", "review my work" | Get a description of the work/solution → find deviations from FPF/Pack principles → name specific violations with the principle and its location |
| **prioritize** | "most important", "for a role", "in the role", "for me as" | Identify the role from the argument → find FPF/Pack principles relevant to that role → rank by applicability → explain why each matters for that role specifically |

**BLOCKING — No-Jargon:** Every FPF term in output → engineering equivalent in parentheses or in place of the term. No exceptions.
- Known terms: `memory/fpf-reference.md` § Translation (Holon, F-G-R, Alpha, Mereology, Affordance, ADI...)
- Unknown terms (TransformerRole, senseFamily, Γ_*, ReferencePlane, etc.): translate by context, add `(FPF: <original>)`. Do not leave any FPF term without translation.
- **Pre-output check:** scan the output — is there any term an engineer without FPF background would not understand? If yes — translate it.

## Algorithm

### 0. Verify you are reading the full text, not a reference

A link to FPF, a list of file names, or a truncated fragment is not access to the text (author rule, `FPF/USING-FPF.md`).

This step applies to the local copy of `FPF/` in the workspace. Paths below are relative to its root (`$IWE_WORKSPACE`); paths with spaces (`Engineering DPF Suite/...`) must be quoted. In the browser version where no local copy exists, or when search runs via MCP: read the document in full (`knowledge_get_document`) and name the source. If neither a local copy nor MCP access to the full text is available → state that the full text is unavailable and suggest installing a copy (`bash update.sh`) or connecting MCP.

- Confirm that `FPF/USING-FPF.md` exists and read it if you have not done so in this session: it is the author's general guide for searching and reading patterns.
- State the copy version: `git -C FPF log -1 --format='%h %ad' --date=short`. If the commit date is more than 30 days old or `USING-FPF.md` is missing → tell the user: the copy is outdated; run `update.sh` to update it (or manually `git -C FPF pull --ff-only` if the copy has no local edits).
- If the `FPF/` folder is missing or the required pattern is not in the full text → explicitly state "full text not accessible" and leave dependent conclusions open. Do not reconstruct patterns from memory.
- Search: `rg -n -i -C 2 --no-ignore -g '*.md' -- '<term in English and Russian>' FPF`. A match in a table of contents or index is not the pattern body.
- Read a complete pattern by ID (escape the dot in the ID with `\.`): `rg -U --no-heading --no-line-number --no-filename --color never '(?ms)^## <ID> [^\r\n]*\r?\n.*?^### <ID>:End[ \t]*\r?$' -- <file>`. If output is truncated → read the same file by line range.
- No `rg` (ripgrep) → use the same steps with `grep -rn -i --include='*.md' -- '<term>' FPF` (recursive, without `**`, which is not recursive in bash without globstar) and read by line ranges (`sed -n 'A,Bp'`): start at the line `## <ID> `, end at `### <ID>:End`.

### 1. Determine mode

Use the table above. If unclear — use lookup mode.

### 2. Classify the source

- Domain knowledge (architecture, domain, service) → source_type=pack
- Form, process, correctness → source=SPF
- Base distinctions, first principles → source=FPF

### 3. Search via iwe-knowledge

- `iwe-knowledge search(query="<query>", source_type="pack")` — across all Packs
- `iwe-knowledge search(query="<query>", source="SPF")` — across SPF
- `iwe-knowledge search(query="<query>", source="FPF")` — across FPF
- If the first level returns no results — follow the fallback chain

### 4. If iwe-knowledge is unavailable

(not in `/mcp`):
- Pack: read `PACK-*/pack/` files via Glob + Read
- SPF: read `SPF/docs/` via Glob + Read
- FPF: read `FPF/Readme.md` (overview) or search via Grep across `FPF/`
- DPF suites: alongside the specification, the FPF author publishes `FPF/Engineering DPF Suite/` (reference: `ENGINEERING-DPF-SUITE-REFERENCE.md`) and `FPF/Foundational Thinking DPF Suite/` (reference: `FOUNDATIONAL-THINKING-DPF-SUITE-REFERENCE.md`); these are not part of `FPF-Spec.md`. Entry rules are in `FPF/USING-FPF.md`: start from a real situation, select a suite via `FPF/Readme.md` and the suite reference; locate a pattern by its heading `## <ID> - …`, its end marker is `### <ID>:End`. If these folders are absent from the local `FPF/` copy, the copy is outdated — update it.

### 5. Show the result

List the relevant principles with an explanation of how they apply to the task. Include a reference to the source (github_url from the search result or the file path). **Translate FPF terms** into engineering language.

**Source at the end of the response.** State: which publication and copy version (commit), pattern numbers and sections used, what you are assuming, and what information is missing for a complete conclusion. Verbatim quotation is only necessary when verifying an interpretation, not in every response.

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
