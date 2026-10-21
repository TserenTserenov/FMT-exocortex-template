# Knowledge Routing

> **Source-of-truth** for all KE prompts.
> When adding a new Pack — update ONLY this file.
> All prompts read routing from here.

---

## 1. Pack Repositories by Domain

> Add your Packs to this table. Example:

| Domain | Pack | Prefix | Path |
|--------|------|--------|------|
| _Your domain (e.g. Machine Learning)_ | _PACK-my-domain_ | _MD_ | _{{WORKSPACE_DIR}}/PACK-my-domain/pack/my-domain/_ |

<!-- Delete the example above and add your Packs. Format:
| Domain (keywords) | Pack repo name | Short prefix (2-3 letters) | Path to pack/ directory |
-->

## 2. Directories by Knowledge Type

| Type | Code | Directory in Pack | File format |
|------|------|-------------------|-------------|
| Domain entity | `entity` | `02-domain-entities/` | Separate file |
| Distinction | `distinction` | `01-domain-contract/01B-distinctions.md` | Section in file |
| Method | `method` | `03-methods/` | Separate file |
| Work Product | `wp` | `04-work-products/` | Separate file |
| Failure mode | `fm` | `05-failure-modes/` | Separate file |
| Characteristic | `chr` | `06-characteristics/` | Separate file |
| SoTA annotation | `sota` | `08-sota/` | Separate file |
| Rule (global) | `rule` | `{{WORKSPACE_DIR}}/CLAUDE.md` | Lines |
| Rule (local) | `rule` | `<repo>/CLAUDE.md` | Lines |
| Rule (lesson) | `rule` | `memory/<topic>.md` | Lines |

## 3. File Naming

**Convention:** `{PREFIX}.{TYPE}.{NNN}-{slug}.md`

| Component | Source | Example |
|-----------|--------|---------|
| `PREFIX` | "Prefix" column from table 1 | `MD`, `DP`, `PP` |
| `TYPE` | Type code (AISYS, METHOD, FM, WP, CHR, SOTA, ...) | `METHOD` |
| `NNN` | max(existing) + 1 | `002` |
| `slug` | kebab-case of the name | `handler-per-state` |

## 4. Routing Test

For each candidate:

1. **Domain?** → identify Pack from table 1
2. **Knowledge type?** → identify directory from table 2
3. **MCP check:** `knowledge_search("candidate topic")` → is it already in the knowledge base?
4. **Bounded Context check:** Read `00-pack-manifest.md` of the target Pack — does the candidate fall within scope?
5. **If the candidate does not fit any Pack** → propose defer and clarify with the user

## 5. DS Routing (Implementation Knowledge)

> Implementation knowledge (vendor, stack, deployment, configuration) → DS repo, **not Pack**.
> One KE pipeline → two outputs: domain → Pack (§1-4), implementation → DS docs/ (§5).

| Signal | Where to route |
|--------|----------------|
| Used in another project/context? **Yes** | → Pack (domain) |
| Tied to a specific stack/vendor? **Yes** | → DS docs/ (implementation) |
| Describes "what" and "why" (architectural pattern)? | → Pack |
| Describes "exactly how" (configuration, deployment)? | → DS docs/ |

### DS Repositories by System

> Add your DS repos to this table. Example:

| System | DS repo | Path to docs/ |
|--------|---------|---------------|
| _My bot_ | _your-org/my-bot_ | _{{WORKSPACE_DIR}}/your-org/my-bot/docs/_ |

<!-- Delete the example and add your DS repos -->

### Directories in DS docs/

| Implementation knowledge type | Directory | Format |
|-------------------------------|-----------|--------|
| Usage scenario | `docs/scenarios/` | Separate file |
| Process / algorithm | `docs/processes/` | Separate file |
| Data schema | `docs/data/` | Separate file |
| Architectural decision (stack, integration) | `implementation.md` in C.IT-Platform | Section in file |

### Formalizing DS Candidates

DS candidates **do not require** a frontmatter with trust/epistemic_stage (unlike Pack). Format:

```markdown
# {Scenario/process name}

## Description
{What it does}

## Steps / Algorithm
{How it works}

## Relations
- Pack: [{ID}](path) — domain basis
- Code: `{module/file}` — implementation
```

## 6. Feedback

On reject/defer — record the reason in `config/feedback-log.md`.
On repeated inbox check — read feedback-log and do not propose similar candidates again.

---

*Last updated: {{today's date}}*