---
agents: single
argument-hint: '[optional: --check to view the profile without a new survey]'
browser_safe: true
description: 'Mastery stage diagnosis (Diagnostician R28, FORM.089 §6.1 v5.0) directly
  in VS Code / claude.ai. Up to 6 questions, ~3 min. Saves the cp-profile to the canonical
  log learning.cp_assessments — via MCP tool (browser) or directly to Neon (VS Code).
  Run when: the pilot says "run diagnosis", "what is my stage", "/diagnose" — or PROACTIVELY
  when you see an empty cp_profile or a new user with no data.'
gates_enforced: []
gates_rationale: operational skill; WP Gate applicable only when creating a new WP,
  not for operational invocations
gates_required: []
interaction: multi-step
layer: L1
name: diagnose
related:
- WP-318
- WP-370
- DP.ROLE.042
- DP.SC.132
- PD.FORM.089
routing:
  deterministic: false
  executor: sonnet
status: active
triggers:
  phrases: []
  slash:
  - /diagnose
version: 5.0.0
---

# /diagnose — Mastery Stage Diagnosis

> ⚡ **Algorithm, not free conversation.** Execute steps 1–5 in sequence. Wait for a response after each question. Do not draw conclusions early.

> **CAT Algorithm (FORM.089 §6.1 v5.0):** 5 anchor questions + up to 1 drill-down, starting from stage 3.
> WP-370: cp.iwe → informational (does not block the stage), cp.skl is derived from cp.rhy.

## When to use

Mastery stage diagnosis (Diagnostician R28, FORM.089 §6.1 v5.0) directly in VS Code / claude.ai. Up to 6 questions, ~3 minutes. Run when: the pilot says "run diagnosis", "what is my stage", "/diagnose" — or PROACTIVELY when you see an empty cp_profile.

## Skill contract

- **Input:** the pilot called `/diagnose`, or Claude sees an empty cp_profile.
- **Output:** cp-profile in the chat + saved record (path depends on the interface — see Step 5).
- **Time:** ≤3 min (5–6 questions).
- **Does not:** provide development recommendations (that is the Navigator R27), does not build a personal guide.

## Identify the interface (FIRST action)

**Browser (claude.ai):** Bash tool unavailable → save via `learning_ctx_record_cp_assessment` (canonical log).
**VS Code / local:** Bash available → save to Neon via psycopg2 (+ local fallback).

Check: attempt Bash. If unavailable — operate in browser mode.

## Algorithm

## Step 0. Check existing profile

### Browser mode

Call `mcp__claude_ai_IWE__learning_ctx_get_onboarding_state` (reads from the same canonical `learning.cp_assessments` that Step 5 writes to).

- `has_diagnosis: true` → display the current `cp_stage`, offer to re-run (button "Repeat"). The tool does not return `assessed_at` — the exact 7-day cooldown (as in VS Code mode) cannot be checked here; leave the decision to re-run or not to the pilot.
- `--check` → display and exit.
- `has_diagnosis: false` → continue to Step 1.

### VS Code mode

```bash
source ~/.config/aist/env
python3 -c "
import os, json
try:
    import psycopg2
    conn = psycopg2.connect(os.environ['NEON_LEARNING_URL'])
    cur = conn.cursor()
    cur.execute('''SELECT stage, bottleneck_slot, recommended_stream, assessed_at, valid_until
                   FROM learning.cp_assessments
                   WHERE account_id = %s::uuid
                   ORDER BY assessed_at DESC LIMIT 1''',
                (os.environ['DT_USER_ID'],))
    row = cur.fetchone()
    conn.close()
    if row:
        stage, bottleneck, stream, assessed_at, valid_until = row
        print(json.dumps({'stage': stage, 'bottleneck': bottleneck, 'stream': stream,
                          'assessed_at': str(assessed_at)[:10], 'valid_until': str(valid_until)[:10]}))
    else:
        print('null')
except Exception as e:
    print(f'error: {e}')
"
```

**Cooldown:** 7 days. If a fresh profile exists — display it and ask "Run diagnosis again?".

