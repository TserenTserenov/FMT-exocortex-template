# 04. Domain Entities Identification

## Purpose

Identify the stable structural elements of the domain: roles, objects of attention, constraints, and relationships. These entities exist regardless of which specific methods are used or which specific practitioners operate.

---

## Why Entities, Not Practices

Common mistake: Start with "what people do" (practices).

| Starting with Practices | Starting with Entities |
|------------------------|----------------------|
| Captures current habits | Captures stable structure |
| Changes with trends | Persists across trends |
| Conflates method with tool | Roles and objects are distinct from methods |
| No criterion for completeness | Entities provide framework |

Practices are instances; entities are the types that make practices intelligible.

---

## Inputs

| Input | Source | Required |
|-------|--------|----------|
| Bounded context | Stage 02 | Yes |
| Distinctions | Stage 03 | Yes |
| Domain knowledge | Expertise, literature | Yes |

---

## Activity

### 1. Identify Roles

Roles are **functional positions**, not persons or job titles.

| Role | NOT Role |
|------|----------|
| Agent (who develops) | "John" (person) |
| Mentor (who guides) | "Manager" (job title) |
| Analyst (who reviews) | "The team" (collective) |

For each role:
- What responsibility does this role hold?
- What methods does this role typically perform?
- What products does this role produce or consume?

### 2. Identify Objects of Attention

Objects of attention are **what practitioners attend to** when performing methods.

| Object of Attention | NOT Object |
|--------------------|------------|
| Time allocation | "Life" (too vague) |
| Behavior patterns | "Everything" (no boundary) |
| Skill gaps | "Self" (not operational) |

For each object:
- What is observed or measured?
- Which methods attend to this object?
- What products capture this object?

### 3. Identify Environmental Constraints

Constraints are **conditions that bound practice** in this domain.

| Constraint | Example |
|-----------|---------|
| Resource limits | Time is finite (168 hours/week) |
| Information limits | Cannot observe own cognition directly |
| Role limits | Agent cannot mentor themselves (feedback loop) |

### 4. Document Entity Relationships

Create files in `02-domain-entities/`:

| File | Content |
|------|---------|
| `02A-roles.md` | Role definitions, responsibilities, typical methods |
| `02B-objects-of-attention.md` | Objects, observation criteria, related methods |
| `02C-methods-index.md` | Index of methods (populated in Stage 07) |
| `02D-tools-index.md` | Index of tools (secondary to methods) |

---

## Output: Work Products

| File | Content |
|------|---------|
| `02-domain-entities/02A-roles.md` | Role definitions |
| `02-domain-entities/02B-objects-of-attention.md` | Objects of attention |
| `02-domain-entities/02C-methods-index.md` | Methods index (skeleton) |
| `02-domain-entities/02D-tools-index.md` | Tools index (skeleton) |

---

## Completion Criteria

| Criterion | Test |
|-----------|------|
| Roles identified | At least 2 distinct roles |
| Roles are functional | Each role has responsibility, not just name |
| Objects of attention identified | At least 3 objects |
| Objects are observable | Each has observation criteria |
| Role-method mapping sketched | Which roles perform which method types |
| Entity files created | Files exist in `02-domain-entities/` |

---

## Typical Errors

### E1. Roles Are Persons or Titles

**Symptom**: "Role: Project Manager" or "Role: Senior Developer"

**Problem**: These are job titles or seniority levels, not functional positions.

**Correction**: Ask: What function does this role perform? "Planner" (plans), "Executor" (executes), "Reviewer" (reviews).

### E2. Objects Are Too Abstract

**Symptom**: "Object of attention: Personal growth" or "Object: The self"

**Problem**: Cannot observe or measure; no operational criteria.

**Correction**: What specifically is observed? "Skill level in X," "Time allocation to Y," "Frequency of behavior Z."

### E3. Practices Listed as Entities

**Symptom**: "Entity: Daily standup" or "Entity: Retrospective"

**Problem**: These are practices (things people do), not stable structural elements.

**Correction**: What role performs this? What object does it attend to? Extract the entities.

### E4. Methods Confused with Roles

**Symptom**: "Role: Time Accountant" (method disguised as role)

**Problem**: Time accounting is a method, not a role.

**Correction**: The role is "Agent"; time accounting is a method the Agent may perform.

### E5. Skipping to Information

**Symptom**: "Entities are obvious, let's gather sources."

**Problem**: Without entities, information cannot be filtered or organized.

**Correction**: Complete entity identification; entities determine what information is relevant.

### E6. Missing Role-Method Mapping

**Symptom**: Roles listed but no connection to methods.

**Problem**: Roles without responsibilities are empty labels.

**Correction**: For each role, identify at least one method type it performs.

---

## Entities vs. Methods

| Entity (Stage 04) | Method (Stage 07) |
|-------------------|-------------------|
| Who acts (role) | How they act (method) |
| What is attended to (object) | How it is attended to (method) |
| Structural | Procedural |
| Persists across methods | Method is one way to engage entities |

---

## Transition to Next Stage

When Domain Entities Identification is complete:
- Role definitions exist in `02A-roles.md`
- Objects of attention exist in `02B-objects-of-attention.md`
- Index files are created (to be populated later)
- Role-method mapping is sketched

Proceed to [05. Information Ingestion](05-information-ingestion.md) to admit materials for analysis.
