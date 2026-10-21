---
agents: single
argument-hint: '[solution description]'
browser_safe: false
description: Assessment of an architectural decision across 7 EMOGSSB characteristics
  (v3.1 — admission filter, attribute-scenarios, advice from affected parties; profile
  without aggregate score, conjunctive screening). Use when a user proposes an architectural
  decision, a new tool, or a system-level change.
gates_enforced: []
gates_rationale: operational skill; WP Gate applicable only when creating a new WP,
  not for operational invocations
gates_required: []
interaction: multi-step
layer: L1
name: archgate
routing:
  deterministic: false
  executor: opus
status: active
triggers:
  phrases: []
  slash:
  - /archgate
version: 1.1.0
---

# ArchGate v3.1 — Architectural Decision Assessment

Assess the decision: $ARGUMENTS

## When to use

Assessment of an architectural decision across 7 EMOGSSB characteristics (v3.1 — admission filter, attribute-scenarios, advice from affected parties; profile without aggregate score, conjunctive screening). Use when a user proposes an architectural decision, a new tool, or a system-level change.

## Algorithm

## Extensions `before` (BLOCKING)

Before Step 0-A, load extensions exactly once per top-level invocation (the `before` phase is mandatory even on the fast track — the admission filter runs only after it completes):

```bash
bash .claude/scripts/load-extensions.sh archgate before
```

Exit code `0` → read each path from the output in alphabetical order and execute it.
Exit code `1` → no extensions; continue. Any other code, an extension error,
an explicit `BLOCK`/`STOP`, or a substantive reviewer objection inside an extension
blocks the start of the assessment: show the file path and the observed reason.

Each `before`/`checks` extension must end its instructions with an explicit marker:
`ARCHGATE_EXTENSION: PASS` or `ARCHGATE_EXTENSION: BLOCK — <reason>`.
A missing or unknown marker equals a blocking-phase error, not PASS.

**Recursion guard:** each phase — `before`, `checks`, `after` — runs at most once per top-level invocation. An extension must not invoke `/archgate`, reload `archgate.*`, or otherwise re-enter this lifecycle. Any recursion attempt is treated as a current-phase error: it blocks `before`/`checks`, and in `after` it produces a warning and is skipped.

Extensions are trusted local instructions; the text detector is a guard against accidental direct recursion, not a sandbox for hostile shell code. Do not execute any command or instruction assembled from an extension via `eval`, decoding, variable substitution, or concatenation. Treat an ambiguous indirect command as the same recursion error (BLOCK in `before`/`checks`, WARN and skip in `after`).

## Step 0-A. Admission Filter

> The criterion for "architectural significance" is cost-to-change (Levenchuk/ailev; Fowler: architecture is what is hard to change). The full gate applies to costly decisions; cheap, reversible decisions go through the fast track (WP-548 Phase 1: verification against industry practice).

Assess the decision on 3 axes. An axis is **high** when:

| Axis | High when |
|------|-----------|
| **Cost-to-change** | The change touches ≥ 3 independent delivery units (repository, deployed service, platform Skill/Script), OR modifies a data/API contract, OR modifies platform-protected files (list: `docs/critical-files-map.yaml`) |
| **Reversibility window** | Rollback requires a data migration or external notifications, OR exceeds 1 calendar day of work for one person |
| **External commitments** | Affects promises to users (SC), SLAs, security/PII, payments, or regulatory requirements |

- Any axis is high, OR there is any doubt → full gate (Step 0 and beyond). Doubt always resolves toward the full gate (an override valve, intentionally not formalized — it only errs on the safe side).
- All three axes are low → `core_result = fast_tracked`: Steps 0–4.6 are skipped, but the route does NOT bypass the publication contract — it must pass through Extensions `checks` (Step 4.7) and publication in Step 5. The Step 5 payload for a fast track: a mini-DRR using the "Fast-track" section of the template `.claude/templates/drr-template.md` (fixed fields: date, decision, one line per axis explaining why it is low, decision owner) — stored in the same location as full DRRs.
- The filter is part of the gate lifecycle: the recursion guard applies to it (an extension must not invoke Step 0-A or the core pipeline again).

## Step 0. Principles (BEFORE the assessment)

Verify the decision against Level 2 principles (DP.ARCH.001 §7). If the decision violates a principle, report it and propose a correction before proceeding to the assessment.

## Step 1. Three Questions for the User (BLOCKING)

> **STOP. Do not proceed to Step 2 until the user has answered ALL THREE questions.**
> Do not guess on the user's behalf. Do not decide yourself. ASK and WAIT for the answer.

**Question 1:** "Which 1–2 characteristics are critical for this decision?"