**Existing profile display format:**

```
📊 Current cp-profile (diagnosis from YYYY-MM-DD)

Stage: [name] ([N] of 5)
Growth priority: [slot label]
Recommended guide: [SN]
Valid until: YYYY-MM-DD

Do you want to run the diagnosis again?
```

## Step 1. Announce the diagnosis

Open with a single message:

```
🔬 Mastery Stage Diagnosis

Up to 5 questions with answer options. Takes ~3 minutes.
Choose the option that best matches your current practice.

Ready? Let's begin.
```

Wait for a response ("yes", "let's go", "start", or any other signal of readiness).

## Step 2. Phase 1 — anchor questions (all 5)

Ask one at a time, wait for the answer (1–5) after each. Record in `scores`.

**Question 1 (cp.rhy):**
```
📍 Question 1 of 5

How do you track time spent on self-development, and how regular is your rhythm?
Approximately how many hours per week?

1 — I do not allocate time; it happens as it comes
2 — I try, but without a rhythm (1–2 h/week)
3 — Explicitly weekly (3–4 h/week)
4 — Daily practice + tracker (5–10 h/week)
5 — Automated + artifacts (10+ h/week)
```

**Question 2 (cp.wld):**
```
📍 Question 2 of 5

How do you make important decisions?
Through intuition, values, or systematic analysis?

1 — Mostly by intuition
2 — I try different approaches; nothing has solidified
3 — Through formulated principles / worldview
4 — Systematically: goals, constraints, alternatives
5 — I pass my methods and principles on to others
```

**Question 3 (cp.int):**
```
📍 Question 3 of 5

Do you apply Systems Thinking — do you see roles, boundaries,
interfaces, supersystems in real tasks?

1 — No experience
2 — I have heard of it, but do not apply it
3 — Basic distinctions (role/function/boundary)
4 — Systematic analysis in work
5 — I formalize models and teach others
```

**Question 4 (cp.agt):**
```
📍 Question 4 of 5

How often over the past month were tasks initiated by you personally —
not handed down to you, but spotted and taken on by you?

1 — Almost everything comes from above
2 — Sometimes by me, rarely
3 — About half are mine
4 — Most tasks are my initiative
5 — I set the agenda for others
```

**Question 5 (cp.iwe — informational, does not block the stage):**
```
📍 Question 5 of 5

How well set up is your knowledge work environment —
notes, knowledge base, tools (VS Code + Pack + AI, or alternatives)?

1 — No environment
2 — Very basic (phone notes, cloud folder)
3 — Basically set up, used regularly
4 — Multiple services, structure, links, search
5 — Developing it as a system — Pack / protocols / agents
```

After all 5 questions: `scores = {cp.rhy: X, cp.wld: X, cp.int: X, cp.agt: X, cp.iwe: X}`.

**WP-370: cp.skl is derived from cp.rhy** (§6.1 v5.0 — rhythm and mastery correlate):
```python
scores['cp.skl'] = scores['cp.rhy']
```

## Step 3. Phase 2 — drill-down (if needed)

**MANDATORY_SLOTS = ['cp.rhy', 'cp.wld', 'cp.skl', 'cp.int', 'cp.agt']** — cp.iwe is excluded.

```python
mandatory_scores = {s: scores[s] for s in MANDATORY_SLOTS}
bottleneck_slot = min(mandatory_scores, key=mandatory_scores.get)
need_drilldown = mandatory_scores[bottleneck_slot] < 3
```

If `need_drilldown = True` — ask one clarifying question for the bottleneck:

| Bottleneck | Question |
|---|---|
| cp.rhy / cp.skl | "Do you have 'rituals' for starting or closing the work week? Or regular reflection checkpoints?"<br>1-Nothing at all / 2-Occasionally do a wrap-up / 3-Weekly ritual / 4-Structured rituals / 5-Full Day Open/Day Close/Week Close practice |
| cp.wld | "Can you name 2–3 principles that guide your decisions? How explicit are they?"<br>1-Not formulated / 2-Vague feeling / 3-Can name 1–2 / 4-Explicit, written down / 5-A working system |
| cp.int | "Have you tried breaking down a situation through supersystem and subsystem? Identifying roles, functions, constraints?"<br>1-Unfamiliar / 2-Heard of it, have not applied it / 3-Intuitively / 4-Consciously / 5-Teach others |
| cp.agt | "Do you take responsibility for results even when circumstances were unfavorable?"<br>1-I explain it by circumstances / 2-Sometimes I do / 3-Usually I do / 4-Always / 5-I set the standard |

The drill-down answer updates the corresponding slot in `scores`. If bottleneck = cp.skl — update cp.rhy, then redefine `scores['cp.skl'] = scores['cp.rhy']`.

## Step 4. Compute the profile

```python
MANDATORY_SLOTS = ['cp.rhy', 'cp.wld', 'cp.skl', 'cp.int', 'cp.agt']

vals = {s: scores.get(s, 2) for s in MANDATORY_SLOTS}
stage = min(vals.values())
bottleneck = 'none' if stage >= 4 else min(vals, key=vals.get)

if stage == 5:
    recommended_stream = 'WD'
else:
    recommended_stream = f'S{max(1, min(4, stage))}'
```

Stages: 1-Random / 2-Practitioner / 3-Systematic / 4-Disciplined / 5-Proactive

Bottleneck labels:
- cp.rhy → "regularity and rhythm of practice"
- cp.wld → "worldview and systems perspective"
- cp.skl → "time tracking and focus"
- cp.iwe → "work environment and tools"
- cp.int → "Systems Thinking"
- cp.agt → "agency and initiative"
- 'none' → "No bottlenecks — maintain your pace and move to the next stages"

Streams: S1-"Foundation" / S2-"Systematization" / S3-"Scale" / S4-"Transfer" / WD-"Work Development"

## Step 5. Display results and save

First display the result in the chat:

```
📊 Diagnosis Results

Stage: [NAME] ([N] of 5)

[Growth priority: <bottleneck label>]
OR
[No bottlenecks — maintain your pace.]

Recommended guide: [SN] — [label]
[If stage=5: "Next program: Work Development (WD)"]

Profile by slot:
cp.rhy [N] | cp.wld [N] | cp.skl [N]
cp.iwe [N] | cp.int [N] | cp.agt [N]

(valid for 180 days)
```

Then save — the path depends on the interface:

### Browser mode (claude.ai) — save via learning_ctx_record_cp_assessment

Compute `occurred_at` (now, ISO UTC). Generate `event_id` for idempotency: `diagnose-browser-<occurred_at>` (ISO time without separators is acceptable; the only requirement is no repetition within the same Session).

Call `mcp__claude_ai_IWE__learning_ctx_record_cp_assessment` (writes to the canonical log `learning.cp_assessments`, the same one used by VS Code mode below — not to the personal digital twin):
- **event_id:** `<generated>`
- **stage:** `<N>`
- **cp_scores:** `{"cp.rhy": <N>, "cp.wld": <N>, "cp.skl": <N>, "cp.iwe": <N>, "cp.int": <N>, "cp.agt": <N>}`
- **bottleneck_slot:** `<cp.xxx or 'none'>`
- **recommended_stream:** `<SN or 'WD'>`
- **skip_to_stage:** `<N>`
- **questions_count:** `<number of questions asked>`
- **rcs_version:** `v5.0`
- **occurred_at:** `<occurred_at>`
- **written_by:** `browser`

If the call returns success → report: `✅ Profile saved` (do not mention "digital twin" — the record goes to the shared log).
If error → display the profile in the chat and ask the user to copy it manually.

### VS Code mode — save to Neon via Bash

