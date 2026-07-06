# IWE Data Policy

> **Version:** 1.1 | **Date:** 2026-03-27 | **Full version:** [DP.D.035](https://github.com/TserenTserenov/PACK-digital-platform/blob/main/pack/digital-platform/01-domain-contract/DP.D.035-data-policy.md)

This document describes what data IWE collects, where it is stored, and how to manage it.

---

## 1. What Data Is Collected

The scope of data depends on your tier:

| Tier | What Is Collected |
|------|-------------------|
| **T0 No Account** | Nothing is collected (no account login) |
| **T1 Start** | Telegram profile, name, occupation, marathon answers (~15 fields) |
| **T2 Exploration** | + feed, Q&A, session history, notes, subscription (~40 fields) |
| **T3 Personalization** | + digital twin: goals, self-assessment, reflection (~60 fields) |
| **T4 Creation (IWE)** | + CLAUDE.md, memory/, extensions/, git commits (~100+ fields) |

---

## 2. Where Data Is Stored

IWE is delivered in two ways: **distribution** (Git + CLI, for advanced users) and **hosted platform** (one button, for beginners). As you grow, you export and take ownership.

| What | Where | Who Controls It |
|------|-------|-----------------|
| Profile, sessions, tests, digital twin | Neon PostgreSQL (cloud) | IWE (server side) |
| Template (methodology, scripts) | Git repo `FMT-exocortex-template` | IWE (updated via `update.sh`) |
| `memory/`, `extensions/`, `params.yaml` (your context) | **Your machine + your private GitHub** | **You** |
| DS-strategy (your strategy) | **Your machine + your private GitHub** | **You** |

> **IWE does not have access to your personal files.** Your `memory/`, `extensions/`, and DS-strategy exist only on your machine and in your private GitHub repository.

---

## 3. What Is Sent to External Services

| Service | What Data | Frequency |
|---------|-----------|-----------|
| **Anthropic API** (Claude) | Prompt + profile + question text | On every request |
| **GitHub** | Repository contents | On push |
| **WakaTime** (optional) | Metadata (project, language, time). **Not** file contents | Continuously |
| **MCP iwe-knowledge** (Gateway) | Search queries (text). **No** PII | On search |

Anthropic **does not use API data for training** ([API Terms](https://www.anthropic.com/api-terms)).

---

## 4. Template vs. Your Files

| | Template (updatable) | Your Files (personal) |
|--|----------------------|-----------------------|
| What is included | `setup.sh`, `update.sh`, `scripts/`, `seed/`, `roles/`, `CLAUDE.md §1-8` | `memory/`, `extensions/`, `params.yaml`, `CLAUDE.md §9-10`, DS-strategy |
| Who writes it | IWE | You |
| Updated automatically | Yes (`update.sh`) | **Never** |
| Contains your data | No | Yes |
| Deleted when account is deleted | No (this is methodology) | No (these are your files) |

---

## 5. Your Rights

### Viewing Data
The `/mydata` command in the bot displays all collected data: profile, activity, progress, and consultations.

### Deleting Data
In the bot, enter: `Удалить. {Ваше имя}` — this triggers a cascading delete from all tables.

After deletion:
- Profile, history, notes, digital twin — removed from the server side
- `memory/`, `extensions/`, DS-strategy — remain with you (delete them yourself if desired)
- Anonymized aggregates (DAU/MAU) — are not deleted

### Revoking Consent
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

Continued use of IWE after a policy update constitutes acceptance of the new version.

---

## 6.1. Data Freedom

All your data is stored in open formats (Git, Markdown, YAML). At any time you can:

- **Take everything** — `git clone` your repositories
- **Export your digital twin** — export via the bot
- **Wipe your data** — full deletion from the server side
- **Switch AI vendor** — your files are not tied to Anthropic
- **Develop independently** — fork the template, write your own scripts, build your own integrations

---

## 7. Security

### Recommendations for Your Machine

- **FileVault** — enable disk Encryption
- **Firewall** — must be active
- **Secrets** — keep only in `.env` (gitignored) or a password manager
- **SIP** — do not disable

### Self-Hosted Alternatives

| SaaS | Self-Hosted |
|------|-------------|
| WakaTime | [Wakapi](https://github.com/muety/wakapi) |
| GitHub | [Gitea](https://gitea.io/) or [GitLab Self-Managed](https://about.gitlab.com/install/) |

---

> Full policy version with technical details: [DP.D.035](https://github.com/TserenTserenov/PACK-digital-platform/blob/main/pack/digital-platform/01-domain-contract/DP.D.035-data-policy.md)