List ALL 7 characteristics with a preliminary relevance assessment for this decision:

| Characteristic | My relevance assessment | Why |
|----------------|------------------------|-----|
| Evolvability | high/medium/low | [1 sentence] |
| Scalability | high/medium/low | [1 sentence] |
| Learnability | high/medium/low | [1 sentence] |
| Generativity | high/medium/low | [1 sentence] |
| Speed | high/medium/low | [1 sentence] |
| Currency | high/medium/low | [1 sentence] |
| Security | high/medium/low | [1 sentence] |

Recommendation: "In my assessment, [X] and [Y] are critical. Do you agree, or are there others?"
Mark the answer: ❌ on a critical characteristic fixes `core_result = rejected` under
blocking rule #1. Stop further core assessment, but do not end the skill: the mandatory
route through Extensions `checks` in Step 4.7 remains in effect.

**Question 2 (A.19 Lawful Comparison):** "What alternatives were considered?"
- Answer: ≥ 2 options → build a comparison table (Step 2b).
- Answer: "none" / "only this one" → continue the assessment, but note in the verdict (Step 5): *"Assessment without comparison — lower confidence."*

**Question 3 (Advice Process — Harmel-Law "Facilitating Software Architecture"; ISO 42010 stakeholders):** "Who is affected by this decision, and whose advice should be gathered before a verdict?"
- List all affected parties (template users, neighboring agents/sessions, external services, future maintainers) and subject-matter experts.
- For system-level decisions, the default is a second opinion from a Peer partner (peer session; connected via the `archgate.checks` extension).
- All gathered advice is recorded in the DRR, in the "Advice from affected parties" section: who was consulted → what advice was given → what was accepted/rejected and why. "Nobody is affected" is a valid answer — it requires a justification, which also goes into the DRR.

**Ask all three questions in a single message. Wait for the answer. Only then proceed to Step 2.**

## Step 2. EMOGSSB Profile

Assess the decision across 7 characteristics. **No aggregate score — profile only.**

Scale:
- ✅ **Sufficient** — the characteristic is satisfied for this context
- ⚠️ **Weak** — risk is present; requires mitigation or conscious acceptance
- ❌ **Blocker** — the characteristic does not meet the minimum acceptable level

| Characteristic | Question | Status | Justification |
|----------------|----------|--------|---------------|
| **E**volvability | What breaks on change? Can a component be replaced without a cascade? | ✅/⚠️/❌ | [specific] |
| **M**asScalability | What happens at 10x load? Where is the bottleneck? | ✅/⚠️/❌ | [specific] |
| **O** (Learnability) | How much reading is needed to get started? Exoskeleton or prosthesis? | ✅/⚠️/❌ | [specific] |
| **G**enerativity | Does it create a platform? Does it work within the exocortex template? | ✅/⚠️/❌ | [specific] |
| **S**peed | Bot < 3 s, CLI < 1 s? Where is the latency? | ✅/⚠️/❌ | [specific] |
| **S** (Currency) | How do the best solve this problem? What is missing from SOTA? | ✅/⚠️/❌ | [specific] |
| **B** (Security) | What are the threats? PII, secrets, injection surface? Lock-in? See checklist §B below. | ✅/⚠️/❌ | [specific] |

### 2a. Attribute-Scenarios for Critical Characteristics (mandatory)

> ATAM (SEI): attribute-scenarios are assessed, not abstract qualities. "Abstractly green" is not allowed.

For each characteristic identified as critical in Step 1, provide at least one concrete scenario: **stimulus → environment → expected response**, plus business importance (why this scenario matters to the business). A critical characteristic without a scenario cannot receive ✅ — the maximum is ⚠️ with the note "assessment without scenario."

### 2b. Comparison Mode (multiple options)

If ≥ 2 options are provided, build a summary table:

| Characteristic | Option A | Option B | ... |
|----------------|----------|----------|-----|
| Evolvability | ✅/⚠️/❌ | ✅/⚠️/❌ | |
| Scalability | ✅/⚠️/❌ | ✅/⚠️/❌ | |
| Learnability | ✅/⚠️/❌ | ✅/⚠️/❌ | |
| Generativity | ✅/⚠️/❌ | ✅/⚠️/❌ | |
| Speed | ✅/⚠️/❌ | ✅/⚠️/❌ | |
| Currency | ✅/⚠️/❌ | ✅/⚠️/❌ | |
| Security | ✅/⚠️/❌ | ✅/⚠️/❌ | |
| **Preliminary core result** | READY/BLOCKED | READY/BLOCKED | |

Recommended option: the fewest ⚠️ with no ❌ on critical characteristics.

