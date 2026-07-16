# IWE Learning Path (Intellectual Work Environment)

> **IWE (Intellectual Work Environment)** is a personal intelligent work environment — the IDE equivalent for developing thinking. Just as an IDE gives a programmer an editor, compiler, linter, and debugger — IWE gives a person formalized knowledge (Pack), automatic extraction (Extractor), correctness checking (FPF/SPF), and gap diagnostics (Digital Twin). The person works together with AI agents, each playing its own Role.
>
> Each section covers: **why** → **what to study** → **where to find it**.
> Not on macOS or not using Claude Code? → **[PORTABILITY.md](PORTABILITY.md)**

## How to Use This File

1. **Beginner:** Sections 1–2 (what IWE is, Architecture). About 1 hour. You will understand how everything works.
2. **First week:** Sections 3–5 (foundation, repositories, daily work). Use as needed.
3. **Active user:** Sections 6–8 (knowledge, agents, quality). When you start creating Pack.
4. **Advanced:** Sections 9–10 (Platform, growth). When you want to scale.
5. **Reference:** Section 11 — quick answers.

> **Terminology:** IWE = Intellectual Work Environment, described through 5 architectural viewpoints: systems, descriptions, Roles, Methods, Work Products (§ 1.2). Triad A.7: Role → Method → Work Product. Exocortex = the description storage system inside IWE (CLAUDE.md + memory/). Details: [DP.IWE.001](https://github.com/TserenTserenov/PACK-digital-platform/blob/main/pack/digital-platform/02-domain-entities/DP.IWE.001-intelligent-working-environment.md).

> **Setup:** [SETUP-GUIDE.md](SETUP-GUIDE.md) | **Data Policy:** [DATA-POLICY.md](DATA-POLICY.md) | **Quick Reference:** [IWE-HELP.md](IWE-HELP.md) | **Principles vs Skills:** [principles-vs-skills.md](principles-vs-skills.md)
>
> Links starting with `./` refer to files in this repo. Links starting with `github.com/...` refer to other repositories.

## 1. What IWE Is

### 1.1. Definition

IWE is a personal system for intellectual work and development. Just as an IDE unifies an editor, compiler, and debugger into one environment for a programmer — IWE unifies knowledge, planning, and AI agents into one environment for thinking.

### 1.1a. Core Principle: Exoskeleton, Not Prosthetic

> DP.ARCH.001 principle #21. Details: [DP.IWE.001 §5.1](https://github.com/TserenTserenov/PACK-digital-platform/blob/main/pack/digital-platform/02-domain-entities/DP.IWE.001-intelligent-working-environment.md).

IWE amplifies the user's thinking — it does not replace it. The Distinction:

- **Prosthetic:** AI thinks for you → task is done, but you learned nothing → atrophy
- **Exoskeleton:** you think yourself, AI amplifies → task is done + you became more competent → growth

Three exoskeleton mechanisms in IWE:

1. **Surfacing, not generating.** The AI presents your own knowledge (Pack, memory/, Digital Twin) at the right moment. You do the thinking.
2. **Questions, not answers** (in strategic decisions). WP Gate requires planning before action. Consultation T2–T3 asks "what do you think?" in response to lazy requests.
3. **Fading scaffolding.** Training: more assistance at beginner levels, less at advanced levels. Tiers T0→T4: from direct answers to co-thinking.

**Criterion:** after interacting with IWE, the user has become more competent — not just received a result.

### 1.2. IWE Anatomy: Five Architectural Viewpoints

IWE as a system is examined from five viewpoints (ISO/IEC/IEEE 42010): systems, descriptions, Roles, Methods, and Work Products. The central organizing principle is FPF triad A.7: **Role → Method → Work Product**.

> **Three IWE classifications:** Viewpoints (this section) answer "through which lens are we looking." Perimeters L1–L4 (§ 2.1) answer "where it lives." Tiers T0–T4 + TM/TA/TD (§ 9.1) answer "what level of access."

#### Viewpoint 1: Systems (U.System) — What Has 4D Boundaries

Systems with boundaries, inputs, outputs, and an owner. Can be started, stopped, and updated. The main IWE systems are listed here; additional ones (WakaTime, etc.) are described in § 2.6.

| System | Type | What it does | Perimeter (§ 2.1) |
|--------|------|-------------|--------|
| **Claude Code CLI** (A1) | LLM agent | Primary AI executor: code, analysis, planning | L4 Personal |
| **Telegram bot** (I1, @aist_me_bot) | Service | Notes, programs, Digital Twin, notifications | L2 Platform |
| **MCP servers** (I3–I8) | Protocol | Access to Pack, guides, DS descriptions from Claude Code | L2 Platform |
| **Git + GitHub** | VCS | Versioning, storage, CI | L3 Template / L4 |
| **Exocortex** | File system | Storage and delivery of descriptions (CLAUDE.md + memory/) | L3 Template / L4 |
| **Neon DB** (Digital Twin) | DBMS | Storage of Digital Twin events | L2 Platform |

> **Test:** Does it have 4D boundaries, an owner, inputs/outputs? → System.
>
> **Exocortex** is visible from two viewpoints. Through the "Systems" lens: a file system with a lifecycle (Open/Close), an owner, and boundaries. Through the "Descriptions" lens: the content of those files — Distinctions, principles, protocols. Not two objects, but two perspectives on one (ISO 42010).
>
> **Neon DB** — similarly. Through the "Systems" lens: a running DBMS with 4D boundaries (HD #27: the bot is a client, not the owner). Through the "Work Products" lens: events recorded in that DBMS.

Roles (Viewpoint 3) are triggered automatically via the OS system scheduler: launchd (macOS) or cron (Linux). The scheduler is not part of IWE — it is operating system Infrastructure. It is installed once during setup.

#### Viewpoint 2: Descriptions (U.Description) — Knowledge Loaded Into Systems

Text descriptions that are loaded into the AI's context and define its behavior. They are not executed — they are read.

| Description | Composition | Purpose |
|----------|--------|-----------|
| **Principles** (FPF, SPF, ZP) | Encoded in the exocortex and prompts | Principles of correct thinking, fallback chain |
| **Exocortex content** | `CLAUDE.md` + `MEMORY.md` + `memory/*.md` | Rules, Distinctions, SOTA, navigation |
| **Pack entities** | `PACK-{domain}/pack/**/*.md` | Formalized domain descriptions (source of truth) |
| **Role prompts** | `roles/*/prompts/*.md` | Role Configuration: day-plan, week-review, session-close, etc. |

> **Test:** Can it be delivered as a file and loaded into a system? → Description.

#### Viewpoint 3: Roles (U.RoleAssignment) — Functions Independent of the Performer

A Role describes a function (WHAT to do), not a performer (WHO does it). One Role Performer (holder) can play multiple Roles. One Role can be played by different performers (Claude, a bash Script, a human). Details: [DP.ROLE.001 §3](https://github.com/TserenTserenov/PACK-digital-platform/blob/main/pack/digital-platform/02-domain-entities/DP.ROLE.001-platform-roles.md).

| Role | Code | Performer (holder) | What it does | When |
|------|-----|-------------|-----------|-------|
| **Strategist** | R1 | Claude CLI (scheduled) | Planning, reflection, Session preparation | Every morning, evening, week |
| **Extractor** | R2 | Claude CLI | Extracting descriptions into Pack | On Close, on demand, every 3h |
| **Synchronizer** | R8 | bash script (scheduled) | Schedule coordination, notifications, nightly review | On schedule |
| **Guide** | R13 | Telegram bot | Navigating the user through Platform services | On user request |
| **User** | — | Human | Decision-making, creating, reflecting | Always |

> **Test:** Is it a function describable without naming the performer? → Role.
>
> **Role ≠ Role Performer (HD #5).** The notation "Strategist (R1) ← Claude" reads: Role is Strategist, holder is Claude. "Human" is not a Role — it is a performer playing the "User" Role.
>
> **FPF notation:** `Holder#Role:Context@Window` (A.2). Full catalog: 21 platform Roles in DP.ROLE.001 §3.2.

#### Viewpoint 4: Methods (U.MethodDescription) — How a Role Produces a Work Product

Method descriptions (procedures for "how to do") that connect a Role to a Work Product. They have their own lifecycle, owners, and correctness tests.

| Method | What it describes | Owner Role | Work Product |
|-------|--------------|---------------|-----------------|
| **OWC Protocol** | Open → Work → Close for each Session | All Roles | WP context, plans, reports |
| **Capture-to-Pack** | Knowledge extraction at Work milestones | R2 Extractor | Pack entities |
| **ArchGate** (EMOGSSS) | Evaluation of architectural decisions by 7 characteristics | R1 Strategist | Assessment table, decision |
| **Knowledge Extraction** (KE) | Transformation of raw data into Pack entities | R2 Extractor | Pack entities |
| **Note-Review** | Processing notes, routing to the appropriate repos | R1 Strategist | Processed notes, tasks |

> **Test:** Is it a "how to do" procedure, describable independently of the performer? → Method.
>
> **Why a separate viewpoint?** Triad A.7 (Role → Method → Work) is the central Distinction of FPF. Without the "Methods" viewpoint, protocols get lost among Descriptions — even though they are not merely knowledge, but **procedures** connecting Roles to Work Products.

#### Viewpoint 5: Work Products (U.Work) — What Is Produced

Observable Work Products. They can be read, verified, versioned, and handed off without explanation.

| Work Product | Where | Who produces it | Purpose |
|----------|-----|---------------|----------|
| **Strategy hub** | `DS-strategy/` | R1 Strategist + User | Storage of personal documents (plans, strategy, inbox) and conducting strategy Sessions |
| **Pack documents** | `PACK-{domain}/` | R2 Extractor + User | Accumulation of formalized domain descriptions (sole source of truth) |
| **Project repos** | `DS-{projects}/` | User + Claude Code | Creating specific products: code, bots, courses, content |
| **Digital Twin events** | Neon DB | Bot + LMS + Club | Personalization and reflection: Profile, Progress, self-assessment |
| **Notes** | `DS-strategy/inbox/` | Bot (from Telegram) | Quick capture of thoughts and observations for subsequent Strategist processing |
| **Posts, drafts** | `DS-strategy/drafts/`, Knowledge Index | User | Crystallizing thoughts and publishing |

> **Test:** Can it be handed off to another person without explanation? Does it persist after the work is done? → Work Product.

#### How the Viewpoints Connect

```
         Role ──method──→ Method ──produces──→ Work Product
              ↑                                    │
         Descriptions                        Capture-to-Pack
         loaded into Roles                   back into Descriptions
              ↑
         Systems
         execute Roles

Example chains (Role → Method → Work Product):
  R1 Strategist ──── OWC ──────────────── WeekPlan, DayPlan
  R2 Extractor ─── Capture-to-Pack ──── Pack entities
  R1 Strategist ──── Note-Review ─────── Processed notes
  User ─────────── ArchGate ─────────── EMOGSSS table + decision
```

> **Integrity principle:** Remove any viewpoint and IWE degrades. Without Systems — no execution. Without Descriptions — a stateless assistant. Without Roles — task chaos. Without Methods — ad hoc work. Without Work Products — no results.

### 1.3. User Journey

```
T axis (learner):
T0 No Ory           T1 Start            T2 Learning         T3 Personalization   T4 Creation (IWE)
├── /start in bot   ├── Ory registration ├── Programs         ├── Digital Twin      ├── setup.sh
├── telegram_id     ├── UUID             ├── Marathon          ├── Profile + goals   ├── Claude Code
├── 30-day trial    ├── 30-day trial     ├── Bot + content    ├── Mentor            ├── Strategist + plans
└── Basic search    └── Assistant        └── Expert           └── Mentor            └── Co-thinker

Orthogonal axes (assigned):
TM1-TM3: Mentor    TA1-TA4: Administrator    TD1: Developer
```

**Key point:** T0–T3 work without Git — everything goes through the bot. T4 adds Claude Code, Git, and automated agents. TD1 (developer) is an orthogonal axis: access to source code, Deployment, and architectural decisions. Owner = T4 + TA4 + TD1. The transition is gradual — everything accumulated previously (Digital Twin, Profile, Progress) is preserved.

**Central IWE invariant:** Platform updates (Standard) **never** affect user data (Personal). Your plans, knowledge, and strategy belong to you.

## 2. Architecture: Perimeters and Spaces

### 2.1. Four System Perimeters

IWE does not exist in isolation — it is part of a 4-perimeter system. Each perimeter corresponds to its own level in the principles hierarchy (§ 3.1):

```
L1: Ecosystem    — the entire system: Platform + community + all IWE users
  L2: Platform   — Infrastructure and services (bot, MCP, Knowledge Index)
    L3: Template — this Template (CLAUDE.md + memory/ + Strategist + seed/)
      L4: Personal IWE — your instance (configured, with personal Pack and data)
```

| Perimeter | What it means for you | Example | How it is updated |
|--------|-------------|--------|-----------------|
| **L1: Ecosystem** | Community, seminars, content | systemsworld.club, Telegram channels | You participate |
| **L2: Platform** | Services you connect to | Bot @aist_me_bot, Knowledge Index | Updated by the developer |
| **L3: Template** | The Template your IWE was created from | This repo (FMT-exocortex-template) | `update.sh` — Platform-space |
| **L4: Personal IWE** | Your work, plans, knowledge | ~/IWE/CLAUDE.md, DS-strategy/ | Only you (User-space) |

**Where to learn more:**
- `DS-ecosystem-development/11-platform-contours.md` — full architectural model (ecosystem governance repo, created locally during Deployment, not published to GitHub)

### 2.2. From Template to Workspace

#### FMT-exocortex-template Repo Structure

```
FMT-exocortex-template/
│
├── CLAUDE.md                        # Rules for Claude Code
├── README.md                        # Quick start
├── REPO-TYPE.md                     # Repository type (Format)
├── ONTOLOGY.md                      # Exocortex Ontology
├── update.sh                        # Update from upstream
│
├── memory/                          # Working memory (≤10 files)
│   ├── MEMORY.md                    # ★ PERSONAL: tasks, navigation
│   └── *.md                         # PLATFORM: protocols, SOTA, checklists
│
├── docs/                            # Reference documentation
│   └── LEARNING-PATH.md             # This file
│
├── roles/                          # Roles (extension point)
│   └── strategist/                  # Strategist: prompts + scripts + launchd
│
├── seed/                            # Starters → separate repos after setup
│   └── strategy/                    # → DS-strategy/
│
└── .claude/                         # Claude Code Configuration
    ├── hooks/                       # WakaTime heartbeat
    └── skills/                      # /setup-wakatime
```

#### Four Zones

| Zone | What | update.sh | User |
|------|-----|-----------|-------------|
| **PLATFORM** | `CLAUDE.md` (§1–7), `memory/protocol-*.md`, `roles/`, `docs/`, `.claude/` | Updates | Do not modify |
| **USER-SPACE** | `CLAUDE.md` § "My Rules" (the `<!-- USER-SPACE -->` section) | **Does not modify** | Your own rules, Distinctions |
| **CONFIG** | `memory/day-rhythm-config.yaml` | Does not modify | Configure parameters |
| **PERSONAL** | `memory/MEMORY.md`, AUTHOR-ONLY zones in protocols | Does not modify | Edit freely |
| **SEED** | `seed/strategy/` | N/A | After setup → becomes separate DS-strategy/ repo |

> **USER-SPACE** is the "8. My Rules" section at the end of CLAUDE.md. Add your own rules, Distinctions, and lessons only here — they are preserved during updates. Everything above (§1–7) is platform content and is updated via `update.sh`.
> **AUTHOR-ONLY zones** are blocks inside PLATFORM files marked with `<!-- AUTHOR-ONLY -->` markers. They are preserved by update.sh. Details: [CLAUDE.md §7](../CLAUDE.md).

#### What setup.sh Does

1. Forks the Template → your GitHub account
2. Substitutes 7 placeholders (`{{GITHUB_USER}}`, `{{WORKSPACE_DIR}}`, etc.)
3. Copies `CLAUDE.md` → workspace root directory
4. Copies `memory/*.md` → `~/.claude/projects/.../memory/`
5. Creates `DS-strategy/` from `seed/strategy/` (separate private repo)
6. Installs launchd agents for the Strategist

#### Workspace After Setup

```
~/IWE/
├── CLAUDE.md                          # read at the start of every Session (auto)
├── DS-strategy/                       # ★ daily: plans, inbox, strategy
│   ├── current/DayPlan, WeekPlan      # Strategist writes, you read
│   ├── inbox/WP-*.md                  # Work Product contexts
│   └── docs/Strategy.md              # your strategy
├── FMT-exocortex-template/            # DO NOT modify (updated via update.sh)
├── PACK-{domain}/                     # when you create one: domain knowledge
└── DS-{projects}/                     # when you create one: code, tools
```

### 2.3. What the Platform Provides Through the Template (Standard)

Through the Template and updates, you receive a ready-made methodology:

| Component | What it is | Files |
|-----------|---------|-------|
| **Protocols** | Open → Work → Close: how to run a Session | `memory/protocol-*.md` |
| **Memory** | 11 files: Distinctions, SOTA, Roles, checklists, navigation | `memory/*.md` |
| **Strategist** | 7 automated planning Scenarios | `roles/strategist/prompts/` |
| **Tools** | WakaTime hook, Claude Code skills | `.claude/hooks/`, `.claude/skills/` |
| **Rules** | Repo Architecture, processes, gates | `CLAUDE.md` |

All of this is updated via `update.sh` — you receive improvements without losing personal data.

### 2.4. What Accumulates for You (Personal)

Your data lives separately and is **never affected by updates**:

| Layer | What | Where | How it grows |
|------|-----|-----|-----------|
| **Fleeting notes** | Quick thoughts | `DS-strategy/inbox/fleeting-notes.md` | Bot: ".text" |
| **Captures** | Captured knowledge | `DS-strategy/inbox/captures.md` | Claude: Capture-to-Pack |
| **Memory** | Tasks, lessons, navigation | `MEMORY.md` | Claude updates each Session |
| **Configuration** | Behavior parameters | `memory/day-rhythm-config.yaml` | You configure |
| **AUTHOR-ONLY zones** | Your protocol extensions | `memory/protocol-*.md` | You add |
| **Pack entities** | Formalized knowledge | `PACK-{domain}/` | Extractor formalizes captures |
| **Content** | Posts, courses | `DS-{projects}/` | You create |

#### Three Customization Patterns (L3 → L4)

| Pattern | Mechanism | Example | Purpose |
|---------|----------|--------|----------|
| **Config** | yaml file with parameters | `strategy_day: saturday` | Agent behavior settings |
| **AUTHOR-ONLY zones** | HTML markers in protocols | Checks for system-specific conditions | Extending protocols without conflicts with update.sh |
| **Placeholders** | `{{WORKSPACE_DIR}}` etc. | Paths, GitHub username | Auto-substitution during setup |

More about AUTHOR-ONLY zones: [CLAUDE.md §7](../CLAUDE.md).

### 2.5. Updates: update.sh

**One command:** `cd ~/IWE/FMT-exocortex-template && bash update.sh`

The Script downloads the update Manifest from GitHub, compares sha256 checksums of local files against upstream, shows a preview, and applies changes after confirmation:

| Step | What it does | Result |
|-----|-----------|-----------|
| 0. Self-update | Checks for a new version of update.sh | Script is always current |
| 1. Manifest | Downloads `update-manifest.json` from GitHub | List of files to update |
| 2. Comparison | sha256 of local files vs remote | List of new and changed files |
| 3. Preview | Shows: new files, updated files, untouched files | You decide: apply or not |
| 4. Apply | Downloads and replaces files, substitutes variables | Platform files updated |
| 5. Platform-space | Copies CLAUDE.md → workspace, memory/ → ~/.claude/ | Live files updated |
| 6. Roles | Reinstalls Roles if their files changed | Agents updated |

**What is NOT affected:**

```
CLAUDE.md § "My Rules"     ← USER-SPACE section (your rules and Distinctions)
MEMORY.md                  ← Your Work Product table
DS-strategy/               ← Your plans, inbox/, docs/
PACK-{domain}/             ← Your domain knowledge
.secrets/, .mcp.json       ← Keys and Configuration
.claude/settings.local.json ← Your permissions
```

**Your own rules:** add them to the "8. My Rules" section at the end of CLAUDE.md (after the `<!-- USER-SPACE -->` marker). This section is preserved during updates. Rules in `<repo>/CLAUDE.md` of specific repos are not affected at all.

**Additional modes:**
- `bash update.sh --check` — only show whether updates are available (no apply)
- `bash update.sh --yes` — apply without confirmation

**Cumulative update model:**

Changes in the Template accumulate. You can update once a day, once a week, or once a month — one `bash update.sh` command applies everything accumulated in that period. CHANGELOG.md shows what changed.

**Telegram notifications:**

Every morning at 7:28, bot @aist_me_bot sends a digest of changes from the last 24 hours (if any). Subscribe to the update channel so you do not miss anything. A notification is information. The decision to update is always yours.

**Three ways to update:**
1. Terminal: `bash update.sh`
2. AI CLI: tell your AI *"update my exocortex"*
3. Check without applying: `bash update.sh --check`

### 2.6. Optional Services

The Template (L3) recommends but does not require these. Each is configured separately:

| Service | Type | Setup | Role | Product |
|--------|-----|-----------|------|---------|
| WakaTime | Tool | `/setup-wakatime` | Work Observability | Metrics by project and category |
| Digital Twin | Data | Bot → `/twin` | Response and plan personalization | Goals, self-assessment, context |
| systemsworld.club | Ecosystem | Registration | Community, seminars | Access to materials |
| Git + GitHub | Infrastructure | `setup.sh` (auto) | Versioning, agents | Repositories, CI |
| Marp | Tool | VS Code extension + CLI | Markdown → slides | Sliduments (PDF/HTML) |
| Cloud Scheduler | Automation | `setup/optional/setup-cloud-scheduler.sh` | IWE runs 24/7 when Mac is off | Backup, health check, notifications |

**Cloud Scheduler — IWE cloud automation:** A GitHub Actions workflow runs backup and health check daily at 04:00 MSK — even when your Mac is off. Base level ($0/month, no LLM). Optional: Telegram notifications with a report. Installation: `bash setup/optional/setup-cloud-scheduler.sh`. Details: `setup/optional/README.md`, Scenario [DP.SC.019](../../PACK-digital-platform/pack/digital-platform/08-service-clauses/DP.SC.019-autonomous-cloud-runtime.md).

**Health Check setup (extended):** By default, the health check monitors only the strategy repo. For multi-repo Monitoring:
1. GitHub → Settings → Variables → Actions → add `HEALTH_CHECK_REPOS` — a comma-separated list of your repos (`owner/repo, owner/repo2`)
2. (Optional) Add `BOT_HEALTH_URL` — bot health endpoint URL to check availability
3. (Optional) Add Secrets: `TELEGRAM_BOT_TOKEN` + `TELEGRAM_CHAT_ID` for Telegram notifications
4. The PAT (`STRATEGY_REPO_TOKEN`) must have access to all listed repos

Manual run: `gh workflow run cloud-scheduler.yml --field task=health-check`. Report: commits (24h + 7d by repo), DayPlan, WeekPlan, backup (<48h), Sessions, bot status, WP statistics, traffic-light summary.

**Marp — presentation preparation:** Marp converts Markdown files into slides (PDF, HTML, PPTX). Workflow: write a `.md` file with `---` separators → preview in VS Code (Marp extension) → export with `marp --pdf slides.md`. Sliduments (MIM.WP.001) are text-based, so Markdown + Git = versions, diffs, and edits via Claude Code. Installation: `npm install -g @marp-team/marp-cli` + VS Code → Extensions → "Marp for VS Code".

**IntegrationGate rule:** Before adding a new tool to your IWE: (1) type, (2) perimeter (L2/L3/L4), (3) Roles, (4) products, (5) processes.

## 3. Thinking Foundation

### 3.1. Principles Hierarchy

All knowledge is organized into 4 levels. Each level is Constrained by the one above it:

```
Level 0: ZP (zero principles)         ← axioms, no framework
    ↓ discipline
Level 1: FPF (first principles)        ← principles + framework (bundle)
    ↓ constrain
Level 2: SPF → Pack (second principles) ← framework + principles (separate)
    ↓ define
Level 3: S-2r etc. → DS               ← frameworks + principles (separate)
```

**Fallback chain:** DS (level 3) → Pack (level 2) → Base.Principles (SPF → FPF → ZP). If the current level is unclear — move up one level.

**Zero principles (ZP)** — 6 trans-disciplinary Constraints:

| Principle | Essence |
|---------|------|
| ZP.1 Axiomaticity | Build on axioms, not intuition |
| ZP.2 Structure and Symmetry | Describe through invariants, not objects |
| ZP.3 Multi-scale | Models must work at different scales |
| ZP.4 Optimization | Find the extremum, do not enumerate |
| ZP.5 Probability and Information | Describe uncertainty quantitatively |
| ZP.6 Computational Limits | Account for finite resources |

**Where to learn more:**
- [ZP/hierarchy.md](https://github.com/TserenTserenov/ZP/blob/main/hierarchy.md) — map of all 4 levels
- [ZP/principles/](https://github.com/TserenTserenov/ZP/tree/main/principles) — each principle in detail
- [CLAUDE.md](../CLAUDE.md) § 1 — type table and fallback chain

### 3.2. Hard Distinctions

30+ pairs of concepts that **must not be confused**. Confusion is the primary source of errors:

| # | Pair | Essence |
|---|------|------|
| 1 | System ≠ Episteme | Physical boundaries vs. knowledge domain |
| 2 | Method ≠ Tool | Way of working vs. working instrument |
| 3 | Work Product ≠ Description | Observable Artifact vs. text about it |
| 4 | Accounting ≠ Planning | Recording facts vs. recording intentions |
| 5 | Role ≠ Agent ≠ Tool | Mask vs. who wears the mask vs. instrument |
| 6 | Method ≠ Skill | Reproducible process vs. personal ability |
| 7 | Observation ≠ Judgment | Fact vs. interpretation |
| 8–11 | Data ≠ Insight, Artifact ≠ Process, Pack ≠ Governance, Process ≠ Service ≠ Scenario | Ontological |
| 12–22 | Description ≠ Knowledge, DDD strategic ≠ tactical, Platform ≠ Template ≠ Personal IWE, … | Methodological and operational |
| 25–26 | Draft ≠ Starter, Starter ≠ Post | Stages of the creative Pipeline |
| 27 | Bot ≠ Platform; Neon = one Digital Twin | Digital Twin Architecture |
| 28 | Prosthetic ≠ Exoskeleton | AI–human interaction pattern (§ 1.1a) |
| 29 | Pack knowledge ≠ Implementation decision | Domain truth → Pack. Technical choice → DS |
| 32 | Three Verification classes | closed-loop / open-loop / problem-framing (§ 5.1b) |
| 36 | Exocortex ≠ IWE | Exocortex is the description storage Subsystem inside IWE |

**Where to learn more:**
- [memory/hard-distinctions.md](../memory/hard-distinctions.md) — all 22 pairs with examples and tests

### 3.3. FPF First Principles

FPF (First Principles Framework) is the "operating system for thinking." It defines basic constructs and rules for combining them.

| Part | Contents | When to read |
|-------|-----------|-------------|
| A | Core: Holon, BoundedContext, Role–Method–Work | Basic Distinctions |
| B | Aggregation, Trust, Evolution Cycles | Understanding processes |
| C | Domain extensions (CAL) | Custom calculi |
| D | Ethics and conflict optimization | Multi-scale decisions |
| E | Constitution and authorship | Framework governance |
| F | Terminology: UTS, Bridges | Cross-domain alignment |
| G | SoTA Kit | Knowledge work patterns |

**How to read:** NOT sequentially. Start with the table of contents, then navigate to needed sections by code (e.g., `FPF A.7` = Strict Distinction).

**Where to learn more:**
- [FPF/README.md](https://github.com/ailev/FPF) — overview
- [memory/fpf-reference.md](../memory/fpf-reference.md) — navigation through key sections

## 4. Repositories and Projects

### 4.1. Three Repository Types

Each Repository belongs to one of 3 types. The type determines who creates it and what it stores:

| Type | Subtype | What it stores | Source of truth? | Examples |
|-----|--------|-----------|-----------------|---------|
| **Base** | Principles | ZP, FPF, SPF — principles and frameworks | Yes | ZP, FPF, SPF |
| **Base** | Formats | FMT-* — structural protocols | Yes (for the format) | FMT-exocortex-template, FMT-s2r |
| **Pack** | — | Domain passport | Yes | PACK-{domain} |
| **DS** | instrument / governance / surface | Derived from Pack | No | DS-strategy, DS-ai-systems |

**Key point:** **Base = Platform provides** (principles, frameworks, Templates). **Pack and DS = user creates.** Pack is the **only** source of truth for domain knowledge. DS consumes, it does not create.

**Where to learn more:**
- [CLAUDE.md](../CLAUDE.md) § 1 — full table, fallback chain
- [memory/repo-type-rules.md](../memory/repo-type-rules.md) — rules for each type

### 4.2. DS: Three Subtypes

DS is the most common Repository type you will create:

| Subtype | What it stores | Examples | When to create |
|--------|-----------|---------|----------------|
| **governance** | Plans, strategy, coordination | DS-strategy, DS-ecosystem-development (local) | During setup (DS-strategy — automatically) |
| **instrument** | Code, bots, agents, MCP | DS-ai-systems, DS-aist-bot | When building a system based on Pack |
| **surface** | Courses, guides, posts, content | DS-Knowledge-Index, DS-blog | When creating educational content |

### 4.3. Base/Formats — Standard Templates

The Platform provides standard formats (Base/Formats) — Repository structural protocols:

| Format | Purpose | For whom |
|--------|-----------|----------|
| **FMT-exocortex-template** | Personal workspace (IWE) | Every T4+ user |
| **FMT-s2r** | Project repos: 3×3 matrix (systems × Roles) | Advanced users with multi-component projects |

**FMT-s2r (System-to-Role)** organizes a project by kernels, each described through 9 documents (3 systems × 3 Roles). Useful when a project has multiple systems: mobile app + backend + Infrastructure.

> **Your own formats:** A user can create their own format — it will be a DS repo with `template: true` in REPO-TYPE.md.

**Where to learn more:**
- [FMT-s2r/README.md](https://github.com/TserenTserenov/FMT-s2r) — overview and structure

### 4.4. Creating and Managing DS Projects

**When to create:**

| Situation | What to create | How |
|----------|------------|-----|
| Identified a Knowledge Domain | `PACK-{domain}` | `/pack-new` — guided flow through SPF (checks/clones SPF+FPF, defines the Domain, creates scaffold) |
| Building a system (bot, tool) | `DS-{project}` (instrument) | `gh repo create DS-my-tool --private` |
| Creating a course or content | `DS-{project}` (surface) | `gh repo create DS-my-course --private` |
| Coordinating multiple systems | `DS-{hub}` (governance) | `gh repo create DS-my-hub --private` |

**What every DS-* repo must contain:**
- `CLAUDE.md` — rules for Claude Code (specific to this repo)
- `inbox/WP-*.md` — contexts of active Work Products (single source — aggregated by `scripts/active-wp-sweep.sh`)
- `MAPSTRATEGIC.md` — where THIS system is headed

**MAPSTRATEGIC.md vs Strategy.md:**

| | MAPSTRATEGIC.md | Strategy.md |
|---|----------------|-------------|
| **Where** | In each system's repo | `DS-strategy/docs/` |
| **Who writes** | System owner | Strategist (aggregation) |
| **What** | "Where THIS system is headed" | "Where I am headed" |

**Flow:** MAPSTRATEGIC (each repo) → Strategist (session-prep) → Strategy.md → WeekPlan

### 4.5. Naming and Coding

**Repository prefixes:**

| Prefix | Type | Example |
|---------|-----|--------|
| `ZP`, `FPF`, `SPF` | Base/Principles | ZP, FPF, SPF |
| `FMT-` | Base/Formats | FMT-exocortex-template |
| `PACK-` | Pack | PACK-digital-platform |
| `DS-` | DS | DS-ai-systems, DS-strategy |

**Pack entity coding:** `CONTEXT.TYPE.NNN`

| Part | What | Example |
|-------|-----|--------|
| Context | Pack abbreviation | DP (digital-platform), MIM, PD |
| Type | Entity kind | M (method), WP (Work Product), D (Distinction), FM (failure mode) |
| Number | Unique sequential | 001, 002, … |

**Examples:** `DP.M.001` (method), `MIM.FM.003` (failure mode), `DP.ROLE.001` (agent)

**Where to learn more:**
- [SPF/spec/SPF.SPEC.001-entity-coding.md](https://github.com/TserenTserenov/SPF/blob/main/spec/SPF.SPEC.001-entity-coding.md) — full specification

## 5. Daily Work

### 5.1. OWC Fractal: Day and Session

OWC (Opening → Work → Closing) is a **fractal pattern** operating at two scales. A Day consists of Sessions; each Session is a complete OWC cycle inside the daily cycle.

```
Day
├── Day Open   — morning ritual: yesterday → plan → self-development → world
│   ├── Session 1: Open → Work → Close
│   ├── Session 2: Open → Work → Close
│   └── ...
└── Day Close  — evening ritual: results → praise → setup for tomorrow

Session
├── Session Open  — WP Gate → Alignment ritual
├── Session Work  — Capture-to-Pack + Work milestone checks
└── Session Close — KE → statuses → backup → report
```

**Skipping Open** = unplanned work. **Skipping Close** = unrecorded result.

| Scale | Stage | Trigger | Role |
|---------|--------|---------|------|
| **Day** | Opening | "open the day" | R1 Strategist |
| **Day** | Work | Between Day Open and Day Close | R1 + R6 |
| **Day** | Closing | "close the day" / "day summary" | R1 Strategist |
| **Session** | Opening | Any task (no exceptions) | R6 Coder |
| **Session** | Work | After completing Opening | R6 Coder |
| **Session** | Closing | "closing" / "done" / "close" | R6 Coder |

> **Distinction: Day ≠ Session.** Day Open/Close are separate ritual Sessions (trigger only, no task). Session Open/Close always exist in the context of specific work.

#### Day Open (Morning Ritual)

The Strategist (R1) executes 7 steps:

1. **Yesterday** — commits from yesterday across all repos → 1–3 key results
2. **Plan for today** — carry-over from Day Close in full + 2–4 focus Work Products from WeekPlan (≥1h). **Slot 1 = self-development** (mandatory)
3. **Self-development** — current guide, where you left off, active drafts
4. **Strategizing** — if today is `strategy_day` (from `day-rhythm-config.yaml`) → **do NOT create DayPlan** (the day's plan is already in WeekPlan → "Plan for Monday" section). Show WeekPlan, skip step 7
4b. **Pomodoros** — show current settings (work/break/long break), offer to adjust
5. **IWE overnight** — automation logs (sync-agent, note-review, reindex) — did they run?
6. **World** — digest on configured topics (RSS / WebSearch)
7. **Record** — create/update `DayPlan YYYY-MM-DD.md` in DS-strategy/current/. **Skipped on strategy_day** (step 4)

**Product:** DayPlan (on regular days) or WeekPlan (on strategy_day) — handoff Artifact from the Strategist to the Human.

#### Day Close (Evening Ritual)

The Strategist (R1) collects the day's results:

1. **Review** — table of "Work Product × status" (done / partial / not started)
2. **What I learned** — captures in Pack, Distinctions, insights, guide progress
3. **Praise** — what went well, what was difficult
4. **Nothing forgotten?** — uncommitted changes, branch sync, outstanding commitments
5. **Setup for tomorrow** — where to start, what context to prepare (Agent→Agent handoff)
6. **Record** — append "Day Results" to DayPlan, update statuses in WeekPlan + MEMORY.md

#### Day Work (Daily Rules)

| # | Rule | Essence |
|---|---------|------|
| 1 | Slot 1 = self-development | Do not move to routine tasks until slot is complete |
| 2 | Sessions = OWC | Each Session is a full Open → Work → Close cycle |
| 3 | Pomodoros | 25/5, long break after 4 cycles |
| 4 | Reminder | Session > 50 min without break → reminder |
| 5 | Check against plan | Between Sessions: "Am I still on the day's plan?" |

### 5.1b. Session Open: WP Gate + Ritual

#### WP Gate (Blocking)

**First action for ANY task:** check whether the task is in the plan.

1. Read MEMORY.md → section "Work Products for current week"
2. Match found → proceed + **DayPlan Gate:** if the Work Product is not in today's DayPlan → add a line
3. No match → STOP → record the Work Product in 4 places (MEMORY.md, WP-REGISTRY, WeekPlan, WP context file) → only then start

**Exceptions:** tasks ≤15 min, questions requiring no changes, emergency bug fixes. But if an exception grows into real work → *"This is becoming a Work Product. Record it?"*

#### Alignment Ritual

Before starting work, Claude announces:

> **User's Role:** [from 4 Roles]
> **Claude's Role:** [from catalog]
> **Work:** [what]
> **Work Product:** [Artifact]
> **Verification class:** [trivial / closed-loop / open-loop / problem-framing]
> **Method:** [how]
> **Estimate:** ~Xh
> **Model:** [current] — recommend [model] ([reason])

**4 user Roles** (Tseren in his IWE):
1. Platform developer → Pack, DS-ecosystem, FMT
2. Platform user → bot, LMS, courses
3. Own IWE developer → exocortex, CLAUDE.md, protocols (ABOVE the system)
4. Own IWE user → plans, reviews, posts, captures (INSIDE the system)

**Verification class** (determines the working mode):

| Class | Verification | Mode | Model recommendation |
|-------|----------|-------|---------------------|
| **trivial** | Not needed (result is obvious) | Agent autonomously, no captures | Haiku |
| **closed-loop** | Cheap, automated (tests) | Agent autonomously | Sonnet |
| **open-loop** | Expensive, deferred | Collaborative, captures mandatory | Opus |
| **problem-framing** | Unknown | Exoskeletal: questions > answers | Opus |

> **Switching model — two scenarios:**
> - **Entire Session on a different model:** If at Opening Claude determines the task is trivial/closed-loop and the current model is excessive, it will say: *"This task is trivial; I recommend switching to Haiku via `/model`. I cannot switch automatically."* The user switches manually → the entire Session runs on the cheaper model.
> - **Individual task within a Session:** A trivial task appears mid-Session → Claude delegates to a sub-agent on a cheaper model. The Session is not interrupted. Delegation only goes downward: Opus→Sonnet/Haiku, Sonnet→Haiku. Switching upward requires `/model`.

**Exoskeletal mode** (problem-framing only): Claude does NOT offer a solution immediately. First: 3 clarifying questions (What? Why? Constraints?) → answers → 2–3 approach options with trade-offs → user chooses → work begins.

**Session registration:** after the ritual → one line in `<governance-repo>/inbox/open-sessions.log`.

### 5.1c. Session Close: Full Checklist

- [ ] Pull → `cd DS-strategy && git pull --rebase`
- [ ] Knowledge Extraction (R2): collect captures → Extraction Report → approval
- [ ] Update MEMORY.md (Work Product statuses)
- [ ] Update WP-REGISTRY.md (statuses + new Work Products)
- [ ] Git commit + push
- [ ] Update WeekPlan (Work Product statuses)
- [ ] Update DayPlan (statuses of ALL lines: Work Products + ad-hoc)
- [ ] Backup: memory/ + CLAUDE.md → DS-strategy/exocortex/
- [ ] WP Context File: update (in_progress) or archive (done → archive/wp-contexts/)
- [ ] Selective Reindex: Pack changed? → `selective-reindex.sh`
- [ ] Repo CLAUDE.md: feat-commits → new rules?
- [ ] Draft-list: Pack enriched → suggest a draft?
- [ ] Template CHANGELOG: commits in FMT-exocortex-template? → update
- [ ] Session log: remove line from open-sessions.log
- [ ] Close report: what was done, what remains

#### Exit Protocol (for all Roles)

| # | Step | Why |
|---|-----|-------|
| 1 | **Artifact** | Without an Artifact, work does not exist |
| 2 | **Status** | Without a status, Progress is invisible |
| 3 | **Notification** | Without a notification, the chain breaks |

**Where to learn more:**
- [CLAUDE.md](../CLAUDE.md) § 2 — slim rules and triggers
- [memory/protocol-open.md](../memory/protocol-open.md) — Day Open algorithm + Session Open (full algorithms)
- [.claude/skills/day-open/SKILL.md](../.claude/skills/day-open/SKILL.md) — DayPlan, WeekPlan, compact dashboard templates (lazy loading)
- [memory/protocol-work.md](../memory/protocol-work.md) — Day Work + Session Work
- [memory/protocol-close.md](../memory/protocol-close.md) — Day Close + Session Close (full algorithms)

### 5.2. Three-Layer Memory

| Layer | File | Contents | Limit | When read |
|------|------|-------------|-------|---------------|
| 1 | `MEMORY.md` | Weekly tasks, lessons, navigation | ≤100 lines | Every Session (auto) |
| 2 | `CLAUDE.md` | Slim core: blocking rules + navigation | ~90 lines | At startup (auto) |
| 3 | `memory/*.md` | Protocols, Distinctions, SOTA, Roles, checklists | ≤11 files | On triggers from CLAUDE.md |
| 4 | `.claude/skills/` | Templates, rituals (lazy loading) | On call | Only via `/skill` command |

**memory/ files:**

| File | Topic | When to read |
|------|------|-------------|
| `protocol-open.md` | Opening protocol | Every Session (auto) |
| `protocol-work.md` | Work protocol | After opening |
| `protocol-close.md` | Closing protocol | At completion |
| `navigation.md` | Repo navigation | Finding files |
| `hard-distinctions.md` | 30+ Distinctions | When terminology is unclear |
| `fpf-reference.md` | FPF navigation | When creating/reviewing Pack |
| `sota-reference.md` | SOTA practices | For architectural decisions |
| `checklists.md` | Quality checklists | Before responding, before modifying |
| `repo-type-rules.md` | Rules by repo type | When working with a specific type |
| `roles.md` | Role catalog (AI + human) | During Session opening ritual |

> **`roles.md` is a living file.** The Template provides platform Roles (R1–R21). Add your own Roles in the "User Roles" section (R100+). This helps Claude select the correct behavior for each task — not guessing, but consulting the table.

**Policy:** Maximum 11 files. Reference files ≤100 lines, protocols ≤150, registries ≤200 + cleanup on Close. Cross-system content → memory/. System-specific content → `<repo>/CLAUDE.md`.

### 5.3. Capture-to-Pack: Capturing Knowledge

At each Work milestone (subtask completed, pattern discovered, decision made), ask: **is there knowledge to record? Is there a seed for a post?**

| Knowledge type | Where | When | Who writes |
|------------|------|-------|-----------|
| Rule for all repos (1–3 lines) | `~/IWE/CLAUDE.md` | Immediately | Claude |
| Rule for one repo | `<repo>/CLAUDE.md` | Immediately | Claude |
| Domain knowledge (Architecture, patterns) | Corresponding Pack | On Close | R2 Extractor → Pack |
| Distinction, method, FM, WP | Corresponding Pack | On Close | R2 Extractor → Pack |
| Implementation knowledge (protocols, processes, configs) | DS docs/, PROCESSES.md, protocol-*.md | Immediately/Close | Claude / R2 |
| Seed for a post | `DS-strategy/drafts/draft-list.md` + `drafts/` | On Close | Claude |
| Major lesson | `memory/<topic>.md` | Immediately | Claude |

> **Dual KE routing (HD #29):** Pack knowledge ≠ Implementation decision. The Extractor (R2) at Close proposes recording knowledge in two places: domain knowledge → Pack, implementation knowledge → DS docs/. One Pipeline, two outputs.

**Announcement format:** *"Capture: [what] → [where]"*

### 5.4. CLAUDE.md: Structure and Configuration

The system uses two levels of CLAUDE.md:

| Level | File | Scope | Who updates |
|---------|------|-----------------|---------------|
| **Root** | `~/IWE/CLAUDE.md` | All repos in workspace | Platform (update.sh) + you (lessons) |
| **Repo-level** | `<repo>/CLAUDE.md` | This repo only | You (repo-specific rules) |

**When to use which:**
- Rule applies to all projects → root CLAUDE.md
- Rule is specific to one repo → `<repo>/CLAUDE.md`
- Example: "Always pull before commit in DS-strategy" → root. "Commit format in DS-aist-bot: feat/fix/chore" → repo-level.

**When you create a new DS-* repo**, add a CLAUDE.md containing:
- Repo type (downstream/instrument)
- Related Pack (source of knowledge)
- Specific rules (commit format, tests, Deployment)

### 5.5. Strategist: Automated Planning

The Strategist is Role R1, executed by Claude Code on a schedule (launchd on macOS, cron on Linux) or by trigger:

| Scenario | When | What it does | Product |
|----------|-------|-----------|---------|
| **Day Open** | Morning (trigger "open the day") | 7 steps: yesterday → plan → self-development → pomodoros → IWE overnight → world → record | DayPlan |
| **Day Close** | Evening (trigger "close the day") | Results → what I learned → praise → setup for tomorrow | Updated DayPlan |
| **Session-Prep** | Monday morning (auto) | Analysis of last week + MAPSTRATEGIC | WeekPlan draft |
| **Strategy-Session** | After session-prep | Interactive plan discussion | Approved WeekPlan |
| **Week-Review** | Sunday evening (auto) | WakaTime metrics, achievements, lessons | "Results W{N}" section in WeekPlan |
| **Note-Review** | As needed | Processing fleeting notes and captures | Routing to Pack/inbox |
| **Add-WP** | When new task arrives | Adding Work Product to plan (4 places) | Updated WeekPlan + WP file |

**DS-strategy — the strategy hub:**

| Folder | Contents |
|-------|-------------|
| `current/` | Current WeekPlan, DayPlan |
| `inbox/WP-*.md` | Task contexts (living work history) |
| `docs/Strategy.md` | Your overall strategy |
| `docs/Dissatisfactions.md` | Dissatisfactions (triggers for change) |
| `drafts/` | Personal drafts + draft-list.md (index, ≤7 days TTL) |
| `archive/` | Completed plans |
| `exocortex/` | Backup of memory/ + CLAUDE.md |

**Single-source pattern:** DS-strategy (hub) is the sole Registry (`WP-REGISTRY.md` + `inbox/WP-*.md`), aggregated via `scripts/active-wp-sweep.sh`. Hub-and-spoke with WORKPLAN.md was replaced by WP-283 F-H (May 2026).

#### Configuring the Strategy Day

By default, the strategy Session launches on **Sunday** (`strategy_day: sunday` in `memory/day-rhythm-config.yaml`). You can choose any day of the week:

```yaml
# memory/day-rhythm-config.yaml
day_open:
  strategy_day: saturday   # sunday..sunday — your strategy day
```

On this day:
- `strategist.sh` runs `session-prep` instead of `day-plan`
- `scheduler.sh` runs `week-review`
- **Day Open does not create a DayPlan** — the day's plan is already embedded in WeekPlan (the "Plan for [day]" section)
- All three components read `strategy_day` from the config — no hardcoded values

#### Activation Gate: How Pending Work Products Enter the Plan

Every Work Product with ⏳ pending status has an **activation condition** — the answer to "under what condition does this Work Product enter WeekPlan?"

| Condition type | Example | How it is checked |
|-------------|--------|----------------|
| **date** | `W15`, `after April 1` | Strategist at Session-Prep: `date ≤ current week?` |
| **dep** | `dep: WP-73` | At dependency Close: `WP-73 = done → alert` |
| **on-demand** | `when budget is available` | Manually on strategy day only |

**Dormant Review:** `on-demand` items older than 3 weeks → automatically added to the strategy session agenda. Question: "Archive (📦) or assign a specific condition?" This prevents accumulation of "dead" Work Products.

Conditions are stored in the Work Product context file (`inbox/WP-NNN/WP-NNN.md`, the `activation:` field in frontmatter — e.g., `activation: on-demand` or `activation: dep:WP-73`). WP-REGISTRY is an index only (number/Priority/name/status/repo/budget); details of a specific Work Product, including activation condition, live in its context file (issue #263).

**Where to learn more:**
- [roles/strategist/prompts/](../roles/strategist/prompts/) — 9 prompts for each Scenario

### 5.6. Creative Pipeline: From Note to Post

> Formalization: [PD.FORM.005 Creative Pipeline](https://github.com/aisystant/PACK-personal/blob/main/pack/personal-development/02-domain-entities/formalizations/PD.FORM.005-creative-pipeline.md)

The Creative Pipeline is a closed process that turns thoughts into published texts and formalized knowledge. The key invariant: **nothing accumulates** — every Artifact must advance or be closed within its TTL.

#### 4 Artifact Stages

```
Note (≤7d) → Draft (≤7d) → Starter (≤14d) → Post
fleeting-notes   DS-strategy/      Knowledge Index      Published
inbox/           drafts/            status: draft         status: published
```

| Stage | Where stored | TTL | Visibility |
|--------|-------------|-----|-----------|
| **Note** | `DS-strategy/inbox/fleeting-notes.md` | ≤7 days | Private |
| **Draft** | `DS-strategy/drafts/*.md` | ≤7 days | Private |
| **Starter** | `DS-Knowledge-Index/docs/` (status: draft) | ≤14 days | Public |
| **Post** | `DS-Knowledge-Index/docs/` (status: published) | — | Public |

#### 7 Note Routing Directions

Note-Review classifies each note into one direction. A Draft is a recommendation only — it is created after approval.

| # | Category | Criterion | Where |
|---|-----------|----------|------|
| 1 | **Dissatisfaction** | Discomfort, "I want to change this" | `Dissatisfactions.md` |
| 2 | **Task** | Specific action, "do this tomorrow" | WeekPlan / DayPlan |
| 3 | **Knowledge** | Pattern, Distinction, method, rule, insight | `captures.md` → Pack |
| 4 | **Draft** | Seed for a post, reflection with concepts | Recommendation → `drafts/` (after approval) |
| 5 | **Idea** 🔄 | Reflection, no specific action | Stays in notes (revisit at strategy session) |
| 6 | **Personal data** | Contact, account, token, credentials | `personal/*.md` |
| 7 | **Noise** | Test, duplicate, already done, link without context | ~~strikethrough~~ → archive |

#### Two Key Distinctions

1. **Draft ≠ Starter.** A Draft is a private text (`DS-strategy/drafts/`), it may be raw. A Starter is a public text (`DS-Knowledge-Index/`, status: draft), it must be coherent. *Test:* can you show it to someone else? No → Draft.

2. **Starter ≠ Post.** A Starter is published but not promoted. A Post is actively promoted. *Test:* ready to attract attention? No → Starter.

#### Anti-accumulation: TTL and Guards

Every Artifact MUST exit into one of the directions within its TTL. When Drafts accumulate, guards are triggered:

| Threshold | Response | What to do |
|-------|---------|-----------|
| ≤5 Drafts | Normal | Work by Priority |
| 6–10 Drafts | **Warning** | Prioritize or close extras until ≤5 |
| >10 Drafts | **Block** | Cannot add new ones. First advance or close until ≤5 |

Guards are checked at every Note-Review and when creating a new Draft.

#### Closed Loop: Pack ↔ Content

The Pipeline does not run linearly — it operates as a **closed loop**:

1. **Feedback from posts** — reader reactions → new notes → new cycle.
2. **Pack → Content** — when the Extractor adds ≥3 entities on one topic to Pack → a Draft post is automatically suggested (popularizing formalized knowledge).

#### Pipeline Health Test (at every strategy session)

1. Inputs ≈ outputs? (N notes created → ~N sorted)
2. TTLs not violated? (notes >7d? Drafts >7d? Starters >14d?)
3. Guard not violated? (Drafts ≤5?)
4. Pack → post? (were there captures → was a Draft suggested?)

If ≥2 answers are "no" → Pipeline is stuck → raise as a question in the strategy session.

#### IWE Materialization

| Component | File |
|-----------|------|
| Draft index | `DS-strategy/drafts/draft-list.md` |
| Drafts | `DS-strategy/drafts/*.md` |
| Sorting protocol | `roles/strategist/prompts/note-review.md` (category #4) |
| Close protocol | `memory/protocol-close.md` (step 9: draft-list) |

## 6. Knowledge: Pack and Extraction

### 6.1. What Pack Is

Pack is a formalized domain passport. It is the **only source of truth** for domain knowledge.

**Contains:**
- Bounded Context (domain boundaries)
- Distinctions (what must not be confused)
- Ontology (entities and relationships)
- Roles (who acts)
- Methods (how to act)
- Work Products (results of Methods)
- Failure Modes (typical errors)
- SOTA annotations (knowledge currency)

**Live example:** [PACK-digital-platform](https://github.com/TserenTserenov/PACK-digital-platform) (40+ entities)

### 6.2. Creating Pack (11 SPF Stages)

SPF defines the Pack creation process:

| # | Stage | Essence |
|---|--------|------|
| 01 | Domain selection | Define and bound the domain |
| 02 | Bounded Context | Establish semantic boundaries |
| 03 | Distinctions work | Which pairs must not be confused |
| 04 | Entity identification | Roles, objects, Constraints |
| 05 | Information intake | Input materials for analysis |
| 06 | Analysis and formalization | Formalization through Distinctions |
| 07 | Method and WP extraction | Methods → Work Products |
| 08 | Failure mode extraction | Typical interpretation errors |
| 09 | SOTA annotations | current / hypothesis / deprecated |
| 10 | Map maintenance | Graph of relationships between entities |
| 11 | Review and evolution cycle | Continuous update Protocol |

**Quick start:** `/pack-new` — the Skill guides you through domain selection, Pack name, scaffold creation, and shows the F1–F6 Roadmap.

**Where to learn more:**
- [SPF/process/](https://github.com/TserenTserenov/SPF/tree/main/process) — all 11 stages
- [SPF/pack-template/](https://github.com/TserenTserenov/SPF/tree/main/pack-template) — structure Template
- [docs/PACK-CREATION.md](PACK-CREATION.md) — practical guide for beginners

### 6.3. Pack Structure

```
PACK-{domain}/
├── 00-pack-manifest.md           # Header: name, version, BC
├── 01-domain-contract/
│   ├── 01A-bounded-context.md    # Semantic frame
│   ├── 01B-distinctions.md       # Key Distinctions
│   └── 01C-ontology.md           # Entities and relationships
├── 02-domain-entities/
│   ├── 02A-roles.md              # Roles in the domain
│   ├── 02B-objects-of-attention.md
│   ├── 02C-methods-index.md      # Method index
│   └── 02D-tools-index.md        # Tool index
├── 03-methods/                    # Method cards
├── 04-work-products/              # Work Product cards
├── 05-failure-modes/              # Typical errors
├── 06-sota/                       # SOTA annotations
└── 07-map/                        # Navigation map
```

### 6.4. Knowledge Extractor (R2)

**Role:** Transforms information into formalized Pack entities.

**Pipeline:** `classify → route → formalize → validate`

| Scenario | Trigger | When you see the result |
|----------|---------|--------------------------|
| Session-Close | Close Protocol | At Session close, Claude proposes new Pack entities |
| On-Demand | Your command | Immediately in Claude Code |
| Bulk-Extraction | Document processing | After analysis — Extraction Report |
| Inbox-Check | Schedule | In DayPlan (if there is something new) |

**Key rule:** The Extractor always **proposes** — it never writes without approval.

**How this works for you:**
1. You work in Claude Code → captures appear during the Session
2. At Close → Claude activates the Extractor Role (R2) and shows the Extraction Report
3. You approve → entities are written to Pack

**Where to learn more:**
- Close Protocol (§ 5.1) — when the Extractor is activated
- [DP.ROLE.001](https://github.com/TserenTserenov/PACK-digital-platform/blob/main/pack/digital-platform/02-domain-entities/DP.ROLE.001-platform-roles.md) R2 — full Role description

### 6.5. Knowledge MCP Servers

Claude Code connects to the Platform's Gateway MCP server (via https://claude.ai/settings/connectors). The `iwe-knowledge` Gateway (`mcp.aisystant.com/mcp`) aggregates all backends — a single connection point for all knowledge tools.

#### knowledge — knowledge base search

Hybrid search (vector + keyword) across all Pack repositories and documentation. ~5400 documents.

| Tool | What it does | Example |
|------------|-----------|--------|
| `knowledge_search` | Semantic + keyword search | `knowledge_search("service tiers", source_type="pack")` → DP.ARCH.002 |
| `knowledge_get_document` | Specific document by name | `knowledge_get_document("DP.ROLE.001-platform-roles.md")` |
| `knowledge_list_sources` | List all sources | Shows document count by category |

**Source types:** `pack` (domain knowledge), `guides` (guides), `ds` (processes).

> Guide search: `knowledge_search("query", source_type="guides")`. A separate guides server is not needed — the Gateway combines all sources.

#### digital-twin — learner Digital Twin

Learner data metamodel: goals, self-assessment, context, Progress.

| Tool | What it does | Example |
|------------|-----------|--------|
| `dt_describe_by_path` | Metamodel structure | `dt_describe_by_path("/")` → 4 categories IND.1–4 |
| `dt_read_digital_twin` | Read data | `dt_read_digital_twin("1_declarative/1_2_goals")` → learner goals |
| `dt_write_digital_twin` | Write to IND.1 | `dt_write_digital_twin("1_declarative/...", data)` |

> **IND.1 (Declarative)** is the only writable category. IND.2 (Collected), IND.3 (Derived), IND.4 (Generated) — read-only.

#### When to Use Each Tool

| Situation | Gateway tool |
|----------|---------------|
| Domain question, pattern, Architecture | `knowledge_search(query, source_type="pack")` |
| Specific document by code (DP.ROLE.001) | `knowledge_get_document("filename")` |
| Learning, methodology, guides | `knowledge_search(query, source_type="guides")` |
| Learner goals, self-assessment | `dt_read_digital_twin("path")` |
| Before writing to Pack — duplicate check | `knowledge_search` + `knowledge_get_document` |

### 6.6. Ontology: Knowledge Graph

Ontology is a graph of concepts and relationships. Each level has its own:

| Level | Where | What |
|---------|-----|-----|
| SPF-level | `SPF/ontology.md` | Universal framework concepts |
| Pack-level | `PACK-{}/01-domain-contract/01C-ontology.md` | Entities of a specific Pack |
| Ecosystem | `DS-ecosystem-development/ontology.md` (local repo) | 31 concepts: Platform + ecosystem |
| Personal | `DS-strategy/ontology.md` | Personal development + cross-references |

**Principle:** SPF inherits from FPF → Pack extends SPF → Downstream references Pack.

**Where to learn more:**
- [SPF/ontology.md](https://github.com/TserenTserenov/SPF/blob/main/ontology.md) — SPF-level
- [SPF/docs/conceptual-model.md](https://github.com/TserenTserenov/SPF/blob/main/docs/conceptual-model.md) — conceptual map

## 7. Roles and AI Agents

### 7.1. Role-Centric Approach (DP.D.033)

In IWE, a Role is described **independently of the performer**. First: what to do, what obligations, what Work Products. Then: who performs it.

| Concept | Definition |
|---------|-----------|
| **Role** | Function: WHAT to do (obligations, Work Products, Methods) |
| **Performer (holder)** | System: WHO does it (Claude, bash, human) |
| **Agent** | Performer with autonomy (Grade 2+) |
| **Tool** | Performer without autonomy (Grade 0–1) |

**Key principles:**
- **Role ≠ System.** One name can refer to both a Role and a system — these are different perspectives
- **One performer — many Roles.** Claude plays the Strategist, Extractor, and Coder Roles
- **One Role — many performers.** Synchronizer Role: bash (mechanics) + Claude (Audit)

**Notation:** `Holder#Role:Context@Window` (FPF A.2)

### 7.2. Agent Catalog

#### At Your Level (L4 Personal IWE)

These agents run in your Claude Code, on your machine:

| Agent | Role | What it does | When you see the result |
|-------|------|-----------|----------------------|
| **Strategist (R1)** | Planning | Day Open/Close, WeekPlan, DayPlan, strategy Sessions | Morning (launchd → Telegram), Session (Claude Code) |
| **Extractor (R2)** | Knowledge formalization | Captures → Pack entities (dual routing: Pack + DS) | Session Close in Claude Code |

#### On the Platform (L2 Platform)

These agents run on Platform Infrastructure. You only see their results:

| Agent | Role | What it does | How you see the result |
|-------|------|-----------|------------------------|
| **Synchronizer (R8)** | Coordination | Fleeting-notes sync, notifications | Telegram notifications |
| **Template Manager (R9)** | Template updating | Drift detection, Validation | During `update.sh` |
| **Analyst (R10)** | Analytics | DAU/WAU/MAU, retention | `/analytics` in bot |
| **Fixer (R11)** | Error correction | Auto-fix, restart, escalate | GitHub Issues, Telegram notifications |

> **For T4 users:** R1 (Strategist) and R2 (Extractor) are primary. Platform agents (R8–R11) run in the background.

### 7.3. Agent Interaction Diagram

```
Schedule / User action
    ↓
R8 Synchronizer (dispatcher)
    ├─→ R1 Strategist (plans, reviews)
    │   └─→ DS-strategy/current/Plan, Day, Report
    ├─→ R2 Extractor (knowledge)
    │   └─→ Pack entities, DS-strategy/inbox/
    ├─→ R9 Template Manager (updates)
    │   └─→ FMT-exocortex-template/
    ├─→ R11 Fixer (bot errors)
    │   └─→ GitHub PR, Issues
    ├─→ R10 Analyst (analytics)
    │   └─→ Telegram report, /analytics
    └─→ Telegram notifications
```

**Where to learn more:**
- Role catalog (21 Roles R1–R21): [DP.ROLE.001](https://github.com/TserenTserenov/PACK-digital-platform/blob/main/pack/digital-platform/02-domain-entities/DP.ROLE.001-platform-roles.md)
- Architectural rationale: [DP.D.033](https://github.com/TserenTserenov/PACK-digital-platform/blob/main/pack/digital-platform/01-domain-contract/DP.D.033-role-centric-architecture.md)

### 7.4. Role Contract (for Developers)

Every Role in `roles/` follows a formal contract — a specification of what the Role directory must contain. The contract enables auto-discovery: `setup.sh` and `update.sh` automatically find and process Roles without hardcoded lists.

**Minimum required files:**
- `role.yaml` — machine-readable Manifest (name, type, installation mode)
- `README.md` — human-readable description
- `install.sh` — installation entry point

**Details and role.yaml schema:** [roles/ROLE-CONTRACT.md](../roles/ROLE-CONTRACT.md)

## 8. Quality and Architectural Decisions

### 8.1. ArchGate (EMOGSSS)

**Blocking rule:** Every architectural decision is evaluated by 7 characteristics. Threshold ≥8.

| Characteristic | Question |
|----------------|--------|
| **E**volvability | What breaks when something changes? |
| **M**anageability | What happens at 10x? |
| **O**nboardability | How much reading is needed to start? Exoskeleton or prosthetic? |
| **G**enerativity | Does it create a Platform for new things? |
| **S**peed | What is the latency? (bot <3 sec, CLI <1 sec) |
| **S**tate-of-the-art | How do the best do it? Check SOTA. |
| **S**ecurity | What are the threats? PII, secrets, injection surface? |

**Format:** Decision → principles (step 1) → assessment table (step 2) → what is weak → how to strengthen (step 3).

**Coordination cost check** (for multi-agent solutions): Are coordination costs < gain from parallelism? Three conditions: (1) context isolation, (2) parallelism gain, (3) tool specialization. If all three are NOT met → single-agent.

### 8.2. SOTA Practices

Priority trio (check ALWAYS for architectural decisions):

| # | Practice | Essence |
|---|----------|------|
| 1 | Context Engineering | Write/Select/Compress/Isolate — what enters the agent's context |
| 2 | DDD Strategic | BC = Pack scope, UL = Ontology, Context Map = typed `related:` |
| 3 | Coupling Model | Connections across 3 dimensions: knowledge, distance, volatility |

Full list: Platform + Pack architectural practices.

**Where to learn more:**
- [memory/sota-reference.md](../memory/sota-reference.md) — all 18 with descriptions
- [CLAUDE.md](../CLAUDE.md) § 5 — currency checklist

### 8.3. Quality Checklists

| Checklist | When |
|---------|-------|
| Before responding | At least 1 file loaded, repo type known |
| Before modifying | CLAUDE.md read, source of truth not broken |
| When recording a process | Pack + PROCESSES.md + CLAUDE.md (all three) |
| Before proposing a fix | ArchGate applied, root cause fixed |

**Where to learn more:**
- [memory/checklists.md](../memory/checklists.md) — all checklists

### 8.4. IntegrationGate

**Before adding a new tool, agent, or system — STOP.** Answer 5 questions:

1. **Type:** tool (Grade 0–1) or agent (Grade 2+)?
2. **Perimeter:** L2 Platform / L3 Template / L4 Personal?
3. **Roles:** which Roles does it perform?
4. **Products:** what does it create, and for whom?
5. **Processes:** which Method descriptions are affected?

No answers → do NOT start. Define the level → describe → then implement.

### 8.5. Security in IWE

IWE works with personal data: strategy, plans, goals, Digital Twin. Security is an architectural characteristic (EMOGSSS), not an add-on.

#### Security Model: 3 Zones

```
┌────────────────────────────────────────────────────┐
│  Zone 1: LOCAL (your computer)                     │
│  CLAUDE.md, memory/, DS-strategy/ (local copy)     │
│  → Protection: OS-level (FileVault, password)      │
└───────────────────────┬────────────────────────────┘
                        │ git push (you control this)
┌───────────────────────▼────────────────────────────┐
│  Zone 2: PRIVATE REPOS (your GitHub)               │
│  DS-strategy/, PACK-*/, DS-*/ (private repos)      │
│  → Protection: GitHub access control + SSH/OAuth   │
└───────────────────────┬────────────────────────────┘
                        │ API calls (authorized)
┌───────────────────────▼────────────────────────────┐
│  Zone 3: PLATFORM (IWE services)                   │
│  Bot, Claude API, Digital Twin                     │
│  → Protection: per-user OAuth, tokens, isolation   │
└────────────────────────────────────────────────────┘
```

#### IWE Security Principles

| Principle | What it means | How it is implemented |
|---------|-----------|-----------------|
| **Secrets outside git** | API keys and tokens do not enter repositories | `~/.config/`, `~/.wakatime/`, env vars |
| **Per-user blast radius** | Compromising one user does not affect others | Per-user OAuth 2.0, isolated data |
| **Personal data isolated** | Your plans and strategy belong only to you | Private repos, local memory/ |
| **Platform-space ≠ User-space** | Methodology (shared) is separated from data (personal) | Standard vs Personal zones |
| **CLI permission whitelist** | Claude Code executes only permitted commands | `.claude/settings.local.json` with explicit allowlist |

#### What Claude Sees (and Does Not See)

| Claude sees | Claude does NOT see |
|-------------|-----------------|
| CLAUDE.md, memory/*.md (your instructions) | Passwords, SSH keys, API tokens |
| Files in open Sessions (while you work) | Other users' files |
| Current conversation context | History of past conversations (reset in new Session) |
| Contents of repos you have granted access to | Repos outside the working directory |

> **Anthropic API:** Anthropic [does not use API data](https://www.anthropic.com/policies/privacy-policy) to train models. Data is processed but not stored for training.

#### What the User Should Do

1. **DS-strategy/ — private.** Confirm when creating: `gh repo create DS-strategy --private`
2. **Do not commit `.env` files.** If working with API keys — add to `.gitignore`
3. **Use SSH for git.** `gh auth login` → SSH → more secure than passwords
4. **FileVault (macOS) / LUKS (Linux).** Disk Encryption protects the local zone
5. **Token rotation.** If compromised — `gh auth refresh`, update keys in `~/.config/`

#### AI System Security (AI-Specific Threats)

IWE uses LLM (Claude) — this creates a specific class of threats:

| Threat | Description | How IWE protects |
|--------|----------|------------------|
| **Prompt injection** | Malicious instruction embedded in data | CLAUDE.md — explicit allowlist, ArchGate checks injection surface |
| **Context leakage** | Data from one Session leaks into another | Each Claude Code Session is a new context. Memory — only what you recorded |
| **Excessive trust in AI** | AI proposes, but can be wrong | Protocols require confirmation: WP Gate, ArchGate, Capture |

**Where to learn more:**
- [CLAUDE.md](../CLAUDE.md) § 5 — EMOGSSS (including the Security characteristic)
- [DP.ARCH.001 § 4.7](https://github.com/TserenTserenov/PACK-digital-platform/blob/main/pack/digital-platform/02-domain-entities/DP.ARCH.001-platform-architecture.md) — Security architectural characteristic

## 9. Platform: Bot and Tiers

### 9.1. 4-Axis Tier Model

**T axis (learner):**

| Tier | Name | Entry | AI Role | Workspace |
|-----|---------|------|---------|---------------------|
| T0 | No Ory | /start in bot (telegram_id) + 30-day trial | Reference | Bot only (trial: all features) |
| T1 | Start | Ory registration (UUID) + 30-day trial | Assistant | Bot only (trial: all features) |
| T2 | Learning | BR subscription (system-school.ru) | Expert | Bot + content |
| T3 | Personalization | Digital Twin | Mentor | + Digital Twin |
| T4 | Creation (IWE) | setup.sh | Co-thinker | + Git + Claude Code + Strategist |

> **T0/T1 — current nomenclature.** Old names (T1_NEW, T1_START) are deprecated and not used. T5–T9 are reserved.

**Orthogonal axes (assigned):**

| Axis | Tiers | What it provides | Requires |
|-----|------|----------|---------|
| TM (mentor) | TM1–TM3 | Homework review panel, groups | T2+ |
| TA (administrator) | TA1–TA4 | Stream management, finances, access | T1+ |
| TD (developer) | TD1 | Source code, Deployment, Template management | T2+ |

Each T tier is a Configuration of 5 dimensions: knowledge, data, AI Role, actions, workspace. TM/TA/TD axes are orthogonal: one person = T + TM? + TA? + TD?. Platform owner = T4 + TA4 + TD1.

### 9.2. Tier-to-Perimeter Mapping

| Tier | Perimeters | What is available |
|-----|---------|------------|
| T0–T3 | L2 (Platform) | Platform services through the bot |
| T4 | L3 → L4 | Template instantiated as Personal IWE |
| TD1 | L2 + L3 | Platform and Template development |

### 9.3. Bot (@aist_me_bot)

The Telegram bot is the primary entry point for T1–T3. For T4+, the bot remains useful for quick actions.

**Bot capabilities:**

| Feature | Command / action | Tier |
|-------------|-------------------|-----|
| Knowledge base search | Any question | T1+ |
| Marathons and programs | `/programs` | T2+ |
| Notes (fleeting notes) | `.text` or `.` + reply | T2+ |
| Digital Twin | `/twin` | T3+ |
| Personalized responses | Auto (from Twin) | T3+ |
| Class schedule | `/schedule` | T2+ |

**Connection to exocortex:** The bot syncs fleeting notes → `DS-strategy/inbox/fleeting-notes.md`. The Strategist sees them during Note-Review.

**Where to learn more:**
- [DP.ARCH.002](https://github.com/TserenTserenov/PACK-digital-platform/blob/main/pack/digital-platform/02-domain-entities/DP.ARCH.002-service-tiers.md) — service tiers

### 9.4. IWE Processes and Scenarios

#### Distinction: Process / Service / Scenario

| Term | What | Analogy |
|--------|-----|---------|
| **Process** | Logic inside one system | Room |
| **Service** | Entry point to a process | Door |
| **Scenario** | Cross-system path (owner changes) | Path through buildings |

#### Key Scenarios

**User-facing:**
- 1.1: Work Session (Open → Work → Close)
- 1.2: Weekly strategy Session (Week-Review → Session-Prep → Strategy-Session)
- 1.3: Daily cycle (DayPlan → focus → DayClose)

**Platform:**
- 2.1: Day-Close (collect commits, update plans, backup)
- 2.2: Exocortex backup (memory/ → DS-strategy/)
- 2.3: Ontology sync (Pack → master)
- 2.4: File sync (GitHub → local)
- 2.5: Template sync (author → FMT-exocortex-template)
- 2.6: Pack projection (Pack → Downstream)

**Where to learn more:**
- [CLAUDE.md](../CLAUDE.md) § 3 — Distinction and placement
- `DS-ecosystem-development/PROCESSES.md` — all Scenarios (ecosystem governance repo, created locally during Deployment, not published to GitHub)

## 10. Growth and Development

### 10.1. Creating Your Own Pack

**When to create:**
- You regularly work in one domain
- It is important not to lose knowledge between Sessions
- You want Claude to know the terms and patterns of your domain

**How to create:** type `/pack-new` in Claude Code (or "I want to create a pack", "new pack").

The Skill guides you through 5 steps:
1. Checks/clones FPF and SPF (if absent)
2. Defines the Domain via 3 questions (SPF §01)
3. Proposes 2–3 name options → you choose
4. Creates the `PACK-{slug}/` structure scaffold + starter files
5. Shows the F1–F6 content Roadmap

**Roadmap after creation:**

| Phase | What to do | Time |
|------|-----------|-------|
| F1. Distinctions | 7–10 domain Distinctions (SPF §03) | 1–2h |
| F2. Entities | Roles, WP, Methods — enumeration (SPF §04) | 1–2h |
| F3. Methods | Describe key Methods (SPF §07) | 2–4h |
| F4. Work Products | Artifacts + Definition of Done (SPF §07) | 1–2h |
| F5. Failure modes | 5–10 typical errors (SPF §08) | 1h |
| F6. SoTA | Sources, knowledge version (SPF §09) | 1–2h |

Tool for content: `/ke` — captures knowledge into Pack during work.

### 10.2. New Agents and Tools

Before adding anything — IntegrationGate (§ 8.4). After defining the components:

| Component | Type | Description location | Implementation location |
|-----------|-----|-------------|---------------|
| Extractor | Agent (Grade 2) | DP.ROLE.001 R2 | DS-ai-systems/extractor/ |
| Synchronizer | Agent + Tool | DP.ROLE.001 R8 | DS-ai-systems/synchronizer/ |

**Principle:** Minimum complexity at the start. The Strategist alone is sufficient for the first months. The Extractor — when Pack reaches 10+ entities. The Synchronizer — when you have 3+ repositories.

### 10.3. MAPSTRATEGIC.md: Strategy of Each System

When you create a new repo, add `MAPSTRATEGIC.md`:

```markdown
# MAPSTRATEGIC: {System Name}

## Current Phase
{Description: what tasks are being solved now}

## Next Phase
{Where the system is headed}

## Horizon
{Long-term vision}
```

The Strategist reads all MAPSTRATEGIC files during Session-Prep and aggregates them into `Strategy.md`.

### 10.4. How to Develop IWE Independently

**Principle:** Start with the minimum, add complexity as you grow.

```
Day 1:        setup.sh → FMT (fork) + DS-strategy          ← start
Week 1:       Daily work with Claude Code + Strategist      ← building habit
Weeks 2–4:    First PACK-{domain}                          ← formalizing knowledge
Months 2–3:   DS-{projects} (code, content)                ← creating
As you grow:  Extractor, Synchronizer, your own Format     ← scaling
```

**Recommendations:**
- **Do not clone** all repositories at once — start with FMT + DS-strategy
- **Do not create Pack** until you have defined the domain and accumulated captures
- **Do not add agents** until you can manage without them (IntegrationGate, § 8.4)
- **Clone SPF** only when you are ready to create Pack (read-only reference)

## 11. Quick Reference

> **Architecture FAQ:** Practical questions ("how to do") are here. Domain questions ("what is", "why") are in [DP.IWE.002 §11](../../PACK-digital-platform/pack/digital-platform/02-domain-entities/DP.IWE.002-iwe-template-and-setup.md) (source of truth for the bot).

### Protocols and Workflow

| Question | Answer | Where |
|--------|-------|-----|
| Where to record knowledge? | Pack (domain), CLAUDE.md (rule), memory/ (lesson) | [CLAUDE.md](../CLAUDE.md) § 2 |
| Can WP Gate be skipped? | Only if ≤15 min, exploration, or emergency bug fix | [CLAUDE.md](../CLAUDE.md) § 2 |
| How to propose a solution? | ArchGate first (7 characteristics, threshold ≥8) | [CLAUDE.md](../CLAUDE.md) § 5 |
| How to end a Session? | Close Protocol (15 steps) | § 5.1c |
| Why does a pending Work Product not enter the plan? | Check activation condition in WP-REGISTRY (date/dep/on-demand) | § 5.5 |
| What to do with old pending Work Products? | Dormant Review at strategy session: archive or assign condition | § 5.5 |
| How to change the strategy day? | `strategy_day: saturday` in `memory/day-rhythm-config.yaml` | § 5.5 |
| Why is there no DayPlan on Monday? | On strategy_day, the day plan is embedded in WeekPlan | § 5.1, 5.5 |

### Repositories and Structure

| Question | Answer | Where |
|--------|-------|-----|
| What type is this repo? | See `REPO-TYPE.md` in the repo | `<repo>/REPO-TYPE.md` |
| Is this a system or an episteme? | Distinction #1 | [hard-distinctions.md](../memory/hard-distinctions.md) |
| How to create a DS project? | `gh repo create DS-my-project --private` + CLAUDE.md | § 4.4 |
| What is S2R? | Format for project repos (3×3 matrix) | § 4.3 |
| How to configure CLAUDE.md for a new repo? | Type + related Pack + specific rules | § 5.4 |

### Knowledge and Pack

| Question | Answer | Where |
|--------|-------|-----|
| Which SOTA is applicable? | Priority trio | [sota-reference.md](../memory/sota-reference.md) |
| Where is domain knowledge? | Pack repositories or Knowledge MCP | § 6.5 |
| How to create Pack? | 11 SPF stages | § 6.2 |
| What does a Pack entity ID mean? | `CONTEXT.TYPE.NNN` | § 4.5 |

### Navigation and Tools

| Question | Answer | Where |
|--------|-------|-----|
| Which perimeter am I in? | L4 (Personal IWE) if T4+. L2 (Platform) if T1–T3 | § 2.1 |
| Where to add a tool? | IntegrationGate: define the perimeter | § 8.4 |
| How to update the Template? | `bash update.sh` | § 2.5 |
| Where is my strategy? | `DS-strategy/docs/Strategy.md` | § 5.5 |
| How to configure WakaTime? | `/setup-wakatime` in Claude Code | § 2.6 |
| Where is my Digital Twin? | Bot → `/twin` | § 2.6 |
| How to join the club? | [systemsworld.club](https://systemsworld.club) | § 2.6 |
| What are FPF, SPF, ZP? | Three levels of principles: ZP → FPF → SPF → Pack. Each generates the next | § 3.1 |
| What can the bot do? | Marathon, Feed, Consultation, Notes, /twin, /profile | [DP.IWE.002 §11](../../PACK-digital-platform/pack/digital-platform/02-domain-entities/DP.IWE.002-iwe-template-and-setup.md) |
| What is my tier? | `/twin` or `/profile` in the bot. T0–T4, determined automatically | [DP.IWE.002 §11](../../PACK-digital-platform/pack/digital-platform/02-domain-entities/DP.IWE.002-iwe-template-and-setup.md) |
| How to use notes? | `.text` in bot → accumulate → Note-Review → routing | [DP.IWE.002 §11](../../PACK-digital-platform/pack/digital-platform/02-domain-entities/DP.IWE.002-iwe-template-and-setup.md) |
| How to set up IWE on Windows? | WSL + VS Code. Files in ~/IWE/ (WSL), not /mnt/c/ | § 11 "Windows + WSL" |

### Common Problems and Solutions

#### "Claude loses context between Sessions"

**What happens.** You describe a task in detail in chat — Claude understands and works. New Session — as if nothing happened.

**Why.** Claude Code does not "remember" chat. Between Sessions, only what is written to files is preserved: MEMORY.md, CLAUDE.md, memory/*.md, WP files in inbox/. If information stayed only in the chat — it is gone.

**What to do.**
1. **WP file = persistent task memory.** When creating a Work Product via WP Gate, Claude writes the context to `DS-strategy/inbox/WP-{N}-slug.md`. In the next Session it reads this file and restores the context.
2. **If the WP file was not created** — the task was likely assessed as ≤2h and ≤1 Session. Say: *"Create a context file for this task."* Or add a rule to `<repo>/CLAUDE.md`: *"Always create a WP file when adding a Work Product."*
3. **Bulk task intake** (from Obsidian, notes, Backlog): create one Work Product "Triage tasks from [source]". The result = a set of WP files in inbox/ with full context for each task. Then sort them by dissatisfactions at a strategy Session.

**Key point:** Claude does not lose context — it does not record it if not told where. The Close Protocol (§ 5.1) + WP files solve this problem.

#### "Pack is not used during work"

**What happens.** You put knowledge into a Pack Repository. But when working, Claude does not see or use it.

**Why.** Claude automatically sees only 3 things: MEMORY.md, CLAUDE.md, memory/*.md. Pack repositories are files on disk that Claude does not read without an explicit command.

**Three ways to connect Pack** (from simple to powerful):

| Method | When | What to do |
|--------|-------|-------------|
| **1. Direct link** | Pack <50 files | Add path to Pack in `memory/navigation.md`. When assigning a task, say: *"Context: see Pack-X/entity-Y.md"* |
| **2. Index in CLAUDE.md** | Pack 50–100 files | Add list of key Pack entities to `<repo>/CLAUDE.md` or `memory/navigation.md` |
| **3. Gateway MCP** | Pack >100 files | Configure knowledge search via Gateway for your Pack (DP.IWE.002 § 7.1). Claude can search the full knowledge base |

**Practical minimum:** Add a section with links to your Pack repositories in `memory/navigation.md`:
```
## My Pack Repositories
| Pack | Path | Topic |
|------|------|-------|
| PACK-my-domain | ~/IWE/PACK-my-domain/ | Key entities of my domain |
```

#### "I do not understand what gets recorded where"

**One-line rule:** if Claude must see it in **every** Session — MEMORY.md or CLAUDE.md. Everything else is files Claude reads on request.

| What | Where | Why there |
|-----|------|--------------------|
| List of weekly tasks (Work Products) | `MEMORY.md` | Claude sees it every Session, checks via WP Gate |
| Rules for all projects | `~/IWE/CLAUDE.md` | Claude sees it every Session |
| Rules for one project | `<repo>/CLAUDE.md` | Claude sees it when working in this repo |
| Reference (terms, checklists) | `memory/*.md` | Claude reads on trigger (§ 5.2) |
| Details of each task | `DS-strategy/inbox/WP-*.md` | Claude reads when opening a task (Ritual, step 3) |
| Domain knowledge | Pack repositories | Claude reads on explicit request or via MCP |
| Strategy, dissatisfactions | `DS-strategy/docs/` | Strategist (R1) uses for planning |

**Where memory/ is physically located:** `~/.claude/projects/{workspace-hash}/memory/`. This is a hidden Claude Code folder. Backup → `DS-strategy/exocortex/`.

#### "Work Products are not being created automatically"

WP Gate **must** trigger on every task. If it does not, check:

1. **Is CLAUDE.md in place?** The file `~/IWE/CLAUDE.md` must exist and contain a "Session Stages — OWC" section.
2. **Is MEMORY.md in place?** `~/.claude/projects/{workspace-hash}/memory/MEMORY.md` must contain a "Work Products for current week" table.
3. **Is protocol-open.md in place?** `memory/protocol-open.md` alongside MEMORY.md.
4. **Is the task >15 min?** Tasks ≤15 min are exceptions to WP Gate.
5. **Which model?** Opus follows protocols more reliably. Sonnet may skip steps. Opus is recommended for early Sessions. Haiku — only for trivial tasks (renaming, Formatting, search) and cron agents.

If everything is in place but WP Gate still does not trigger — check that CLAUDE.md contains the line: *"WP Gate: For ANY task → Opening protocol."*

#### "What can be changed in CLAUDE.md, and what cannot?"

| Zone | Can modify? | Examples |
|------|--------------|---------|
| **My Rules** | Yes, freely | "Always write commits in English", "Use pytest" |
| **MEMORY.md** | Yes, this is your data | Tasks, statuses, notes |
| **memory/*.md** | With care | Adding lessons is fine. Modifying protocols — understand the consequences first |
| **Root CLAUDE.md** (standard) | With a caveat | update.sh will overwrite the standard part. Your additions — at the end of sections |

**Safe pattern:** Add your rules to `<repo>/CLAUDE.md` (not affected by update.sh).

#### "Why this folder structure?"

```
DS-strategy/
├── docs/        ← Long-lived (strategy, dissatisfactions) — changes rarely
├── current/     ← Current (week/day plan) — changes daily
├── inbox/       ← Incoming (task contexts, notes) — processed and cleared
├── drafts/      ← Drafts (posts, ideas) — TTL ≤7 days
├── archive/     ← Closed (completed plans) — for retrospectives
└── exocortex/   ← Backup of memory/ — safety net
```

The **Inbox → Processing → Archive** pattern: incoming is processed → result goes to docs/ or Pack → source is archived. Nothing accumulates uncontrolled.

You can modify this, but preserve the "active / incoming / closed" separation — without it, the inbox will grow indefinitely.

#### "What can the Strategist do?"

Main Scenarios:

| # | Scenario | Launch | What it does | Result |
|---|----------|--------|-----------|-----------|
| 1 | **Day Open** | Morning (trigger) | 7 steps: yesterday → plan → self-development → pomodoros → IWE → world → record | DayPlan |
| 2 | **Day Close** | Evening (trigger) | Results → what I learned → praise → setup for tomorrow | Updated DayPlan |
| 3 | session-prep | Monday morning (auto) | Analysis of last week + MAPSTRATEGIC from all repos | WeekPlan draft |
| 3b | strategy-session | Manual | Interactive review of dissatisfactions → priorities | Approved WeekPlan |
| 4 | week-review | Sunday evening (auto) | WakaTime metrics + what was done + lessons | "Results W{N}" section in WeekPlan |
| 5 | add-wp | Manual | Add new task to plan (4 places) | Updated WeekPlan + WP file |
| 6 | note-review | As needed | Classify notes → Pack/inbox/archive | Routed notes |

**The Strategist cannot:** write code, access Pack without MCP, deploy. It plans, reflects, and routes.

#### "How to work with IWE on two devices (laptop + desktop)?"

**What happens.** You have two computers (possibly on different operating systems). You need an identical Environment and the ability to switch between them.

**Architecture.** IWE consists of layers with different sync mechanisms:

| # | Layer | Mechanism | Cross-OS |
|---|------|----------|-----------|
| 1 | Repos (code, Pack, DS) | git push/pull | Yes |
| 2 | Exocortex (CLAUDE.md, memory/) | git backup in DS-strategy → restore on second device | Yes |
| 3 | Claude Code config (.claude/) | Part in git (exocortex backup), part local | Yes (JSON) |
| 4 | VS Code | Settings Sync (built-in, via GitHub) | Yes |
| 5 | MCP servers | Config Template + envsubst (paths differ between OS) | Template + platform-specific |
| 6 | Secrets (.env, API keys) | Password manager (1Password CLI / Bitwarden CLI) | Yes |
| 7 | Cron/LaunchAgents | macOS: plist. Linux: systemd/cron. Setup Script in repo | Different formats |
| 8 | Packages (brew, apt) | Brewfile (macOS) + Linux equivalent | Setup Script |

**Critical rule: Push before switch.** Before switching to another device — push all dirty repos. Check:

```bash
for repo in ~/IWE/*/; do
  [ -d "$repo/.git" ] && git -C "$repo" status --porcelain | grep -q . && echo "DIRTY: $repo"
done
```

**Cross-OS notes:**
- **Paths:** Use `~/IWE/` (tilde is cross-platform), or the variable `$IWE_HOME`
- **Symlinks:** `memory/` → `.claude/...` — each device's own `setup.sh` creates symlinks
- **LaunchAgents vs systemd:** Templates for both are stored in the repo, `setup.sh` installs the appropriate one
- **MCP paths:** `claude_desktop_config.json` contains absolute paths — use Template + envsubst or platform-specific configs
- **Line endings:** `.gitattributes` with `* text=auto`

**Bootstrapping a new device:**

```bash
git clone <all-repos> ~/IWE/
cd ~/IWE && ./setup.sh   # creates symlinks, installs packages, configures cron
```

`setup.sh` detects the OS (`uname`) and executes the appropriate actions. It lives in DS-ecosystem-development (local governance repo) or a dotfiles repo.

**Where:** § 2.2 (from Template to workspace), § 5.2 (memory)

#### "Windows + WSL: Step-by-Step Setup"

**What happens.** You have Windows. Claude Code is installed, but it is unclear which terminal to use — Git Bash (MINGW64) or WSL.

**Answer: use the WSL terminal inside VS Code.** Git Bash is not suitable — it does not support the full Linux stack required by Claude Code and MCP servers.

**Step by step:**
1. Install WSL: `wsl --install` in PowerShell (as administrator)
2. Inside WSL: `mkdir -p ~/IWE && cd ~/IWE` — all repositories must be in the WSL file system, **not** in `/mnt/c/`
3. VS Code: install the "WSL" extension (ms-vscode-remote.remote-wsl)
4. Open VS Code: `code .` from the WSL terminal → VS Code connects to WSL
5. Terminal in VS Code (Ctrl+\`) → confirm it is WSL (bash/zsh), not PowerShell/MINGW64
6. Claude Code: `npm install -g @anthropic-ai/claude-code` inside WSL
7. `cd ~/IWE && claude` — done

**Why not Git Bash?** MINGW64 emulates Linux commands on top of Windows, but MCP servers, Node.js scripts, and cron tasks are designed for a full Linux Environment. In Git Bash they either do not work or behave unpredictably.

**Why files in WSL, not on the Windows drive?** The WSL file system (`~/`) is 5–10 times faster than accessing `/mnt/c/` (Windows drive via WSL). Watch scripts, git operations, and MCP indexing on `/mnt/c/` are critically slow.

#### "I do not understand what to record in notes"

**What happens.** You see the notes feature in the bot (`.text`), but do not know what to put there — daily tasks? ideas? everything?

**Rule:** notes = incoming stream for intellectual work (inbox). Record:
- **Thoughts and ideas** — things that came to mind during the day and you do not want to lose
- **Observations from reading** — noticed something useful in a book/article → `.text`
- **Questions to explore** — did not understand something in a course → `.why does the meta-meta-model matter?`
- **Captures** — knowledge that needs to be formalized into Pack

**Do not record:**
- Daily chores ("buy oil") — use to-do apps (Todoist, Apple Reminders) for those
- Exact quotes without your own interpretation — a quote without a thought is dead text

**Note lifecycle:** `.text` → bot saves → accumulates → Note-Review (Strategist or manual) → routing: to Pack (knowledge), to Work Product (task), or to archive (no longer relevant).

#### "The bot gives unrelated answers"

**What happens.** You ask the bot a question, but the response is off-topic, too shallow, or gets cut off.

**Three causes and solutions:**

| Cause | How to recognize | What to do |
|---------|---------------|-----------|
| **Question outside the knowledge base** | Bot responds with generic phrases, no reference to specific documents | The bot knows what is in the knowledge base (Gateway iwe-knowledge). Ask more precisely: "What does course X say about Y?" instead of the abstract "tell me about Y" |
| **Long response is cut off** | Text ends mid-sentence | Telegram limits message length. Say: "continue" or "give me a short version" |
| **Context lost** | Bot does not remember what you asked a minute ago | Each question in Consultation mode is a separate request. Formulate your question completely, without references to "as I said before" |

**If the response is completely wrong** — react with 👎. This triggers automatic classification (feedback_triage), and the issue will appear in the developer's report.

### Recommended Learning Sequence

#### Day 1: Orientation (1.5 hours)
1. System perimeters (§ 2.1) — 10 min
2. From Template to workspace (§ 2.2) — 15 min
3. 3 repository types (§ 4.1) — 15 min
4. Principles hierarchy (§ 3.1) — 15 min
5. 5 key Distinctions from § 3.2: #1 (system ≠ episteme), #2 (method ≠ tool), #5 (role ≠ agent ≠ tool), #11 (process ≠ service ≠ scenario), #22 (platform ≠ template ≠ personal) — 15 min

#### Day 2: Work Protocols (2 hours)
1. OWC fractal: Day + Session (§ 5.1) — 20 min
2. Session Open: WP Gate + Ritual (§ 5.1b) — 15 min
3. Three-layer memory (§ 5.2) — 10 min
4. Capture-to-Pack (§ 5.3) — 10 min
5. Distinctions — key 10 of 30+ (§ 3.2) — 20 min
6. Strategist, planning, and Activation Gate (§ 5.5) — 15 min

#### Day 3: Tools and Agents (1.5 hours)
1. CLAUDE.md: how to configure (§ 5.4) — 15 min
2. Agents (§ 7.2) — 15 min
3. ArchGate (§ 8.1) — 15 min
4. Checklists (§ 8.3) — 10 min

#### Day 4: Pack and SOTA (1 hour)
1. What Pack is (§ 6.1) — 10 min
2. Knowledge MCP (§ 6.5) — 10 min
3. SOTA practices (§ 8.2) — 15 min
4. Quick Reference (§ 11) — 5 min

#### Then: As Needed
- Creating Pack → § 6.2 + § 10.1
- DS projects → § 4.4
- Ontology → § 6.6
- Platform and bot → § 9
- Growth → § 10

*Last updated: 2026-03-15 (v2: OWC fractal, Verification classes, all sections updated)*
