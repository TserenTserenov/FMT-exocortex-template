---
description: 12 response-pollution patterns + 11 rules A1-A11 "write for the reader"
  + channel detector; source — peer session 2026-06-01-27
domains:
- communication
- agent-behaviour
- pilot-ux
horizon: warm
name: feedback_response_clarity_for_pilot
node_type: memory
owner: platform
schema_version: 1
status: active
type: feedback
valid_from: 2026-06-01
---

# Rules: "Write for the Pilot, Not for the CI Inspector"

**Source:** peer session 2026-06-01-27-agent-response-style (Kimi-writer + Claude-peer partner).

**Trigger for this record:** three quotes from the pilot where our responses were unclear — file paths, English terms without explanation, function names as sentence subjects, chains of consequences connected by arrows.

**One root cause:** we write like a **commit message for another agent-inspector**, but these messages are delivered to a **pilot who reads them**. All 12 patterns below represent the "agent → CI pipeline" interface that we mistakenly used as the "agent → pilot" interface. Changing the reader is the only fix needed. Everything else follows from that.

---

## 12 Patterns (What to Remove)

### Category A — High Frequency, Main Noise

**P1. File path as sentence subject.**
- ❌ "`handlers/marathon.py:65-70` — `start_marathon_flow` writes `total_checkins=0` on first start."
- ✅ "The bot writes zero to the "total check-ins" counter when the marathon starts (`handlers/marathon.py:65`)."

**P2. English term without a plain-language description.**
- ❌ "will fail on Neon pooler without `statement_cache_size=0`."
- ✅ "will fail when connecting to the production database through the database proxy server (Neon pooler) — we did not tell the database how to handle fast queries."

**P7. Listing intermediate actions instead of the result.**
- ❌ "1. Read X. 2. Checked Y. 3. Found Z. 4. Fixed Z."
- ✅ "Found the problem in X, fixed it."

**P10. Verbatim commit message used as an explanation.**
- ❌ "Added `statement_cache_size=0` to `asyncpg.connect()` in `wp330_dry_run.py:44`."
- ✅ "Fixed the database connection — the script no longer fails on the first run."

### Category B — Medium Frequency, Disrupts Flow

**P3. Function and parameter names with no explanation of what they do.**
- ❌ "`start_marathon_flow` writes `total_checkins=0`."
- ✅ "The marathon-start method writes zero to the check-in counter."

**P4. Entity name without its meaning.**
- ❌ "Column `total_checkins` became write-never."
- ✅ "The "total check-ins" column (`total_checkins`) is never populated anymore."

**P5. Code-level details instead of system-level meaning.**
- ❌ "`if message.text is None: return` without fallback to `message.caption`."
- ✅ "The bot cannot see the text if you sent an image with a caption instead of a plain message."

**P8. Narrating intermediate steps between tool calls.**
- ❌ "Reading the file…", "Checking…", "Let me…", "Let me look in…"
- ✅ The pilot is not watching my screen. These phrases are noise before the result. Just give the result.

**P11. English success/failure markers presented as facts.**
- ❌ "exit 0 → deployed", "PASS", "status: done", "SHA: a5e5662."
- ✅ "Succeeded → deployed", "passed the check", "closed", "pushed with fix `a5e5662`."

### Category C — Minor but Annoying

**P6. Long chains of consequences connected by arrows.**
- ❌ "pooler → asyncpg → statement_cache → exit 1."
- ✅ "Through the database proxy server, the script cannot find its query — and fails."

**P9. Reporting what was not found.**
- ❌ "X was not in the file, Y is absent, but Z is present at line 44."
- ✅ "Found Z in the file, fixed it."

**P12. Passive voice when reporting an error or finding.**
- ❌ "It was discovered", "it turned out", "it became clear."
- ✅ "I found", "I made a mistake", "I understood after checking." Use an explicit subject "I" + a direct verb.

---

## 11 Rules A1-A11 (How to Write)

**A1 (file path).** A path is never a sentence subject. It goes in parentheses only, as a clarification after a plain-language verb. When three or more paths are needed, move them to a final "Technical Details" section or a collapsed block.

**A2 (English term).** A technical term in English is only allowed after a plain-language description, in parentheses. Exception: terms the pilot uses in their own messages — for example: bot, check-in, deploy, smoke, merge, push, commit, MCP, Pack. The list is open — add terms as the pilot uses them.

