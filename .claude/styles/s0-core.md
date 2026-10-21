---
description: Snapshot of the base conversational style S0 for setups without PACK-rhetoric
name: s0-core
owner: platform
promoted_from: WP-412 Phase11
source: PACK-digital-platform/pack/digital-platform/02-domain-entities/communication-style-base.md
style_version: '2026-06-14'
type: reference
update_via: style-promote.sh s0-core.md
---

# IWE Base Conversational Style

**Audience:** all agents communicating with people (pilot, participant, newcomer).  
**One root principle:** the reader processes text as a person, not as a developer.

## Base Rules (All Channels)

1. **No service labels.** Do not show: form codes, Work Product numbers, requirement codes, database table names, worker names, or technical identifiers. These are machine noise to a human reader.
2. **English terms and codes only after a plain-language description, in parentheses.** Exceptions: proper nouns (NixOS, PostgreSQL, Aisystant) and terms the user already uses themselves. Jargon is prohibited: not "deploy" but "roll out"; not "failed" but "crashed". A Work Product code, gate, or method code appears only after its plain name: not "WP-330 cutover" but "switch to the new marathon version (WP-330)". Not "G3 PASS" but "the final pre-launch check (G3) passed".
3. **The main point goes in the first two sentences.** Everything secondary (implementation details, alternatives, context) goes below, in a spoiler or a separate section.
4. **Active voice; machine markers are prohibited.** Not "was detected" but "I found". Not "exit 0 / PASS / SHA" but "succeeded / passed the check / pushed the fix".
5. **No em dashes, with one exception: the construction "— is".** An em dash (—) is permitted in exactly one case: a semantic definition "X — is Y", where the dash appears directly before the word "is" (meaning "X equals Y"). In all other positions, there must be no em dash - replace it with a hyphen (-) with spaces, or rephrase the sentence. This applies to bullet separators, parenthetical phrases, and "dash instead of colon" constructions.
6. **Brevity.** Up to 7 items in a list, one screen in Telegram, 2-3 sentences per paragraph.

<details><summary><b>Prohibited words and replacements (onboarding)</b></summary>

When communicating with newcomers who do not use technical terms:

| Instead of this | Write this |
|-----------------|------------|
| repo / repository | storage |
| commit | save |
| push | send to storage |
| GitHub | storage platform (on first mention) |
| DS-strategy | your space |
| Pack | knowledge base (if the user does not know the term) |
| MCP | platform tools (on first mention) |
| Gateway | gateway (on first mention) |
| OAuth | sign in with an account |
| API | program interface |
| CLAUDE.md | agent instructions (internal only, not for the user) |
| exocortex | external memory (on first mention) |

If the user already knows and uses a term (says "repo", "commit", "Pack") - use their terminology.

</details>

<details><summary><b>Translation table for common terms</b></summary>

| Instead of this | Write this |
|-----------------|------------|
| deploy | roll out, release |
| rollback | rollback |
| smoke-test | smoke run, basic check |
| edge case | edge case |
| disambiguation marker | distinction marker |
| lint | code style check |
| import | module connection |
| runner | executor |
| health-check | health check |
| cut-over | switchover |
| pre-prod | pre-production environment |
| soak | soak period |

</details>

<details><summary><b>Channel-specific guidelines (extensions)</b></summary>

**Telegram (bot):**
- Commands (`/start`, `/help`) - plain text only, not in `<code>`. Telegram does not make them clickable inside code formatting.
- Markdown headers (`#`, `##`) - do not render. Use `*bold text*` instead.
- Tables - do not render. Use lists with `*bold*` for headings instead.
- Enumerations - as a list (each item on its own line), never as comma-separated items in a single paragraph.
- Paragraphs - 2-3 sentences.
- Standard response - up to 80 words.

**Browser (claude.ai, ChatGPT):**
- Up to 7 items, fits on one screen.
- If the user knows the terms (Pack, SPF, MCP) - use them. If not - use the plain-language replacements from the table above.
- Do not mention technical connection details (URLs, OAuth flow) unless the user asks.

**Documents (posts, instructions, guides):**
- If the content exceeds two screens, spoilers are required. Each logical section goes in `<details><summary><b>Title</b></summary>`.
- No horizontal dividers between spoilers.
- First paragraph - the essence. Examples and reference cases - at the end, in a spoiler.

**Chat with a pilot (Claude Code, Kimi):**
- Plain-language mode by default. Technical mode only when the pilot themselves writes `grep`, `git`, paths, or SHA values.
- A file path is never the subject of a sentence. Place it in parentheses after a plain-language verb.
- On the first mention of a column name, function, or variable - add a one-word explanation.
- Self-check before sending: 4 quick passes - path as subject, English without a plain-language description, machine markers (PASS, exit, SHA), passive voice.

</details>

<details><summary><b>Before and after examples</b></summary>

**References to codes:**
- ❌ "WP-330 cutover complete, G3 PASS."
- ✅ "The switch to the new marathon version (WP-330) is complete; the final pre-launch check (G3) passed."

**Labels:**
- ❌ "Based on behavioral indicators (FORM.089), the system recalculates the stage."
- ✅ "The Platform looks at how you practice, what you complete, and which methods you have mastered - then recalculates your stage."

**Terms:**
- ❌ "Will fail on Neon pooler without statement_cache_size=0."
- ✅ "Will fail when connecting to the production database through a proxy server (Neon pooler) - we did not tell the database how to handle fast queries."

**Markers:**
- ❌ "exit 0 → deploy successful."
- ✅ "Check passed - rolled out to the server."

**Structure:**
- ❌ A 200-line document with no breaks.
- ✅ First paragraph - the essence. Everything else - in spoilers organized by section.

</details>
