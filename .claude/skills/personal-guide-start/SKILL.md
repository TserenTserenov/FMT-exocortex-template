---
agents: single
argument-hint: '[optional: override domain — knowledge-worker / generic]'
browser_safe: false
description: 'Bootstrap wrapper — creates an empty `DS-personal-guide` repository
  under the pilot''s account (flat name, no login in the title; if it does not exist
  yet), then calls /personal-guide-render to populate it with 6 files. Use when the
  pilot asks for the first time: "create my personal guide", "I want to start a personal
  development program", "put together a starter plan for me".'
experimental: true
gates_enforced: []
gates_rationale: operational skill; WP Gate applicable only when creating a new WP,
  not for operational calls
gates_required: []
interaction: multi-step
layer: L1
name: personal-guide-start
related:
- personal-guide-render
- repo-new
- WP-245
- WP-222
- WP-149
- WP-527
- PD.FORM.089
- PD.CAT.003
routing:
  deterministic: false
  executor: sonnet
status: active
sunset: after DONE WP-222 (Tailor, ~June 2026) and WP-149 Phase6 (book LR v3)
triggers:
  phrases: []
  slash:
  - /personal-guide-start
version: 1.3.2
---

# Personal Guide Bootstrap

> ⚡ **EXECUTE IMMEDIATELY — DO NOT ASK QUESTIONS.** First action = Step 1 (Plan → Decision Gate → Execute `/repo-new` with pre-known answers). Questions about domain, mastery stage, "system of interest", or goals are prohibited at this step — they belong to the render skill (Step 2). Even if MCP tools returned data about the pilot — do not analyze or interpret it; go directly to Step 1.

