# 05. Information Ingestion

## Purpose

Admit materials (sources, experiences, observations) for analysis. Information is the **raw input** to the knowledge-creation process — it is NOT knowledge and does NOT become pack content directly.

---

## Information ≠ Knowledge

| Information | Knowledge |
|-------------|-----------|
| Raw material | Structured understanding |
| Needs analysis | Result of analysis |
| Source-dependent | Source-independent (once validated) |
| May be wrong | Has assigned SoTA status |
| Outside pack | Inside pack |

**Information enters; knowledge is produced.** This stage admits information; Stage 06 transforms it.

---

## Inputs

| Input | Source | Required |
|-------|--------|----------|
| Bounded context | Stage 02 | Yes |
| Distinctions | Stage 03 | Yes |
| Domain entities | Stage 04 | Yes |
| Materials to analyze | Various sources | Yes |

---

## What Counts as Information

| Acceptable Information | How It Enters |
|-----------------------|---------------|
| Published literature (books, papers) | Citation + summary |
| Expert testimony | Attributed claim |
| Observed practice | Documented observation |
| Own experience | Documented experience |
| Existing frameworks | Referenced framework |

| NOT Information (Do Not Admit) | Why |
|-------------------------------|-----|
| Unsourced claims | No traceability |
| Hearsay ("people say...") | No accountability |
| Pure opinion without reasoning | No analysis possible |
| Proprietary content without rights | Legal issues |

---

## Activity

### 1. Identify Candidate Materials

Given the bounded context, what materials might contain relevant knowledge?

| Material Type | Example | Relevance Test |
|--------------|---------|----------------|
| Foundational texts | Lyubishchev's time diaries | Historical origin of method |
| Academic literature | Papers on self-quantification | Research findings |
| Practitioner accounts | Blog posts by practitioners | Experience reports |
| Existing frameworks | GTD, Pomodoro, etc. | Adjacent practices |

### 2. Apply Relevance Filter

Use distinctions and bounded context as filter:

| Filter Question | Action if No |
|----------------|--------------|
| Is this within bounded context? | Exclude |
| Does this relate to identified entities? | Exclude |
| Can this be analyzed through distinctions? | Defer (may need new distinctions) |

### 3. Create Ingestion Log

**Location**: NOT in pack. Ingestion log is process artifact, not knowledge artifact.

For each admitted material:

```
Material: [Title/Description]
Source: [Citation/Reference]
Date ingested: [Date]
Relevance: [Why this material is relevant]
Notes: [Initial observations]
Status: [pending-analysis | analyzed | rejected]
```

### 4. Batch for Analysis

Group materials by:
- Topic area (which entities/methods they might inform)
- Source type (primary vs. secondary)
- Confidence level (peer-reviewed vs. opinion)

---

## Output: Work Products

| Product | Location | Content |
|---------|----------|---------|
| Ingestion log | `/process/working/ingestion-log.md` (not in pack) | List of admitted materials |
| Material summaries | `/process/working/` (not in pack) | Brief summaries for analysis |

**These outputs are NOT pack content.** They are process artifacts.

---

## Completion Criteria

| Criterion | Test |
|-----------|------|
| Materials identified | At least one material per major entity |
| Relevance filtered | Each material passes bounded context test |
| Ingestion log created | Log file exists with entries |
| Materials batched | Grouped for analysis |
| No pack files modified | Information not yet in pack |

---

## Typical Errors

### E1. Information Becomes Pack Content Directly

**Symptom**: Copy-paste from source into `03-methods/` file.

**Problem**: Information is not knowledge; it has not been analyzed, validated, or formalized.

**Correction**: Information goes to ingestion log → Stage 06 analysis → only then to pack.

### E2. No Relevance Filter

**Symptom**: "This is interesting, let's include it" (even if outside scope).

**Problem**: Pack accumulates off-topic content; coherence degrades.

**Correction**: Every material must pass bounded context and entity relevance tests.

### E3. Source Not Recorded

**Symptom**: "I read somewhere that..." (no citation).

**Problem**: Cannot trace claims; cannot validate; cannot update when source updates.

**Correction**: Every material needs attribution before ingestion.

### E4. Ingestion Log in Pack

**Symptom**: `/pack/<domain>/sources.md` with list of materials.

**Problem**: Sources are process artifacts, not knowledge artifacts.

**Correction**: Ingestion log stays in `/process/working/`, not in `/pack/`.

### E5. Skipping to Extraction

**Symptom**: "I know what the methods are, let's just write them."

**Problem**: Methods without information trail are unsupported claims.

**Correction**: Even "known" methods should have information sources documented.

### E6. Information Overload

**Symptom**: Hundreds of materials ingested without batching.

**Problem**: Analysis becomes impossible; paralysis.

**Correction**: Batch by relevance; prioritize foundational materials.

---

## Information Types and Treatment

| Information Type | Treatment | Confidence |
|-----------------|-----------|------------|
| Primary source (original practice) | High priority | High |
| Peer-reviewed research | Analyze claims | Medium-High |
| Practitioner account | Extract experience, verify | Medium |
| Popular literature | Extract claims, high scrutiny | Low-Medium |
| Opinion/Blog | Use only if corroborated | Low |

---

## Transition to Next Stage

When Information Ingestion is complete:
- Ingestion log exists with attributed materials
- Materials are filtered for relevance
- Materials are batched for analysis
- No pack files have been modified

Proceed to [06. Analysis and Formalization](06-analysis-and-formalization.md) to transform information into candidates.
