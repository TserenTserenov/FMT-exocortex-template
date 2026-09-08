# FORMAT.md — guide-kit data format specification

**Status:** normative. **`schema_version: 1`** across all artifacts below. Breaking changes bump this number; the Structurer refuses to write and the Generator refuses to read a mismatched version without an explicit `--allow-schema-mismatch` flag (deferred to implementation).

## Who this is for

You own a base of notes (Obsidian vault, Notion export, a folder of markdown, your own database export) and want the Structurer to classify it without reading guide-kit's source code. This document is the whole contract: six files, one pipeline order, one precedence rule for conflicts. If your data doesn't fit any of these shapes, `2.4` (see below) is the honest fallback, not an error.

## Pipeline order

```
media preprocessing → quarantine → homes.yaml → per-file classifier → freshness → type-index.json
```

Each stage only narrows what the previous stage left undecided. A file that a sidecar override already typed skips every later stage; a file no stage can place lands as `2.4`, never as a guess.

**Quarantine runs before typing, not after** (revised 2026-07-15 — the original draft placed it after the classifier; implementation found that a file already typed by `homes.yaml` never even had its content read, so a post-hoc quarantine check would either skip that file or force an unconditional re-read anyway). It is still cross-cutting, not a numbered stage of its own: any content-bearing file gets scanned once, before anything else decides its type, and a positive result short-circuits every stage that would follow.

---

## 1. Media preprocessing

Binary files are never classified from their raw bytes — text is extracted first, then the extracted text goes through the same pipeline as any other file.

| Format | Extractor | Status |
|---|---|---|
| `.md`, `.txt`, `.canvas` | none (already text) | built in |
| audio, video | local transcription (MLX Whisper wrapper) | configurable, see `extractors.yaml` |
| PDF | text layer first; empty layer → OCR queue | configurable |
| images (`.png`, `.jpg`, scans) | OCR / vision description | **no default extractor — see §6** |
| everything else | placement only (`homes.yaml`) | — |

Rules:

1. **A transcript is a derived file.** It lives at `.structurer/transcripts/<mirrored-path>.md`, never inside your own vault. Its frontmatter carries `derived_from`, `extractor`, `extracted_at`, `review_status: unreviewed`.
2. **The type is assigned to the original file, not the transcript.** The transcript inherits the original's type and quarantine flags. The Generator reads the transcript's text, but `decision_log` cites the original as the source (with a pointer to `derived_text`).
3. **Sidecar override wins over extraction.** See §5 — if you've already told the Structurer the type by hand, it does not spend time transcribing an hour of audio just to guess something you already know.
4. **Quarantine heuristics run on transcripts too.** A recording can expose a third party's PII (another person's voice) even when the original file's metadata looks clean.
5. **No extractor installed → honest gap, not a guess.** The file gets `"type": null, "pending": "needs-extractor"` in `type-index.json` and a line in the human-readable report (`.structurer/quarantine-report.md`'s sibling, the "unplaced" report). Content is never invented or inferred from the filename (same invariant as the classifier default in §3).

---

## 2. `homes.yaml` — placement-based typing

The first, coarse pass: a folder pattern maps to a type.

```yaml
schema_version: 1
homes:
  - path: "daily-notes/**"
    type: "2.2"
  - path: "concepts/**"
    type: "2.3"
  - path: "journal/**"
    type: "2.4"
    note: "reflections — unformalized remainder by default"
  - path: "archive/**"
    type: "auto"          # explicitly defer to the per-file classifier (§3)
```

**Precedence rule (proposed, not backed by an existing convention — flag for confirmation before implementation):** the most specific matching glob wins (`daily-notes/2026/**` outranks `daily-notes/**`); ties break on file order, first match wins. A path with no matching rule, or matched to `type: "auto"`, falls through to §3.

---

## 3. Per-file classifier

Applies only where `homes.yaml` didn't already decide (no match, or `type: "auto"`).

**Order, highest to lowest:**

1. Sidecar `<file>.meta.yaml` `type:` field (§5) — for files that have no frontmatter of their own (binaries: images, audio, proprietary formats). Sidecar and frontmatter never compete on the same file — a text file with frontmatter doesn't get a sidecar, a binary can't carry frontmatter. This is a partition by file kind, not a precedence contest.
2. Frontmatter `type:` / `user_intent:` field inside the file itself (text files only) — an explicit human statement always outranks a heuristic.
3. Structural signal:
   - has an event date → `2.2`
   - self-declared fact about the user → `2.1-declared`
   - a computed rollup of a stream (e.g. a weekly summary auto-generated from daily notes) → `2.1-derived`, tagged `"mirror": true` so the Generator knows not to treat it as an independent source
   - fits an established conceptual/methodical form (definitions, distinctions, methods) → `2.3`
   - a record of the user's own decisions/reasoning trail → `2.4`
4. LLM classification — **only** for files still ambiguous after 1–3, and only if an LLM backend is configured (`guide-kit.config.yaml`). Zero-config installs skip this step entirely.
5. **Default: `2.4`.** If nothing above placed the file — including "LLM disabled" — it is `2.4`, not a guess at a more specific type. Guessing content is exactly the failure mode `guide-kit` refuses to have (same "no invented facts" invariant that governs the hard-fail gate in `generator/adapter.py` and the missing-extractor case in §1). This is a deliberate trade-off: a file that would read as `2.3` to a human eye may still land in `2.4` when the signal is genuinely ambiguous and no LLM is configured to break the tie. That's the honest failure mode, not silent misclassification.

**Quarantine is cross-cutting**, not a fifth step: it runs before 1–4 (see pipeline order above and §4a), and it takes priority over whatever type the step would otherwise have assigned.

---

## 4. `type-index.json` — classifier output

One JSON file, one entry per source path (the *original* path — see §1 rule 2 for how media entries relate to their transcripts), wrapped in a `schema_version` envelope (see §Versioning — every artifact in this format carries the same version number at the top).

```json
{
  "schema_version": 1,
  "files": {
    "notes/2026/idea.md": {
      "type": "2.3",
      "mode": "index",
      "confidence": 0.95,
      "source": "homes",
      "freshness": { "valid_from": "2026-05-01" }
    },
    "media/standup-2026-06-01.mp4": {
      "type": "2.2",
      "mode": "pointer",
      "confidence": 0.7,
      "source": "classifier-on-transcript",
      "media": {
        "kind": "video",
        "derived_text": ".structurer/transcripts/media/standup-2026-06-01.mp4.md",
        "extractor": "whisper-mlx",
        "extracted_at": "2026-07-14"
      }
    },
    "photos/whiteboard.png": {
      "type": null,
      "pending": "needs-extractor",
      "note": "no OCR tool configured; placement-only if homes.yaml covers this path"
    },
    "inbox/voice-memo-with-a-colleagues-name.m4a": {
      "type": null,
      "quarantine": {
        "reason": "third-party-pii",
        "excluded_from_generation": true,
        "detected_by": "quarantine-heuristic-on-transcript"
      }
    }
  }
}
```

Field reference:

| Field | Meaning |
|---|---|
| `type` | `2.1-declared` \| `2.1-derived` \| `2.2` \| `2.3` \| `2.4` \| `null` — **`null` whenever `quarantine` is present** (quarantine is outside the 2.1-2.4 axis, not a fifth value on it), or when `pending` is present |
| `mode` | `index` (full text usable directly) \| `pointer` (points elsewhere, e.g. at a transcript) \| `external` (referenced but not owned by this base — `path` to a base outside this vault, e.g. a shared team drive; named in `CONCEPT-portable-guide-generator.md` §Разметчик, not otherwise illustrated here) |
| `confidence` | 0–1, classifier's own confidence; `homes.yaml` matches are `1.0` |
| `source` | which stage decided: `homes` \| `sidecar` \| `frontmatter` \| `classifier` \| `classifier-on-transcript` \| `llm-assisted` \| `default` |
| `freshness` | see §7 — present when the file has a determinable `valid_from` |
| `media` | present only for files that went through §1; carries the transcript pointer |
| `pending` | present only when `type` is `null` and the file isn't quarantined — always `"needs-extractor"` today, reserved for future pending reasons |
| `quarantine` | present only when the file is out-of-axis (§4a) — `reason`, `excluded_from_generation`, `detected_by` |

### 4a. Quarantine — outside the axis, not a value on it

Quarantine is **not** one of the 2.1-2.4 types — a quarantined file is out-of-axis by definition (mirrors the concept's own framing: "карантин «вне оси»"). It is encoded as a sibling `quarantine` object on the entry, with `type: null`, not as a string value inside `type`. `reason` is one of `pii` \| `secret` \| `payment` \| `third-party-pii` (this enum, and the `excluded_from_generation`/`detected_by` field names, were this document's own proposal — confirmed by implementation, peer-session 2026-07-15-01).

There is no normative `quarantine.yaml` — quarantine status lives on the `type-index.json` entry itself, so the Generator's loader filters on one field (`quarantine` presence) instead of cross-referencing two files. The Structurer additionally writes `.structurer/quarantine-report.md` — a plain-language list of quarantined paths and reasons, meant for the human to skim and correct false positives, not a second source of truth.

**What's actually detected vs. forced-flag-only (implementation decision, 2026-07-15).** The source concept frames the whole bucket as "чужие PII" (**someone else's** PII) — a credit card number or an API key is contraband regardless of whose it is, but a person's own email in their own notes is not a leak. A regex has no way to tell "my phone number" from "someone else's" (no identity source exists in this pipeline), so:

