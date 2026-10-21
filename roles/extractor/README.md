# Extractor (Knowledge Extractor, R2)

> Extracts, formalizes, and routes knowledge to Pack repositories and DS docs/.

## What It Does

At Session close or on demand — finds knowledge (patterns, distinctions, methods, errors), formalizes it, and proposes writing it to the correct location. **Two routing outputs:** domain knowledge → Pack (using the SPF Template), implementation knowledge → DS docs/ (scenarios, processes, data). The user always approves before anything is written.

## Scenarios

| Scenario | Trigger | Mode |
|----------|---------|------|
| **Session-Close** | Session closing (Close Protocol) | Interactive |
| **On-Demand** | "Write this to Pack" | Interactive |
| **Knowledge Audit** | "Audit Pack" / monthly | Interactive |
| **Inbox-Check** | launchd every 3h (optional) | Headless (report) |

## When to Connect

- You have created your first Pack (PACK-{your-domain})
- You work with Claude Code regularly (≥3 sessions/week)
- You want to capture knowledge automatically

## Setup

### 1. Configure Routing

Edit `config/routing.md` — add your Packs:

```markdown
| Domain | Pack | Prefix | Path |
|--------|------|--------|------|
| My domain | PACK-my-domain | MD | {{WORKSPACE_DIR}}/PACK-my-domain/pack/my-domain/ |
```

### 2. Connect the Extractor to Your Subscription (required for Headless scenarios)

Headless scenarios (Inbox-Check, launchd/systemd) launch Claude Code without an interactive login — a long-lived token from your Claude Code subscription (Pro/Max/Team/Enterprise) is required:

```bash
bash "$IWE_TEMPLATE/roles/extractor/scripts/connect.sh"
```

One command, one browser login — the Script explains what to do, asks you to paste the printed token, and verifies the connection with a test call. The token is stored locally at `~/.secrets/claude_code_oauth_token` (permissions 600) — the same convention used for all other template secrets (`scripts/add-secret.sh`).

The token is read from `~/.secrets/claude_code_oauth_token` (a single line containing the token) or, if that file is absent or empty, from `~/.secrets/claude-subscription` (a line `CLAUDE_CODE_OAUTH_TOKEN=<token>`). The environment variable `CLAUDE_CODE_OAUTH_TOKEN` takes precedence over both files.

**The subscription takes precedence over a proxy and an API key.** When a token is found, the extractor resets `ANTHROPIC_BASE_URL`, `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, and `ANTHROPIC_CUSTOM_HEADERS` (including any values loaded by `~/.config/aist/env`) and connects directly to Anthropic. A subscription token is not accepted by an LLM proxy or a third-party gateway — and such a proxy may also strip tool descriptions, causing the run to finish "successfully" without producing a report. This applies to Claude Code only; a different `AI_CLI` keeps its own environment. If you intentionally work through your own gateway or API key, set `IWE_EXTRACTOR_USE_API_ENV=1`: the environment remains as-is, and the subscription token is not used for that run.

The token may expire over time (the lifetime is not officially documented) — if Inbox-Check starts failing, `extractor.sh` will show a hint in the log to re-run `connect.sh`. To verify the stored token without logging in again: `connect.sh --check`.

Interactive scenarios (Session-Close, On-Demand) do not require connection — they run inside your already-open Claude Code Session.

### 3. (Optional) Enable Automatic Inbox-Check

```bash
cd {{WORKSPACE_DIR}}/IWE/roles/extractor
bash install.sh
```

This installs a launchd agent that checks the inbox every 3 hours.

### 4. Manual Run

```bash
# Inbox-check (without launchd) — run via the assembled runtime copy, NOT the raw file in FMT
bash "$IWE_RUNTIME/roles/extractor/scripts/extractor.sh" inbox-check

# Knowledge Audit
bash "$IWE_RUNTIME/roles/extractor/scripts/extractor.sh" audit
```

## How It Works

```
Knowledge Extraction Pipeline:

  Discovery → Classification → Routing → Formalization → Validation → Approval → Write

  1. Find knowledge (captures + missed insights)
  2. Determine type (entity, distinction, method, fm, wp, rule)
  3. Determine: domain or implementation? (domain test)
     ├─ domain → Pack by domain (routing.md §1-4)
     └─ implementation → DS docs/ by system (routing.md §5)
  4. Create file: Pack → SPF Template; DS → docs/ Template
  5. Check: no duplicates or contradictions
  6. Show Extraction Report to the user
  7. Write only approved items
```

## Files

| File | Purpose |
|------|---------|
| `config/routing.md` | Routing tables (Packs, types, directories) |
| `config/feedback-log.md` | Log of rejected candidates (do not propose again) |
| `prompts/session-close.md` | Prompt: extraction at Session close |
| `prompts/on-demand.md` | Prompt: extraction on demand |
| `prompts/inbox-check.md` | Prompt: headless inbox check |
| `prompts/knowledge-audit.md` | Prompt: Pack Audit |
| `scripts/extractor.sh` | Launch Script (analogous to strategist.sh) |
| `scripts/launchd/` | launchd plist for inbox-check |

## Principles

1. **Human-in-the-loop:** The Extractor proposes — it does not write without approval.
2. **Single Pipeline:** All scenarios use classify → route → formalize → validate.
3. **Universality test:** Can this be used in another context? No → governance, do not extract.
4. **Lazy reading:** Inbox-check reads only the target Pack, not all Packs at once.

---

*Source-of-truth: DP.AISYS.013 (PACK-digital-platform)*
