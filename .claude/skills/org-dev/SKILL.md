# /org-dev — Organizational Development Manager (R31)

> ⚡ **Algorithm, not a free conversation.** Steps 0a → 0 → 1 → 2 → 3 → 4 execute in sequence. Wait for a response after each question. Do not issue recommendations before completing the applicability check.

> **Boundary:** WD (work development). If the request is clearly about PD (worldview, "why am I here", personal growth without a work context) → decline + CTA to Navigator (R27).

## Skill contract

- **Input:** subject's request for change (self / team / organization).
- **Output:** concrete first step ≤30 min + entry in personal-guide / team-guide / org-guide.
- **Time:** ~10–15 min dialogue.
- **Does not:** maintain a long-term trajectory (Tailor R28-catalog); work with worldview (Navigator R27); write a new Pack (R30).

## Step 0a — Read subject context

1. Identify the subject from the request: `self` | `other_person` | `team` | `organization`.
2. Locate the context:
   - `subject = self` → `${IWE_WORKSPACE:-$HOME/IWE}/PACK-personal/personal-guide/`
   - `subject = team` → `${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}/team-guide/`
   - `subject = organization` → `${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}/org-guide/`
3. Read the last ≤5 entries in `## Org-Dev Session YYYY-MM-DD` blocks to avoid contradicting previous recommendations.
4. If the context file is missing — mark "first interaction" and continue.

Log: create `${IWE_WORKSPACE:-$HOME/IWE}/.claude/state/org-dev-session-YYYY-MM-DD-NN.yaml` (NN = incremental daily counter); write `subject` and `request_raw`.

## Step 0 — MIM.M.030 classifier (7 questions)

Explain to the subject in one sentence: "I will ask 7 short questions to identify the type of system to change. Answer A / B / C."

Ask questions **strictly one at a time**, wait for the answer, and accumulate weights in `scores = {personality, team, organization}`.

### Q1. What is the scale of the system you want to change?

- **A.** Myself (my behavior, habits, thinking) — `+3 personality`
- **B.** My team / family / immediate circle (3–10 people) — `+2 team`
- **C.** My organization / company / community (>10 people, has structure) — `+3 organization`

### Q2. Where does the root of the problem currently lie — in me, in the relationships between people, or in structure/processes?

- **A.** In me (I understand that my behavior produces the result) — `+3 personality`
- **B.** In relationships (people do not agree, roles are unclear, conflicts exist) — `+3 team`
- **C.** In structure (processes break down, scaling causes failures) — `+3 organization`

### Q3. Who else, besides you, is involved in the change?

- **A.** No one — I am working on myself alone — `+3 personality`
- **B.** Specific people (I can name them), we interact regularly — `+3 team`
- **C.** Many people I do not know personally; the change concerns positions, not individuals — `+3 organization`

### Q4. Which tool feels more intuitive: practice and reflection / roles and agreements / processes and metrics?

- **A.** Practice and reflection (exercises, journaling, self-observation) — `+3 personality`
- **B.** Roles and agreements (RACI, contracts, regular meetings) — `+3 team`
- **C.** Processes and metrics (workflow, KPIs, dashboards, regulations) — `+3 organization`

### Q5. What time horizon do you see for the change?

- **A.** Weeks (I want to feel a shift within a month) — `+3 personality`
- **B.** Months (changes in a team take 3–6 months) — `+2 team`
- **C.** Years (company transformation is a long cycle) — `+3 organization`

### Q6. What triggered this request?

- **A.** Internal discomfort (I am dissatisfied with myself) — `+3 personality`
- **B.** External conflict (with a colleague, within the team) — `+2 team`
- **C.** External pressure (market, regulator, competitors, stakeholders) — `+3 organization`

### Q7. What will change first if the plan works?

- **A.** My actions (I will start doing things differently) — `+3 personality`
- **B.** Our interactions (we will start reaching agreements differently) — `+3 team`
- **C.** Our processes (documents, regulations, and metrics will change) — `+3 organization`

### Scoring

```
dominant = max(scores, key=scores.get)
second   = second highest score
margin   = scores[dominant] - second
```

If `margin < 3` → ask 1–2 clarifying questions (see MIM.M.030 §"Ambiguity threshold"):
- personality + team: "If you could change only one thing — yourself or how you interact with the team — which would it be?"
- team + organization: "Does the change concern specific people in the team, or the roles (positions) they occupy?"
- personality + organization: "Is this a case where you, as a leader, must change yourself to change the organization, or is it sufficient to change the structure/processes independently of you?"

After clarification — recalculate scoring and repeat the check. If `margin < 3` a second time — escalate to R5 (IWE Architect) and end the skill.

Otherwise → `system_type` ∈ {personality, team, organization}. Write to session-yaml.

## Step 1 — Applicability (3 conditions)

Ask 3 questions:

1. **Autonomy:** "Do you have the authority to change this subject?" (yes/no)
2. **Consent:** "If the subject is another person/team, do they explicitly consent to the change?" (yes/no/n-a; for `subject = self` — implicit yes)
3. **Charter (mandate):** "Is there an explicit mandate (formal or implied) for the organizational change?" (yes/no)

If at least one answer is `false` → decline + explain the boundary. **Do not issue a method.** Write `applicability: failed, reason: <condition>` to session-yaml. End the skill.

## Step 2 — R28 Diagnostician (subject readiness)

Goal: obtain the subject's `cp.iwe`.

