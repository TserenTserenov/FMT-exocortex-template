---
type: doc
status: draft
created: 2026-02-10
updated: 2026-02-10
---

# DDD and FPF/SPF/Pack: Full Mapping

> **Purpose:** Formalize knowledge of how the FPF→SPF→Pack→Downstream methodology relates to Domain-Driven Design. What DDD does, what it rejects, the pros and cons of both approaches, and how DDD ideas live in our architecture.
>
> **Short version:** [fpf-spf-pack.md § 14.1](docs/fpf-spf-pack.md)
> **Downstream:** club post — [DS-Knowledge-Index-Tseren/posts/2026-02-10-ddd-vs-fpf-spf-pack.md](https://github.com/TserenTserenov/DS-Knowledge-Index-Tseren/blob/main/posts/2026-02-10-ddd-vs-fpf-spf-pack.md)

---

## 1. What DDD is

**Domain-Driven Design** — a software development approach proposed by Eric Evans (2003). Core idea:

> *"The heart of software is its ability to solve domain problems for the user."*

DDD asserts: software complexity lies in the domain, not the technology. Design must be driven by domain understanding: deep immersion in the business, constant collaboration between experts and developers, a Ubiquitous Language across all artifacts.

### 1.1. Two levels of DDD

| Level | What it does | Scale |
|-------|-------------|-------|
| **Strategic DDD** | How to decompose a large domain and how the parts relate | Organization, system of systems |
| **Tactical DDD** | How to implement a domain model within a single context | One service, one module |

### 1.2. Key books

| Book | Author | Year | Focus |
|------|--------|------|-------|
| *Domain-Driven Design: Tackling Complexity in the Heart of Software* | Eric Evans | 2003 | Foundational "blue book" — all patterns |
| *DDD Reference* | Eric Evans | 2015 | Condensed reference for all patterns (free PDF) |
| *Implementing Domain-Driven Design* | Vaughn Vernon | 2013 | "Red book" — practical guide |
| *Domain-Driven Design Distilled* | Vaughn Vernon | 2016 | Brief introduction (170 p.) |

---

## 2. DDD work products

DDD produces artifacts of **two kinds**: descriptions (non-code) and code.

### 2.1. Descriptive artifacts (non-code)

These artifacts exist **before** and **independently of** code. A team can run Event Storming and build a Context Map without writing a single line.

| # | Work product | What it is physically | Who does it |
|---|-------------|----------------------|-------------|
| 1 | **Ubiquitous Language Glossary** | Document/wiki: table of terms with definitions | Experts + developers together |
| 2 | **Bounded Context Definitions** | Document: boundary, inside — terms and rules | Architect + experts |
| 3 | **Context Map** | Diagram: all contexts and connections between them | Architect |
| 4 | **Subdomain Classification** | Table: Core / Supporting / Generic | Strategist/architect |
| 5 | **Domain Vision Statement** | 1 page: why this domain, where the value lies | Product + expert |
| 6 | **Event Storming Board** | Stickers/Miro: events → commands → aggregates → policies | Whole team |

### 2.2. Code artifacts

| # | Work product | What it is | Example |
|---|-------------|-----------|---------|
| 7 | **Entity** | Class with unique ID and lifecycle | `class Order(id: OrderId)` |
| 8 | **Value Object** | Immutable class without ID, defined by values | `class Money(amount, currency)` |
| 9 | **Aggregate** | Root Entity + nested objects with shared invariants | `Order` → `OrderLine[]`, accessed only through `Order` |
| 10 | **Domain Event** | Notification object: something happened in the domain | `class OrderPlaced(orderId, timestamp)` |
| 11 | **Domain Service** | Stateless operation, does not belong to one entity | `PricingService.calculate(order, discounts)` |
| 12 | **Repository** | Abstraction for storing/retrieving aggregates | `OrderRepository { find(id), save(order) }` |
| 13 | **Factory** | Encapsulation of complex object creation | `OrderFactory.createFromCart(cart)` |
| 14 | **Layered Architecture** | Structure: UI → Application → Domain → Infrastructure | 4 layers, dependencies only downward |

### 2.3. Important clarification: descriptions in DDD serve code

In DDD descriptive artifacts are **intermediate**:
- Glossary is needed so classes are named correctly
- Context Map — so microservices are sliced correctly
- Event Storming — to find aggregates for code

The ultimate goal of all descriptions in DDD is **code**. This is Evans's deliberate decision (see §3).

---

## 3. Evans's position: "The model is the code"

### 3.1. What Evans rejects

Evans explicitly opposes the "model on the shelf" — a document written by analysts, handed to developers, and thereafter living separately from code.

> *"The model is not the diagram. The model is not the document. The model IS the code."*

### 3.2. Evans's arguments

| Argument | Essence |
|----------|---------|
| **Model = code** | The domain model materializes directly in the code of the domain layer. Aggregates, entities, Value Objects, domain events — all of this IS the "formalization" |
| **UL is oral, not documentary** | Ubiquitous Language is maintained through constant communication, pair programming, discussions. The glossary is a supporting, not central, artifact |
| **Context Map is informal** | May be a drawing on a whiteboard, a diagram in a wiki. DDD prescribes no strict format |
| **Document inevitably becomes outdated** | Any document disconnected from code will sooner or later diverge from reality. Better to make code so expressive that it itself is a readable model |

### 3.3. The logic of this position

Evans solves a specific problem: in 2003 a typical project looked like this:
1. Analyst writes a requirements document
2. Architect draws diagrams
3. Developer writes code that matches neither
4. Documents become outdated the next day

DDD says: **throw away the intermediate documents, make the code the model**.

---

## 4. Pros and cons of the DDD approach

### 4.1. Pros

| Pro | Why it is valuable |
|-----|-------------------|
| **Code = model → no desync** | The single source-of-truth (code) cannot become outdated relative to itself |
| **Deep domain understanding** | Knowledge crunching forces developers to understand the business |
| **Expressive code** | Intention-revealing interfaces, ubiquitous language in class names — code reads like a domain description |
| **Bounded Context** | Clear boundaries prevent "Big Ball of Mud" — modularity at the architectural level |
| **Rich integration taxonomy** | 9 Context Map patterns (Partnership, ACL, Conformist...) — precise tools for describing connections |

### 4.2. Cons

| Con | Consequences |
|-----|-------------|
| **Knowledge locked in code** | A business expert who cannot read code cannot independently validate the model. UL works only while the team communicates regularly |
| **No knowledge transfer without people** | A key developer/expert leaves — knowledge of *why* the model is structured this way is lost. Code shows *what*, but not *why* |
| **No formal verification** | Cannot check that code matches domain rules because those rules are nowhere fixed separately from code in structured form |
| **Scaling through people, not artifacts** | DDD works well in one team with live communication. As teams multiply, oral UL stops scaling |
| **Mixing domain and implementation** | Code is an implementation in a specific language, specific framework, with technical compromises. Domain knowledge inevitably mixes with implementation decisions |
| **No meta-level** | No way to formalize rules for creating models. Every team invents its own approach |

### 4.3. Attempts to compensate for cons

There were attempts to supplement DDD with formal artifacts, but none became a standard:

| Attempt | What it does | Why it does not solve the problem |
|---------|-------------|----------------------------------|
| **Event Storming** (Brandolini) | Visual event map on stickers | Informal, becomes outdated quickly |
| **Domain Story Telling** | Visual narratives | No strict format |
| **BDD (Given-When-Then)** | Executable specifications | Tied to a test framework |
| **ADR** (Architecture Decision Records) | Records decisions | Records decisions, not the model |

---

## 5. Pros and cons of the FPF/SPF/Pack approach

### 5.1. Pros

| Pro | Why it is valuable |
|-----|-------------------|
| **Knowledge as an independent artifact** | Pack exists and has value without code. A domain expert can read, validate and improve Pack |
| **Knowledge transfer via artifact** | Pack can be handed to another team, another project, an AI agent — without verbal explanation |
| **Formal verification** | Distinctions with tests, failure modes, trust metrics — structured ways of verifying correctness |
| **Scaling through Pack** | A new team reads Pack and gets formalized domain knowledge. No human mentor needed |
| **Meta-levels** | FPF → SPF ensure portability of patterns across domains. Rules for creating Packs are the same for any domain |
| **Explicit evolution tracking** | SoTA + revision criteria show when knowledge has become outdated. In DDD the model is refactored as needed, without a system |
| **Downstream contract** | Explicit interface between knowledge and application. Code, courses, agents — all use one Pack |

### 5.2. Cons

| Con | Consequences |
|-----|-------------|
| **Two sources of truth** | Pack (text) and Code (downstream) can desync — the very problem Evans was solving. Requires an explicit synchronization process (see §6) |
| **Formalization overhead** | Creating a Pack with IDs, frontmatter, distinctions, failure modes — significant effort. May be excessive for a small team |
| **No runtime patterns** | Aggregate, Domain Event, Repository — code organization patterns not in Pack. When transitioning to code, DDD must be additionally applied |
| **Risk of "model on the shelf"** | If the Pack→Code synchronization process does not work, Pack becomes the very outdated document Evans opposed |
| **Young methodology** | No wide community, no validation at scale, little tooling |

---

## 6. The two-source-of-truth problem: Pack vs Code

### 6.1. Problem statement

Evans is right: a document disconnected from code becomes outdated. We accept this problem but solve it differently.

In DDD the solution: **remove the document, keep the code**.
In FPF/SPF/Pack the solution: **keep both, introduce a synchronization process**.

### 6.2. When Pack and Code diverge

Divergence of Pack and Code is a normal situation. The question is: **what to update?**

| Situation | What to update | Why |
|-----------|---------------|-----|
| New domain knowledge discovered during code development | **Pack** (then Code follows) | Pack is source-of-truth. Knowledge is formalized in Pack, code follows |
| Technical compromise in code forces deviation from model | **Code** (with an ADR record of why) | Implementation may require compromises, but Pack remains the "ideal" model |
| Business expert found an error in the model | **Pack** (then Code follows) | Expert validates Pack directly |
| Code refactoring reveals a better structure | **Both**: Pack is refined, Code consolidates | Code refactoring is a form of knowledge crunching |
| AI agent is working with outdated Pack | **Pack** (update to current understanding) | Agent must work with current knowledge |

### 6.3. Synchronization rule

> **When Pack and Code diverge — do not automatically update one of them. Determine where the truth lies and update the one that is wrong.**

This differs from DDD (where code is always right) and from traditional waterfall (where the document is always right). Our approach: **truth is determined by analysis**, not convention.

### 6.4. Mechanisms to prevent desync

| Mechanism | How it works | Status |
|-----------|-------------|--------|
| **Capture-to-Pack** (Work protocol) | When developing code, discovered knowledge is recorded in Pack | Implemented |
| **Downstream contract** (SPF spec) | Explicit Pack→Code interface with traceability rules | Implemented |
| **SoTA + revision criteria** | Each Pack entity has a revision criterion | Implemented |
| **Process lint** | Automated check of Pack against SPF | Partial |
| **Code lint → Pack** | Check that Code references Pack entities | Not implemented (potential) |

---

## 7. How DDD ideas live in FPF/SPF/Pack

### 7.1. Ideas we took and generalized

| DDD idea | How it lives with us | What we added |
|----------|---------------------|--------------|
| **Bounded Context** | U.BoundedContext (FPF A.1.1) → Pack (SPF) | Generalization to any domain (not just code). 4 required components: Glossary, Invariants, Roles, Bridges |
| **Ubiquitous Language** | Glossary + Distinctions (SPF 01A, 01B) | Tests for violations, failure modes, formal IDs |
| **Knowledge Crunching** | 11-step process (SPF process/) + Capture-to-Pack | Formalized process instead of informal workshops |
| **Model-Driven Design** | Pack-driven Downstream | Code is generated/written based on Pack, not the reverse |
| **Explicit boundaries** | Pack Manifest (scope: in/out) + Bridges | upstream/downstream dependencies, loss/fit annotations |

### 7.2. Ideas we did NOT take (and why)

| DDD idea | Why we did not take it | Consequence |
|----------|----------------------|------------|
| **"Model = code"** | We treat knowledge as an independent artifact, not tied to implementation | Synchronization process required (§6) |
| **Aggregate** (runtime boundary) | Pack is knowledge-time, no runtime | No pattern for "a group of entities updated together". Potentially useful to introduce **Knowledge Aggregate** |
| **Domain Events** (runtime notifications) | Pack is not executed | No way to describe "what happened". But this is not needed at knowledge-time |
| **Value Objects** (immutable, no ID) | All Pack entities have IDs | Some elements (metrics, characteristics) could be value objects, but we do not distinguish |
| **Repository** (storing aggregates) | This is an implementation pattern | Lives in downstream/instrument (code) |

### 7.3. Ideas we could take

| What | Why | Where to place | Priority |
|------|-----|---------------|---------|
| **Context Map Integration Patterns** (9 patterns) | Extend Bridge types: Partnership, ACL, Conformist, Open Host, Shared Kernel, etc. | FPF Bridges or SPF spec | High |
| **Core/Supporting/Generic** | Prioritize investment in Pack formalization | Pack Manifest: `subdomain_type` field | Medium |
| **Knowledge Aggregate** | Groups of Pack entities that MUST be updated together | SPF process | Medium |
| **Knowledge Storming** (Event Storming adaptation) | Method for discovering entities, distinctions and failure modes | SPF process (steps 3-4) | Low |

---

## 8. Summary table: DDD vs FPF/SPF/Pack

### 8.1. By capabilities

| Capability | DDD | FPF/SPF/Pack |
|------------|-----|-------------|
| Domain knowledge formalization | Through code (runtime) | Through structured text (knowledge-time) |
| Bounded Context | Yes | Yes (generalized) |
| Ubiquitous language | UL (oral + in code) | Glossary + Distinctions (formal, with tests) |
| Context integration patterns | 9 patterns (ACL, Partnership...) | Bridges (less developed) |
| Meta-level | No | FPF → SPF (2 meta-levels) |
| Runtime patterns | Aggregate, Event, Service, Repository | No (in downstream) |
| Failure modes | No | Yes (SPF 05, first-class citizens) |
| Trust/readiness metrics | No | Yes (F, G, R) |
| SoTA tracking | No | Yes (status + revision criteria) |
| Downstream contract | No | Yes (explicit knowledge→application interface) |
| Domain classification | Core/Supporting/Generic | No (can be taken) |
| Tooling and community | Mature (20+ years) | Young |

### 8.2. By source-of-truth

| Aspect | DDD | FPF/SPF/Pack |
|--------|-----|-------------|
| **Source-of-truth** | Code | Pack (text) |
| **If text ≠ code** | Update text (code is right) | Determine where truth lies and update the wrong one |
| **Who validates** | Developer (reads code) | Expert (reads Pack) + developer (reads code) |
| **Scaling** | Through people (communication) | Through artifact (Pack) |
| **Risk** | Knowledge locked in code | Desync between Pack and Code |

### 8.3. By work products

| DDD artifact | FPF/SPF/Pack analog | Match |
|-------------|--------------------|----|
| Ubiquitous Language Glossary | Glossary + Distinctions | High (ours are stricter) |
| Bounded Context Definition | Pack = Bounded Context | High (ours are more general) |
| Context Map | Bridges + Pack Manifest | Medium (DDD is richer) |
| Domain Vision Statement | Pack Manifest (scope) | Medium |
| Subdomain Classification | — | No (can be taken) |
| Entity | Domain Entity (DP.XXX.NNN) | Medium |
| Value Object | — | No analog |
| Aggregate | — | No (→ Knowledge Aggregate) |
| Domain Event | — | No (runtime vs knowledge-time) |
| Domain Service | Method (SPF 03) | Medium |
| Repository | Downstream/instrument | Low |
| Layered Architecture | 4-level hierarchy | Analogy (different layers) |

---

## 9. Positioning: what we are relative to DDD

### 9.1. Formulation

> **FPF/SPF/Pack is a generalization of key DDD patterns (Bounded Context, Ubiquitous Language, explicit boundaries) beyond code, to the formalization of domain knowledge as an independent artifact.**
>
> DDD formalizes the domain **through code**. We formalize the domain **before code**, in structured text (Pack), and code is a downstream product of Pack.
>
> At the same time we add what DDD lacks: meta-levels (FPF/SPF), failure modes, trust metrics, SoTA, downstream contracts.
>
> DDD and FPF/SPF/Pack **do not compete — they are sequential**:
>
> ```
> Domain (reality)
>     ↓  FPF/SPF/Pack: knowledge formalization
> Pack (source-of-truth)
>     ↓  DDD: code design based on knowledge
> Code (downstream/instrument)
> ```

### 9.2. Can we say "we do DDD"?

**No** — that would be imprecise. DDD is about code. We are about knowledge before code.

**Yes** — one can say: "we use DDD patterns (Bounded Context, UL), generalized to knowledge management".

**Most precisely:** "Our approach includes and extends the strategic patterns of DDD, but adds an independent domain knowledge artifact (Pack) that DDD does not create."

---

## 10. The core problem we are solving

DDD in effect proposes: "let the code be the model." But code is an implementation in a specific language, in a specific framework, with technical compromises. It inevitably mixes domain knowledge with implementation decisions.

A full-fledged domain knowledge artifact — independent of implementation, verifiable, readable by both business and developers and AI agents — DDD does not create. This is Evans's deliberate decision, not an oversight. But it has consequences:

- **Knowledge locked in code** — business expert cannot validate
- **No transfer without people** — developer leaves, knowledge of "why" leaves with them
- **No formal verification** — domain rules are nowhere fixed separately
- **Scaling through people** — oral UL does not scale to many teams

Pack solves these problems by creating an independent domain knowledge artifact. At the cost of needing to maintain Pack and Code synchronization (§6).

---

## Sources

- Evans, Eric. *Domain-Driven Design: Tackling Complexity in the Heart of Software.* 2003.
- Evans, Eric. *Domain-Driven Design Reference.* 2015. (CC-licensed)
- Vernon, Vaughn. *Implementing Domain-Driven Design.* 2013.
- Vernon, Vaughn. *Domain-Driven Design Distilled.* 2016.
- Fowler, Martin. [BoundedContext](https://martinfowler.com/bliki/BoundedContext.html), [DomainDrivenDesign](https://martinfowler.com/bliki/DomainDrivenDesign.html).
- FPF-Spec.md, A.1.1 (U.BoundedContext): *"FPF generalizes the proven DDD idea of a Bounded Context from software into a universal modeling primitive."*
- SPF/docs/fpf-spf-pack.md, §14.1.