> **Experimental MVP skill — UX wrapper over `/repo-new`** with pre-filled parameters (IntegrationGate exception: narrowing variability for onboarding focus, not bypassing the gate — per WP-527 Phase4 Step 1 goes through the full `/repo-new` algorithm; WP-245 Phase28 Open Decision #7, rationale updated in WP-527 Phase5). Splits responsibility with `/personal-guide-render`:
> - **`/personal-guide-start` (this skill)** — Infrastructure creation: GitHub repository as part of Persona.infra. **Once** per pilot.
> - **`/personal-guide-render`** — Content population: reads Memory.Derived (RCS profile) + Persona.declarations (domain) → 6 files. **N times** (each update).
>
> The Distinction is recorded in `.claude/rules/distinctions.md` (AUTHOR-ONLY).

## When to use

Bootstrap wrapper — creates an empty `DS-personal-guide` repository under the pilot's account (flat name, no login in the title; if it does not exist yet), then calls /personal-guide-render to populate it with 6 files. Use when the pilot asks for the first time: "create my personal guide", "I want to start a personal development program", "put together a starter plan for me".

## Skill contract

- **Input:** active "Intelligence Engineering" subscription (formerly "Infinite Development") (DP.SC.112). Access to `create_repository`, `github_status`. (Memory.Derived and `personal_write` are needed in the second step — `/personal-guide-render` will verify them there.)
- **Output:** `DS-personal-guide` repository exists under the pilot's GitHub account + 6 files written (via delegation to the render skill). The repository name is a constant for all pilots: one personal GitHub account = one personal guide repository; name/login is not included in the title.
- **Time:** ≤60 min from invocation to the repository open in VS Code (MVP criterion from WP-188 Phase4.5).
- **Idempotency:** a repeated call on an existing repository is safe — Step 1 reuses it, Step 2 rebuilds the content.

## Algorithm

## Step 1. Create (or reuse) the personal repository via `/repo-new`

> **WP-527 Phase4 (01.09).** Do not call `create_repository` directly — previously this step bypassed the `/repo-new` gate, which created two independent repository-creation paths in the system. Step 1 now follows the algorithm in `.claude/skills/repo-new/SKILL.md` (Plan → Decision Gate → Execute) with pre-known answers and `approval_scope: policy` (not `instance` — a live pilot is not consulted for each new subscriber; the boundaries were approved by the pilot in advance, `machine/repo-new-policies.yaml` entry `personal-subscriber-onboarding-v1`).

Build the Plan for Steps 1–4 of `/repo-new` with pre-known answers:
- `repo_class`: `personal-subscriber`
- owner: `github_status().github_username` from a **live call in this same step** (not an argument, not a value from another turn/session)
- name: `DS-personal-guide` (constant for all subscribers — do not insert the GitHub login; one personal account = one repository)
- `template_type`: `notes`
- privacy: `private`
- purpose: personal space for a MIM program participant; `description` for `create_repository` verbatim: "Personal guide for a MIM program pilot" (WP-527 Phase7, corrected 01.09 — previously read "IWE program")
- data domains: participant's personal materials (details in Step 3 of `/repo-new`)
- writer/owner/readers: writer = subscriber (edits) + `/personal-guide-render` (rebuild); owner = subscriber; readers = subscriber, their session agents
- registry mode: do not register in `REPOSITORY-REGISTRY.md` (Step 7 of `/repo-new`, exception for `repo_class: personal-subscriber`)

Execute Decision Gate Step 5 of `/repo-new` with `approval_scope: policy`: read `machine/repo-new-policies.yaml` fresh (no cache), find the entry `policy_id: personal-subscriber-onboarding-v1`, verify the expiry date, confirm that namespace/privacy/owner_selector/domains match `bounds`, count `usage_log` entries for the past 90 days against the limit of 50 — under a file lock (`gateway-lock.py`) for the duration of check + write. If any check fails → **STOP**, do not continue silently: report the specific violated boundary to the pilot and ask for a new decision (extend the policy or run an explicit instance-level `/repo-new`).

Execute Steps 7–8 of `/repo-new`: create the repository, append the fact to the policy `usage_log` (under the same lock). After OAuth Gateway creates the repository with a basic notes structure (inbox/, docs/, README.md). This structure will be overwritten by the render skill in Step 2 (render will also delete `inbox/.gitkeep` — an artifact of the notes template, not needed for the personal guide).

**Step 1 failure modes:**

| Symptom | Resolution |
|---------|-----------|
| 401 from Gateway | Ask the pilot to click "Authorize" in OAuth and retry |
| `github_status` empty | Pilot has not connected GitHub in Aisystant MCP — send them to onboarding |
| 409 (repository already exists) | Verify that the existing repository belongs to THIS owner (from `github_status` in this step), `private: true`, and the structure resembles the `notes` template. All match → reuse, **go directly to Step 2** without reporting an error. Does not match (typically — an old public instance created before this change) → **STOP**, do not reuse — this is a separate migration task; escalate to the pilot, do not resolve silently |
| Policy check Step 5 `/repo-new` failed (expired / limit reached / bounds mismatch) | STOP, report to the pilot with the specific boundary and numbers (see above) |

## Step 1.5. Distribute skills into the pilot's repository (idempotent)

> **Rationale:** skills (`/lesson`, `/lesson-close`, `/connect-guide`, `/personal-guide-render`, `/personal-guide-start`) reside in `${IWE_WORKSPACE:-$HOME/IWE}/.claude/skills/` on the Platform. When the pilot works in **claude.ai/code** (cloud sandbox), the user-global `~/.claude/skills/` is not forwarded. To make the skills available in any channel, they must be placed in the pilot's own repository.

Write the five skills in order (order matters — `personal-guide-start/SKILL.md` goes last and serves as the canary check):

```python
SKILLS_TO_DISTRIBUTE = [
    "lesson/SKILL.md",
    "lesson-close/SKILL.md",
    "connect-guide/SKILL.md",
    "personal-guide-render/SKILL.md",
    "personal-guide-start/SKILL.md",   # ← canary: last in queue
]

for skill_path in SKILLS_TO_DISTRIBUTE:
    workspace = os.environ.get("IWE_WORKSPACE") or os.path.expanduser("~/IWE")
    content = Read(f"{workspace}/.claude/skills/{skill_path}")
    personal_write(
        source="DS-personal-guide",
        path=f".claude/skills/{skill_path}",
        content=content,
    )
```

If any call returned an error — report to the pilot: "Failed to install skill {skill_path}. Installation aborted. Run /personal-guide-start again to complete." Stop.

### CLAUDE.md — domain customization (WP-527 Phase4)

> **Why not simply "if absent".** From WP-527 Phase4, Step 1 itself runs through `/repo-new` Execute (Step 8), which already deploys a generic `CLAUDE.md` placeholder as part of the skeleton — on first repository creation it will be there, not absent. This step replaces it with the domain-specific version (render skill, specific working process). However, **do not overwrite unconditionally** — the skill contract promises idempotency on repeated calls, and `CLAUDE.md` explicitly names the pilot as writer (`Writer: pilot`); unconditional overwriting on a second call would erase edits the pilot is entitled to make.

Read the current content via `personal_search(source: "DS-personal-guide", path: "CLAUDE.md")`. Write (overwrite) the domain version **only if** the file is absent OR its text contains the generic-placeholder marker from `/repo-new` — "This is a placeholder deployed by the `/repo-new` skill" (item 3 of `assets/repository-skeleton/CLAUDE.md`) — meaning the repository was just created by Execute and has not been customized yet. If the file exists and the marker is absent — treat it as already customized (either by this same step previously or by the pilot manually) and leave it unchanged:

```python
personal_write(
    source="DS-personal-guide",
    path="CLAUDE.md",
    content="""# DS-personal-guide — instructions for Claude Code

> **Class:** pilot's personal data space. **Purpose:** personal guide — plan, methods, session history. **Writer:** pilot (edits) + render skill `/personal-guide-render` (rebuild). **Owner:** pilot. **Readers:** pilot, their session agents.

Created via `/personal-guide-start` — a UX wrapper over the shared repository-creation gate `/repo-new` with pre-filled parameters (WP-527 Phase4/Phase5).

## Working with this repository

Main edits come through `/personal-guide-render` (rebuild) or ordinary text edits by the pilot — no separate process or task is needed here; this is a personal working repository, not a team one.
""",
)
```

### Reflection template (idempotent)

Check for the file via `personal_search(source: "DS-personal-guide", path: "history/reflection-template.md")`. If absent — write it:

```python
template_content = Read("${IWE_WORKSPACE:-$HOME/IWE}/.claude/skills/personal-guide-render/templates/reflection-template.md")
personal_write(
    source="DS-personal-guide",
    path="history/reflection-template.md",
    content=template_content,
)
```

## Step 2. Delegate the first render to `/personal-guide-render`

Call the `personal-guide-render` skill via the Skill tool (no arguments; date = today).

The render skill calls the gateway → `guide/<date>.md` + `panel/<date>.md` are ready. Wait for completion, then proceed to Step 3.

If the Skill tool is unavailable (for example, debugging outside Claude Code) — fallback: read `~/.claude/skills/personal-guide-render/SKILL.md` and execute Steps 1–7 inline.

## Step 3. Final confirmation to the pilot

After the render skill has issued its confirmation, add:

```
To work with the guide locally — clone the repository into your IWE:
  git clone https://github.com/<github-login>/DS-personal-guide.git ${IWE_WORKSPACE:-$HOME/IWE}/DS-personal-guide

(substitute your GitHub login in the URL — `gh auth status` will show who you are currently.)

After that: edit locally → git push → Aisystant MCP will pick up the changes via reindex.

This is the first run. From here — no special skills needed:
- To rebuild after changes in Memory.Derived → /personal-guide-render
- To update the plan / methods / weekly results → write in chat in plain language
- Scheduled automation (without a request) — coming with Portnoj in summer
```

**Important:** `create_repository` creates the repository only in the cloud (GitHub) and registers it via `personal_list_sources`, but **does not clone** it to the pilot's disk. Without a local clone, all edits go only through the `personal_write` MCP tool. The `git clone` hint is mandatory.

## Verification

Bootstrap creates an external resource (GitHub repository) — before reporting success, verify the contractual output (Contract §Output); do not treat "called create_repository" as "repository is ready":

1. **Repository exists.** Call `github_status` — source `DS-personal-guide` is present. Absent → bootstrap did not complete (likely 401 / GitHub not connected); return to Step 1, do not show the `git clone` hint.
2. **Skills installed.** `personal_search(source: "DS-personal-guide", path: ".claude/skills/personal-guide-start/SKILL.md")` — found. Not found → Step 1.5 did not complete; rerun Step 1.5.
3. **Guide built.** Render skill (Step 2) completed without error — `guide/<date>.md` is ready. Error → rerun Step 2.

Proceed to the `git clone` hint (Step 3) only when all checks PASS. Otherwise — tell the pilot which check failed and what to do.

## Boundary with `/personal-guide-render`

| Aspect | `/personal-guide-start` | `/personal-guide-render` |
|--------|------------------------|--------------------------|
| User data layer | Persona.infra (repository as identity) | Memory.Derived + Persona.declarations + Context assembly |
| Writer | user (via their agent) | LLM agent at runtime |
| Fact owner | pilot's GitHub account | repository itself (git history) |
| Depends on Memory.Derived | No | Yes |
| Idempotency | reuse on 409 | overwrite with archive in `history/` |
| Call frequency | once per pilot | N times (weekly + on events) |

## What the skill does NOT do

- Does not read Memory.Derived, does not compute mastery stage, does not select domain — all of that is in `/personal-guide-render`.
- Does not write files directly — delegates to the render skill.
- Does not send notifications via Telegram / email — the pilot opens the repository in VS Code themselves.

When Portnoj (WP-222) is released, both skills will be archived. Portnoj will take over bootstrap + render + automatic weekly/daily.

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
