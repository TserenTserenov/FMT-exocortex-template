---
agents: single
browser_safe: false
description: Classifies raw pilot request → structured JSON {task_type, class, artifact,
  budget_estimate, confidence, routing_tag, resolution_path, schema_version, result_type,
  expected_result_kind, result_kind_resolution, hypothesis_relation}. Keyword-fast
  (<200ms) or Haiku fallback (<60s). Does NOT create WP or call executor.
gates_enforced: []
gates_rationale: operational skill; WP Gate applicable only when creating a new WP,
  not for operational invocations
gates_required: []
interaction: multi-step
layer: L1
name: artifactor
owner_role: DP.ROLE.058
related:
- DP.SC.160
- DP.ROLE.058
- DP.ROLE.059
routing:
  deterministic: false
  executor: sonnet
status: active
triggers:
  phrases: []
  slash:
  - /artifactor
version: 1.1.0
---

# /artifactor — Artifactor-Postmaster

> **Role:** DP.ROLE.058 Artifactor-Postmaster
> **Trigger:** request without routing-tag (Router → Artifactor) or `/artifactor "text"`
> **Service Clause:** DP.SC.160

## When to use

Classifies raw pilot request → structured JSON {task_type, class, artifact, budget_estimate, confidence, routing_tag, resolution_path, schema_version, result_type, expected_result_kind, result_kind_resolution, hypothesis_relation}. Keyword-fast (<200ms) or Haiku fallback (<60s). Does NOT create WP or call executor.

## Promise (contract)

**Input:** raw pilot request text (any length, no routing-tag)
**Output:** JSON, schema_version 3 (WP-575 Phase 2 — field `result_type` added) → stdout:

```json
{
  "task_type": "string",
  "class": "trivial | closed-loop | open-loop | problem-framing",
  "artifact": "string (single line in Russian — noun denoting the result)",
  "budget_estimate": "~Xh | ?",
  "confidence": "high | low",
  "routing_tag": "string",
  "resolution_path": "keyword | llm",
  "schema_version": 3,
  "result_type": "system | episteme | unresolved",
  "expected_result_kind": "kind_id from PACK-digital-platform/pack/digital-platform/result-kinds-registry.yaml | null",
  "result_kind_resolution": "static | deferred-to-session | unresolved",
  "hypothesis_relation": "unclassified"
}
```

