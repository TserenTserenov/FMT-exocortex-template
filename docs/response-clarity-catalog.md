---
description: 12 patterns of agent response pollution + 11 rules for "writing in reader
  mode"
layer: S0
name: response-clarity-catalog
promoted_from: WP-412 phase 13
spec_for_hook: .claude/hooks/response-clarity-hook.sh
spec_for_hook_sha: 15a38b91
type: reference
---

# Catalog: write for the human, not for the CI inspector

This file is a specification that the mechanical detector `.claude/hooks/response-clarity-hook.sh` partially verifies (Stop hook, rules A1/A8/A10 from the list below). If the hook was updated after commit `15a38b91` above — check that the rules here have not diverged from what the hook actually catches.

**One root cause:** the agent often writes like a commit message intended for another inspector agent, then delivers that output to a human reader. All patterns below are consequences of mixing these two interfaces. Changing the addressee is the only fix needed.

## 12 patterns (what to remove)

### Category A — high frequency, primary noise

**P1. File path as the subject of a sentence.**
- ❌ "`handlers/marathon.py:65-70` — `start_marathon_flow` writes `total_checkins=0` on first start."
- ✅ "The bot writes zero to the total check-ins counter when a marathon starts (`handlers/marathon.py:65`)."

**P2. English term with no description.**
- ❌ "will crash on the Neon pooler without `statement_cache_size=0`."
- ✅ "will crash when connecting to the production database through the database proxy server (Neon pooler) — we did not tell the database how to handle fast queries."

**P7. Listing intermediate actions instead of the outcome.**
- ❌ "1. Read X. 2. Checked Y. 3. Found Z. 4. Fixed Z."
- ✅ "Found the problem in X, fixed it."

**P10. Literal commit message used as an explanation.**
- ❌ "Added `statement_cache_size=0` to `asyncpg.connect()` in `wp330_dry_run.py:44`."
- ✅ "Fixed the database connection — the script no longer crashes on first run."

### Category B — medium frequency, disrupts flow

**P3. Function and parameter names with no explanation of what they do.**
- ❌ "`start_marathon_flow` writes `total_checkins=0`."
- ✅ "The marathon start method writes zero to the check-in counter."

**P4. Entity name with no meaning attached.**
- ❌ "The `total_checkins` column became write-never."
- ✅ "The total check-ins column (`total_checkins`) is never populated again."

**P5. Code-level details instead of system-level details.**
- ❌ "`if message.text is None: return` with no fallback to `message.caption`."
- ✅ "The bot cannot see the text when you send an image with a caption instead of a plain message."

**P8. Announcing intermediate steps between tool calls.**
- ❌ "Reading the file…", "Checking…", "Let me…", "I will now look at…"
- ✅ The reader is not watching the agent's screen. These phrases are noise before the result. Give only the result.

**P11. English success/failure markers stated as facts.**
- ❌ "exit 0 → deployed", "PASS", "status: done", "SHA: a5e5662."
- ✅ "Succeeded → deployed", "passed verification", "closed", "pushed as commit `a5e5662`."

### Category C — minor but irritating

**P6. Long chains of consequences connected by arrows.**
- ❌ "pooler → asyncpg → statement_cache → exit 1."
- ✅ "Through the database proxy server the script cannot locate its query and crashes."

**P9. Reporting what was not found.**
- ❌ "The file did not contain X, Y is absent, but Z is present at line 44."
- ✅ "Found Z in the file, fixed it."

**P12. Passive voice when reporting an error or a finding.**
- ❌ "It was discovered", "it turned out", "it became clear."
- ✅ "I found", "I made a mistake", "I understood after checking." Explicit subject "I" plus a direct verb.

## 11 rules (how to write)

**A1 (file path).** A path is never the subject. It goes in parentheses after a plain-language verb. Three or more paths go in a final "technical details" section or under a collapsible block.

**A2 (English term).** An anglicism is only acceptable after a description in the reader's language, in parentheses. Exception: terms the reader already uses themselves.

**A3 (entity name).** On first mention of a column, function, or variable — give its meaning in one word.

**A4 ("why does the reader need this phrase" filter).** Before each phrase: will the reader make a decision based on it? If not — move it to technical details or delete it.

**A5 (what matters more than how).** Lead with what will happen to the reader or the system. Follow with how it will be fixed, in one phrase.

**A6 (one consequence link per phrase).** "A → B" is acceptable. "A → B → C" — split into two sentences.

**A7 (report after action).** Format: "Did X. Effect: Y." The technical log goes separately, not in the main text.

**A8 (process log).** Intermediate actions ("reading", "checking") are not written by default.

**A9 (channel detector).** Dense technical style — for agent-to-agent transcripts, commit messages, PRs. Conversational style — for responses to a human.

**A10 (English markers).** "exit 0", "PASS", "status: done", "SHA: abc..." — replace with plain words.

**A11 (active voice).** When reporting an error or a finding — explicit subject "I" plus a direct verb. Passive voice is prohibited in the main text.

## Self-check before sending a response

1. Is there a path used as the subject? (P1/A1) → move it to parentheses.
2. Is there an English term with no description? (P2/A2) → add a description.
3. Is there "exit", "PASS", or "SHA" stated as a fact? (P11/A10) → replace with a plain word.
4. Is there "it was discovered" or "it turned out"? (P12/A11) → rewrite with "I".
5. Are you listing intermediate steps instead of the outcome? (P7) → collapse into the result.
