---
description: 12 patterns of agent response clutter + 11 rules for "writing in reader
  mode"
layer: S0
name: response-clarity-catalog
promoted_from: WP-412 Ф13
spec_for_hook: .claude/hooks/response-clarity-hook.sh
spec_for_hook_sha: 15a38b91
type: reference
---

# Catalog: write for a human, not for a CI inspector

This file is a specification that the mechanical detector `.claude/hooks/response-clarity-hook.sh` partially enforces (Stop hook, rules A1/A8/A10 from the list below). If the hook was updated after commit `15a38b91` above — verify that the rules here have not diverged from what the hook actually catches.

**One root cause:** an agent often writes like a commit message addressed to another inspector agent, then hands that output to a human reader. Every pattern below is a consequence of mixing these two interfaces. Changing the addressee is the only fix needed.

## 12 patterns (what to remove)

### Category A — high frequency, primary noise

**P1. File path as the sentence subject.**
- ❌ "`handlers/marathon.py:65-70` — `start_marathon_flow` writes `total_checkins=0` on first start."
- ✅ "The bot writes zero to the total check-ins counter when the marathon starts (`handlers/marathon.py:65`)."

**P2. English term with no plain-language description.**
- ❌ "will crash on Neon pooler without `statement_cache_size=0`."
- ✅ "will crash when connecting to the production database through a connection proxy (Neon pooler) — we never told the database how to handle prepared statements."

**P7. Listing intermediate steps instead of the outcome.**
- ❌ "1. Read X. 2. Checked Y. 3. Found Z. 4. Fixed Z."
- ✅ "Found the problem in X and fixed it."

**P10. Verbatim commit message used as an explanation.**
- ❌ "Added `statement_cache_size=0` to `asyncpg.connect()` in `wp330_dry_run.py:44`."
- ✅ "Fixed the database connection — the script no longer crashes on first run."

### Category B — medium frequency, disrupt reading flow

**P3. Function and parameter names with no explanation of what they do.**
- ❌ "`start_marathon_flow` writes `total_checkins=0`."
- ✅ "The marathon start method writes zero to the check-in counter."

**P4. Entity name without its meaning.**
- ❌ "Column `total_checkins` became write-never."
- ✅ "The total check-ins column (`total_checkins`) is never populated anymore."

**P5. Code-level details instead of system-level description.**
- ❌ "`if message.text is None: return` without fallback to `message.caption`."
- ✅ "The bot does not see the text when you send an image with a caption instead of a plain message."

**P8. Narrating intermediate steps between tool calls.**
- ❌ "Reading the file…", "Checking…", "Let me…", "Let me look at…"
- ✅ The reader is not watching the agent's screen. These phrases are noise before the result. Just give the result.

**P11. English success/failure markers stated as fact.**
- ❌ "exit 0 → deployed", "PASS", "status: done", "SHA: a5e5662."
- ✅ "Succeeded → deployed", "passed verification", "closed", "shipped as `a5e5662`."

### Category C — minor but irritating

**P6. Long consequence chains connected by arrows.**
- ❌ "pooler → asyncpg → statement_cache → exit 1."
- ✅ "Through the database proxy, the script cannot locate its query and crashes."

**P9. Reporting what was not found.**
- ❌ "File did not contain X, Y is absent, but Z is present at line 44."
- ✅ "Found Z in the file and fixed it."

**P12. Passive voice for errors or findings.**
- ❌ "Was discovered", "it turned out", "it became clear."
- ✅ "I found", "I made a mistake", "I realized after checking." Use an explicit subject "I" with a direct verb.

## 11 rules (how to write)

**A1 (file path).** A path is never the sentence subject. It goes in parentheses after a plain-language verb. Three or more paths go in a final "technical details" section or under a collapsible block.

**A2 (English term).** A borrowed term is acceptable only after a plain-language description in parentheses. Exception: terms the reader already uses themselves.

**A3 (entity name).** On first mention of a column, function, or variable — give its meaning in one word.

**A4 (reader relevance filter).** Before every sentence ask: will the reader make a decision based on this? If not — move to technical details or delete.

**A5 (what over how).** Lead with what will happen to the reader or system. Follow with how it will be fixed, in one sentence.

**A6 (one consequence link per sentence).** "A → B" is acceptable. "A → B → C" — split into two sentences.

**A7 (post-action report).** Format: "Did such-and-such. Effect: such-and-such." Technical log goes separately, not in the main text.

**A8 (process log).** Intermediate actions ("reading", "checking") are not written by default.

**A9 (channel detector).** Dense technical style is for agent-to-agent transcripts, commit messages, and PRs. Conversational style is for responses to a human.

**A10 (English markers).** "exit 0", "PASS", "status: done", "SHA: abc..." — replace with plain words.

**A11 (active voice).** For errors and findings — explicit subject "I" with a direct verb. Passive voice is prohibited in the main text.

## Self-check before sending a response

1. Is a file path used as the sentence subject? (P1/A1) → move to parentheses.
2. Is an English term used without a plain-language description? (P2/A2) → add a description.
3. Are "exit", "PASS", or "SHA" stated as plain fact? (P11/A10) → replace with plain words.
4. Are "was discovered" or "it turned out" present? (P12/A11) → rewrite using "I".
5. Are you listing intermediate steps instead of the outcome? (P7) → collapse into the result.

