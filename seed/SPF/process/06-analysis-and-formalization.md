# 06. Analysis and Formalization

## Purpose

Transform ingested information into **candidates** for pack content by applying distinctions systematically. Analysis separates signal from noise; formalization structures candidates for extraction.

---

## Why Analysis Cannot Be Skipped

| Without Analysis | With Analysis |
|-----------------|---------------|
| Source text copied | Source claims examined |
| Author's framing preserved | Domain framing applied |
| Implicit assumptions inherited | Assumptions made explicit |
| Terminology mixed | Distinctions applied |

Analysis is the act of **applying distinctions to information**. Without it, information remains external opinion, not domain knowledge.

---

## Inputs

| Input | Source | Required |
|-------|--------|----------|
| Ingestion log | Stage 05 | Yes |
| Distinctions | Stage 03 | Yes |
| Domain entities | Stage 04 | Yes |
| Materials | Stage 05 batches | Yes |

---

## Activity

### 1. Apply Distinctions to Each Material

For each ingested material, ask:

| Distinction | Question |
|-------------|----------|
| method vs. tool | Does this describe a way of acting or an artifact? |
| role vs. person | Does this describe a function or an individual? |
| work product vs. description | Does this identify an artifact or narrate about one? |
| actual vs. intended | Does this describe what happened or what should happen? |
| observation vs. judgment | Does this record facts or evaluate them? |

Document which distinctions apply and what the material says when viewed through each.

### 2. Identify Candidates

Through distinction-based analysis, identify:

| Candidate Type | How Identified |
|----------------|----------------|
| Method candidate | Source describes repeatable way of acting with inputs/outputs |
| Work product candidate | Source describes observable artifact with criteria |
| Failure mode candidate | Source describes confusion, error, or anti-pattern |
| Distinction candidate | Source reveals contrast that must not be conflated |
| SoTA update candidate | Source provides evidence for status change |

### 3. Check Against Existing Pack Content

| Question | Action if Yes |
|----------|--------------|
| Does this method already exist? | Update existing, not duplicate |
| Does this distinction already exist? | Refine or extend existing |
| Does this contradict existing content? | Flag for resolution |
| Does this extend existing content? | Note the extension |

### 4. Formalize Candidates

For each candidate, create a structured entry:

**Method Candidate**:
```
Candidate ID: [temp ID]
Type: method
Source: [citation]
Name: [proposed name]
Definition: [what it is]
Inputs: [what it takes]
Outputs: [what it produces]
Distinctions applied: [which distinctions structure this]
Open questions: [what needs clarification]
Status: pending-extraction | ready | rejected
```

**Work Product Candidate**:
```
Candidate ID: [temp ID]
Type: work-product
Source: [citation]
Name: [proposed name]
Definition: [what it is]
Observability criteria: [how to verify it exists]
Produced by: [which method]
Open questions: [what needs clarification]
Status: pending-extraction | ready | rejected
```

**Failure Mode Candidate**:
```
Candidate ID: [temp ID]
Type: failure-mode
Source: [citation]
Name: [proposed name]
Error type: [ontological | methodological | role | deprecated-interpretation]
Distinction violated: [which distinction]
Symptoms: [how it manifests]
Open questions: [what needs clarification]
Status: pending-extraction | ready | rejected
```

### 5. Do NOT Copy Source Text

| Forbidden | Required |
|-----------|----------|
| "According to Smith, the method is..." | "The method produces X by doing Y" (domain terms) |
| Quoting source's framing | Using pack's distinctions |
| Preserving source's terminology | Mapping to domain terminology |

The pack is not a collection of citations. It is domain knowledge expressed through domain distinctions.

---

## Output: Work Products

| Product | Location | Content |
|---------|----------|---------|
| Analysis notes | `/process/working/` (not in pack) | Distinction application notes |
| Candidate list | `/process/working/candidates.md` | Formalized candidates |

**These outputs are NOT pack content.** They are inputs to extraction stages.

---

## Completion Criteria

| Criterion | Test |
|-----------|------|
| Materials analyzed | Each ingested material has analysis notes |
| Distinctions applied | Each analysis references specific distinctions |
| Candidates identified | At least one candidate of each relevant type |
| Candidates formalized | Each candidate has structured entry |
| No source text copied | Pack-language used, not source-language |
| Open questions noted | Uncertainties are explicit |

---

## Typical Errors

### E1. Copying Source Text

**Symptom**: Pack file contains phrases from source materials.

**Problem**: Source's framing is preserved; distinctions not applied.

**Correction**: Express everything in domain terms through domain distinctions.

### E2. Analysis Without Distinctions

**Symptom**: "This looks like a method" (intuition only).

**Problem**: No criterion for identification; inconsistent results.

**Correction**: Explicitly apply method vs. tool distinction (and others).

### E3. Creating Duplicates

**Symptom**: "New method" that overlaps substantially with existing method.

**Problem**: Pack becomes redundant; relationships unclear.

**Correction**: Always check existing content before creating new.

### E4. Skipping Formalization

**Symptom**: "I know what this should be" → jumps to pack file.

**Problem**: Candidate not vetted; may be incomplete or wrong.

**Correction**: Formalize candidate first; extract only "ready" candidates.

### E5. Preserving Source's Errors

**Symptom**: Source confuses method and tool; pack inherits confusion.

**Problem**: Pack reproduces errors instead of correcting them.

**Correction**: Apply distinctions to detect and correct source errors.

### E6. Over-Analysis

**Symptom**: Endless analysis without producing candidates.

**Problem**: Analysis becomes academic exercise, not production process.

**Correction**: Time-box analysis; produce candidates even if imperfect.

---

## Analysis vs. Extraction

| Analysis (Stage 06) | Extraction (Stages 07-08) |
|--------------------|--------------------------|
| Produces candidates | Produces pack files |
| Applies distinctions | Uses formalized candidates |
| In working directory | In pack directory |
| Can be revised freely | Changes require process |

---

## Transition to Next Stage

When Analysis and Formalization is complete:
- Materials are analyzed through distinctions
- Candidates are formalized with structured entries
- Candidates have status (pending/ready/rejected)
- Open questions are documented

Proceed to:
- [07. Method and Product Extraction](07-method-and-product-extraction.md) for method/product candidates
- [08. Failure Modes Extraction](08-failure-modes-extraction.md) for failure mode candidates
