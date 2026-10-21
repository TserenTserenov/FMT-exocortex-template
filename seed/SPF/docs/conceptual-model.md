# FPF, SPF and Pack: Conceptual Model

This document establishes the **conceptual model** for knowledge organization within SPF.

---

## 1. Why all this: knowledge, learning and the AI era

### 1.1. Professionals have a picture of their domain

In any applied field, strong specialists have a **picture of their domain**: what matters here, what risks are typical, where the "weak spots" are, which distinctions must not be confused.

This picture almost always emerges from practice, standards, mistakes and their analysis. It exists sometimes parallel to any textbooks and courses as "professional reality".

### 1.2. Why formalization became critical in the AI era

AI can significantly accelerate domain understanding **when a knowledge structure exists**, but without a formalized structure AI reinforces confusion.

---

## 2. Concepts and distinctions: full glossary

### 2.1. Object, description, carrier

| Term | Definition | Example |
|------|-----------|---------|
| **Object** | What exists "in the domain reality" | Car; construction object |
| **Description** | Model/text/diagram about an object | Characteristic card, specification |
| **Carrier** | File/page/video/site where the description resides | Markdown file, PDF, web page |

**Must not confuse**: object ≠ description ≠ carrier.

### 2.2. Knowledge, learning, representation

| Term | Definition | Example |
|------|-----------|---------|
| **Knowledge** | Structured domain content | Pack |
| **Learning** | A way to guide a person through knowledge | Course, training |
| **Representation (view)** | A specific assembly of knowledge for an audience | Guide, course, RAG index |

**Must not confuse**: knowledge ≠ course/textbook ≠ any publication.

### 2.3. Method, tool, practice, scenario

| Term | Definition | Example |
|------|-----------|---------|
| **Method** | A way of acting/evaluating | Time tracking |
| **Tool** | A means of execution | Toggl, Excel spreadsheet |
| **Practice** | A reproducible pattern of applying methods | Daily time recording |
| **Scenario/route** | A step-by-step plan | "30-day program" |

**Must not confuse**: method ≠ tool; method ≠ scenario.

### 2.4. Characteristic, metric, indicator

| Term | Definition | Example |
|------|-----------|---------|
| **Characteristic** | An evaluation axis for an object | "Safety", "agency" |
| **Metric** | A measurable quantity | Response time, % completion |
| **Indicator** | An observable sign/measure | Number of initiatives per week |

### 2.5. State

**State** — a class/mode of an object based on characteristic/indicator values.

**Must not confuse**: state ≠ learning stage. State is "how it is now", not "how to get there".

### 2.6. Work product

**Work product** — an observable, verifiable result of a method/evaluation.

### 2.7. Typical interpretation errors (failure modes)

**Failure mode** — a typical misunderstanding/substitution error.

### 2.8. SoTA status

**SoTA status** — a marker of the currency of a statement/interpretation.

| Status | Meaning |
|--------|---------|
| `current` | Current, confirmed by practice |
| `hypothesis` | New, requires verification |
| `deprecated` | Outdated |

### 2.9. Domain and bounded context

| Term | Definition |
|------|-----------|
| **Domain** | An applied field with language, objects, methods |
| **Bounded context** | Explicitly fixed boundaries and vocabulary of the domain |

---

## 3. First Principles

### 3.1. What are first principles

**First principles** — universal distinctions and requirements for correct thinking about knowledge:

- method ≠ tool
- result ≠ description of result
- characteristic ≠ way to change it
- state ≠ action plan
- object ≠ model
- knowledge ≠ learning

### 3.2. Universality of first principles

First principles are **universal in content**: the same in construction, cooking, medicine, management.

---

## 4. FPF — First Principles Framework

### 4.1. First principles exist before formalization

First principles "have always existed". **FPF does not invent first principles.**

FPF does three things:

