# 10. Map Maintenance

## Purpose

Maintain the navigation map that connects all pack content. The map is **mandatory infrastructure** — it is not optional documentation. Every structural change to the pack requires a corresponding map update.

---

## Why Maps Are Mandatory

| Without Map | With Map |
|-------------|----------|
| Content is discoverable only by filename | Content is discoverable by relationship |
| Relationships implicit | Relationships explicit |
| Completeness unknown | Gaps visible |
| Navigation by browsing | Navigation by structure |

The map answers: **"What is in this pack, and how does it connect?"**

---

## When Map Updates Are Required

| Action | Map Update Required |
|--------|-------------------|
| Add method | Yes |
| Add work product | Yes |
| Add failure mode | Yes |
| Add distinction | Yes |
| Add SoTA annotation | Yes |
| Modify relationships | Yes |
| Fix typo in existing file | No |
| Update SoTA status | Yes (if changes relationships) |

**Rule**: If the change affects what exists or how things connect, update the map.

---

## Inputs

| Input | Source | Required |
|-------|--------|----------|
| Current pack content | All pack files | Yes |
| Recent changes | Stages 03-09 | Yes |
| Map template | `/pack/_template/07-map/` | Yes |

---

## Activity

### 1. Identify Map Impact

For each change, determine:

| Question | If Yes |
|----------|--------|
| New item added? | Add to relevant map section |
| Relationship changed? | Update cross-reference matrix |
| Item removed/deprecated? | Mark in map (do not delete) |
| Status changed? | Update status column |

### 2. Update Map File

File: `/pack/<domain>/07-map/PD.MAP.001.md` (or similar)

Required sections to check:

| Section | Update If |
|---------|-----------|
| Pack Status | Item counts change |
| Distinctions table | Distinction added/changed |
| Roles table | Role added/changed |
| Objects of Attention table | Object added/changed |
| Methods table | Method added/changed |
| Work Products table | Product added/changed |
| Failure Modes table | FM added/changed |
| SoTA Annotations table | SoTA added/changed |
| Cross-Reference Matrix | Any relationship changes |

### 3. Verify All Links

For every link in the map:

| Check | Action if Fails |
|-------|----------------|
| Link resolves | Fix path |
| Target exists | Create or remove link |
| Anchor exists | Fix anchor or remove |

### 4. Update Relationship Diagram (if present)

If the map includes a visual diagram:
- Add new items
- Add new relationships
- Keep diagram consistent with tables

### 5. Update Update Log

At the bottom of the map file:

```markdown
## Update Log

| Date | Change |
|------|--------|
| YYYY-MM-DD | Added METHOD.002, updated cross-references |
```

---

## Output: Work Products

| Product | Location |
|---------|----------|
| Updated map file(s) | `/pack/<domain>/07-map/` |

---

## Completion Criteria

| Criterion | Test |
|-----------|------|
| All new items in map | Every added method/product/FM/etc. appears |
| Counts accurate | Pack Status section matches actual content |
| Links valid | All links resolve |
| Relationships current | Cross-reference matrix reflects actual links |
| Update log entry | Current date and change noted |

---

## Typical Errors

### E1. Skipping Map Update

**Symptom**: New method exists but map still shows "None yet."

**Problem**: Method is undiscoverable; pack appears incomplete.

**Correction**: Make map update part of extraction stage.

### E2. Map Counts Inaccurate

**Symptom**: Map says "3 methods" but there are 5.

**Problem**: Pack status misrepresented; gaps invisible.

**Correction**: Count actual files; update status table.

### E3. Broken Links

**Symptom**: Map links to `PD.METHOD.001.md` but file is named differently.

**Problem**: Navigation fails; trust in map degrades.

**Correction**: Verify links after every update.

### E4. Missing Cross-References

**Symptom**: Method produces WP but map doesn't show relationship.

**Problem**: Relationships invisible; structure unclear.

**Correction**: Update cross-reference matrix when adding content.

### E5. Map as Afterthought

**Symptom**: Map updated sporadically, long after content changes.

**Problem**: Map drifts from reality; becomes unreliable.

**Correction**: Map update is part of every extraction stage, not a separate task.

### E6. Multiple Inconsistent Maps

**Symptom**: Several map files with conflicting information.

**Problem**: No single source of truth for structure.

**Correction**: One primary map per pack; additional maps are views, not sources.

---

## Map Maintenance Checklist

Before committing any pack change:

- [ ] Is this change reflected in the map?
- [ ] Are item counts accurate?
- [ ] Are all links valid?
- [ ] Is the cross-reference matrix current?
- [ ] Is the update log entry added?

---

## Map Structure Reference

Standard map sections:

```
1. Pack Status (counts by type)
2. Relationship Diagram (optional visual)
3. Distinctions Table
4. Roles Table
5. Objects of Attention Table
6. Methods Table
7. Work Products Table
8. Failure Modes Table
9. SoTA Annotations Table
10. Cross-Reference Matrix
    - Methods ↔ Distinctions
    - Methods ↔ Failure Modes
    - Failure Modes ↔ Distinctions
    - Work Products ↔ Roles
11. Navigation Hints
12. Update Log
```

---

## Transition to Next Stage

Map maintenance is not the "last" stage — it is performed after every extraction.

After map is updated, either:
- Return to earlier stages for more content (05 → 06 → 07/08/09 → 10)
- Proceed to [11. Review and Evolution Cycle](11-review-and-evolution-cycle.md) for periodic review
