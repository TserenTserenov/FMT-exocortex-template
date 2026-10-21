# Personal Data Residency in IWE

> Date: 2026-07-11 · Status: template principle (WP-475)

**If you arrived here from [DATA-POLICY.md](DATA-POLICY.md):** that document covers data the **platform** collects about you (Profile, Progress, digital twin). This document covers data **you** bring into your IWE from external sources (health, calendar, working time) and where that data is and is not allowed to go.

---

## 1. Principle

Data you place inside your IWE perimeter does not leave it without your explicit consent. Reading data the platform collects into your IWE is normal and does not require a separate permission each time. The question is not where IWE reads data from, but where the outbound stream can go. Assembly (computation, generation) based on your data always happens on the IWE side, not on the platform.

**"Residency" here is not a geographic concept** (not server jurisdiction, as in the industrial term *data residency*) **— it is a control rule**: data you place inside your IWE perimeter does not leave it without explicit consent. The term is borrowed from another domain and redefined here.

**"IWE perimeter"** is not a physical location or a trust level assigned to a service. It is a question of substrate: the perimeter is where the tree of your personal IWE is physically versioned (`memory/`, `extensions/`, `params.yaml`, your strategy). This means your local machine plus your private git hosting (GitHub, GitLab, self-hosted — any). Everything else — platform Neon, Railway, WakaTime, and other services — is not the IWE substrate. These are external points: some can be read from (inbound stream, always permitted), some can receive data with explicit consent (outbound stream, requires opt-in).

Example: the digital twin in Neon is not part of the perimeter, even if IWE reads it regularly (inbound stream, permitted). Your private git repository is part of the perimeter, because it is the storage location for the IWE tree itself, not a data destination.

> Terminology note: [DATA-POLICY.md §2](DATA-POLICY.md) refers to the server-side of the platform as "IWE (server side)" in one table alongside your personal files. In this document, "IWE" refers only to "your personal instance" — the platform is separate.

---

## 2. Three-Layer Model

Pilot decision, 10.07.2026:

| Layer | What it provides | What it does not do |
|-------|-----------------|---------------------|
| **Platform** | Collects its own data about your activity within the platform (courses, diagnostics, events) and delivers it to your IWE (inbound stream) | Never acts as a transit point or storage for your local data |
| **IWE Template** | Provides the mechanism (data need declaration + consent + Skill inventory) and ready-made recipes for popular sources | Does not impose a specific method for exporting data |
| **User** | Decides and performs their own data export — using a template recipe, a custom Script, or manually | — |

Exporting data from devices and clouds is always your own action. Neither the platform nor the template transfers data on your behalf.

---

## 3. Types of Personal Data

Source: the post "Everyone has an all-knowing AI, but only those who built it themselves have a useful one" (six types of information, four of which are personal):

| Type | Description | Where it typically lives |
|------|-------------|--------------------------|
| **2.1** | Stable facts about you (Profile, goals) | Partly platform (inbound stream to IWE), partly your local notes |
| **2.2** | Operational event stream (health, working time, activity) | Usually a third-party device/service → your local IWE |
| **2.3** | Formalised personal knowledge (your Pack) | Your git hosting |
| **2.4** | Non-formalisable personal practice (decision chronicle, intuition) | Your git hosting (sessions, `memory/`) |

---

## 4. Third-Party Cloud — Two Distinct Cases

Infrastructure that is neither the platform nor the substrate of your IWE (see §1) is also an external point and also requires consent for outbound streams. However, it covers two distinct cases with different risk profiles:

| Subtype | Example | Who manages the infrastructure | Consent |
|---------|---------|-------------------------------|---------|
| **PaaS under your control** | Health data receiver on Railway | You (your account, your instance, deletable at any time) | Required — data physically leaves the device, even if the infrastructure is "yours" |
| **SaaS aggregator** | WakaTime | Third-party service — you do not control the processing | Required — same principle; higher risk: no control over how the service uses the data downstream |

Both cases are outbound streams and require explicit consent. A finer-grained consent strictness model (for example, different UX for the two subtypes) is a question for the Implementation Phase, not this document.

---

## 5. Data Source Recipe Format

Specific data sources are structured as template Extensions (`extensions/`). The general pattern and data need declaration schema are the subject of a separate Phase; a draft example is already outlined in one of the WP-475 sessions.

### 5.1 Mandatory Declaration Rules (Pilot decisions 16.07.2026, WP-476 Phase 1)

- **Schema version (`schema_version`) is required in every data need declaration.** A declaration without a version fails validation — the gate stops the function with a clear error rather than substituting a default version. This ensures the Pipeline registry is built only on top of verified schemas.
- **Pre-grant list requires explicit pilot confirmation.** The sole permanent carrier of install-time permissions is the file `pre-grant.yaml` located alongside the gate Skill (`.claude/skills/residency-gate/`). Each entry must carry `approved_by: pilot` and an `approved_at` date; an entry without confirmation is a blocking load error — a function cannot add itself to the list. Outbound streams (`flow_direction: outbound`) never appear in pre-grant. Deterministic check: `python3 residency-gate.py validate-pre-grant` (candidate for the weekly audit scan in Week Close).

---

## 6. Your Data Inventory

A Skill is planned to help you ask: what data of types 2.1–2.4 do you have and where does it live — instead of manually designing an Integration for each source every time. The location is `.claude/skills/` in the template, alongside other inventory Skills; the specific name and full implementation are the subject of a separate Phase.

---

## Out of Scope for This Phase

- **Back-reference from `DATA-POLICY.md`.** This document references `DATA-POLICY.md`, but not the reverse — `DATA-POLICY.md` is synchronised with an external Pack source (DP.D.035), and editing its content is a decision for the owner of that Pack document, not a task for this Phase.
- **Formal registration of the principle in a Pack** (draft identifiers `DP.SC.475-residency`, `DP.ROLE.475`) — an open question since the first Phase of WP-475, awaiting a pilot decision.
- **Consent mechanism (ResidencyGate)** — data need declaration, consent state, consent request points — designed and passed architectural Assessment within WP-475, but implementation (code) is a separate Phase/child work item.
