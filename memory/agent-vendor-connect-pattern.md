---
description: Pattern for connecting a new vendor agent to IWE and simple selection
  between connected agents
metadata:
  domains:
  - reference
  - agent-architecture
  horizon: warm
  modified: 2026-07-28 12:49:31.166000+00:00
  node_type: memory
  originSessionId: c962bd9f-0f47-43ca-9cb5-f5c3cd8ee516
  owner: platform
  schema_version: 1
  status: active
  type: reference
  valid_from: 2026-07-28
name: agent-vendor-connect-pattern
---

# Connecting a Vendor Agent to IWE

> **Verified in practice:** multiple vendor agents are connected simultaneously to a shared working tree and coordinate on the same files via locks without conflicts.

## Pattern A — Connecting a New Vendor Agent

1. The agent reads `AGENTS.md` in the root of the working tree — the shared minimum ruleset for file agents (not the Claude-specific CLAUDE.md).
2. If the agent edits Repository files in parallel with other agents, it connects to the local gateway (file-lock) under its own agent identifier and registers as an independent MCP client (not through a Claude-orchestrated wrapper — see "Difference from the peer-adapter scenario" below).
3. A commit attribution line is created (`Co-Authored-By: <Agent> <noreply@vendor-domain>`).
4. If the agent has its own Skill discovery mechanism, point it at the shared skills folder (following the pattern of already-connected agents). If not, skip this step — it is not a blocker.

## Pattern B — Simple Selection of Which Connected Agent Handles a Task

A table of "which agent for which task type" is kept in the user's project Memory and is extended as new agents are connected. The user (or an agent before starting work) checks the table manually — no new tool is required.

**Trigger for revising the table:** recurring task-routing errors, or a real change in the capabilities of already-connected agents — not a one-off preference.

## Difference from the Peer-Adapter Scenario (Important Distinction)

The wrapper adapter (a headless call from one agent to another, with a PII filter and content guard) is a DIFFERENT scenario: one agent orchestrates a second as a Peer partner inside a conversational Session (one writes, the other critiques). It is not a model for a "simply connected" file agent from Pattern A above — in Pattern A the agent works independently and is not invoked as a subordinate process.

## Coordination Mechanism (Technical Basis of Pattern A)

The local gateway maintains a shared lock manager. Each agent connects through a bridge (stdio↔socket) that passes the agent identifier during the MCP handshake. Agent identification uses an environment variable passed to the bridge process — there is no separate API call for registration.

Coordination on a shared file:
1. Before editing → `acquire_file_lock`.
2. After committing → `release_file_lock`.
3. Lock collision → backoff, or switch to a different file.
4. Architectural disagreement between agents → escalate to the user; agents do not resolve it between themselves.
