# AI View Specification

This document specifies how AI systems should consume and represent SPF Personal content.

---

## Purpose

AI systems (chatbots, agents, RAG pipelines) need to:
1. Retrieve relevant domain knowledge
2. Maintain accuracy to source
3. Respect the epistemology (not invent distinctions)

---

## Retrieval Architecture

### Recommended Approach

```
[SPF Markdown] → [Chunking/Embedding Pipeline] → [Vector Store]
                          ↓
              [Metadata Preservation Layer]
                          ↓
                   [AI Agent/RAG]
```

### Chunking Guidelines

| Content Type | Chunk Strategy |
|--------------|----------------|
| Method cards | One chunk per card (preserve wholeness) |
| Distinctions | One chunk per distinction block |
| Work products | One chunk per card |
| Failure modes | One chunk per card |
| Maps | Do not chunk; use as navigation metadata |

### Metadata to Preserve

Each chunk should retain:
- `id`: The stable ID (e.g., `PD.M.001`)
- `type`: method | work-product | failure-mode | distinction | sota
- `source_path`: Relative path in repo
- `sota_status`: current | deprecated-interpretation | hypothesis (if applicable)

---

## Response Generation Rules

AI systems using SPF content should:

### Do
- Quote or paraphrase source accurately
- Cite IDs when referencing specific items
- Respect SoTA status (flag hypotheses as such)
- Distinguish methods from tools, work products from descriptions

### Do Not
- Invent new methods not in the source
- Present deprecated interpretations as current
- Conflate different entity types
- Add didactic framing ("Step 1: ...) unless user requests it

---

## Grounding Protocol

When an AI response references SPF content:

```
User: What methods exist for X?

AI: According to SPF Personal, the following methods address X:
- [PD.M.001] Method Name — brief description
- [PD.M.002] Method Name — brief description

[Note: PD.M.002 has SoTA status "hypothesis" — evidence is preliminary]
```

---

## Hallucination Prevention

- AI should admit when SPF has no content for a query
- Phrase: "SPF Personal does not currently include methods for X"
- Do not generate plausible-sounding but non-existent methods

---

## Update Synchronization

AI systems should:
1. Re-index when SPF version changes
2. Invalidate cached embeddings on major version bumps
3. Log source version in responses (optional)

---

## Testing Recommendations

Downstream AI teams should test:
- [ ] Accurate retrieval of method cards by ID
- [ ] Correct SoTA status reporting
- [ ] No hallucinated methods
- [ ] Proper distinction between methods/tools/work-products