- `secret` and `payment` are detected automatically — ownership is irrelevant, the pattern alone is the signal (known vendor token formats, PEM private key headers, a labeled high-entropy assignment for arbitrary third-party keys; Luhn-valid card numbers, checksum-valid IBANs).
- `pii` and `third-party-pii` are **not** detected by heuristic in this slice. They stay valid `reason` values, reachable only through the forced flag below (or a future LLM-assisted pass) — guessing "this email belongs to someone else" is exactly the invented-fact failure mode this format refuses to have (same principle as the `2.4` default in §3 and the missing-extractor case in §1).

**Forced flag and escape hatch, for text files.** `speakers_third_party: true` was originally documented only as a sidecar field (§5, binaries without frontmatter); it is equally valid as a frontmatter key on text files — same forced-quarantine semantics, `reason: third-party-pii`, `detected_by: "forced-flag"`. Symmetrically, `quarantine: false` in frontmatter is the escape hatch for a heuristic false positive (a `secret`/`payment` match on the user's own legitimate data, e.g. documentation containing an example key). If both are set on the same file, the forced flag wins — a stale `quarantine: false` left over from an earlier edit must not silently override an explicit "this exposes someone else's data" statement.

```yaml
---
type: "2.3"
quarantine: false   # this "AKIA..." string is a documentation example, not a real key
---
```

---

## 5. Sidecar override — `<file>.meta.yaml`

For binaries that have no frontmatter of their own (images, audio before transcription, proprietary formats).

```yaml
schema_version: 1
type: "2.2"
note: "team standup recording, 2026-06-01"
speakers_third_party: true   # forces quarantine regardless of type above
```

`speakers_third_party: true` (or any future forced-quarantine flag) overrides `type` — a file can be both "I know what this is" and "this must not leave quarantine" at the same time.

---

## 6. `extractors.yaml` — pluggable media extractors

```yaml
schema_version: 1
extractors:
  - extensions: [".mp3", ".mp4", ".m4a", ".wav"]
    command: "whisper-mlx"
    output: "text"
  - extensions: [".pdf"]
    command: "pdf-text-layer"
    fallback: "needs-ocr"
```

Zero-config default: plain text formats pass through untouched; Whisper is used automatically if it's installed, otherwise audio/video fall through to `pending: needs-extractor`. Add your own OCR command by adding an entry — the Structurer doesn't need code changes, only this file.

---

## 7. Freshness

Freshness metadata is **optional per file** — a file that carries none is simply "age unknown" to downstream consumers, not an error. But **once a file asserts `valid_from`, it must also assert exactly one way to die**: expiration (a TTL, for naturally-decaying facts) or explicit replacement (`superseded_by`, for knowledge that's still true until something contradicts it). `valid_from` with neither is the malformed state — a partial assertion, not a valid minimal one.

Frontmatter fields (text files) or `type-index.json`'s `freshness` block (everything else):

```yaml
valid_from: "2026-05-01"     # if present, one of the two fields below must also be present
ttl_days: 180                 # OR superseded_by — not both
superseded_by: null           # path or id of the fact that replaced this one
```

`2.1-declared`/`2.1-derived` facts typically use the TTL form (things about you drift). `2.3` conceptual knowledge typically uses `superseded_by` (a definition doesn't expire, it gets replaced).

**`ttl_days` is a confirmed convention as of 2026-07-16** — originally this document's own proposal (the upstream freshness model specified the two-mechanism shape but no wire field name), it was adopted verbatim by that upstream model's own reference application: the Ф4а freshness markup of the author's `personal/` and `Lifework/` homes uses exactly `valid_from`/`ttl_days`/`superseded_by`, making this file and that markup the same convention.

---

## 8. `profile.yaml` — what the Structurer does *not* own

`profile.yaml` is the Generator's input contract (RCS profile + four horizons: quarter/month/week/day + artifacts summary — the full shape lives in `generator/horizons.py`, `RCSProfile`/`HorizonContext`). **The Structurer does not populate this file.** It is filled by self-diagnosis (`/diagnose-lite`, 6 questions), a hand-written YAML, or a platform pull if the user is connected — none of which are Structurer concerns.

**Platform pull** (`generator/personal_export.py`). Run separately (by hand, or wired into your own cron/CI — the generator does not invoke it), it fetches the platform-derived RCS profile and stage (mastery level within a role, 1-5 — not the platform's qualification degree, a self-reported stage is legitimate on its own, see `DP.D.252`) via JSON-RPC 2.0 (`dt_read_digital_twin` / `dt_describe_by_path`, read-only allowlist), using the token in `GUIDE_KIT_PLATFORM_TOKEN`, and writes a `profile.platform.yaml` alongside the user's `profile.yaml`. When `personal_export: on` (default), the adapter merges this already-on-disk overlay into the declared profile on a per-field basis at generation time — this merge is a local file read only, it never itself calls the platform, and it only ever runs for a connected user who has this overlay file at all; an offline user's declared profile is used as-is, nothing to compare against. If `profile.platform.yaml` is stale or absent, the adapter proceeds on whatever is on disk (or the declared profile alone) — it does not fetch a fresh one — priority: `manual_override` (declared, but only if it carries `override_reason` + `override_at` — an unmarked or unaccountable override is demoted to plain `manual`) > `computed_from_events` (platform-derived) > `manual` (declared) > `diagnostic_session` (declared). A missing or unrecognized declared `source` counts as `unknown`, the lowest priority. Rationale: this is about freshness, not legitimacy — `computed_from_events` is continuously recalculated from behavior, so an unmarked local edit is more often stale than deliberate; if the platform trail itself has gone stale (the user stepped away from the platform and updated `profile.yaml` locally instead), an explicit `manual_override` is the only channel that wins. The overlay never deletes a declared key. The stage arrives as an atomic bundle (`rcs.stage_derived` + `provenance.stage_label`); the overlay writes both only when parsing succeeds, otherwise it writes only `provenance.stage_label_raw` and leaves the declared stage untouched. A missing overlay file is not an error — the generator proceeds with the declared profile alone (same cold-start path as a missing `profile.yaml`).

**Qualification degree** (`qualification_degree` block, top-level in `profile.yaml`/`profile.platform.yaml` — a separate axis from `rcs`, per `DP.D.252`) is fetched by the same platform pull, from the digital twin's council-assigned degree record (`DP.D.050` — `Ученик → Работник → Стратег → Специалист → Практик → Мастер → Реформатор → Общественный деятель`, e.g. `DEG.Worker`). Unlike stage, the merge here has no priority table: since a degree is never behaviorally computed and never freely self-assignable, platform data wins whenever present. The one escape hatch is `use_declared: true` on the declared block — an explicit, auditable statement that the platform record is stale (mirrors `manual_override` for stage, but simpler: there's no "freshness by computation" case to weigh, since a council record doesn't get recalculated on its own). A declared `certified_at` date is an informational freshness signal, not enforced. `qualification_degree.degree` is stored as whatever code the source uses (e.g. `DEG.Worker`) — not validated against a fixed enum, since the platform's full `DEG.*` list beyond `DEG.Worker`/`DEG.Freshman` isn't confirmed anywhere in the Pack. An absent degree is never defaulted to the first level — the planner omits it from the LLM's context entirely rather than assume one.

What the Structurer *does* provide toward this contract: `type-index.json` and `residency.yaml` (§9) are separate artifacts the Generator's profile loader can optionally consult, not fields inside `profile.yaml` itself. A missing `profile.yaml` is a valid cold start (`generator/adapter.py` already treats it that way) — the Structurer doesn't need to produce one for the Generator to run.

**Live curated-materials fallback** (`generator/platform_knowledge.py`, DP.SC.060 scenario 1 — distinct from the platform pull above: that fetches the user's own derived data, this fetches the platform's shared curated corpus). `adapter.load_card_content()` looks up the chosen `element_id` under the local `cards_path`/demo catalog first; when `platform_knowledge: on` (default off) and there is no local hit, it queries the platform's *public* `knowledge-mcp` layer (`knowledge_search`, no token — unlike `personal_export.py`'s `dt_read_digital_twin`/`dt_describe_by_path`, which require `GUIDE_KIT_PLATFORM_TOKEN`) instead of leaving the slot to an `llm-assisted` guess. Platform unreachable, empty, or unparseable response → `None`, the same honest gap as a missing local card — never a crash (I2 of DP.SC.060). This call only ever carries `element_id` (a catalog code, not user data) in its request body — there is no code path for profile PII to reach it.

**Applied-mastery domain traits** (`domain_traits`, top-level list in `profile.yaml`, Ф5b of WP-483 — consumed by `generator/adapter.py::build_horizon_context()`, drives the planner's applied-track section alongside the worldview lesson, see `generator/horizons.py::DomainTrait`). Each entry is `{characteristic, domain, status, rung, state}` — the shape produced by the Lab's per-domain characteristic process (`WP-493 domain-traits-process.md` Step 8), not redefined here. `status` must be one of `measured` / `no_source_yet` / `dormant-no-source` (`DOMAIN_TRAIT_STATUSES`) — anything else, including a case/spelling typo, fails loud at construction rather than silently passing as an active step. A structurally broken entry (not a dict, or missing `characteristic`/`domain`) instead degrades honestly — logged and skipped, the same posture as malformed YAML elsewhere in this file — so one bad entry doesn't crash the whole profile; only the status enum is intentionally strict. The same honest-degradation posture applies one level up: if `domain_traits` itself isn't a list (a number, a string, a bare dict — a plausible YAML authoring slip), it's treated as empty with one clear log line, not iterated character-by-character or key-by-key. A missing `domain_traits` key is a valid cold start — `build_horizon_context` yields an empty list, same as a profile with no applied-mastery domains at all. This block is entirely personal/local data (the user's own applied-domain characteristics, e.g. swimming or piano) — the Structurer does not produce it and the platform does not own it (per `domain-traits-process.md`'s pilot correction: only the fundamental/worldview axis is platform-evaluated).

**Autonomous snapshot download** (`scripts/fetch-snapshot.py`, DP.SC.060 scenario 2 — for a user with no platform account at all, so the live fallback above has nothing to call). A versioned archive of CAT.001-003 is published as a GitHub Release asset on this repo (`scripts/publish-snapshot.sh`, tagged `snapshot-YYYY-MM-DD`, its own namespace separate from code release tags — the two change on independent schedules). `fetch-snapshot.py --out-dir DIR --today YYYY-MM-DD` downloads the latest (or `--tag`-pinned) release via `gh release download`, verifies the manifest's `schema_version` before touching any card content (a mismatch refuses extraction rather than best-effort-parsing an archive shaped differently than expected), and extracts into `DIR/baseline` — replacing any prior extraction there wholesale, not merging. Point `curriculum_path` at the extracted `baseline/CAT.001` directory. A snapshot older than `--max-age-days` (default 90) prints an advisory warning but still extracts — a stale local copy is still more useful than none for a fully offline user (DRR-snapshot-service.md NBR #1).

---

## 9. Out of scope for this document

**`residency.yaml`** is not specified here — the Structurer does not produce this file at all (revised 2026-07-15, peer-session). What it does instead: `structurer/residency.py` checks the Structurer's own permission to read a classified `data_type` (`function_id=structurer`, `flow_direction=inbound`) against an optional local `.structurer/residency-state.yaml`, a portable, base-local store — not the author's personal exocortex `~/IWE/current/data-residency.yaml` (that path belongs to `FMT-exocortex-template`'s `ResidencyGate` skill and would break this kit's zero-server, runs-on-a-stranger's-machine invariant if imported directly). A missing state file means every `data_type` is allowed — same cold-start posture as a missing `profile.yaml`.

**Provenance invariant.** Whether a file is `2.1-declared` vs `2.1-derived` (self-declared vs a mirror of some stream) is decided only by declaration — `homes.yaml`, a sidecar, or frontmatter — never inferred from content. The residency check above answers "may the Structurer read this data_type", not "where did this file actually come from" — that question belongs to whatever imported the file (a sync job, a manual export), each with its own consent check at pull time, out of scope for the Structurer.

---

## Versioning

One `schema_version` integer, repeated identically at the top of `homes.yaml`, `type-index.json`, `profile.yaml`, and any sidecar file. A version bump is atomic across all of them — even a change to only the sidecar schema bumps the shared number. This trades a slightly higher bump frequency for a stronger guarantee: mixed-version artifacts from an upgraded and a not-yet-upgraded run of the Structurer are detectable by a single field comparison, not a per-file compatibility matrix.

**Upstream model pin: `model_version: "1.0"`.** This format is a consumer of the data-lifecycle model С1-С9/П1-П9 (`CONCEPT-data-pipelines.md`): the 2.1-2.4 type axis, the out-of-axis quarantine framing (§4a) and the freshness shape (§7) were all written against that model's `model_version: "1.0"` (its frontmatter field). **Drift-check rule:** any revision of this document, and any Structurer release, compares this pinned value against the current `model_version` in the upstream concept's frontmatter; a mismatch is a blocking review item — re-verify §§3, 4a and 7 against the changed model before touching the pin — never a silent auto-bump. `schema_version` above stays independent: it versions these wire artifacts, the pin versions the conceptual model they encode. (Decided at the upstream model's architecture review 2026-07-14, mitigation "Эволюционируемость"; retrofitted 2026-07-16.)

---

*Source: `CONCEPT-full-architecture.md §5`. Solo-authored 2026-07-14 after the intended peer-review session failed at the infrastructure level (Kimi adapter returned empty output twice, unrelated to this content). An independent cold-context review found and fixed two contradictions with the source concept (quarantine wrongly encoded as a `type` value instead of out-of-axis; an internal contradiction on whether freshness is mandatory). One item remains flagged in-text as this document's own proposal, not a confirmed convention: `homes.yaml` glob-specificity precedence. (The quarantine `reason` enum + field names were confirmed by implementation on 2026-07-15 — see §4a above; `ttl_days` was confirmed by the upstream model's own reference application on 2026-07-16 — see §Versioning above. Both were in this list until their respective confirmations.)*
