# FPF, SPF and Pack: Conceptual Model

> **FPF Reference:** The full FPF specification is available locally: `~/IWE/FPF/FPF-Spec.md`
> Codes like `A.1`, `B.5` refer to FPF patterns.

This document captures the **conceptual model** of knowledge organization used in this repository.
It is **normative**: the definitions and demarcations below are mandatory for interpreting the repository structure, working process, and role of downstream artifacts.

---

## Quick navigator

1. [Why all this: knowledge, learning, and the AI era](#1-why-all-this-knowledge-learning-and-the-ai-era)
2. [Concepts and distinctions: full vocabulary](#2-concepts-and-distinctions-full-vocabulary)
3. [First principles: what they are and their universality](#3-first-principles)
4. [FPF: what it is, what it's for, and what it does NOT do](#4-fpf--first-principles-framework)
5. [Second principles: what they are, how they exist before formalization](#5-second-principles)
6. [SPF: what it is, what it's for, and how it relates to FPF](#6-spf--second-principles-framework)
7. [Domain passport (pack): what it is and what it is NOT](#7-pack--domain-passport)
8. [How a pack is created: logical order and practical process](#8-how-a-pack-is-created)
9. [How FPF helps SPF and pack](#9-how-fpf-helps-spf-and-pack)
10. [Typical errors (anti-patterns)](#10-typical-errors-anti-patterns)
11. [Binding to domain: "Characteristics and states of a creator"](#11-binding-to-domain-characteristics-and-states-of-a-creator)
12. [Readiness checklists (Definition of Done)](#12-readiness-checklists-definition-of-done)
13. [Level hierarchy and three dimensions](#13-level-hierarchy-and-three-dimensions)
14. [Relationship to other methodologies](#14-relationship-to-other-methodologies)
15. [Mapping to repository structure](#15-mapping-to-repository-structure)
16. [Brief glossary](#16-brief-glossary)
17. [Final formula](#17-final-formula)

---

## 1. Why all this: knowledge, learning, and the AI era

### 1.1. Professionals have a picture of their domain

In any applied area (construction, culinary arts, medicine, logistics, industrial safety) strong specialists have a **picture of their domain**: what matters here, what risks are typical, where the "thin spots" are, which distinctions must not be confused.

This picture almost always emerges from practice, standards, mistakes, and their analysis. It sometimes exists in parallel with any textbooks and courses as "professional reality", while textbooks/courses are most often an attempt to package this reality for learning purposes.

### 1.2. Why formalization became critical in the AI era

Previously one could "get by" on experience and intuition: they lived in the specialist's head, and transfer happened through mentorship and years of practice.

Now AI can significantly accelerate domain understanding **given a knowledge structure**, while in the absence of a formalized structure AI reinforces confusion (beautifully, confidently, but incorrectly for your context).

Therefore, formalization matters above all to those who want to:
- maintain professional relevance,
- train and scale faster,
- build AI assistants that "understand your domain specifics", not just generic platitudes.

---

## 2. Concepts and distinctions: full vocabulary

A strict language is used below. If word meanings are not fixed, subsequent descriptions will inevitably be read "colloquially".

### 2.1. Object, description, carrier (FPF A.7: Strict Distinction)

| Term | Definition | Example |
|------|------------|---------|
| **Object** | That which exists "in the reality of the domain" | Car; construction site; person as assessment object |
| **Description** | Model/text/diagram about the object | Characteristic card, specification |
| **Carrier** | File/page/video/website where the description resides | Markdown file, PDF, web page |

**Must not be confused**: object ≠ description ≠ carrier. (FPF A.7)

### 2.2. Knowledge, training, representation

| Term | Definition | Example |
|------|------------|---------|
| **Knowledge** | Structured domain content (distinctions, characteristics, methods, verification criteria, typical errors) | Pack |
| **Training** | A way to guide a person through knowledge (learning path, exercises, sequence) | Course, workshop |
| **Representation (view)** | A specific assembly of knowledge for an audience or task | Guide, course, hints, RAG index |

**Must not be confused**: knowledge ≠ course/textbook ≠ any publication.

### 2.3. Method, tool, practice, scenario (FPF A.3)

| Term | Definition | Example | FPF |
|------|------------|---------|-----|
| **Method** | Way of acting/assessing (what to do in principle) | Time tracking | A.3.1 |
| **Tool** | Means of execution (app, timer, template, device) | Toggl, Excel spreadsheet | — |
| **Practice** | Reproducible pattern of applying methods in context | Daily time logging | A.15 |
| **Scenario/path** | Step-by-step plan for reaching a state | "30-day program" | — |

**Must not be confused**: method ≠ tool; method ≠ scenario. (FPF A.7)
A practice is often "assembled" from methods + context + habits.

### 2.4. Characteristic, metric, indicator

| Term | Definition | Example |
|------|------------|---------|
| **Characteristic** | Axis of object assessment | "Car safety", "creator's agency" |
| **Metric** | Measurable quantity related to a characteristic | Braking reaction time, % of fulfilled commitments |
| **Indicator** | Observable sign/measure for assessment (can be input/computed/derived) | Number of initiatives per week |

**Must not be confused**: characteristic ≠ metric ≠ indicator.

### 2.5. State

**State** — class/mode of an object based on characteristic/indicator values.

| State examples | Context |
|---------------|---------|
| "Overloaded", "stable", "at risk" | Systems |
| "Random", "practicing", "systematic" | Learner |

**Must not be confused**: state ≠ learning stage.
State — "how it is now", not "how to get there".

### 2.6. Work product

**Work product** — an observable, verifiable result of a method/assessment.

| Examples | Context |
|----------|---------|
| Protocol, profile, risk map | Documents |
| Time budget, test report | Assessment results |

**Must not be confused**: work product ≠ unverifiable description; work product ≠ promise.

### 2.7. Typical interpretation errors (failure modes)

**Failure mode** — a typical error of understanding/substitution.

| Examples |
|----------|
| "Confusing method with tool" |
| "Substituting fact with report" |
| "Optimizing for a single test" |

### 2.8. SoTA status

**SoTA status** — a currency mark on a statement/interpretation.

| Status | Meaning |
|--------|---------|
| `current` | Up to date, confirmed by practice |
| `hypothesis` | New, requires verification |
| `deprecated` | Outdated, a better interpretation exists |

**SoTA is not a "literature review"** — it is currency management for statements with revision criteria.

### 2.9. Domain area and bounded context (FPF A.1.1)

| Term | Definition | FPF |
|------|------------|-----|
| **Domain area** | Applied sphere with its own language, objects, metrics, methods | A.1 |
| **Bounded context** | Explicitly fixed boundaries and vocabulary of that area (what's in/out; term meanings) | A.1.1 |

**Must not be confused**: "domain" ≠ "course" ≠ "community of people". (FPF A.7)
A domain is defined through boundaries, language, and object types.

---

## 3. First principles

### 3.1. What are first principles

**First principles** — universal distinctions and requirements for correct thinking about knowledge, the same for any domain. They answer the question:

> How to think about and describe knowledge so as not to destroy meaning?

**Examples of first principles (FPF A.7: Strict Distinction):**
- method ≠ tool (A.3)
- result ≠ description of result (A.7)
- characteristic ≠ way to change it (A.17)
- state ≠ action plan (A.19)
- object ≠ model (A.7)
- knowledge ≠ training (A.7)

### 3.2. The universality of first principles

First principles are **universal in content**:
- the same in construction, culinary arts, medicine, management
- independent of subject matter — they define correctness of thinking

### 3.3. When first principles are absent or violated

Then "knowledge decay" occurs:
- methods turn into rituals and advice
- tool is presented as method ("installed the app → became disciplined")
- report substitutes for result ("document exists → therefore done")
- training substitutes for knowledge ("course exists → therefore domain is described")
- errors become invisible (no language of distinctions)
- AI scales confusion

---

## 4. FPF — First Principles Framework

### 4.1. First principles exist before formalization

First principles have "always existed" as a practice of humanity. **FPF does not invent first principles.**

FPF does three things:

| Function | Description |
|----------|-------------|
| **Explication** | Makes first principles explicit (describes distinctions) |
| **Normativity** | Turns them into correctness requirements (what counts as a confusion error) |
| **Discipline** | Provides language and constraints to maintain correct description |

### 4.2. What FPF defines

FPF defines:
- universal entity types (A.1-A.3): role, method, work product, process, description, carrier
- permissible and impermissible distinctions (A.7: Strict Distinction)
- rules for working with contexts (A.1.1: Bounded Context)
- strict demarcations (A.7):
  - object / description / carrier
  - knowledge / representation / publication
  - method / scenario
  - system / process
- multi-view description principles (E.17: MVPK)
- requirements for verifiability, SoTA (Part G) and trust (B.3: F-G-R)

FPF answers the question:
> "How is it fundamentally permissible to describe knowledge and thinking?"

### 4.3. What FPF does NOT do

FPF:
- **does not describe specific domain areas**
- does not contain second principles
- is not a course (for human training)
- does not provide "step-by-step scenarios"

### 4.4. FPF universality

FPF is **universal in content**:
- it is equally applicable to any knowledge domain
- its types and distinctions are subject-independent
- it provides a meta-ontology and description language

FPF is universal in the same way as logic, type theory, basic ontology.

---

## 5. Second principles

### 5.1. What are second principles

**Second principles** — stable domain-specific patterns and distinctions within a specific area. They answer the question:

> What really matters here? Which distinctions are critical? What are the typical errors?

### 5.2. They exist before formalization

Second principles live:
- in professional experience
- in standards
- in craft
- in "domain sense"

They exist **before any description**.

### 5.3. Their universality

Second principles:
- are **not universal in content** (different domains have different ones)
- but are **"universal in type"** in this sense:
  - every domain has them
  - in every domain they can be brought to engineering form
  - and the requirements for that form are defined by first principles discipline (FPF)

---

## 6. SPF — Second Principles Framework

### 6.1. What is SPF

**SPF** is a framework that defines **how to formalize second principles** of a domain area so that engineering knowledge is produced.

SPF answers the question:
> What form and criteria are needed so that second principles become a verifiable core of the domain?

### 6.2. What SPF does

SPF defines:

**Minimum mandatory elements for an engineering description of a domain:**
- bounded context
- key distinctions
- characteristics
- assessment/verification methods
- work products
- failure modes
- SoTA statuses and revision criteria

**Structure requirements:**
- identifier and reference rules (to make knowledge traceable)
- canonical pack structure

**Process gates:**
- process lint: checks that didactics were not introduced, entity types were not mixed
- contracts between source-of-truth and downstream

SPF answers the question:
> "How, following FPF rules, to produce and maintain second principles?"

### 6.3. What SPF does NOT do

SPF:
- does not add domain content
- does not decide for you which second principles are valid
- does not build courses
- does not replace research/expertise

### 6.4. How SPF relates to FPF

| FPF | SPF |
|-----|-----|
| Defines correctness of types and distinctions ("how to think") | Builds on this and defines the engineering format for capturing domain knowledge ("how to formalize second principles") |
| Prevents logical and ontological confusion | Prevents domain knowledge from turning into "a collection of tips" |

### 6.5. SPF universality

SPF is **universal in form and process**, but **not in content**:
- pack structure is the same for any domain
- knowledge creation process is the same
- lint and gates are the same
- but pack content is always domain-specific

SPF is universal like an engineering standard, a production framework, a normative methodology.

---

## 7. Pack — domain passport

### 7.1. What it is

**Domain passport** (aka **pack**) — an already assembled, formalized, and stabilized engineering description of a domain, where second principles have been brought to the state of engineering knowledge.

> Pack = domain passport

### 7.2. Pack is a result, not a process

**Important**: a pack is not a process and not "a way to assemble". A pack is a **result, a knowledge artifact** (source of truth).

### 7.3. What a pack includes

| Element | Description |
|---------|-------------|
| Bounded context | Fixed semantic frame of the domain |
| Distinctions | Conceptual boundaries of the domain |
| Domain entities | Roles, objects of attention, constraints |
| Methods | Ways of acting (not scenarios) |
| Work products | Verifiable results of methods |
| Failure modes | Typical interpretation errors |
| SoTA annotations | Currency statuses |
| Relationship map | Graph of links between elements |

**Pack is the source-of-truth** for the given domain.

Pack answers the question:
> "What does the stabilized knowledge of this specific domain look like?"

### 7.4. What a pack is NOT

| Pack is NOT | Where it belongs |
|-------------|-----------------|
| Course, textbook | Downstream (training systems) |
| Development path | Downstream (guides, coaching) |
| "How to implement" | Downstream (implementation) |
| Embeddings/index | Downstream (AI implementations) |
| Collection of publications | Downstream (content) |

A pack can **generate** (downstream) courses/guides/indexes, but is not one itself.

### 7.5. Non-universality of packs

Each pack:
- is tied to one domain area
- contains domain-specific distinctions and methods
- cannot be directly transferred to another domain

Universality is achieved **not through pack content**, but through the fact that *all packs are built following one SPF and on top of one FPF*.

---

## 8. How a pack is created

### 8.1. Logical order

1. **First principles** exist independently and are explicated in FPF as normative distinctions for correct thinking about knowledge. The principles exist independently of FPF.

2. **Second principles** of a specific domain area exist in professional experience; SPF defines requirements and the process for their engineering capture in a Pack.

3. **Pack** — these are the second principles of a domain area, formalized as an engineering knowledge core in compliance with FPF and SPF requirements.

### 8.2. Practical process (iterations)

In practice, a pack is created iteratively, "together with" capturing second principles:

#### Iteration 0: Domain contract

| Task | Artifact |
|------|----------|
| Fix bounded context (domain name, boundaries, vocabulary) | `01-domain-contract/01A-bounded-context.md` |
| Fix core distinctions (bans on type confusion) | `01-domain-contract/01B-distinctions.md` |
| Fix truth criteria (what counts as verification/artifact) | In bounded context |

#### Iteration 1: Engineering structure

| Task | Artifact |
|------|----------|
| Create characteristics catalog (like safety/reliability in automotive) | `02-domain-entities/02E-characteristics-registry.md` |
| Create characteristic card template | `_template/03-characteristics/` |
| Create top-level map (role/state/characteristic/indicator) | `07-map/PD.MAP.002.md` |

#### Iteration 2: MVP characteristic

Pick 1 characteristic (e.g., agency) and build a minimum set:

| Element | Artifact |
|---------|----------|
| Definition and distinctions | Characteristic card |
| Indicators/metrics | In the card |
| Assessment methods and test scenarios | `03-methods/PD.METHOD.NNN.md` |
| Assessment work products | `04-work-products/PD.WP.NNN.md` |
| Typical errors | `05-failure-modes/PD.FAIL.NNN.md` |
| SoTA status | `06-sota/PD.SOTA.NNN.md` |

#### Iteration 3+: Expansion

- Add next characteristic (caliber of personality)
- Later: stress resilience and others

#### Continuously: Evolution

- SoTA review
- Update criteria, metrics, tests
- Check "haven't we slipped into training"

### 8.3. Process stages (detailed)

The detailed process is described in [`/process/`](/process/):

```
01. Domain Selection
02. Bounded Context
03. Distinctions Work
04. Domain Entities Identification
05. Information Ingestion
06. Analysis & Formalization
07. Method & Product Extraction
08. Failure Modes Extraction
09. SoTA Annotation
10. Map Maintenance
11. Review & Evolution Cycle
```

---

## 9. How FPF helps SPF and pack

### 9.1. What FPF provides for SPF

FPF ensures **base correctness**:
- don't confuse statement types
- don't mix tool/method
- don't substitute result with description
- don't describe "domain as a system" (without specifying which)
- don't confuse states with learning paths

FPF is the "protective grammar" for everything else.

### 9.2. What FPF provides for pack

FPF makes a pack:
- type-consistent
- suitable for tracing and verification
- resistant to "content sprawl"

### 9.3. How SPF helps create a pack

SPF:
- defines the "engineering form" and minimum mandatory elements
- introduces process gates (lint) to ensure:
  - pack doesn't turn into a course
  - doesn't become a collection of lifehacks
  - doesn't lose verifiability
  - doesn't mix levels

---

## 10. Typical errors (anti-patterns)

### 10.1. Pack-level errors

| Error | Symptom | How to avoid |
|-------|---------|--------------|
| **Pack turns into training** | Steps, lessons, "how to pass a stage" appear | Didactics is downstream |
| **States become "stages"** | A linear path appears instead of state classes | States are classes, not a sequence |
| **Tools declared as methods** | App, timer, template = "method" | Method ≠ tool (D.001) |
| **Artifact substitutes for fact** | Report = "quality ensured" | Work product ≠ description (D.005) |
| **SoTA turns into "literature review"** | Instead of statuses and revision criteria — a lit review | SoTA = status + revision criterion |
| **Downstream becomes source-of-truth** | Course/index/embeddings start "overriding" the core | Pack is the only source-of-truth |

### 10.2. Banned formulations

| Banned | Why |
|--------|-----|
| Mixing SPF and pack in formulations | Different levels |
| Considering SPF universal knowledge by content | SPF is universal by form, not content |
| Considering a pack training material | Pack ≠ course |
| Turning methods into scenarios | Method ≠ scenario |
| Considering AI representations a source of truth | Embeddings ≠ knowledge |
| "Creator is a system" | Which system? Specify the object of description! |

---

## 11. Binding to domain: "Characteristics and states of a creator"

### 11.1. Domain area

**Domain name**: Characteristics and states of a creator

**Engineering analogy**: just as in the automotive industry a product has characteristics (safety, reliability) and test methods, a "creator" also has characteristics (agency, caliber of personality, etc.) and assessment/verification methods.

**Bounded context**: [01A-bounded-context.md](/pack/personal-development/01-domain-contract/01A-bounded-context.md)

### 11.2. Creator roles

The pack captures creator roles as participation modes:

| Role | Description |
|------|-------------|
| Learner | Learning acquisition mode |
| Intellectual | Analysis and reflection mode |
| Professional | Productive activity mode |
| Researcher | New knowledge discovery mode |
| Enlightener | Knowledge transfer mode |

### 11.3. Learner states

States are **state classes**, not a trajectory or training program:

| State | Description |
|-------|-------------|
| Random | No regularity, chaotic actions |
| Practicing | Regularity appears |
| Systematic | Has a system, follows it |
| Disciplined | Sustained adherence to the system |
| Proactive | Anticipatory actions, initiative |

### 11.4. Characteristics

Characteristics catalog by analogy with engineering specs:

| Characteristic | Category | Priority |
|---------------|----------|----------|
| Agency | Core | High |
| Caliber of personality | Core | High |
| Stress resilience | Resilience | Medium |

### 11.5. Digital twin

**DS-twin** acts as an external "measurement circuit":
- indicators and their types
- derived score computation (e.g., stage/mastery/agency/risk)
- while generative texts/interpretations do not become truth in themselves

In the pack, this is formalized as an **interface contract**: which indicators are used and how they link to characteristics/states.

---

## 12. Readiness checklists (Definition of Done)

### Phase A: Domain contract stabilization

Done when:
- [ ] Bounded context exists
- [ ] Core distinctions exist
- [ ] Reference/ID rules exist
- [ ] No didactics or "transitions"

### Phase B: Catalog layer

Done when:
- [ ] Characteristics registry exists
- [ ] Characteristic card template exists
- [ ] Top-level map exists
- [ ] Digital twin interface exists

### Phase C: MVP characteristics

Done when for one characteristic:
- [ ] Definition/distinctions exist
- [ ] Indicators/metrics exist
- [ ] Assessment methods + test scenarios exist
- [ ] Work products exist
- [ ] Failure modes exist
- [ ] SoTA status and revision criterion exist

---

## 13. Level hierarchy and three dimensions

### 13.1. Canonical hierarchy

```
FPF (Level 1)  →  first principles framework (meta-ontology + distinctions)
       ↓              Part A-G: Holon, BoundedContext, Γ, F-G-R, SoTA Kit
SPF (Level 2)  →  second principles framework (form + process)
       ↓              process/, pack-template/, spec/
Pack           →  formalized knowledge of a specific domain
       ↓              source-of-truth
Downstream     →  derived representations (courses, AI agents, guides)
```

| Level | What | Universality | FPF Parts |
|-------|------|-------------|-----------|
| **FPF** | Meta-level (ontology and distinctions) | Universal in content | A-G |
| **SPF** | Level of form, process, and guardrails | Universal in form and process | builds on A, B, G |
| **Pack** | Second-level domain knowledge | Domain-specific | uses A.1.1, A.7 |
| **Downstream** | Derived representations (not source-of-truth) | Free form | — |

### 13.2. Three orthogonal dimensions

Knowledge organization is described by three **independent** dimensions:

| Dimension | What it determines | Examples |
|-----------|-------------------|----------|
| **Content** | What is inherited semantically | FPF → SPF → Pack → Downstream |
| **Form** | How the repository is structured | S2R, custom layout |
| **Process** | How knowledge is produced and maintained | ingestion, lint, gates |

### 13.3. Orthogonality of dimensions

Dimensions are **independent of each other**:
- **Content** (knowledge level) does not dictate storage form
- **Form** (repository structure) does not determine the working process
- **Process** (knowledge production) is applicable to different forms

This means:
- A Pack can use S2R structure or another one
- A Downstream repository can use the same S2R as a Pack
- The SPF process applies regardless of the chosen form

### 13.4. S2R — structure format, not knowledge level

**S2R** (Structured Second-level Repository) — is a **form** specification, not a content level:
- S2R defines *how to organize files and folders*
- S2R does NOT define *what level of knowledge is stored in them*
- S2R can be applied to both Pack and Downstream

**Related repositories**:
- [ailev/FPF](https://github.com/ailev/FPF) — First Principles Framework (level 1)
- [TserenTserenov/FMT-S2R](https://github.com/TserenTserenov/FMT-S2R) — structure format specification
- [aisystant/DS-ecosystem-development](https://github.com/aisystant/DS-ecosystem-development) — downstream, uses S2R

### 13.5. What "framework" means in this architecture

In this context, a **framework** is **not a content set** and **not a knowledge library**.

A framework is:
- a set of mandatory distinctions
- a canonical structure
- a normative process
- correctness verification rules
- contracts between levels

---

## 14. Relationship to other methodologies

The FPF → SPF → Pack architecture does not exist in isolation. Below is a comparison with well-known approaches.

### 14.1. Domain-Driven Design (DDD)

| Aspect | DDD | FPF/SPF/Pack |
|--------|-----|--------------|
| **Focus** | Software code and architecture | Formalized knowledge (not code) |
| **Bounded Context** | Model boundary in code | Pack boundary (semantic frame) |
| **Ubiquitous Language** | Shared language of team and code | Distinctions as shared language |
| **Entity/Value Object** | Objects in code | Roles, Objects of Attention, Work Products |

**Key difference**: DDD is about code and software architecture. FPF/SPF/Pack is about knowledge formalization before code.

**Level analogy**:
- FPF ≈ Strategic DDD patterns (conceptual level)
- SPF ≈ Tactical DDD patterns (structural patterns)
- Pack ≈ Bounded Context implementation (concrete implementation)

### 14.2. Ontology Engineering (OWL, SKOS)

| Concept | OWL/SKOS | FPF/SPF/Pack |
|---------|----------|--------------|
| Upper Ontology | DOLCE, BFO, SUMO | FPF (meta-ontology) |
| Domain Ontology | Specific domain ontology | Pack (domain knowledge) |
| Classes/Properties | Types and relationships | Distinctions, Roles, Methods |
| Reasoning | Logical inference | SoTA + revision criteria |

**Difference**: Formal ontologies are for machine reasoning. Pack is for human-readable knowledge with AI support.

### 14.3. Knowledge Graphs

| Concept | Knowledge Graphs | FPF/SPF/Pack |
|---------|------------------|--------------|
| Schema | Graph schema | SPF (_template) |
| Entities | Graph nodes | Pack elements (Methods, WPs, FMs) |
| Relations | Graph edges | Links in Map, cross-references |
| Provenance | Data source | SoTA annotations + material ingestion |

**Difference**: Knowledge Graphs are data-centric (facts). Pack is methodology-centric (how domain knowledge is structured).

### 14.4. What makes FPF/SPF/Pack unique

1. **Explicit separation of content, form, and process** — most frameworks mix these dimensions

2. **Process-driven knowledge production** — SPF defines not only structure but also the knowledge creation process

3. **Failure Modes as first-class citizens** — typical interpretation errors are explicitly modeled

4. **SoTA as attribute, not literature review** — currency status is attached to specific statements with revision criteria

5. **Downstream contract** — explicit interface between source-of-truth and derived representations

6. **AI-ready, human-readable** — Pack is human-readable and suitable for AI agents without losing structure

---

## 15. Mapping to repository structure

### 15.1. FPF (interface to first principles)

- `/fpf/README.md` — describes how this repository builds on FPF
- FPF itself is not implemented here, but connected as an external source of norms

### 15.2. SPF (second principles framework)

| Component | Path |
|-----------|------|
| Pack template | `/pack/_template/` |
| Knowledge-creation process | `/process/` |
| Process lint | `/process/process-lint.md` |
| Downstream specs | `/spec/` |
| Constitution | `CLAUDE.md` |

This is the **universal part**, independent of the domain area.

### 15.3. Pack "Characteristics and states of a creator"

| Path | Purpose |
|------|---------|
| `/pack/personal-development/` | All pack content |
| `00-pack-manifest.md` | Metadata and scope |
| `01-domain-contract/` | Domain contract |
| `02-domain-entities/` | Roles, objects of attention |
| `03-methods/` | Methods |
| `04-work-products/` | Work products |
| `05-failure-modes/` | Typical errors |
| `06-sota/` | SoTA annotations |
| `07-map/` | Relationship maps |

**Note**: The folder is named `personal-development` for historical reasons. The pack's domain name is "Characteristics and states of a creator".

### 15.4. Downstream (explicitly not here)

The following things **are not part of the pack and are not stored in this repository**:
- courses
- guides
- learning paths
- implementation checklists
- AI embeddings and indexes
- publications (PDF, websites)

---

## 16. Brief glossary

| Term | Definition |
|------|------------|
| **Bounded context** | Fixed semantic frame of a domain |
| **Distinction** | A demarcation preventing ontological confusion |
| **Method** | Way of acting, not a scenario |
| **Work product** | Verifiable result of a method |
| **Failure mode** | Typical interpretation error |
| **SoTA annotation** | Currency status of a statement |
| **Map** | Graph of links between pack elements |
| **Downstream view** | Derived representation of a pack |
| **Characteristic** | Axis of object assessment |
| **Indicator** | Observable sign for assessment |
| **State** | Class/mode of an object based on characteristic values |
| **Practice** | Reproducible pattern of applying methods in context |

---

## 17. Final formula

> **First principles** — universal distinctions for correct thinking about knowledge; they exist independently of formalization and define which entity types are permissible in description and what must not be confused in any domain area.

> **FPF (First Principles Framework)** — a framework that explicates first principles, makes them explicit and normative, provides language and correctness criteria for knowledge description, but contains no domain content.

> **Second principles** — stable domain-specific patterns and distinctions of a specific area; they exist before formalization in professional experience, practice, and implicit rules, and are not universal in content.

> **SPF (Second Principles Framework)** — a framework of requirements and processes that defines how second principles can be captured and stabilized as engineering knowledge (through domain boundaries, distinctions, characteristics, verification methods, work products, failure modes, and currency management), building on FPF discipline.

> **Pack / domain passport** — an already assembled and formalized engineering core of a specific domain area: second principles brought to an engineering state in compliance with FPF and SPF requirements; it is a knowledge artifact (source of truth), not a process and not training.

---

## Key distinction: information vs knowledge

| Information | Knowledge (Pack) |
|-------------|-----------------|
| Raw data, materials | Formalized through distinctions |
| Not verified | Passed SPF process |
| No SoTA status | Has SoTA + revision criterion |
| Input to the process | Output of the process |

---

*This document is normative for the spf-personal repository.*
