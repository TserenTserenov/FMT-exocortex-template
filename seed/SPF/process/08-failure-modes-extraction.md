# 08. Failure Modes Extraction

## Purpose

Extract and formalize failure modes as **first-class pack content**. Failure modes are not secondary documentation — they are essential knowledge about how domain practice goes wrong. A pack without failure modes is incomplete.

---

## Why Failure Modes Are First-Class

| Without Failure Modes | With Failure Modes |
|----------------------|-------------------|
| Only "correct" knowledge | Complete domain understanding |
| Errors unnamed | Errors identifiable and diagnosable |
| Confusion persists | Confusion has remediation path |
| Knowledge is theoretical | Knowledge is operational |

Every distinction implies at least one failure mode (the confusion it prevents). Every method has failure modes (ways it can be performed incorrectly or misunderstood).

---

## Failure Mode Types

| Type | Definition | Example |
|------|------------|---------|
| **Ontological** | Confusing two types of things | Tool confused with method |
| **Methodological** | Performing a method incorrectly | Accounting treated as planning |
| **Role** | Role missing or misassigned | No Agent performing the method |
| **Deprecated interpretation** | Using outdated understanding | Treating accounting as productivity hack |
| **Work product** | Product missing or malformed | Description substituted for artifact |

---

## Inputs

| Input | Source | Required |
|-------|--------|----------|
| Failure mode candidates | Stage 06 | Yes |
| Distinctions | Stage 03 | Yes |
| Methods | Stage 07 | Yes |
| Failure mode template | `/pack/_template/05-failure-modes/` | Yes |

---

## Activity

### 1. Source Failure Mode Candidates

Failure modes come from:

| Source | How |
|--------|-----|
| Distinctions | Each distinction implies confusion that can occur |
| Methods | Each method can be misperformed or misunderstood |
| Information analysis | Sources describe errors, anti-patterns |
| Experience | Observed failures in practice |

### 2. Type Each Failure Mode

Assign a type from the taxonomy:

| Type | Test |
|------|------|
| Ontological | Does this confuse two types of entities? |
| Methodological | Does this describe incorrect method execution? |
| Role | Does this describe missing or wrong role? |
| Deprecated interpretation | Does this describe outdated but persistent understanding? |
| Work product | Does this describe missing or malformed artifact? |

### 3. Assign Stable ID

| Item | Pattern | Example |
|------|---------|---------|
| Failure Mode | `<DOMAIN>.FAIL.<NNN>` | `PD.FAIL.001` |

### 4. Create Failure Mode Card

File: `/pack/<domain>/05-failure-modes/<ID>-<name>.md`

Required sections:

| Section | Content |
|---------|---------|
| YAML frontmatter | id, name, type, severity, status, dates |
| Definition | What the failure mode is |
| Error type | Ontological, methodological, etc. |
| Detection test | How to recognize this error in speech/text/behavior |
| Why it is an error | What makes this wrong (reference distinction) |
| Correct understanding | What should be understood instead |
| Risk/harm | Consequences if not corrected |
| Related items | Links to distinctions, methods, products |
| Detection methods | How to identify early |

### 5. Link to Distinctions

Every failure mode should reference the distinction it violates:

| Failure Mode | Violates Distinction |
|--------------|---------------------|
| Tool confused with method | D.001 Method vs. Tool |
| Work product confused with description | D.005 Work Product vs. Description |
| Accounting treated as planning | D.003 Accounting vs. Planning |

### 6. Cross-Reference

Ensure bidirectional links:
- Failure Mode → Distinction (violates)
- Failure Mode → Method (affects)
- Failure Mode → Work Product (affects)
- Distinction → Failure Mode (implied by)
- Method → Failure Mode (has failure modes)

---

## Output: Work Products

| Product | Location |
|---------|----------|
| Failure mode card(s) | `/pack/<domain>/05-failure-modes/` |
| Updated cross-references | In linked files |

---

## Completion Criteria

| Criterion | Test |
|-----------|------|
| Type assigned | Error type is explicit |
| Detection test exists | Can identify this error in practice |
| Distinction linked | References violated distinction |
| Consequence stated | Risk/harm is specified |
| ID follows convention | `<DOMAIN>.FAIL.<NNN>` |
| Cross-references valid | All links resolve |

---

## Typical Errors

### E1. Failure Mode Is Too Vague

**Symptom**: "Failure mode: Doing it wrong"

**Problem**: No detection criteria; cannot identify in practice.

**Correction**: Specify how this manifests in speech, text, or behavior.

### E2. Failure Mode Has No Distinction Link

**Symptom**: Failure mode described but no underlying confusion identified.

**Problem**: Root cause unclear; remediation impossible.

**Correction**: What distinction does this violate? Link it.

### E3. Missing Detection Test

**Symptom**: Failure mode defined but no way to recognize it.

**Problem**: Cannot diagnose; error goes unnoticed.

**Correction**: Add detection test: "This error manifests when..."

### E4. Failure Modes Not First-Class

**Symptom**: Failure modes mentioned in method cards but no separate files.

**Problem**: Cannot navigate to failure modes; cannot cross-reference.

**Correction**: Create dedicated failure mode cards.

### E5. No Severity Assessment

**Symptom**: All failure modes treated equally.

**Problem**: Cannot prioritize correction.

**Correction**: Assign severity: critical / major / minor.

### E6. Copying Instead of Formalizing

**Symptom**: Failure mode description copied from source.

**Problem**: Source's framing preserved; distinctions not applied.

**Correction**: Express in domain terms through domain distinctions.

---

## Failure Mode Extraction Checklist

Before committing a new failure mode:

- [ ] Definition is specific and testable
- [ ] Error type assigned (ontological/methodological/etc.)
- [ ] Detection test specifies observable symptoms
- [ ] Distinction link present
- [ ] Correct understanding stated
- [ ] Risk/harm documented
- [ ] Related methods/products linked
- [ ] Severity assigned
- [ ] ID follows convention
- [ ] Cross-references valid

---

## Failure Modes and Distinctions

For every distinction D, there should be at least one failure mode FM:

| Distinction | Implied Failure Mode |
|-------------|---------------------|
| D.001 Method vs. Tool | FM: Tool confused with method |
| D.003 Accounting vs. Planning | FM: Accounting confused with planning |
| D.005 Work Product vs. Description | FM: Description substituted for product |
| D.009 Registration vs. Intervention | FM: Registration expected to cause change |

If a distinction lacks a corresponding failure mode, either:
- The failure mode should be created
- The distinction is not operationally important (reconsider)

---

## Transition to Next Stage

When Failure Modes Extraction is complete:
- Failure mode cards exist in `05-failure-modes/`
- Each failure mode has type, detection test, distinction link
- Cross-references are valid

Proceed to:
- [09. SoTA Annotation](09-sota-annotation.md) for SoTA status assignment
- [10. Map Maintenance](10-map-maintenance.md) to update navigation (mandatory)