- **VS Code mode** (Bash available): attempt via `mcp__claude_ai_IWE__dt_read_digital_twin` (path `1_declarative/cp_profile`) or via a psycopg2 query to `learning.cp_assessments` (for self-subject).
- **Browser mode**: use the same `mcp__claude_ai_IWE__dt_read_digital_twin`.

Routing:
- `cp.iwe ≥ 2` → proceed to Step 3.
- `cp.iwe < 2` → downshift: micro-steps (≤15 min), plus CTA: "First, work with Navigator (R27) to raise readiness to cp.iwe=2."
- cp unavailable / no assessment → ask 1 clarifying question: "How much experience do you have applying systematic work methods? (0=none / 1=heard of them / 2=tried / 3=use regularly / 4=teach others / 5=instruct formally)"; default cp.iwe=2 if the subject declines to answer.

Write `cp_iwe` to session-yaml.

## Step 3 — Routing to guidance (MIM.M.031)

Load the MIM.M.031 routing-table (Pack file in the MIM pack repository; locate via `grep -rn "^id: MIM\\.M\\.031"` or Read at the canonical location in `${IWE:-$HOME/IWE}/PACK-${IWE_MIM_NAME:-MIM}/pack/mim/03-methods/`).

Apply the routing-table:

| `system_type` | primary | discipline |
|---------------|---------|------------|
| personality | R9 (personality-engineering) | PE |
| team | R10 (systems-management) | SM |
| organization | R8 (systems-engineering) | SE |

If `cp.iwe < 3` → add **foundation = R1** (firefighting) — recommend it BEFORE the primary.

Trigger-matching on the request (optional):
- Contains "cannot see the system / distinctions / description language" → foundation = R5 (systems-thinking).
- Contains "choosing a method / method vs. work" and `cp.iwe ≥ 3` → foundation = R7 (methodology).

Retrieve `first_step_pointer.action_template` from the guidance YAML.

## Step 4 — First step + record

Formulate a **concrete first step ≤30 min** using the `action_template` from MIM.M.031, adapted to the applicability result and the subject context from Step 0a.

Write a new block to the subject's `personal-guide / team-guide / org-guide` (via Write or Edit; for self — `${IWE_WORKSPACE:-$HOME/IWE}/PACK-personal/personal-guide/CURRENT.md` or equivalent):

```markdown
## Org-Dev Session YYYY-MM-DD

**Request:** <one phrase>
**System type:** <personality|team|organization> (score: personality=N/team=N/organization=N, margin=M)
**Method:** <PE|SM|SE>
**Guidance:** <R8|R9|R10> + (if applicable) foundation: <R1|R5|R7>
**First step:** <action ≤30 min>
**Applicability:** autonomy=Y/N, consent=Y/N/n-a, charter=Y/N
**Readiness (cp.iwe):** <N>
**Next check-in:** in <N> days
```

If the context file does not exist — create it (`personal-guide/CURRENT.md` or equivalent); if it exists — append.

Finalize session-yaml: `status: completed`.

Report to the subject:
1. System type + score (one line).
2. Method + guidance (path).
3. First step (action template, concrete, ≤30 min).
4. When to return ("in N days — we will review what happened").

## Failure modes

| ID | Condition | Behavior |
|----|-----------|----------|
| FM.01 | Method issued without R28 (cp.iwe unknown) | Do not issue. Return to Step 2. |
| FM.02 | Method issued without MIM.M.030 (system type not determined) | Do not issue. Return to Step 0. |
| FM.03 | `margin < 3` without clarification | Do not issue. Ask 1–2 clarifying questions. |
| FM.04 | Issued without applicability check (at least 1 condition = false) | Decline + explain the boundary. |
| FM.05 | Attempt to run a PD program instead of WD (worldview, personal growth) | CTA to Navigator R27. |
| FM.06 | `first_step_pointer.path` does not exist / section is empty | Fall back to the guidance catalog + interactive sub-section selection with the subject. Log to `learning.guide_routing_misses`. |
| FM.07 | `MIM.M.031` file is missing | FAIL skill (contract violated). Notify the pilot: "MIM.M.031 not found — it must be created (F2.1 WP-377)." |

## Neighbors (Pack distinctions, excerpt from DP.ROLE.063 §5)

### Tailor (DP.ROLE.001 §3.2, catalog-only) vs R31

| Comparison | Tailor | R31 Organizational Development Manager |
|------------|--------|----------------------------------------|
| **Object** | personal-guide of one pilot | organizational change for a subject (individual/team/organization) |
| **State** | cp-profile + learning trajectory (long-term) | first step + applicability check (one-time) |
| **Mode** | long-term accompaniment (weeks–months) | one-time diagnosis + routing (minutes–hours) |
| **Overlap** | organizational change requires a new Pack → call R30 | applying the method requires updating personal-guide → fix via Tailor |

### R27 Navigator vs R31

| Comparison | R27 Navigator | R31 Organizational Development Manager |
|------------|---------------|----------------------------------------|
| **Program** | PD (personal development) | WD (work development) |
| **Trigger** | "personal growth / worldview / why am I here" | "work chaos / org structure / team" |
| **Overlap** | stages 3–4 — both may apply | the program determines the priority |

## Sources

- `DP.SC.049` — Organizational Development Manager promise (8-step contract).
- `DP.ROLE.063` — role carrier R31.
- `MIM.M.030` — system type classifier (Step 0).
- `MIM.M.031` — guidance routing-table (Step 3).
- WP-377 (F2.5 — this skill), WP-369 (DP.ROLE.063 + DP.SC.049 + MIM.M.030).