| Function | Description |
|----------|-------------|
| **Explication** | Makes first principles explicit |
| **Normativity** | Turns them into correctness requirements |
| **Discipline** | Sets the language and constraints |

### 4.2. What FPF defines

- universal entity types (role, method, work product, process, description, carrier)
- permissible and impermissible distinctions
- rules for working with contexts (bounded context)
- principles of multi-view description
- requirements for verifiability, SoTA and trustworthiness

### 4.3. What FPF does NOT do

- **does not describe specific domains**
- does not contain second principles
- is not a course
- does not provide "step-by-step scenarios"

---

## 5. Second Principles

### 5.1. What are second principles

**Second principles** — stable domain regularities and distinctions within a specific field:

> What really matters here? Which distinctions are critical? What are the typical errors?

### 5.2. They exist before formalization

Second principles live in professionals's experience, standards, craft, "feel of the domain".

### 5.3. Their universality

Second principles:
- **are not universal in content** (different domains have different ones)
- but are **"universal in type"**: they exist in any domain and can be brought to engineering form

---

## 6. SPF — Second Principles Framework

### 6.1. What SPF is

**SPF** — a framework that defines **how to formalize second principles** of a domain so that engineering knowledge results.

### 6.2. What SPF does

**Minimum required elements:**
- bounded context
- key distinctions
- characteristics
- evaluation/verification methods
- work products
- failure modes
- SoTA statuses and revision criteria

**Structural requirements:**
- identifier and reference rules
- canonical pack structure

**Process gates:**
- process lint
- contracts between source-of-truth and downstream

### 6.3. What SPF does NOT do

- does not add domain content
- does not decide which second principles are correct
- does not build courses
- does not replace expertise

### 6.4. How SPF relates to FPF

| FPF | SPF |
|-----|-----|
| Defines correctness of types and distinctions | Defines engineering format for capturing domain content |
| Prevents logical confusion | Prevents knowledge from becoming a "collection of tips" |

---

## 7. Pack — domain passport

### 7.1. What it is

**Domain passport** (also **pack**) — a formalized and stabilized engineering description of a domain.

> Pack = domain passport

### 7.2. Pack is a result, not a process

Pack is a **knowledge artifact** (source of truth), not a process.

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
| Map | Graph of connections between pack elements |

### 7.4. What a pack is NOT

| Pack is NOT | Where it should be |
|-------------|-------------------|
| Course, textbook | Downstream |
| Development route | Downstream |
| "How to implement" | Downstream |
| Embeddings/index | Downstream |

---

## 8. How a pack is created

### 8.1. Logical order

1. **First principles** explicated in FPF
2. **Second principles** fixed according to SPF requirements
3. **Pack** — the result of formalization

### 8.2. Practical process (iterations)

#### Iteration 0: Domain contract
- Bounded context
- Core distinctions
- Truth criteria

#### Iteration 1: Engineering structure
- Characteristic catalog
- Card template
- Top-level map

#### Iteration 2: MVP characteristic
- Definition and distinctions
- Indicators/metrics
- Evaluation methods
- Work products
- Typical errors
- SoTA status

#### Iteration 3+: Expansion

#### Continuously: Evolution

### 8.3. Process stages

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

### 9.1. What FPF gives to SPF

FPF ensures **basic correctness**: we don't confuse types, don't mix tool/method, don't substitute result for description.

### 9.2. What FPF gives to pack

FPF makes the pack consistent, traceable, stable.

### 9.3. How SPF helps create a pack

SPF defines the "engineering form" and process gates (lint).

---

## 10. Typical errors (anti-patterns)

### 10.1. Pack-level errors

| Error | How to avoid |
|-------|-------------|
| Pack turns into learning | Didactics go downstream |
| States become "stages" | States are classes, not sequences |
| Tools are declared methods | Method ≠ tool |
| Artifact substitutes fact | Work product ≠ description |
| SoTA becomes "literature review" | SoTA = status + revision criterion |
| Downstream becomes source-of-truth | Pack is the sole source-of-truth |

