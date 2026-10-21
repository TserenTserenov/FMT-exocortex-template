---
description: Communication style for community members - plain language, no service
  noise, compact structure
domains:
- communication
- community
- ux
horizon: warm
name: feedback_community_communication_style
owner: user
schema_version: 1
status: active
type: feedback
valid_from: 2026-06-01
---

# Community Communication Style

**One root principle:** the member reads the text as a person, not as a developer.  
All rules below follow from this Distinction.

**Five rules (inline, for all agents):**

1. **No service labels.** Do not show: form codes, Work Product numbers, requirement codes, database table names, worker names, or technical identifiers. All of these are machine noise for a human reader.
2. **English only after a plain-language description.** Exceptions: proper nouns (NixOS, PostgreSQL, Aisystant) and terms the member uses themselves. Jargon is prohibited: not "deploy" but "roll out"; not "it failed" but "it crashed".
3. **The main point goes in the first two sentences.** Everything secondary — implementation details, alternatives, context — goes below, under a spoiler or a separate section.
4. **Long documents go in spoilers.** If a file exceeds two screens, wrap each logical section under `## Section name`. No horizontal dividers between spoilers.
5. **Active voice; machine markers are prohibited.** Not "was discovered" but "I found". Not "exit 0 / PASS / SHA" but "it worked / passed the check / pushed the fix".

## Common Term Translation Table

| Instead of this | Write this |
|-----------------|------------|
| deploy | roll out, release |
| rollback | rollback |
| smoke-test | smoke test, quick check |
| edge case | edge case |
| commit (verb) | commit to Git |
| push | push to Git |
| merge | merge branches |
| backup | Backup |
| health-check | health check |
| disambiguation marker | Distinction marker |
| lint | code style check |
| import | module import |

## Channel-Specific Notes

**Telegram (bot):**
- Commands (`/start`, `/help`) — plain text only, not in `<code>`. Otherwise Telegram does not make them clickable.
- Markdown headers (`#`, `##`) — do not render. Use `*bold text*` instead.
- Tables — do not render. Use lists with `*bold*` for headings instead.
- Paragraphs — 2–3 sentences.

**Documents (posts, instructions, guides):**
- If longer than two screens, spoilers are required.
- First paragraph — the point. Then — details.
- Examples and reference cases — at the end, under a "Examples" spoiler.

## Before / After Examples

**Labels:**
- ❌ "According to behavioral indicators (FORM.089), the system recalculates the stage."
- ✅ "The Platform looks at how you practice, what you complete, and which Methods you have mastered — then recalculates your stage."

**Terms:**
- ❌ "Will crash on Neon pooler without statement_cache_size=0."
- ✅ "Will crash when connecting to the production database through a proxy server (Neon pooler) — we did not tell the database how to handle fast queries."

**Markers:**
- ❌ "exit 0 → deployment successful."
- ✅ "The check passed — rolled out to the server."

**Structure:**
- ❌ A 200-line document with no breaks.
- ✅ First paragraph — the point. Everything else — in spoilers by section.
