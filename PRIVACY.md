# Privacy Policy

> A brief summary for GitHub visitors. The full version with details on storage layers and rights is available at [docs/DATA-POLICY.md](docs/DATA-POLICY.md) ([DP.D.035](https://github.com/TserenTserenov/PACK-digital-platform/blob/main/pack/digital-platform/01-domain-contract/DP.D.035-data-policy.md) for technical details).

## What Is Collected

The scope depends on your usage tier — from "nothing" (no account) to a full digital twin (profile, goals, self-assessment, git commits) at the top tier. See the per-tier table at [docs/DATA-POLICY.md §1](docs/DATA-POLICY.md#1-what-data-is-collected).

## Where Data Goes (opt-in / External Services)

| Service | What Is Sent | Required |
|---|---|---|
| **Anthropic API** (Claude) | Prompt + profile + question text | Required for agent operation |
| **GitHub** | Contents of your repositories | On `push` — under your control |
| **WakaTime** | Metadata (project, language, time), no file contents | Optional, can be disabled |
| **MCP iwe-knowledge (Gateway)** | Search query text, no PII | Only when search is used |

Anthropic does not use API data to train models ([API Terms](https://www.anthropic.com/api-terms)).

## What Never Leaves Your Machine

`memory/`, `extensions/`, `params.yaml`, and all DS-repository context exist only on your computer and in your private GitHub. This template repository (`FMT-exocortex-template`) has no access to them. The template fork on GitHub is public: do not place personal files in the fork directory or push them there — see [docs/SETUP-GUIDE.md §1.2b](docs/SETUP-GUIDE.md) for details.

## Your Rights

- **View** — use the `/mydata` command in the bot
- **Delete** — send `Delete. {Your name}` in the bot; deletion cascades across all server tables; local files and your private repository remain under your control
- **Export** — `git clone` at any time; data is stored in open formats (Git, Markdown, YAML)
- **Withdraw consent** — disable WakaTime, revoke GitHub OAuth, delete local files

## Questions

For privacy questions, contact **aisystant@gmail.com**. For security vulnerabilities, see [SECURITY.md](SECURITY.md).