### 10.2. Forbidden formulations

- Mixing SPF and pack
- Treating SPF as universal knowledge by content
- Treating pack as learning material
- Turning methods into scenarios
- Treating AI representations as source of truth

---

## 11. Level hierarchy and three dimensions

### 11.1. Canonical hierarchy

```
FPF (Level 1)  →  first principles framework
       ↓
SPF (Level 2)  →  second principles framework
       ↓
Pack           →  formalized domain knowledge
       ↓
Downstream     →  derivative representations
```

| Level | Universality |
|-------|-------------|
| **FPF** | Universal in content |
| **SPF** | Universal in form and process |
| **Pack** | Domain-specific |
| **Downstream** | Free form |

### 11.2. Three orthogonal dimensions

| Dimension | What it defines |
|-----------|----------------|
| **Content** | What is inherited semantically |
| **Form** | How the repository is structured |
| **Process** | How it is produced and maintained |

Dimensions are **independent of each other**.

### 11.3. Downstream: document structural protocols

Downstream repositories (projects, governance, surfaces) may follow various structural protocols for organizing their documents:

- "Systems × roles" matrix — project documents organized by intersection of system levels and role perspectives
- Thematic sections — documents organized by subject areas
- Chronological — decision logs, logs, journals

SPF does not prescribe a specific structure for downstream repositories. SPF defines the **contract** between Pack (source-of-truth) and downstream: downstream references Pack but does not duplicate or substitute it.

**Key distinction:** document structural protocol (form) and Pack (content) are **orthogonal**. One Pack can be used by documents from different structural cells, and one document may reference multiple Packs.

---

## 12. Relationship to other methodologies

### 12.1. Domain-Driven Design (DDD)

**Key difference**: DDD is about code. FPF/SPF/Pack is about formalizing knowledge before code.

### 12.2. Ontology Engineering

**Difference**: Formal ontologies are for machine reasoning. Pack is for human-readable knowledge.

### 12.3. Knowledge Graphs

**Difference**: Knowledge Graphs are data-centric. Pack is methodology-centric.

### 12.4. What makes FPF/SPF/Pack unique

1. Explicit separation of content, form and process
2. Process-driven knowledge production
3. Failure Modes as first-class citizens
4. SoTA as an attribute, not a literature review
5. Downstream contract
6. AI-ready, human-readable

---

## 13. Brief glossary

| Term | Definition |
|------|-----------|
| **Bounded context** | Fixed semantic frame of the domain |
| **Distinction** | A distinction preventing confusion |
| **Method** | A way of acting, not a scenario |
| **Work product** | A verifiable result of a method |
| **Failure mode** | A typical interpretation error |
| **SoTA annotation** | Currency status of a statement |
| **Map** | Graph of connections between pack elements |
| **Downstream view** | A derivative representation of a pack |
| **Characteristic** | An evaluation axis for an object |
| **Indicator** | An observable sign for evaluation |
| **State** | Class/mode of an object by characteristics |
| **Practice** | A reproducible pattern of applying methods |

---

## 14. Final formula

> **First principles** — universal distinctions of correct thinking about knowledge; they exist independently of formalization.

> **FPF (First Principles Framework)** — a framework that explicates first principles, makes them explicit and normative.

> **Second principles** — stable domain regularities of a specific field; they exist before formalization in professional experience.

> **SPF (Second Principles Framework)** — a framework of requirements and processes for engineering fixation of second principles.

> **Pack / domain passport** — formalized engineering core of a specific domain: source of truth.

---

## Key distinction: information vs knowledge

| Information | Knowledge (Pack) |
|-------------|-----------------|
| Raw data | Formalized through distinctions |
| Not verified | Has gone through SPF process |
| No SoTA status | Has SoTA + revision criterion |
| Input for process | Output of process |

---

*This document is normative for SPF.*
