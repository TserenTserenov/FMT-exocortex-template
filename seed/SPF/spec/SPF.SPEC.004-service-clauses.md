---
id: SPF.SPEC.004
name: Service Clause — domain's user-facing promises
status: active
created: 2026-03-30
related:
  - SPF.SPEC.001
  - DP.SOTA.001
---

# SPF.SPEC.004 — Service Clause vs Use Case

## 1. Problem

In Pack development practice, confusion arises between two distinct entities:

- **What the domain promises** to the consumer (regardless of implementation)
- **How** the consumer interacts with the system to achieve a goal

This confusion leads to mixing the Pack level (domain promises) and DS level (interaction scenarios) in a single file or folder.

---

## 2. Distinction: Service Clause ≠ Use Case

### Service Clause (SC) — user-facing promise

| Attribute | Value |
|-----------|-------|
| **What it is** | Domain contract: to whom, what, under what condition is guaranteed |
| **Level** | Domain (Pack) — implementation-independent |
| **Question** | "What does the platform/domain guarantee?" |
| **Changes when** | The domain promise changes (strategic decision) |
| **Where it lives** | `08-service-clauses/` in Pack |
| **Code** | `<CONTEXT>.SC.<NNN>` |

**Format:** "If [actor] [condition] → the domain ensures [guarantee]"

**Example:** `DP.SC.001` — "If a user opens a working day → the platform provides day context (commits, tasks, calendar)"

### Use Case (UC) — interaction scenario

| Attribute | Value |
|-----------|-------|
| **What it is** | Description of the sequence of interactions between an actor and a system |
| **Level** | System (DS) — implementation-dependent |
| **Question** | "How exactly is the goal achieved in a specific system?" |
| **Changes when** | The interface or implementation changes |
| **Where it lives** | `08-use-cases/` in DS repository |
| **Code** | `<SYSTEM>.UC.<NNN>` (not in Pack) |

**Format:** Main flow, alternative flows, preconditions, postconditions

---

## 3. Theoretical basis

### DDD Strategic (DP.SOTA.001): Published Language

In strategic DDD (Khononov, Evans) **Published Language** is the Bounded Context interface for external consumers: what the BC guarantees regardless of internal design. Service Clause is an implementation of Published Language at the Pack level.

Use Cases are **Application Services** within a BC: specific execution scenarios dependent on technologies and implementation. They belong to DS, not Pack.

### FPF A.7: Strict Distinction (Method ≠ Scenario)

FPF A.7 requires separating:
- **Method** (capability, what can be produced) — domain description level
- **Scenario** (step-by-step how) — implementation level

By the same logic:
- **Promise** (what is guaranteed) — Pack level
- **Interaction scenario** (how it is achieved step by step) — DS level

### Service Design / SLA pattern

In Service Design (Stickdorn, Schneider) they distinguish:
- **Service Promise** — what the service commits to ensure (channel-independent)
- **Service Blueprint** — how exactly the service is delivered in a specific channel

Service Clause = Service Promise. Use Case = part of Service Blueprint.

---

## 4. Application rules

### 4.1 Where to place

| Entity | Level | Folder | Example |
|--------|-------|--------|---------|
| Service Clause | Pack | `08-service-clauses/` | `DP.SC.001-daily-planning.md` |
| Use Case | DS | `08-use-cases/` (in DS repo) | `SystemName.UC.001-open-day.md` |

### 4.2 How to distinguish SC from UC

**Test 1 — Implementation question:**
> "If the implementation changes (different interface, different language, different framework), will this file change?"
- No → this is an SC (Pack)
- Yes → this is a UC (DS)

**Test 2 — Guarantee vs steps:**
> Does the file describe a promise (what is guaranteed) or steps (how to interact)?
- Promise → SC
- Steps → UC

**Test 3 — Actor-condition-guarantee:**
> Can it be formulated as "If [actor] [condition] → the domain guarantees [result]"?
- Yes → SC
- No (steps need to be described) → UC

### 4.3 Mixed format (permissible exception)

Operational Packs (e.g. PACK-verification) may contain SCs with a brief execution protocol. This is permissible if:
- The protocol is an integral part of the promise (the SC cannot be understood without it)
- The protocol does not depend on a specific system implementation

Sign of violation: the protocol describes specific UI steps, API calls, or technical details → move to DS.

---

## 5. SC card structure (canonical format)

```markdown
---
id: <CONTEXT>.SC.<NNN>
name: <Short promise name>
kind: SC
status: active | draft | deprecated
layer: L4-Personal | L2-Platform | L3-Template
actor: <who receives the promise>
condition: <under what condition>
guarantee: <what is guaranteed>
created: YYYY-MM-DD
related:
  extends: []      # Higher-level SC
  depends_on: []   # Other SCs without which this doesn't work
---

# <CONTEXT>.SC.<NNN> — <Name>

## Promise

<One sentence: actor + condition + guarantee>

## Trigger

- <condition 1>
- <condition 2>

## Guarantee

<What the domain commits to ensure. No implementation steps.>

## Participants (optional for operational Packs)

| Role | Who |

## Exceptions

<Under what conditions the promise does not apply>
```

---

## 6. SC kind code in SPF.SPEC.001

Service Clause (`SC`) is added to the base kinds table:

| Code | Kind | Pack folder |
|------|------|-------------|
| `SC` | Service Clause | `08-service-clauses/` |

---

## 7. Migration of existing Packs

Packs with an `08-use-cases/` folder containing `*.SC.*` files:
1. Rename the folder: `08-use-cases/` → `08-service-clauses/`
2. Update the repo's CLAUDE.md
3. Update all references

Packs with an `08-use-cases/` folder containing `*.UC.*` files (actual Use Cases):
- Evaluate using tests from §4.2
- If it truly is a UC → keep the filename, move to DS
- If it is an SC named as UC → rename files to `*.SC.*` + rename folder

---

*This document: `SPF.SPEC.004`*
