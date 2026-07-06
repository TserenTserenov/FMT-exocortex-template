<body>
# IWE Learning Path

> **IWE (Intellectual Work Environment)** is a personal intellectual work environment — the equivalent of an IDE for developing thinking. Just as an IDE gives a programmer an editor, compiler, linter, and debugger, IWE gives a person formalized knowledge (Pack), automated extraction (Extractor), correctness verification (FPF/SPF), and gap diagnostics (Digital Twin). The person works together with AI agents, each of which plays its own Role.
>
> Each section: **why** → **what to study** → **where to find it**.
> Not on macOS or not using Claude Code? → **[PORTABILITY.md](PORTABILITY.md)**

## How to use this file

1. **Beginner:** Sections 1–2 (what IWE is, Architecture). Approximately 1 hour. You will understand how everything works.
2. **First week:** Sections 3–5 (foundation, Repositories, daily work). As needed.
3. **Active user:** Sections 6–8 (Knowledge, agents, quality). When you start creating Pack.
4. **Advanced:** Sections 9–10 (Platform, growth). When you want to scale.
5. **Reference:** Section 11 — quick answers.

> **Terminology:** IWE = Intellectual Work Environment, described through 5 architectural viewpoints: systems, descriptions, Roles, Methods, and Work Products (§ 1.2). FPF triad A.7: Role → Method → Work Product. Exocortex = the description storage system inside IWE (CLAUDE.md + memory/). Details: [DP.IWE.001](https://github.com/TserenTserenov/PACK-digital-platform/blob/main/pack/digital-platform/02-domain-entities/DP.IWE.001-intelligent-working-environment.md).

> **Installation:** [SETUP-GUIDE.md](SETUP-GUIDE.md) | **Data policy:** [DATA-POLICY.md](DATA-POLICY.md) | **Quick reference:** [IWE-HELP.md](IWE-HELP.md) | **Principles vs skills:** [principles-vs-skills.md](principles-vs-skills.md)
>
> Links with `./` point to files in this repository. Links with `github.com/...` point to other Repositories.

## 1. What is IWE

### 1.1. Definition

IWE is a personal system for intellectual work and development. Just as an IDE unifies an editor, compiler, and debugger into a single environment for a programmer, IWE unifies knowledge, planning, and AI agents into a single environment for thinking.

### 1.1a. Core principle: exoskeleton, not prosthesis

> DP.ARCH.001 principle #21. Details: [DP.IWE.001 §5.1](https://github.com/TserenTserenov/PACK-digital-platform/blob/main/pack/digital-platform/02-domain-entities/DP.IWE.001-intelligent-working-environment.md).

IWE augments the user's thinking — it does not replace it. The Distinction:

- **Prosthesis:** AI thinks for you → the task is done, but you did not learn → atrophy
- **Exoskeleton:** you think for yourself, AI augments → the task is done + you became more competent → growth

Three exoskeleton mechanisms in IWE:

1. **Presentation, not generation.** The AI surfaces your own knowledge (Pack, memory/, Digital Twin) at the right moment. You do the thinking.
2. **Questions, not answers** (for strategic decisions). WP Gate requires planning before action. Consultation T2–T3 asks "what do you think?" in response to lazy requests.
3. **Fading scaffolding.** Training: more support at early levels, less at advanced levels. Tiers T0→T4: from direct answers to co-thinking.

**Criterion:** after interacting with IWE, the user has become more competent — not merely received a result.

### 1.2. IWE anatomy: five architectural viewpoints

IWE as a system is examined from five viewpoints (ISO/IEC/IEEE 42010): systems, descriptions, Roles, Methods, and Work Products. The central organizing principle is the FPF A.7 triad: **Role → Method → Work Product**.

> **Three IWE classifications:** Viewpoints (this section) answer "through which lens are we looking." Perimeters L1–L4 (§ 2.1) answer "where it lives." Tiers T0–T4 + TM/TA/TD (§ 9.1) answer "what level of access."

#### Viewpoint 1: Systems (U.System) — what has 4D boundaries

Systems with boundaries, inputs, outputs, and an owner. Can be started, stopped, and updated. The main IWE systems are listed here; additional ones (WakaTime and others) are described in § 2.6.

| System | Type | What it does | Perimeter (§ 2.1) |
|--------|------|-------------|-------------------|
| **Claude Code CLI** (A1) | LLM agent | Primary AI executor: code, analysis, planning | L4 Personal |
| **Telegram bot** (I1, @aist_me_bot) | Service | Notes, programs, Digital Twin, notifications | L2 Platform |
| **MCP servers** (I3–I8) | Protocol | Access to Pack, guides, DS descriptions from Claude Code | L2 Platform |
| **Git + GitHub** | VCS | Versioning, storage, CI | L3 Template / L4 |
| **Exocortex** | Filesystem | Storage and delivery of descriptions (CLAUDE.md + memory/) | L3 Template / L4 |
| **Neon DB** (Digital Twin) | DBMS | Storage of Digital Twin events | L2 Platform |

> **Test:** Does it have 4D boundaries, an owner, inputs and outputs? → System.
>
> **Exocortex** is visible from two viewpoints. Through the "Systems" lens: a filesystem with a lifecycle (Open/Close), an owner, and boundaries. Through the "Descriptions" lens: the content of those files — Distinctions, principles, Protocols. These are not two objects, but two perspectives on one (ISO 42010).
>
> **Neon DB** — similarly. Through the "Systems" lens: a running DBMS with 4D boundaries (HD #27: the bot is a client, not an owner). Through the "Work Products" lens: the events written to that DBMS.

Roles (Viewpoint 3) are launched automatically via the OS system scheduler: launchd (macOS) or cron (Linux). The scheduler is not part of IWE — it is operating system Infrastructure. It is installed once during setup.

#### Viewpoint 2: Descriptions (U.Description) — knowledge loaded into systems

Text descriptions that are loaded into the AI's context and define its behavior. They are not executed — they are read.

| Description | Composition | Purpose |
|-------------|-------------|---------|
| **Principles** (FPF, SPF, ZP) | Encoded in the exocortex and prompts | Principles of correct thinking, fallback chain |
| **Exocortex content** | `CLAUDE.md` + `MEMORY.md` + `memory/*.md` | Rules, Distinctions, SOTA, navigation |
| **Pack entities** | `PACK-{domain}/pack/**/*.md` | Formalized Domain descriptions (source of truth) |
| **Role prompts** | `roles/*/prompts/*.md` | Role Configuration: day-plan, week-review, session-close, and others |

> **Test:** Can it be passed as a file and loaded into a system? → Description.

#### Viewpoint 3: Roles (U.RoleAssignment) — functions independent of the performer

A Role describes a function (WHAT to do), not a performer (WHO does it). One Role Performer (holder) can play multiple Roles. One Role can be played by different performers (Claude, a bash script, a person). Details: [DP.ROLE.001 §3](https://github.com/TserenTserenov/PACK-digital-platform/blob/main/pack/digital-platform/02-domain-entities/DP.ROLE.001-platform-roles.md).

| Role | Code | Performer (holder) | What it does | When |
|------|------|--------------------|-------------|------|
| **Strategist** | R1 | Claude CLI (scheduled) | Planning, reflection, Session preparation | Every morning, evening, week |
| **Extractor** | R2 | Claude CLI | Extracting descriptions into Pack | At Close, on demand, every 3 h |
| **Synchronizer** | R8 | bash script (scheduled) | Schedule coordination, notifications, nightly review | On schedule |
| **Navigator** | R13 | Telegram bot | Guiding users through Platform Services | On user request |
| **User** | — | Human | Decision-making, creation, reflection | Always |

> **Test:** A function describable without naming a performer? → Role.
>
> **Role ≠ Role Performer (HD #5).** The notation "Strategist (R1) ← Claude" reads: Role is Strategist, holder is Claude. "Human" is not a Role — it is a performer playing the "User" Role.
>
> **FPF notation:** `Holder#Role:Context@Window` (A.2). Full catalog: 21 Platform Roles in DP.ROLE.001 §3.2.

#### Viewpoint 4: Methods (U.MethodDescription) — how a Role produces a Work Product

Descriptions of Methods (procedures for "how to do"), linking a Role to a Work Product. They have their own lifecycle, owners, and correctness tests.

| Method | What it describes | Owner Role | Work Product |
|--------|-------------------|------------|--------------|
| **ORW Protocol** | Open → Work → Close of each Session | All Roles | WP context, plans, reports |
| **Capture-to-Pack** | Knowledge extraction at Work milestones | R2 Extractor | Pack entities |
| **ArchGate** (EMOSCSS) | Evaluation of architectural decisions by 7 characteristics | R1 Strategist | Evaluation table, decision |
| **Knowledge Extraction** (KE) | Transformation of raw data into Pack entities | R2 Extractor | Pack entities |
| **Note-Review** | Processing notes, routing to the appropriate Repositories | R1 Strategist | Processed notes, tasks |

> **Test:** A procedure for "how to do," describable independently of the performer? → Method.
>
> **Why a separate viewpoint?** The A.7 triad (Role → Method → Work) is the central Distinction of FPF. Without the "Methods" viewpoint, Protocols disappear into Descriptions, even though they are not just knowledge — they are **procedures** linking Roles to Work Products.

#### Viewpoint 5: Work Products (U.Work) — what is produced

Observable Work Products. Can be read, verified, versioned, and handed off without explanation.

| Work Product | Where | Who produces it | Purpose |
|--------------|-------|-----------------|---------|
| **Strategy hub** | `DS-strategy/` | R1 Strategist + User | Storage of personal documents (plans, strategy, inbox) and conducting strategy Sessions |
| **Pack documents** | `PACK-{domain}/` | R2 Extractor + User | Accumulation of formalized Domain descriptions (the sole source of truth) |
| **Project repos** | `DS-{projects}/` | User + Claude Code | Creating concrete products: code, bots, courses, content |
| **Digital Twin events** | Neon DB | Bot + LMS + Club | Personalization and reflection: Profile, Progress, self-assessment |
| **Notes** | `DS-strategy/inbox/` | Bot (from Telegram) | Quick capture of thoughts and observations for later processing by the Strategist |
| **Posts, drafts** | `DS-strategy/drafts/`, Knowledge Index | User | Crystallization of thoughts and publication |

> **Test:** Can it be handed off without explanation? Does it persist after the work is finished? → Work Product.

#### How the viewpoints connect

```
         Role ──method──→ Method ──produces──→ Work Product
              ↑                                    │
         Descriptions                        Capture-to-Pack
         loaded into Roles                   back into Descriptions
              ↑
         Systems
         execute Roles

Example chains (Role → Method → Work Product):
  R1 Strategist ──── ORW ────────────────── WeekPlan, DayPlan
  R2 Extractor  ──── Capture-to-Pack ─────── Pack entities
  R1 Strategist ──── Note-Review ─────────── Processed notes
  User          ──── ArchGate ──────────────── EMOSCSS table + decision
```

> **Integrity principle:** Remove any viewpoint and IWE degrades. Without Systems — no execution. Without Descriptions — a stateless assistant. Without Roles — task chaos. Without Methods — ad hoc work. Without Work Products — no result.

### 1.3. User path

```
T axis (learner):
T0 No Ory         T1 Start          T2 Learning        T3 Personalization   T4 Creation (IWE)
├── /start in bot ├── Ory reg.       ├── Programs        ├── Digital Twin      ├── setup.sh
├── telegram_id   ├── UUID           ├── Marathon        ├── Profile + goals   ├── Claude Code
├── trial 30 days ├── trial 30 days  ├── Bot + content   ├── Mentor            ├── Strategist + plans
└── Basic search  └── Assistant      └── Expert          └── Mentor            └── Co-thinker

Orthogonal axes (assigned):
TM1–TM3: Mentor    TA1–TA4: Administrator    TD1: Developer
```

**Key point:** T0–T3 work without Git — everything goes through the bot. T4 adds Claude Code, Git, and automated agents. TD1 (developer) is an orthogonal axis: access to source code, Deployment, and architectural decisions. Owner = T4 + TA4 + TD1. The transition is gradual — everything accumulated previously (Digital Twin, Profile, Progress) is preserved.

**Central IWE invariant:** Platform updates (Standard) **never** affect user data (Personal). Your plans, knowledge, and strategy belong to you.

## 2. Architecture: perimeters and spaces

### 2.1. Four system perimeters

IWE does not exist in isolation — it is part of a 4-perimeter system. Each perimeter corresponds to its own level in the principles hierarchy (§ 3.1):

```
L1: Ecosystem    — the whole system: Platform + community + all IWE users
  L2: Platform   — Infrastructure and Services (bot, MCP, Knowledge Index)
    L3: Template — this Template (CLAUDE.md + memory/ + Strategist + seed/)
      L4: Personal IWE — your instance (configured, with personal Pack and data)
```

| Perimeter | What it means for you | Example | How it is updated |
|-----------|----------------------|---------|-------------------|
| **L1: Ecosystem** | Community, seminars, content | systemsworld.club, Telegram channels | You participate |
| **L2: Platform** | Services you connect to | Bot @aist_me_bot, Knowledge Index | Updated by the developer |
| **L3: Template** | The Template your IWE was created from | This repo (FMT-exocortex-template) | `update.sh` — Platform-space |
| **L4: Personal IWE** | Your work, plans, knowledge | ~/IWE/CLAUDE.md, DS-strategy/ | Only you (User-space) |

**Where to learn:**
- [ONTOLOGY.md](../ONTOLOGY.md) § "System perimeters"
- `DS-ecosystem-development/11-platform-contours.md` — full architectural model (ecosystem governance repo, created locally at Deployment, not published to GitHub)

### 2.2. From Template to workspace

#### FMT-exocortex-template repo structure

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
│   └── *.md                         # PLATFORM: Protocols, SOTA, checklists
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

#### Four zones

| Zone | What | update.sh | User |
|------|------|-----------|------|
| **PLATFORM** | `CLAUDE.md` (§1–7), `memory/protocol-*.md`, `roles/`, `docs/`, `.claude/` | Updates | Does not modify |
| **USER-SPACE** | `CLAUDE.md` § "My rules" (the `<!-- USER-SPACE -->` section) | **Does not modify** | Own rules, Distinctions |
| **CONFIG** | `memory/day-rhythm-config.yaml` | Does not modify | Configures parameters |
| **PERSONAL** | `memory/MEMORY.md`, AUTHOR-ONLY zones in Protocols | Does not modify | Edits |
| **SEED** | `seed/strategy/` | N/A | After setup → separate repo DS-strategy/ |

> **USER-SPACE** is the "8. My rules" section at the end of CLAUDE.md. Add your own rules, Distinctions, and lessons only here — they are preserved on update. Everything above (§1–7) is Platform-owned and updated via `update.sh`.
> **AUTHOR-ONLY zones** are blocks inside PLATFORM files marked with `<!-- AUTHOR-ONLY -->` markers. They are preserved during update.sh. Details: [CLAUDE.md §7](../CLAUDE.md).

#### What setup.sh does

1. Forks the Template → your GitHub account
2. Substitutes 7 placeholders (`{{GITHUB_USER}}`, `{{WORKSPACE_DIR}}`, and others)
3. Copies `CLAUDE.md` → workspace root directory
4. Copies `memory/*.md` → `~/.claude/projects/.../memory/`
5. Creates `DS-strategy/` from `seed/strategy/` (a separate private repo)
6. Installs launchd agents for the Strategist

#### Workspace after setup

```
~/IWE/
├── CLAUDE.md                          # read every Session (auto)
├── DS-strategy/                       # ★ daily: plans, inbox, strategy
│   ├── current/DayPlan, WeekPlan      # Strategist writes, you read
│   ├── inbox/WP-*.md                  # task contexts
│   └── docs/Strategy.md              # your strategy
├── FMT-exocortex-template/            # DO NOT modify (updated via update.sh)
├── PACK-{domain}/                     # when you create it: domain knowledge
└── DS-{projects}/                     # when you create it: code, tools
```

### 2.3. What the Platform provides through the Template (Standard)

Through the Template and updates, you receive a ready-made methodology:

| Component | What it is | Files |
|-----------|-----------|-------|
| **Protocols** | Open → Work → Close: how to conduct a Session | `memory/protocol-*.md` |
| **Memory** | 11 files: Distinctions, SOTA, Roles, checklists, navigation | `memory/*.md` |
| **Strategist** | 7 automated planning scenarios | `roles/strategist/prompts/` |
| **Tools** | WakaTime hook, Claude Code skills | `.claude/hooks/`, `.claude/skills/` |
| **Rules** | Repository Architecture, processes, gates | `CLAUDE.md` |

All of this is updated via `update.sh` — you receive improvements without losing personal data.

### 2.4. What accumulates for you (Personal)

Your data lives separately and is **never affected by updates**:

| Layer | What | Where | How it grows |
|-------|------|-------|-------------|
| **Fleeting notes** | Transient notes | `DS-strategy/inbox/fleeting-notes.md` | Bot: ".text" |
| **Captures** | Captured knowledge | `DS-strategy/inbox/captures.md` | Claude: Capture-to-Pack |
| **Memory** | Tasks, lessons, navigation | `MEMORY.md` | Claude updates every Session |
| **Configuration** | Behavior parameters | `memory/day-rhythm-config.yaml` | You configure |
| **AUTHOR-ONLY zones** | Your Protocol extensions | `memory/protocol-*.md` | You add |
| **Pack entities** | Formalized knowledge | `PACK-{domain}/` | Extractor formalizes captures |
| **Content** | Posts, courses | `DS-{projects}/` | You create |

#### Three customization patterns (L3 → L4)

| Pattern | Mechanism | Example | Purpose |
|---------|-----------|---------|---------|
| **Config** | yaml file with parameters | `strategy_day: saturday` | Agent behavior settings |
| **AUTHOR-ONLY zones** | HTML markers in Protocols | Checks for specific systems | Extending Protocols without update.sh conflicts |
| **Placeholders** | `{{WORKSPACE_DIR}}` and others | Paths, GitHub username | Auto-substitution during setup |

Details on AUTHOR-ONLY zones: [CLAUDE.md §7](../CLAUDE.md).

### 2.5. Updates: update.sh

**One command:** `cd ~/IWE/FMT-exocortex-template && bash update.sh`

The Script downloads an update Manifest from GitHub, compares sha256 checksums of local files against upstream, shows a preview, and applies changes after confirmation:

| Step | What it does | Result |
|------|-------------|--------|
| 0. Self-update | Checks whether a new version of update.sh exists | Script stays current |
| 1. Manifest | Downloads `update-manifest.json` from GitHub | List of files to update |
| 2. Comparison | sha256 of local files vs remote | List of new and changed files |
| 3. Preview | Shows: new files, updated files, untouched files | You decide: apply or not |
| 4. Apply | Downloads and replaces files, substitutes variables | Platform files updated |
| 5. Platform-space | Copies CLAUDE.md → workspace, memory/ → ~/.claude/ | Live files updated |
| 6. Roles | Reinstalls Roles if their files changed | Agents updated |

**What is NOT affected:**

```
CLAUDE.md § "My rules"     ← USER-SPACE section (your rules and Distinctions)
MEMORY.md                  ← Your WP table
DS-strategy/               ← Your plans, inbox/, docs/
PACK-{domain}/             ← Your domain knowledge
.secrets/, .mcp.json       ← Keys and Configuration
.claude/settings.local.json ← Your permissions
```

**Your own rules:** add them to the "8. My rules" section at the end of CLAUDE.md (after the `<!-- USER-SPACE -->` marker). This section is preserved on update. Rules in `<repo>/CLAUDE.md` of specific repos are not affected at all.

**Additional modes:**
- `bash update.sh --check` — only show whether updates are available (without applying)
- `bash update.sh --yes` — apply without confirmation

**Cumulative update model:**

Changes in the Template accumulate. You can update once a day, once a week, or once a month — one `bash update.sh` command applies everything accumulated during that period. CHANGELOG.md will show what changed.

**Telegram notifications:**

Every morning at 7:28, the @aist_me_bot sends a digest of changes from the last 24 hours (if any occurred). Subscribe to the updates channel so you do not miss anything. A notification is information. The decision to update is always yours.

**Three ways to update:**
1. Terminal: `bash update.sh`
2. AI CLI: tell your AI *"update my exocortex"*
3. Check without applying: `bash update.sh --check`

### 2.6. Optional services

The Template (L3) recommends, but does not require. Each is configured separately:

| Service | Type | Setup | Role | Product |
|---------|------|-------|------|---------|
| WakaTime | Tool | `/setup-wakatime` | Work Observability | Metrics by project and category |
| Digital Twin | Data | Bot → `/twin` | Personalization of responses and plans | Goals, self-assessment, context |
| systemsworld.club | Ecosystem | Registration | Community, seminars | Access to materials |
| Git + GitHub | Infrastructure | `setup.sh` (auto) | Versioning, agents | Repositories, CI |
| Marp | Tool | VS Code extension + CLI | Markdown → slides | Slide documents (PDF/HTML) |
| Cloud Scheduler | Automation | `setup/optional/setup-cloud-scheduler.sh` | IWE runs 24/7 when Mac is off | Backup, health check, notifications |

**Cloud Scheduler — IWE cloud automation:** A GitHub Actions workflow runs backup and health check daily at 04:00 MSK — even when Mac is off. Basic level ($0/month, no LLM). Optional: Telegram notifications with report. Installation: `bash setup/optional/setup-cloud-scheduler.sh`. Details: `setup/optional/README.md`, scenario [DP.SC.019](../../PACK-digital-platform/pack/digital-platform/08-service-clauses/DP.SC.019-autonomous-cloud-runtime.md).

**Health Check setup (extended):** By default, health check only monitors the strategy repo. For multi-repo monitoring:
1. GitHub → Settings → Variables → Actions → add `HEALTH_CHECK_REPOS` — comma-separated list of your repos (`owner/repo, owner/repo2`)
2. (Optional) Add `BOT_HEALTH_URL` — the bot's health endpoint URL to check availability
3. (Optional) Add Secrets: `TELEGRAM_BOT_TOKEN` + `TELEGRAM_CHAT_ID` for Telegram notifications
4. PAT (`STRATEGY_REPO_TOKEN`) must have access to all listed repos

Manual run: `gh workflow run cloud-scheduler.yml --field task=health-check`. Report: commits (24h + 7d by repo), DayPlan, WeekPlan, backup (<48h), Sessions, bot status, WP statistics, traffic light.

**Marp — presentation preparation:** Marp converts Markdown files into slides (PDF, HTML, PPTX). Workflow: write `.md` with `---` separator → preview in VS Code (Marp extension) → export `marp --pdf slides.md`. Slide documents (MIM.WP.001) are text-based, so Markdown + Git = versions, diffs, edits via Claude Code. Installation: `npm install -g @marp-team/marp-cli` + VS Code → Extensions → "Marp for VS Code".

**IntegrationGate rule:** Before adding a new tool to your IWE: (1) type, (2) perimeter (L2/L3/L4), (3) Roles, (4) products, (5) processes.

## 3. Thinking foundation

### 3.1. Principles hierarchy

All knowledge is organized into 4 levels. Each subsequent level is constrained by the one above:

```
Level 0: ZP (zero principles)             ← axioms, no framework
    ↓ discipline
Level 1: FPF (first principles)           ← principles + framework (bundle)
    ↓ constrain
Level 2: SPF → Pack (second principles)   ← framework + principles (separate)
    ↓ define
Level 3: S2R and others → DS              ← frameworks + principles (separate)
```

**Fallback chain:** DS (level 3) → Pack (level 2) → Base.Principles (SPF → FPF → ZP). If something is unclear at the current level, move up one level.

**Zero principles (ZP)** — 6 trans-disciplinary Constraints:

| Principle | Essence |
|-----------|---------|
| ZP.1 Axiomaticity | Build on axioms, not intuition |
| ZP.2 Structure and symmetry | Describe through invariants, not objects |
| ZP.3 Multi-scale | The model must work at different scales |
| ZP.4 Optimization | Find an extremum, do not enumerate |
| ZP.5 Probability and information | Describe uncertainty quantitatively |
| ZP.6 Computational limits | Account for finite resources |

**Where to learn:**
- [ZP/hierarchy.md](https://github.com/TserenTserenov/ZP/blob/main/hierarchy.md) — map of all 4 levels
- [ZP/principles/](https://github.com/TserenTserenov/ZP/tree/main/principles) — each principle in detail
- [CLAUDE.md](../CLAUDE.md) § 1 — type table and fallback chain

### 3.2. Hard Distinctions

30+ pairs of concepts that **must not be confused**. Confusion is the primary source of errors:

| # | Pair | Essence |
|---|------|---------|
| 1 | System ≠ Episteme | Physical boundaries vs. Knowledge Domain |
| 2 | Method ≠ Tool | Way of working vs. instrument of working |
| 3 | Work Product ≠ Description | Observable Artifact vs. text about it |
| 4 | Tracking ≠ Planning | Recording facts vs. intentions |
| 5 | Role ≠ Agent ≠ Tool | Mask vs. who wears the mask vs. instrument |
| 6 | Method ≠ Skill | Reproducible process vs. personal ability |
| 7 | Observation ≠ Judgment | Fact vs. interpretation |
| 8–11 | Data ≠ Insight, Artifact ≠ Process, Pack ≠ Governance, Process ≠ Service ≠ Scenario | Ontological |
| 12–22 | Description ≠ Knowledge, DDD strategic ≠ tactical, Platform ≠ Template ≠ Personal IWE, ... | Methodological and operational |
| 25–26 | Draft ≠ Prepared piece, Prepared piece ≠ Post | Stages of the creative Pipeline |
| 27 | Bot ≠ Platform; Neon = one Digital Twin | Digital Twin Architecture |
| 28 | Prosthesis ≠ Exoskeleton | Pattern of AI interaction with a person (§ 1.1a) |
| 29 | Pack knowledge ≠ Implementation decision | Domain truth → Pack. Technical choice → DS |
| 32 | Three Verification classes | closed-loop / open-loop / problem-framing (§ 5.1b) |
| 36 | Exocortex ≠ IWE | Exocortex is the description storage Subsystem inside IWE |

**Where to learn:**
- [memory/hard-distinctions.md](../memory/hard-distinctions.md) — all 22 pairs with examples and tests

### 3.3. FPF first principles

FPF (First Principles Framework) is the "operating system for thinking." It defines the basic constructs and the rules for combining them.

| Part | Content | When to read |
|------|---------|-------------|
| A | Core: Holon, BoundedContext, Role-Method-Work | Basic Distinctions |
| B | Aggregation, Trust, Evolution cycles | Understanding processes |
| C | Domain extensions (CAL) | Custom calculi |
| D | Ethics and conflict optimization | Multi-scale decisions |
| E | Constitution and authorship | Framework governance |
| F | Terminology: UTS, Bridges | Cross-domain alignment |
| G | SoTA Kit | Knowledge work patterns |

**How to read:** NOT sequentially. Start with the table of contents, then navigate to needed sections by code (for example `FPF A.7` = Strict Distinction).

**Where to learn:**
- [FPF/README.md](https://github.com/ailev/FPF) — overview
- [memory/fpf-reference.md](../memory/fpf-reference.md) — navigation through key sections

## 4. Repositories and projects

### 4.1. Three repository types