**Invariants:**
- Does NOT create a Work Product, does NOT call an executor, does NOT ask clarifying questions.
- `confidence=high` only on keyword path; `confidence=low` on LLM path.
- Request under 5 words: return `{"error": "INSUFFICIENT_INPUT"}`, stop.
- `budget_estimate: "?"` only for `problem-framing` or complete ambiguity.
- `result_type` (WP-575 Phase 2, hard-distinctions.md #36) — Executor (`system`: agent/script/service — something that runs) vs Information object (`episteme`: document/knowledge/rule — something that is read). Resolved BEFORE the artifact name and task class; it is an independent axis from `expected_result_kind` and is NOT derived from `kind_id` (the tuple `kind_id`/`task_type`/`class` is assigned simultaneously; deriving from it would violate "before name and class," and `kind_id` was created for a different distinction). `unresolved` — type is not obvious → forces pilot clarification at WP Gate; the classifier does NOT guess (same principle as `hypothesis_relation: "unclassified"` below).
- **Routing by `result_type`** (performed by the consumer — `/wp-new`/WP Gate Ritual, not the Artifactor itself; same principle as passing `hypothesis_relation` to WP Gate): `system` → IntegrationGate check required (novelty of tool/agent/script/service); `episteme` → Routing Gate (document/knowledge placement map, `DP.KR.001 §5`); `unresolved` → pilot clarification before proceeding.
- `expected_result_kind` — discriminator for the expected result kind (WP-481 Phase 7, "there is no generic result"); NOT an indicator of verification readiness (`gate_ready` is the concern of `/verify`, not the Artifactor).
- `result_kind_resolution: "unresolved"` — no kind in the registry fits; the classifier does NOT substitute the nearest one (anti-leak into supertype).
- `result_kind_resolution: "deferred-to-session"` — meta-trigger (e.g. `peer_session`); kind is resolved inside the process itself, not at classification time.
- **stdout = CONFIG_ERROR** (exit 3) → kind registry is unreadable or has drifted relative to `KEYWORD_MAP` — fail-closed, escalate to pilot, do not ignore the field.
- Pass `hypothesis_relation: "unclassified"` in the handoff to WP Gate. Until one of `tests | enables | responds | researches | operational` is chosen, the Work Product remains pending and must not be started.

## Strategic basis for a Work Product

The Artifactor must not assign a hypothesis to a Work Product without a pilot decision. It must pass the following question to WP Gate:

- `tests H-NNN` — the Work Product tests a single bet;
- `enables H-NNN` — makes that bet measurable or testable;
- `responds H-NNN` — follows from the verdict;
- `researches` — seeks a basis for a new hypothesis;
- `operational` — maintains a norm, resolves an Incident, or fulfills an obligation.

The first three require a single `H-NNN`. The last two do not take a hypothesis number. The `unclassified` relation is visible on the Work Product card and blocks its start, but not its creation: this preserves reversibility and does not break existing automations.

## Algorithm

### Step 1. Keyword lookup

Run the script (returns JSON or a signal):

```bash
S="${IWE_SCRIPTS:-$HOME/IWE/scripts}"
PY3="$(bash "$S/lib/find-python3.sh")" && "$PY3" "$S/artifactor.py" "$ARGUMENTS"
```

Interpreting the result:
- **stdout = JSON with `result_type: system|episteme`** (exit 0) → return to pilot, stop.
- **stdout = JSON with `result_type: unresolved`** (exit 0) → proceed to Step 2 and evaluate the full meaning of the request, including any explicit pilot clarification. The keyword answer does not account for clarification added after a general trigger ("implement the plan"); repeating the same keyword answer after clarification is not allowed. If the primary result is still unknown, Step 2 keeps `unresolved` for the consumer to resolve.
- **stdout = INSUFFICIENT_INPUT** (exit 1) → return `{"error": "INSUFFICIENT_INPUT"}`, stop.
- **stdout = NO_KEYWORD_MATCH** (exit 2) → proceed to Step 2.
- **stderr contains CONFIG_ERROR** (exit 3) → kind registry is unavailable or has drifted — escalate to pilot in one line, do NOT proceed to Step 2 (this is not "no keyword match"; it is a Configuration failure).

### Step 2. LLM classification (on NO_KEYWORD_MATCH or unresolved)

Populate all fields using the rules below. Return JSON with `resolution_path: "llm"`, `confidence: "low"`, `schema_version: 3`. For `expected_result_kind`/`result_kind_resolution` — apply the same logic as the keyword path: select a `kind_id` from `PACK-digital-platform/pack/digital-platform/result-kinds-registry.yaml` by meaning; if none clearly fits — `expected_result_kind: null`, `result_kind_resolution: "unresolved"` (do not substitute the nearest one).

**Step 2.0 — result type (WP-575 Phase 2, FIRST question, before name and class).** Before formulating `artifact`/`class`, answer: will the output of this work be an active system (agent, script, service, MCP tool, bot, automation — something that will EXECUTE) or an information object (document, knowledge, rule, report, plan — something that will be READ)?
- If both are named as independent results with no primary indicated, or neither is defined → `result_type: "unresolved"`, do not guess (same discipline as `result_kind_resolution: "unresolved"`). A document produced by the script being built is a system output; documentation for it is a supporting result. This does not make the type ambiguous if the primary result is explicitly stated. A description of a service without its implementation is `episteme`.
- One characteristic clearly dominates → `result_type: "system"` or `"episteme"` accordingly.
- Example: "create a new bot for X" → `system`. "write a guide for Y" → `episteme`. "finish the loose ends of Work Product N" with no specification of what remains → `unresolved` (could be code or a document).

**Rules for `class`:**

| Class | Criterion |
|-------|-----------|
| `trivial` | Protocol with no ambiguity (Day Open, Week Close, peer session) |
| `closed-loop` | Clear specification + known method (bug fix, Migration, Review, triage) |
| `open-loop` | No specification; output must be generated (content plan, diagnosis, scenarios) |
| `problem-framing` | Vague; method unknown (ideas, concepts, "figure something out for X") |

When in doubt, choose the broader class (open-loop, not closed-loop).

**Rules for `artifact`:** one line, first word is a noun denoting a document, system, or system state (not a process/action — "Breakdown of X", "Analysis of X", "Verification of X" are not valid, even though they are grammatically nouns).
Examples: "List of topics for three posts", "Latency diagnostics report", "Scenario brief".
Not like this: "Breakdown of 88 unreviewed commits" (describes an action) → like this: "Registry of unreviewed commits in branch X" (describes the result artifact).

**General "process → result" test (WP-7 Phase 140, peer session 2026-09-11 with Kimi+Codex).** The specific examples above do not catch deverbal nouns without an object X ("Payment", "Migration", "Integration", "Synchronization") — grammatically nouns, but semantically they name the action itself. Before accepting an `artifact` value:
1. Convert the candidate back to a verb: "Payment" → "to pay", "Integration" → "to integrate", "Synchronization" → "to synchronize", "Migration" → "to migrate". If the conversion is natural → the candidate names a process, not a result — reject it.
2. Ask: "what specifically will exist, or in what verifiable state will the system be after this work?" — name that object/document/state, not the work itself.
3. Name the item that can be opened and verified after the work: a file, folder, service, or verifiable state. The first word is the name of that item ("Registry", "Regulation", "Channel", "Report", "Work Products").

A participle applied to an existing noun preserves the old object and attaches a status to it. Do not name artifacts this way.
- Not "Implemented plan". The plan already existed. What appears is the Work Products derived from that plan, their cards and files. Name: "Work Products from the plan".
- Not "Configured payment channel". The subject is the channel itself. Name: "IWE Workshop payment channel via Aisystant and Telegram".
- Not "Updated strategy". The subject is the strategy document. Name: "Strategy document".
- Not "Rotated secrets". The subject is the secret records in the vault. Name: "Secrets in the vault".

Example: not "Payment for IWE Workshop via Aisystant and Telegram channel" (payment → to pay — the work itself), but "IWE Workshop payment channel via Aisystant and Telegram".

The test also applies to the keyword path (Step 1) — but NOT as a runtime check (that would violate the "<200ms, no LLM" contract). Instead, apply it as a one-time Audit of `KEYWORD_MAP` in `artifactor.py`: the `artifact` value of every entry must pass this test at the time the entry is added or edited.

**Rules for `budget_estimate`:**
- `trivial` → `~0.5h`
- `closed-loop` → `~2h` (if no specific number is given in the request)
- `open-loop` → `~3h`
- `problem-framing` → `?`

**Field `routing_tag`** = value of `task_type` (snake_case).

### Step 3. Return the result

Print JSON to stdout. No additional explanation.

## Failure modes

| Scenario | Behavior |
|----------|----------|
| Request under 5 words | `{"error": "INSUFFICIENT_INPUT"}` |
| Script not found / crash | Proceed directly to Step 2 |
| Request in a foreign language | Classify as-is, `confidence: low` |

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