```bash
source ~/.config/aist/env
CP_SCORES='<JSON with final scores>' \
CP_Q_COUNT=<number of questions asked> \
python3 -c "
import os, json, datetime as dt_lib

scores_raw = os.environ['CP_SCORES']
q_count    = int(os.environ.get('CP_Q_COUNT', '5'))
account_id = os.environ.get('DT_USER_ID', '')
url        = os.environ.get('NEON_LEARNING_URL', '')

ALL_SLOTS     = ['cp.rhy', 'cp.wld', 'cp.skl', 'cp.iwe', 'cp.int', 'cp.agt']
MANDATORY     = ['cp.rhy', 'cp.wld', 'cp.skl', 'cp.int', 'cp.agt']
scores = json.loads(scores_raw)
vals   = {s: int(scores.get(s, 2)) for s in ALL_SLOTS}

# derive cp.skl from cp.rhy (FORM.089 §6.1 v5.0)
vals['cp.skl'] = vals['cp.rhy']

stage  = min(vals[s] for s in MANDATORY)
bn     = 'none' if stage >= 4 else min(MANDATORY, key=lambda s: vals[s])
stream = 'WD' if stage == 5 else 'S' + str(max(1, min(4, stage)))
valid  = dt_lib.datetime.now(dt_lib.timezone.utc) + dt_lib.timedelta(days=180)

saved = False
if url and account_id:
    try:
        import psycopg2
        conn = psycopg2.connect(url)
        cur  = conn.cursor()
        cur.execute(
            '''INSERT INTO learning.cp_assessments
               (account_id, stage, bottleneck_slot, recommended_stream, skip_to_stage,
                cp_scores, source, interface, questions_count, rcs_version, valid_until)
               VALUES (%s::uuid, %s, %s, %s, %s, %s::jsonb, %s, %s, %s, %s, %s)
               RETURNING id''',
            (account_id, stage, bn, stream, stage, json.dumps(vals),
             'self_report', 'vscode', q_count, 'v5.0', valid)
        )
        row_id = cur.fetchone()[0]
        conn.commit()
        conn.close()
        print(f'OK neon id={row_id}')
        saved = True
    except Exception as e:
        print(f'neon error: {e}')

if not saved:
    import pathlib
    d = pathlib.Path.home() / '.aist' / 'cp-assessments'
    d.mkdir(parents=True, exist_ok=True)
    path = d / (dt_lib.date.today().isoformat() + '.json')
    path.write_text(json.dumps({'account_id': account_id, 'stage': stage,
        'bottleneck_slot': bn, 'recommended_stream': stream,
        'cp_scores': vals, 'source': 'self_report', 'interface': 'vscode',
        'questions_count': q_count, 'rcs_version': 'v5.0',
        'valid_until': valid.isoformat()}, indent=2))
    print(f'saved local: {path}')
"
```

If the output contains `OK neon` — the profile is in Neon. If `saved local` — it is saved locally.

## Step 6. Next step

After displaying the results — offer:
```
Next step:
→ Navigator — how to develop [bottleneck label]? — growth recommendations
→ /diagnose in the bot — sync profile
→ /progress in the bot — view full progress profile
```

## Edge cases

| Situation | Action |
|---|---|
| Pilot does not respond with a number 1–5 | Ask again: "Please choose a number from 1 to 5" |
| Pilot wants to skip a question | Assign default 2 (conservative), proceed |
| Fewer than 4 mandatory answers | Display "Diagnosis not completed", offer to run `/diagnose` again |
| learning_ctx_record_cp_assessment unavailable | Display the profile in the chat, ask the user to copy it |
| psycopg2 not installed (VS Code) | Save to `~/.aist/cp-assessments/YYYY-MM-DD.json` |
| Profile already exists (< 7 days) | Display it and ask: "Run again?" |

## Proactive trigger

Claude must offer `/diagnose` **without an explicit request** when:
1. `learning_ctx_get_onboarding_state` returns `has_diagnosis: false` or `cp_stage = null`
2. In Day Open — IWE data is empty or `stage = null`
3. The pilot says "where do I start", "how do I develop", "what should I do next" — without a stage context

Suggested phrasing:
```
I see that your cp-profile is not filled in (or is outdated).
Would you like to run the stage diagnosis? ~3 min, 5 questions — say "yes" or /diagnose.
```

<!-- USER-SPACE -->

<!-- /USER-SPACE -->
