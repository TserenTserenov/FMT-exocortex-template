# Formatting Rules

> Always loaded. Source: CLAUDE.md § 6 (extracted to reduce context size).

## Language — Russian (BLOCKING)

All responses, labels, categories, and headers must be in Russian. EN is allowed only in code, terms (DDD, BC, UL), and file names.
NO: HIGH / MEDIUM / LOW / CRITICAL / DONE. YES: **critical**, **high**, **medium**, **low**, **done**.

## Tables with Work Products

- Active (pending, in_progress): name in **bold**
- Done: strike through the row without bold (`| ~~#~~ | ~~title~~ | ✅ | ~~done~~ |`). Emoji statuses (✅, 🔄, ↗️, 📦) — **without** `~~`. A tilde `~` inside `~~` breaks GitHub — replace `~30 min` → `30 min`, `~/IWE` → `IWE`.

## Collapsible sections (>80 lines) — FILES ONLY

**File Artifact >80 lines** (exhaustive list: WeekPlan, DayPlan, Strategy, WP-context, specifications) → `<details><summary><b>Title</b></summary>…</details>`; main section uses `<details open>`, no `---` between sections.

**BLOCKING — never in chat.** A response to the pilot, synthesis of results, post-report — NEVER wrap in `<details>` (the terminal does not collapse HTML). For a long response, use plain markdown or a report file; `<details>` in chat — only on explicit pilot request (reinforces A7/A7.1).

<!-- USER-SPACE -->
<!-- /USER-SPACE -->