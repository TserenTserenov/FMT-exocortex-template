# Three IWE Layers: What Gets Updated and What Stays Yours Forever

> **Audience:** anyone who has already installed IWE and is asking "what happens to my settings when an update comes out?" or "why do some files live in the Repository and some only on my machine?".
>
> **Short answer:** IWE is organized into three layers. One layer updates automatically. The second is your personal layer and no one will touch it. The third is transitional. Read on to learn how to tell them apart.

---

## 1. The Problem the Layers Solve

When `update.sh` pulls a new Platform version, it must update shared Protocols and Skills — but it has no right to erase your personal settings, notes, or Configuration. If everything were mixed together in one pile of files, every update would be a lottery: either the shared parts get updated, or your personal files get accidentally overwritten.

IWE solves this with an explicit three-layer separation. Each layer has its own owner and its own rule about who can make changes.

## 2. The Three Layers

| Layer | What it is | Who changes it | Where it lives | Does `update.sh` touch it? |
|-------|------------|----------------|----------------|----------------------------|
| **L1 — Platform** | Protocols, Skills, Hooks, Scripts — the shared IWE mechanics | Platform maintainers | `.claude/skills/`, `.claude/hooks/`, `memory/protocol-*.md`, `scripts/` | Yes, updates it |
| **L2 — Team / Staging** | Practices being validated before becoming Platform-level | Maintainers (during staging) | `STAGING.md` | No (until promoted to L1) |
| **L3 — Yours, authored** | Personal settings: constants, extensions, authored rules | You | `extensions/`, `params.yaml`, CLAUDE.md §9 | Never — `update.sh` does not touch this layer |

**The key rule:** your personal changes go into `extensions/` and `params.yaml`, not directly into Platform files. That way, `update.sh` can always pull a new L1 version without touching your work.

## 3. The "Which Layer Does This Belong In?" Test

Ask yourself: **"If I delete this file and reinstall IWE from scratch — should it reappear on its own, or do I need to restore it from a Backup?"**

- It reappears on its own (it is part of the Platform, identical for all users) → **L1**.
- I need to restore it myself — it is mine and mine alone (my Telegram chat_id, my Linear workspace, my personal rules) → **L3**.
- It is temporary — the Practice is still being validated and will either become L1 or be discarded → **L2**.

## 4. Common Question: "Does Everything Have to Live in the Repository Clone?"

No — and that is the whole point of the separation. The Repository clone (the git-tracked part) holds L1 (shared by everyone) and L2 drafts. L3 — your personal data and settings — also physically lives nearby (in `extensions/`, `params.yaml`), but the `.gitignore` and Repository structure mark that part as "do not touch on update". This is not two different locations on disk. It is two different rules for handling the same file tree.

## Further Reading (for Those Writing Code or Skills)

A more technical version of this same division is in [CONTRIBUTING.md, section "Architecture: Three Layers"](../../CONTRIBUTING.md#architecture-three-layers) (in English, for those preparing a pull request to the Platform) and in [author-mode SKILL.md §9](../../.claude/skills/author-mode/SKILL.md) (for authors maintaining their own fork of the Template).

