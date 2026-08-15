---
scope: FMT-exocortex-template
status: active
title: Verifying Knowledge MCP Server Correctness (Pack/SPF/FPF)
updated: 2026-07-28
---

# Verifying Knowledge MCP Server Correctness (Pack/SPF/FPF)

> Audience: a pilot who wants to confirm that the knowledge MCP server (`mcp__aisystant__knowledge_*`) actually sees and correctly returns content from FPF (First Principles Framework) or another platform source (SPF, Pack).
> Time: ~5 minutes.
> The three tools below provide three independent verification levels — from "source is connected at all" to "content is actually findable and matches the original source."

## Level 1 — Source is connected and indexed

```
knowledge_list_sources(source_type="pack")
```

The response must contain an entry with `"source": "FPF"` and a non-zero `doc_count`. If the entry is absent, the source is not connected at the technical level and further checks are pointless.

Live response example (28.07.2026): `FPF` — 3528 documents, `SPF` — 144 documents, all Platform Packs visible alongside them.

## Level 2 — Concept graph is built and not empty

```
knowledge_graph_stats()
```

Look at the `by_level` section — it must contain a row with `"level": "fpf"` and a non-zero `cnt` (the number of FPF-level concepts in the relationship graph; this is not the same as `doc_count` from Level 1 — these are concepts extracted from documents, not the documents themselves).

Also check:

- `orphans` — the list of concepts with no connections in the graph. A small list (tens, not hundreds) is normal; this is expected noise. If FPF concepts appear in `orphans` in large numbers, this signals that the relationship graph was built without accounting for FPF content.
- `suspicious_edges` — connections with low confidence (`weight_source: "embedding"`, not an explicit reference in the text). This is not an error in itself; these are candidates for manual review.

## Level 3 — Content is actually findable and matches the original source

Take a term or principle from FPF that you know well (something you remember verbatim or nearly so) and search for it:

```
knowledge_search(query="<your term>", source="FPF", limit=3)
```

Check the following in the response:

1. **`content`** — does the text actually contain what you expected, not just something loosely related to the topic.
2. **`github_url`** — link to the original source (for example, `https://github.com/ailev/FPF/blob/main/FPF-Spec.md`). Open it and verify that the found fragment is actually present there, verbatim or close to the text.
3. **`score`** — relevance of the found fragment to the query (0–1). If the score for an exact term is noticeably below 0.5, the index may be stale or the term may be absent from the source document.

**Live verification example (28.07.2026):** the query `"Episteme A.2.1 system in a role"` with `source="FPF"` returned an exact quote from `FPF-Spec.md::A.2 - Role Taxonomy` with a correct link to `github.com/ailev/FPF` and a score of 0.79 — content confirmed by verbatim match with the original source.

## If something does not match

- **Source missing at Level 1** — re-indexing was never triggered, or the path to FPF in the MCP server Configuration is incorrect. Contact whoever set up your knowledge MCP server (it is a separate Component, not part of this Repository Template).
- **Source present but graph is empty (Level 2)** — documents are indexed, but concept extraction from them was never triggered or failed with an error.
- **Search does not find a known term (Level 3)** — either the term is phrased differently from the source document (try a different wording), or the index has not been updated since the last change to the FPF source files.

In all three cases the problem is not in your Repository (Template) — it is in the Configuration of the knowledge MCP server itself, which is a separate Service.

## Related documents

- `docs/AGENT-VENDOR-SETUP.md` — connecting an agent to MCP tools in general.