### Coordination cost check (multi-agent/multi-system decisions)

Three conditions for multi-agent: (1) context isolation, (2) parallelism gain, (3) tool specialization.
All three NOT met → single-agent.

### Security Checklist (§B) — WP-212 B7.1

Apply when assessing the **Security** characteristic. Answer each item briefly.

**Auth & Access:**
- Does the component require authentication? Is JWT verified locally (JWKS), not by trusting headers? (ADR-IWE-012)
- Is there authorization (subscription check / RBAC)? If not — ⚠️.
- Can tool arguments substitute a user's identity? (e.g., `user_id` in the request body — it must come from the JWT, not from the body)

**Secrets:**
- Are there new secrets? Where are they stored (Cloudflare secrets / GHA secrets / `.secrets/`)? Not hardcoded?
- Has the B2.1 Secrets Inventory been updated?

**Data Classification (B7.3.1) — BLOCKING for Work Products with PII / payment_credentials / secrets:**

Source of truth: `C.IT-Platform/C2.IT-Platform/C2.2.Architecture/Data-Governance/B7.3.1-l2-data-classification-map.md` in your ecosystem-development repository, if one exists. If a sensitive class is involved, complete all 6 items:

1. **Data class?** public / PII / payment_credentials / secrets — determine by the tests in §1 B7.3.1. If only public → skip the rest of §B.
2. **Layer?** L1 / L2 / L3 / L4 — check the B7.3.1 §2 table "which classes may reside where." Placement prohibited by the table = ❌.
3. **Logging** complies with §3.1 B7.3.1? PII only as masked/type-without-value; payment_credentials and secrets are prohibited in any form. Otherwise ❌.
4. **Encryption at-rest + column-level** complies with §3.2? Column-level Fernet is mandatory for secrets/payment_credentials. Otherwise ❌.
5. **RLS policy** exists for user-level ownership? If not — BLOCKER before the first insert to prod.
6. **Cross-user aggregation** complies with §3.5 (k-anonymity k=10 for groupings, consent for individual rows)? Exporting PII to an external system without a DPA = ❌.

**Injection & Input:**
- SQL: parameterized queries? No whitelist of dynamic names? (otherwise ⚠️)
- Commands: is shell injection possible?
- MCP tools: are arguments sanitized before SQL/shell?

**Encryption:**
- OAuth tokens in the database — are they encrypted? (B2.5 pending — mark as ⚠️ until resolved)
- HTTPS everywhere? TLS to the database (Neon — yes by default)?

**§B Summary:** if ≥ 2 items are ❌, or PII is being logged → Security = ❌ (blocker).

### Currency Checklist (§C)

Priority trio (always):
1. **Context Engineering** (DP.SOTA.002): Write/Select/Compress/Isolate — what is in the agent's context?
2. **DDD Strategic** (DP.SOTA.001): Is the Bounded Context defined? Is the Ubiquitous Language consistent? Is there a Context Map?
3. **Coupling Model** (DP.SOTA.011): Have knowledge/distance/volatility coupling been assessed?

Full reference: `memory/sota-reference.md`.

## Step 3. Veto Filter (Conjunctive Screening)

> Principle: non-compensatory. A high status on one characteristic does NOT compensate for a blocker on another.

Check each rule explicitly and output the result for each one separately:

**Rule 1. Critical characteristics.**
List the characteristics marked as critical in Step 1 and their status from Step 2.
Example: "Security (critical) → ⚠️ — rule did not trigger."
→ Output: triggered / did not trigger.

**Rule 2. Number of blockers (❌).**
List all characteristics with status ❌ from Step 2 (by name).
Example: "No ❌ found" or "❌ Security, ❌ Evolvability — total 2."
→ Output: [N] blockers — triggered (N ≥ 2) / did not trigger (N < 2).

**Rule 3. Ratio of ⚠️ to ✅.**
List all ⚠️ and all ✅ from Step 2 (by name).
Example: "⚠️ Evolvability, Currency, Security (3) | ✅ Scalability, Learnability, Generativity, Speed (4)."
→ Output: triggered (≥ 4 ⚠️ and 0 ✅) / did not trigger.

**Preliminary core result (do not yet publish as a verdict):**
- At least one rule triggered → stop further core assessment.
  Fix `core_result = rejected` and the blocking conditions. Steps 4–4.6 do not run
  for a rejected decision (`DRR = N/A`); proceed to the shared Extensions `checks`
  point (Step 4.7). Do not bypass `checks` by jumping directly to Step 5.
- No rules triggered → **Decision passes the veto filter** → Step 4.

## Step 4. Domain Extensions (L2)

