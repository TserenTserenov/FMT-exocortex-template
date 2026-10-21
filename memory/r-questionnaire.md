---
description: Review questions for weekly and monthly closing
domains:
- reference
- review
horizon: warm
name: r-questionnaire
owner: platform
promoted: 2026-04-25
schema_version: 1
status: active
type: protocol
valid_from: 2026-04-12
wp: 217
---
# R-Questionnaire

> **Class R (Review/judgment):** questions for reflection. **Not yes/no.** The goal is to catch signals that a checklist and drift script cannot catch.
> Distinction T ≠ S ≠ R: see `.claude/rules/distinctions.md`.
> Record answers in the Week Report / Month Report as a separate section, "R-answers".

## Week Close — 3 Questions

> Conduct at the end of the week. Time: 3–5 min.
> **Principle:** End of week = fatigue. 7 questions → formalism. 3 questions + agent data → honest signal.
> **Agent algorithm before questions:** (1) run `behaviour-report.sh`, (2) read the current month's incident log, (3) present patterns to the user — the user confirms, does not recall from memory.
> **Updated:** 13 Apr 2026 (reduced from 7 to 3 based on feedback).

1. **Here is what the system missed regularly — [agent inserts facts from Behaviour Report + incidents]. Is this a systematic pattern or a one-off?**
   _Goal: identify dead rules or points where a detector is needed. If the pattern repeats for 3 consecutive weeks → delete the rule or create a detector._

2. **Which WP took longer than planned — and why, in one word?**
   _Goal: calibrate estimates. One WP, one word: "underestimated" / "blocker" / "scope-crept"._

3. **If you could undo one action from this week — what would it be?**
   _Goal: honest stop signal. "Nothing" for 3 consecutive weeks → remove the question._

## Month Close — 6 Additional Questions

> Conduct on the first Monday of the month via the `/month-close` skill (step 6 of the algorithm). Time: ~10 min.
>
> **Completion rule:** the agent fills in M1, M2, M3, M6 AUTOMATICALLY from data BEFORE showing them to the user. The user only confirms or corrects. Only M4 and M5 are subjective questions for the user.

### Filled in by the agent from data (no question to the user)

M1. **What distinction did I add this month — and did I use it at least once?**
    _Source: `git log --since="YYYY-MM-01" .claude/rules/distinctions.md` + `memory/hard-distinctions.md`. The agent finds new HD items, checks for mentions in commit messages / Work turn contexts from the same month. Goal: decommission unused distinctions (3 months without use → archive)._

M2. **Which memory file grew the most over the month? Signal of growth or decay?**
    _Source: `wc -l memory/*.md` + git diff for the month. The agent distinguishes growth (new HD captured promptly) from decay (duplicates, refinements of refinements)._

M3. **Which health metric (multiplier, drift, memory-bleed) worsened? What is driving it?**
    _Source: `multiplier-trend.md` (trend), `iwe-drift.sh` (drift), `memory-bleed.sh` (memory). The agent compares with the previous month and names the factor._

M6. **Transition to "dormant" mode: which T-actions are candidates?**
    _Source: `iwe-drift.sh --activity` reads `sync-manifest.yaml § activity_checks:` and outputs a list of actions that did not fire for 3 consecutive windows. Plus manual candidates for actions with no measurable trace. If there are no candidates — write "none" and do not ask the user. If candidates exist — show the list and the user decides (active / dormant / archive)._

### Asked of the user (subjective)

M4. **What rule/skill did I NOT add, even though I thought about it? Why?**
    _Goal: distinguish "forgot" (capture problem) from "not needed" (signal that the system can stop its own growth)._

M5. **What in IWE worked unexpectedly well? What should be formalized as a rule?**
    _Goal: positive case. Promote an accidental success into a standing procedure (staging → FMT). Without this question, positive patterns are lost._

## Answer Format

- One paragraph per question (2–5 sentences).
- "Nothing to answer" is a valid response (3 times in a row → the question becomes a candidate for removal from the procedure).
- The agent may suggest facts (from the drift report, git log, WakaTime) but must not formulate the answer on behalf of the user.

## Anti-patterns

- **Formal closing:** "all good, nothing to note." If every week looks like this — the R-Questionnaire is dead; change the questions.
- **Declaration of plans:** "I will fix this next week." The R-Questionnaire is about the past, not the future. Conclusions go on a separate line in the report.
- **Self-flagellation:** "I worked poorly." The goal is to find a signal in the system, not to evaluate yourself.

---

**Total:** 3 (week) + 6 (month) = 9 questions. The Week block was reduced from 7 to 3 (13 Apr 2026, based on feedback — see note above). M6 was added on 10 Apr for decommission triage (decision 6).
