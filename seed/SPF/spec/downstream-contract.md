# Downstream Contract

This document specifies the contract between SPF Personal (this repo) and downstream consumers (courses, AI agents, guides, applications).

---

## Principles

1. **SPF is source-of-truth** for domain knowledge structure
2. **Downstream transforms, does not modify** — consumers read and transform, never write back
3. **Stability guarantees** — IDs are stable; deprecation over deletion

---

## What Downstream Systems May Do

| Action | Allowed | Notes |
|--------|---------|-------|
| Read all `/pack/` content | Yes | Primary use case |
| Transform to other formats | Yes | Markdown to HTML, JSON, etc. |
| Create embeddings/indexes | Yes | For AI retrieval |
| Add didactic wrappers | Yes | "Lesson 1: Understanding X" |
| Create learning paths | Yes | Sequence methods into curricula |
| Track user progress | Yes | In downstream DB, not here |
| Build AI agents | Yes | Using `/spec/ai-view.md` |

---

## What Downstream Systems Must NOT Do

| Action | Forbidden | Reason |
|--------|-----------|--------|
| Modify SPF source | Yes | Read-only dependency |
| Store canonical content in vectors only | Yes | Markdown is source |
| Assume file paths are stable | Yes | Use IDs, not paths |
| Embed FPF into downstream | Yes | Depend on FPF directly |

---

## Versioning Contract

- SPF Personal will use semantic versioning when stable
- Breaking changes (ID renames, structure changes) bump major version
- Additions bump minor version
- Fixes/clarifications bump patch version

Downstream should pin to a version or commit hash.

---

## ID Stability

IDs follow the pattern: `<DOMAIN>.<TYPE>.<NNN>`

| Guarantee | Description |
|-----------|-------------|
| IDs are unique | No two items share an ID |
| IDs are immutable | Once assigned, never reused |
| Deprecated items keep IDs | Marked deprecated, not deleted |

Downstream may rely on IDs for persistent references.

---

## File Format Contract

All content files are:
- UTF-8 encoded Markdown
- YAML frontmatter optional (for metadata)
- GitHub-flavored Markdown syntax

---

## Change Notification

Downstream systems should:
1. Watch releases/tags for updates
2. Diff against previous version
3. Update transformations as needed

No push notification mechanism exists (this is a static repo).