> L2 = informational (not blocking until proven in practice). Full description: DP.M.005 §9.

**4a. Identify triggers:**

| Trigger | L2 characteristic |
|---------|-------------------|
| User-data storage format, data schema, vendor/API dependency | **Data portability** (L2.1) |
| AI system (Zone A), Intervention Loop, non-deterministic component | **Observability** (L2.2) |
| AI assessment of a user (qualification, progress, recommendation, feedback) | **Explainability** (L2.3) |
| Assessment/measurement (digital twin, metrics, stage, score) | **Reproducibility** (L2.4) |
| Automatic action on behalf of a user | **Controllability** (L2.5) |
| Data migration, storage, digital twin schema | **Knowledge preservation** (L2.6) |
| External Integration, exchange Protocol, MCP Registry | **Interoperability** (L2.7) |
| New automated process (agent, Pipeline, Script with LLM call) or change in frequency/volume of existing calls | **Economy** (L2.8) |

No trigger fired → skip the L2 assessment only and continue from Step 4.5.

**4b. Assess triggered L2 items (also ✅/⚠️/❌, no numeric scale):**

Checklists: DP.ARCH.001 §4.8–4.15 (Economy — §4.15: three questions — reflex-first instead of LLM where logic is formalizable; model sized to the task, not oversized; is spending visible before it becomes a problem?). Format:

```
Domain extensions:
  Trigger: [component] → [L2 characteristic]

| [Characteristic] | Status   | Justification |
|------------------|----------|---------------|
| Question 1       | ✅/⚠️/❌ | ...           |
| Question 2       | ✅/⚠️/❌ | ...           |
| Question 3       | ✅/⚠️/❌ | ...           |
| **L2.N total**   | ✅/⚠️/❌ | Informational |
```

L2 verdict: ✅ (no ❌), ⚠️ (1–2 ❌), ❌ (≥ 3 ❌) — a recommendation, not a blocker.

## Step 4.5. NBR — Negative Branch Reservation

> Source: TOC Thinking Processes (Goldratt / Dettmer); Schragenheim S&T tree "monitoring entries." Cheap, powerful, prevents foreseeable damage.

After the decision has passed the veto filter (Step 3) and L2 (Step 4), but **before** final feedback — build 3 negative branches:

"If the chosen decision is implemented, **what bad things could happen** within 1–4 weeks afterward? List the 3 most likely negative consequences (in descending order of probability or damage."

For each branch — provide a **trim** (how to mitigate it, or why the branch is untrimmable):

| # | Negative branch | Probability | Damage | Trim |
|---|-----------------|-------------|--------|------|
| 1 | [what breaks / what risk materializes] | low/medium/high | low/medium/high | [specific mitigation] or **untrimmable** |
| 2 | ... | ... | ... | ... |
| 3 | ... | ... | ... | ... |

**Decision rule:**
- All 3 branches trimmable → proceed to Step 4.6.
- ≥ 1 untrimmable + high damage → **revision** of the option (roll back to Step 2 with refinements).
- ≥ 1 untrimmable + medium damage → record a ⚠️ flag, continue from Step 4.6,
  and at publication in Step 5 require an explicit acknowledgement from the user.

**Anti-pattern:** writing "everything will be fine" / "risks are minimal" / generic phrases without specifics. NBR only works when branches are **specific** (what exactly, which component, which stakeholder).

## Step 4.6. DRR Adequacy Pass

> Verify that the decision has moved from a declaration to an operationalizable contract.

After NBR, before issuing the final verdict, run the **DRR Adequacy Pass**:

| # | Question | Why it matters | Status |
|---|----------|----------------|--------|
| 1 | Is the decision operationalized: is there a checklist, test, or invariant that verifies its fulfillment? | Declaration ≠ working mechanism | ✅/⚠️/❌ |
| 2 | Does the detector/gate actually block, rather than merely existing in a document? | Having a rule does not stop an action | ✅/⚠️/❌ |
| 3 | Is there a forcing function or an explicit acknowledgement from the user? | Showing a prompt ≠ requiring an answer | ✅/⚠️/❌ |
| 4 | Has the contract/promise been verified by an acceptance pass (verify-pass, smoke, canary, acceptance report)? | A promise made ≠ fulfillment measured | ✅/⚠️/❌ |
| 5 | Is the decision record maintained in a single location (OwnerIntegrity)? | One fact — one place | ✅/⚠️/❌ |
| 6 | Is a review date or condition specified? | A decision goes stale without `review_date` / `superseded_by` | ✅/⚠️/❌ |
| 7 | What automatic control (fitness check) guards the critical characteristic after implementation? | A one-time assessment ≠ ongoing guard: degradation must be caught by a mechanism, not by memory (Principle #27 Intervention Loop; fitness functions — Ford/Parsons) | ✅/⚠️/❌ |

**Rules:**
- ≥ 1 ❌ → the decision is not ready for a final verdict; return to Step 2 and add operationalization detail.
- ≥ 3 ⚠️ → a final verdict is possible, but must carry a mandatory ⚠️ flag and explicit acknowledgement.
- Otherwise → DRR Adequacy Pass is complete.

**DRR draft:** prepare the data using the template `.claude/templates/drr-template.md`,
but do not record the decision as accepted until `checks` have passed, all required
acknowledgements have been received, and the final verdict has been issued.

## Step 4.7. Extensions `checks` (BLOCKING)

After the DRR (or `DRR = N/A` for a decision rejected by the core, or
`core_result = fast_tracked` from Step 0-A), but before publishing
the verdict, load checks exactly once:

```bash
bash .claude/scripts/load-extensions.sh archgate checks
```

Exit code `0` → read and execute each file in alphabetical order. Exit code `1` →
no checks. A loader/execution error or a recursion attempt blocks publication:
return `extension_check_error`, the path, and the observed reason. An explicit `BLOCK`/`STOP`
or a substantive reviewer objection blocks publication with type
`extension_check_blocked`, the path, and the reason. After such an outcome Step 5 is
prohibited; any fix must be verified by a new top-level invocation in which each
lifecycle phase runs exactly once.

The marker `ARCHGATE_EXTENSION: BLOCK` always yields `extension_check_blocked`;
`ARCHGATE_EXTENSION: PASS` permits the transition only after all files have succeeded.

## Step 5. Verdict Publication and Feedback

This is the only point at which the result is named and shown to the user as a verdict.

If `core_result = rejected`, do not request mandatory risk acknowledgements:
after successful `checks`, publish the negative verdict immediately. A decision that is
already blocked must not be held in `pending_ack` by asking the user to "accept the risk."

If `core_result = fast_tracked` (Step 0-A), after successful `checks` publish
the lightweight verdict: "Decision passed via fast track (all admission axes are low)" +
mini-DRR (the "Fast-track" section of the template). No mandatory risk acknowledgements
are required — the fast track does not generate risk flags; the `after` phase runs as normal.

Only if the core has passed, **first collect mandatory acknowledgements.** For
each ⚠️ (L1), and for any NBR/DRR flags that require acknowledgement, request an explicit decision:
> "[Characteristic] ⚠️. Choose: (a) accept the risk — [justification]; (b) mitigate — [specific action]."

Until a mandatory response is received, the state is `pending_ack`; this is not a verdict,
the DRR is not finalized, and the `after` phase does not start. If mitigation is chosen,
the revised decision must go through a new top-level ArchGate invocation from the start of
the lifecycle (Extensions `before`, Step 0-A).

**After all mandatory acknowledgements, publish exactly one verdict:**

- If `core_result = fast_tracked`: lightweight fast-track verdict (paragraph above).
- If `core_result = rejected`:
  > "The decision does NOT pass ArchGate. Blocking conditions: [list]. Recommendation: [what to fix]."
- If the core passed and all mandatory risks have been accepted or resolved:
  > "The decision passes ArchGate."

Only after a passing verdict is published, finalize the DRR as an accepted decision
using the template `.claude/templates/drr-template.md`. If `core_result = rejected`,
do not record the decision as accepted; the draft remains unfinalized until a new
successful assessment.

For each ⚠️/❌ (L1) → provide feedback using these principles:
- Consult DP.ARCH.001 §7.1 (principle coverage)
- Principle exists and the decision contradicts it → revise
- Principle exists but is weak → strengthen it
- Principle does not exist → propose one (level: 2nd = domain, 3rd = ADR)

## Extensions `after` (DOES NOT CHANGE THE VERDICT)

After the verdict is published (and, for a passing branch, after all mandatory
explicit acknowledgements from Step 5 have been received), load extensions exactly once:

```bash
bash .claude/scripts/load-extensions.sh archgate after
```

Exit code `0` → read the files in alphabetical order and execute each one, continuing
to the next even after a previous one fails. Exit code `1` → no extensions. For any
other code, still execute each valid path that the loader managed to write to stdout,
and show each stderr diagnostic as a separate warning with the path and reason.
Do not execute a damaged file or a recursion attempt. The `after` phase cannot
overwrite, revoke, or downgrade a verdict that has already been published.

For a diagnostic outcome, `after` may use
`ARCHGATE_EXTENSION: WARN — <reason>`; a `BLOCK` after the verdict is also treated
only as a warning.

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
