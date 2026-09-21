# IWE Data Policy

> **Version:** 1.1 | **Date:** 2026-03-27 | **Full version:** [DP.D.035](https://github.com/TserenTserenov/PACK-digital-platform/blob/main/pack/digital-platform/01-domain-contract/DP.D.035-data-policy.md)

This document describes what data IWE collects, where it is stored, and how to manage it.

---

## 1. What Data Is Collected

The scope of data depends on your tier:

| Tier | What Is Collected |
|------|-------------------|
| **T0 No account** | Nothing collected (no account login) |
| **T1 Start** | Telegram profile, name, occupation, marathon answers (~15 fields) |
| **T2 Exploration** | + feed, Q&A, session history, notes, subscription (~40 fields) |
| **T3 Personalization** | + digital twin: goals, self-assessment, reflection (~60 fields) |
| **T4 Creation (IWE)** | + CLAUDE.md, memory/, extensions/, git commits (~100+ fields) |

---

## 2. Where Data Is Stored

IWE is delivered in two ways: **distribution** (Git + CLI, for advanced users) and **platform hosting** (one button, for beginners). When you are ready, you export your data and own it.

| What | Where | Who Controls It |
|------|-------|-----------------|
| Profile, sessions, tests, digital twin | Neon PostgreSQL (cloud) | IWE (server side) |
| Template (methodology, scripts) | Git repo `FMT-exocortex-template` | IWE (updated via `update.sh`) |
| `memory/`, `extensions/`, `params.yaml` (your context — in your working directory and in Claude Code memory) | **Your machine + your private GitHub** (memory backup goes to `DS-strategy`) | **You** |
| DS-strategy (your strategy) | **Your machine + your private GitHub** | **You** |

> **IWE does not have access to your personal files.** Your `memory/`, `extensions/`, and DS-strategy exist only on your machine and in your private GitHub repository.

> **A template fork is not a private space.** `gh repo fork` creates a public fork: GitHub does not allow converting a fork of a public repository to private. The `memory/` and `extensions/` directories inside the `FMT-exocortex-template/` clone are platform samples, not your personal context. Do not place personal data inside the template directory and do not push from it: with a public fork, anyone can see that content. For details on creating a private copy of the template, see [SETUP-GUIDE §1.2b](SETUP-GUIDE.md).

---

## 3. What Is Sent to External Services

| Service | What Data | Frequency |
|---------|-----------|-----------|
| **Anthropic API** (Claude) | Prompt + profile + question text | On every request |
| **GitHub** | Repository contents | On push |
| **WakaTime** (optional) | Metadata (project, language, time). **NOT** file contents | Continuously |
| **MCP iwe-knowledge** (Gateway) | Search queries (text). **No** PII | On search |

Anthropic **does not use API data for training** ([API Terms](https://www.anthropic.com/api-terms)).

---

## 4. Template vs. Your Files

| | Template (updatable) | Your files (personal) |
|--|----------------------|-----------------------|
| What is included | `setup.sh`, `update.sh`, `scripts/`, `roles/`, `CLAUDE.md §1-8` | `memory/`, `extensions/`, `params.yaml`, `CLAUDE.md §9-10` (in your working directory and Claude Code memory, not inside the template clone), `seed/` (one-time at setup), DS-strategy |
| Who writes it | IWE | You |
| Updated automatically | Yes (`update.sh`) | **Never** |
| Contains your data | No | Yes |
| Deleted when account is deleted | No (this is methodology) | No (these are your files) |

**Personal exclusions from the Manifest.** The list of updatable files is stored in `update-manifest.json`. The `update.sh` script replaces this file in full on every update — your edits to it do not survive. If you need to exclude your own files from coverage checks (for example, custom scripts in a fork), create `update-manifest.local.json` alongside it:

```json
{ "excluded_paths": ["scripts/my-personal-script.sh", "my-folder/"] }
```

The `update.sh` script never modifies this file. The coverage check (`check-manifest-coverage.py`) and the orphaned-file detector both read it together with the main Manifest.

---

## 5. Your Rights

### Viewing Your Data
The `/mydata` command in the bot shows all collected data: profile, activity, progress, and consultations.

### Deleting Your Data
In the bot, enter: `Delete. {Your name}` — this triggers a cascading deletion from all tables.

After deletion:
- Profile, history, notes, digital twin — deleted from the server side
- `memory/`, `extensions/`, DS-strategy — remain with you (delete them yourself if you wish)
- Anonymized aggregates (DAU/MAU) — are not deleted

### Withdrawing Consent
At any time you can:
- Delete your data in the bot
- Delete local files
- Disable WakaTime, revoke GitHub OAuth

---

## 6. Consent

By running `setup.sh`, you confirm that you:

1. Have reviewed what data is collected
2. Understand where data is stored and what is sent to third parties
3. Know how to view (`/mydata`) and delete your data
4. Understand the distinction between the template (updated by IWE) and your files (personal)

Continued use of IWE after a policy update constitutes consent to the new version.

---

## 6.1. Data Freedom

All your data is stored in open formats (Git, Markdown, YAML). At any time you can:

- **Take everything** — `git clone` your repositories
- **Export your digital twin** — via the bot
- **Wipe your data** — full deletion from the server side
- **Switch AI vendor** — your files are not tied to Anthropic
- **Develop independently** — fork the template, write your own scripts, build your own integrations

---

## 7. Security

### Recommendations for Your Machine

- **FileVault** — enable disk Encryption
- **Firewall** — must be active
- **Secrets** — store only in `.env` (gitignored) or a password manager
- **SIP** — do not disable

### Self-Hosted Alternatives

| SaaS | Self-hosted |
|------|-------------|
| WakaTime | [Wakapi](https://github.com/muety/wakapi) |
| GitHub | [Gitea](https://gitea.io/) or [GitLab Self-Managed](https://about.gitlab.com/install/) |

---

> Full policy version with technical details: [DP.D.035](https://github.com/TserenTserenov/PACK-digital-platform/blob/main/pack/digital-platform/01-domain-contract/DP.D.035-data-policy.md)