---
browser_safe: false
description: 'Instructions for the IWE template author: staging channel (testing →
  FMT), L3 author rules, Extensions Gate. Load when: staging / promote / author /
  template / extensions / L3.'
layer: L1
name: author-mode
status: active
triggers:
  phrases:
  - staging
  - promote
  - author
  - author_mode
  - extensions gate
  - L3
  - authoring
  - template FMT
  slash:
  - /author-mode
version: 1.0.0
---

# /author-mode — IWE Author Mode

> **Trigger:** staging / promote / author / template / extensions  
> **Applies to:** template author only (author_mode: true)

## §8. Staging (testing → template)

> Rules under testing. When validated, they move to the template (L1).

### Staging channel

**Rule for adding:** new behavior in §9 (author) → SIMULTANEOUSLY add a row to `STAGING.md` (`status: testing`).

**Promotion (at Week Close):**
1. Review `STAGING.md` — are there `testing` entries ready for promotion? Readiness (`validated`) means more than "the author ran it locally" — the rule must pass verification on at least one non-author profile/user of the template (ADR-IWE-014 R8, carrier-replacement test): any personal path/key/assumption of the author that does not survive that replacement is not ready for promotion — it stays `testing` or moves to `rejected`.
2. Remove author-specific constants → replace with `{{PLACEHOLDER}}`
3. **Mode (ADR-IWE-014 R9, WP-552 Phase 5):** ask — is this mandatory for all template installations, or a toggleable marketplace extension? This axis is orthogonal to R8 and is decided independently of readiness from step 1. Toggleable extension → see "Marketplace extension branch" below; mandatory template rule → go directly to step 4.
4. Move to `IWE` + commit `feat: promote S-NN from staging`
5. Update `STAGING.md`: status → `promoted`, "Mode" column → `mandatory` or `extension`

**Rejection:** anything specific to the author environment → status `rejected` (stays in §9, not promoted). Do not delete from the table — this is a recorded decision.

**Marketplace extension branch:** `promote-common.sh` writes the entry to `marketplace-manifest.yaml` rather than `promotion-status.yaml` — fields: `type` (existing Artifact type: Pack, skill, `AR.NNN`, Role — no new type is created), `owner`, `install_point`, `permissions`, `toggleable`, `conflict_rule`, `staging_source` (reference to the `STAGING.md` row for auditability — which rule passed the R8 test and when).

## §9. Author layer (L3 — my IWE only)

> This section is the personal L3 layer. `update.sh` does **not touch** it during updates.  
> Add rules and constants here that apply only to your environment.  
> L1/L2/L3 Architecture: `CONTRIBUTING.md §Three Layers`.

### Extensions Gate (BLOCKING)

**For users:** customizing Protocols/Skills → ONLY in `extensions/*.md`.  
Directly editing `.claude/skills/` or `memory/protocol-*.md` is an error.

**Architectural rationale:** platform files (L1) and user extensions (L3) are separate layers. Mixing layers creates brittleness during updates.  
Separation: platform → `IWE` → `update.sh`. User → `extensions/` + `params.yaml`.

**Author (author_mode: true):** direct editing of L1 is PERMITTED.  
Delivery to FMT: `bash $IWE_SCRIPTS/{script|hook|skill}-promote.sh <file> [--dry-run]`  
CLAUDE.md: `bash $IWE_SCRIPTS/template-sync.sh` (sync / `--dry-run` / `--check`)

### Naming (placeholders)

- `{{GOVERNANCE_REPO}}` — personal governance hub
- `${IWE_WORKSPACE:-$HOME/IWE}/` — working directory

### Blocking rules (author)

> Fill in with rules specific to the author environment.

### Distinctions (author)

> Stored in `memory/distinctions-warm.md` and `extensions/`. The file `.claude/rules/distinctions.md` belongs to the platform hot layer; `update.sh` preserves only the explicitly marked `USER-SPACE` block.

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