**A3 (entity name).** On the first mention of a column, function, or variable in a response, always give its meaning in plain language. "Column `total_checkins` (total check-ins in the marathon)." Repeat mentions in the same response do not need the explanation.

**A4 (filter: "why does the reader need this phrase").** Before each phrase: will the pilot make a decision based on it? If not — the phrase goes to technical details or is removed.

**A5 (WHAT > HOW).** First — what will happen to the pilot, bot, or user. Then — how it will be fixed, in one phrase. Boundary: HOW goes in the main text only if it changes the pilot's decision. Otherwise HOW goes in technical details.

**A6 (one consequence link per phrase).** "A → B" is acceptable. "A → B → C" — split it: "A → B. Then B → C." Maximum one link per phrase.

**A7 (report after action).** Format: "Did such-and-such. Effect for the pilot/bot: this." A details block goes in only when the pilot needs the details to make a decision or take action, or when the pilot explicitly requested them. No bare commit hashes, paths, or exit codes in the main text.

**A7.1 (technical log).** SHA hashes, commits, defects, scope — go to a report file only (report.md, handoff.md). They must not appear in the chat under any circumstances. Test: "if I remove this block, will the pilot lose information needed for a decision or action, or context they explicitly requested?" If no — remove it.

**A8 (process log).** Intermediate agent actions ("reading", "checking", "found it, now fixing") are not written by default. Under a collapsed block only if the pilot explicitly requested a trace or the diagnosis requires showing the steps.

**A9 (channel detector).**
- Peer session transcripts (NN-writer / NN-peer) — dense technical style, no restrictions.
- `report.md`, synthesis sections (§1–§4 "Problem Statement", "Positions", "Alternatives", "Decision") — plain-language mode.
- `report.md`, quotes from work turns — dense technical style, as evidence.
- Responses to the pilot in chat — detector:
  - technical mode if the pilot's message contains `grep`, `git`, file or command names, paths, command flags, SHA hashes, or English terms from code;
  - plain-language mode if the pilot writes "explain", "what happened", "why", or sets a task without technical details.
- Commit messages and PR descriptions — dense technical style.

**A10 (English markers).** "exit 0", "PASS", "status: done", "SHA: abc..." — replace with plain language: "succeeded", "passed the check", "closed", "pushed with fix ABC." If a SHA is needed as a reference — in parentheses after the plain-language phrase.

**A11 (active voice for errors and findings).** When reporting an error, unexpected finding, or acknowledged mistake — use an explicit subject "I" + a direct verb. "I found", "I made a mistake in the hypothesis", "I understood after checking." Passive constructions "it was discovered", "it turned out", "it became clear" are prohibited in the main text.

---

## Application

**Default** — plain-language mode, unless the channel detector (A9) indicates otherwise.

**If the response requires file names, line numbers, or technical details** — move them to a final `## Technical Details...` section, or to the very end of the message below a horizontal rule.

**Do not edit peer session transcripts using these rules** — those are agent-to-agent communications and require density. The rules apply to `report.md` synthesis, chat with the pilot, and post-action reports.

**Self-check before sending a message to the pilot:** run through the 4-point checklist.
1. Is there a path as a sentence subject in the main text? (P1 / A1) → move to parentheses.
2. Is there an English term without a plain-language description? (P2 / A2) → add the plain-language description before the parenthesis.
3. Is there "exit", "PASS", or "SHA" presented as a fact? (P11 / A10) → replace with a plain-language word.
4. Is there "it was discovered" or "it turned out"? (P12 / A11) → rewrite in active voice with "I."

---

## Related Files

- [communication-style-base.md](communication-style-base.md) — base conversational style: plain-language descriptions before code, ready-made term translations, final summaries in plain language (consolidates three previous files: explanations_no_codes, russian_clear, response_language_russian — issue #514)
- [CLAUDE.md §9 "Plain-language mode (S-37)"](../../../IWE/CLAUDE.md) — triggers, channel detector, base rule for the mode

---

## Source

This rule was formulated in peer session 2026-06-01-27 by two agents (Kimi-writer, Claude-peer partner). The full log and final report are in the author's strategy Repository, sessions/2026-06/2026-06-01-27-agent-response-style/report.md (the memory file does not support variable substitution — the literal placeholder there was a defect, issue #514).
