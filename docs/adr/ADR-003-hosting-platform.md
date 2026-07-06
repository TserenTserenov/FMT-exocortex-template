<body>
# ADR-003: IWE Platform Hosting

**Status:** Accepted (specification)
**Date:** 2026-03-29
**Context:** WP-180 Ф4, FMT-exocortex-template, DP.EXOCORTEX.001

---

## Context

IWE is currently available only via Git+CLI: `gh repo fork` → `bash setup.sh`. This is a barrier for users without terminal experience (Egor's case: "I don't know Git, I don't know CLI"). The value of IWE lies in the methodology and the agent, not in the delivery format.

**From participant feedback:**
- Participant #2: needs access without Git, via web
- Egor: wants to try it "with one click" and figure it out later
- abcdef0101: VM image as a third delivery method

**Analogy:** WordPress.org (self-hosted) vs WordPress.com (hosted). Both deliver the same product with different entry points. A WordPress.com user can export everything and switch to self-hosted.

## Problem

1. **Entry barrier.** Git + CLI + fork + setup.sh ≈ 30–60 min for a beginner, with a risk of errors.
2. **No managed onboarding.** setup.sh asks 7 questions at once — no gradual entry.
3. **No lossless updates** (resolved in Ф0.5–Ф1, but only for CLI users).

## Solution

### Two delivery layers (not "two products")

```
Layer A: Distribution (current)              Layer B: Platform hosting (new)
──────────────────────────                   ──────────────────────────────────
gh repo fork + bash setup.sh                 Web → account → onboarding agent
Git = storage and history                    Git = storage (hidden)
User manages files                           Agent manages files on behalf of user
Update: bash update.sh                       Update: agent proposes automatically
```

Both layers use the same distribution (FMT-exocortex-template). Platform hosting is a **thin layer** on top — not a separate product.

### Platform hosting Architecture

```
┌─────────────────────────────────────────────────────────┐
│  Web Interface (chat)                                   │
│  • Onboarding agent: configures IWE for the user        │
│  • Peer agent: regular work via chat                    │
│  • /iwe-update: agent proposes updates                  │
├─────────────────────────────────────────────────────────┤
│  Hosting API                                            │
│  POST /setup?level=T1   — bash setup.sh --level=T1 --yes│
│  POST /update           — bash update.sh --yes          │
│  GET  /export           — git bundle (full export)      │
├─────────────────────────────────────────────────────────┤
│  User Git Repository (private)                          │
│  • Same FMT-exocortex-template fork                     │
│  • Stored on the platform (or user's GitHub)            │
└─────────────────────────────────────────────────────────┘
```

### Gradient entry — installation levels

The user advances through levels at their own pace (not by week):

| Level | What is included | What setup.sh does | Entry time |
|-------|------------------|--------------------|------------|
| **T1** | git + CLAUDE.md + memory. LLM via platform | Steps 1-3 (placeholders, CLAUDE.md, memory) | ≤15 min |
| **T2** | + Day Open/Day Close/Week Close rituals + extensions/ + params.yaml | + step 4b (skills, hooks) + step 6 (DS-strategy) | +30 min |
| **T3** | + Pack + digital twin (via bot) | + Pack instructions + bot onboarding | +1h |
| **T4 Direct** | + roles + MCP + launchd (requires own API key) | + step 5 (roles, automation) | +1h |
| **T4 Gateway** | + roles + Gateway URL + GitHub OAuth (no CLI) | + GitHub OAuth + MCP connector | +30 min |

**Key principle:** each next level adds to the previous one — it does not replace it. `setup.sh --level=T2` extends a T1 installation.

### Scriptable API (for hosting)

Hosting manages IWE through the same scripts, but without interactive prompts:

```bash
# Initial T1 installation (no prompts)
bash setup.sh \
  --level=T1 \
  --yes \
  GITHUB_USER=alice \
  WORKSPACE_DIR=/home/alice/IWE

# Update
bash update.sh --yes

# Level upgrade
bash setup.sh --level=T2 --yes
```

`--yes` is the hosting flag: skip all interactive prompts and use defaults.

### Data export

A platform hosting user does not lose data when leaving:

```bash
# Full export: git clone = all files + history
git clone https://hosting.iwe.ai/alice/my-exocortex ~/IWE/my-exocortex
cd ~/IWE/my-exocortex && bash setup.sh --level=T4
```

This guarantees vendor lock-in = 0.

### Scenario С6: VM image (from abcdef0101 feedback)

```bash
vagrant up  # downloads Ubuntu + tmux + Claude Code + IWE T1 image
# → user is in a tmux session in ~/IWE/
```

The Vagrant image is the third delivery method (for a DevOps audience and testing).

## What needs to be implemented (Backlog)

| # | Artifact | Level | Dependency |
|---|----------|-------|------------|
| 1 | `setup.sh --yes` — non-interactive mode | Platform | WP-180 Ф4 ✅ (`--level` added) |
| 2 | `setup.sh --level=TX` — level upgrade | Platform | WP-180 Ф4 ✅ |
| 3 | Web interface (chat → onboarding agent) | Hosting | WP-189 (MCP) |
| 4 | Hosting API (POST /setup, POST /update, GET /export) | Hosting | Separate WP |
| 5 | Vagrant image | Delivery | Separate WP |

## Update (April 2, 2026)

**New decisions (DP.ARCH.002 + DP.SC.112):**

1. **30-day trial = full T1–T4.** The user does not need a subscription to install IWE.
2. **Platform LLM Proxy (WP-200).** The user does NOT need their own Anthropic/OpenAI API key. The platform provides AI models as a service (included in the subscription and trial). `PLATFORM_LLM_PROXY_URL` replaces the mandatory `ANTHROPIC_API_KEY`.
3. **T4 = two modes.** `--mode=direct` (Claude Code CLI + MCP + launchd) or `--mode=gateway` (Gateway URL + GitHub OAuth + MCP connector). Both are free.
4. **GitHub OAuth — explicit T4 Gateway onboarding step.** The platform forks FMT-exocortex-template automatically.
5. **Gateway = full T4 (parity principle, DP.IWE.003 §8).** Server-side agents (WP-201) run on the platform.

**New .exocortex.env variables:** `T4_MODE`, `PLATFORM_LLM_PROXY_URL`, `GITHUB_TOKEN`, `GATEWAY_URL`.

## Rejected alternative: "v2 from scratch"

**Rejected (Mar 27, 2026).** IWE is a distribution (rolling release, not major versions). WP-180 implements SOTA incrementally. A double budget is unrealistic at 60h/week. Incremental stabilization was chosen.

## ArchGate (EMOGSSB)

| Characteristic | Score | Rationale |
|----------------|-------|-----------|
| Evolvability | 9 | Single distribution, two delivery layers. The platform does not fork the code |
| Scalability | 8 | Git hosting scales with standard methods |
| Learnability | 9 | Gradient entry lowers the barrier without sacrificing depth |
| Generativity | 9 | Export = full portability. Vendor lock-in = 0 |
| Speed | 8 | T1 in 15 min vs 30–60 min currently |
| Modernity | 9 | WordPress.org/com analogy — a proven model |
| Security | 8 | Private repos, git bundle export |

**Total:** 60/70 — PASS (≥8 on all characteristics including Security ≥8).

</body>