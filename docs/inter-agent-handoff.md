<body>
# Inter-Agent Handoff: Kimi ↔ Claude Code

> Role: architectural pattern WP-207 H6  
> Scope: context transfer between agents in different VS Code windows  
> Status: active

## Problem

When using two agents in different VS Code windows (Kimi in one, Claude in the other), context is not transferred automatically. Each window is an isolated Session.

## Three Handoff Methods (by reliability)

| # | Method | When | Reliability |
|---|--------|------|-------------|
| 1 | **Git commits + Co-Authored-By** | Task >30 min, multiple Phases | ⭐⭐⭐⭐⭐ |
| 2 | **`.handoff.md` bridge file** | Fast Iteration 5–15 min | ⭐⭐⭐⭐ |
| 3 | **Branch-based relay** | Complex tasks, multiple agents | ⭐⭐⭐⭐⭐ |

## `.handoff.md` Template

Place in the IWE root (`~/IWE/.handoff.md`). Lifetime ≤4 hours — stale handoffs are dangerous.

```markdown
# Handoff: [WP-XXX]
## From: [Agent] ([role]) — [date/time]
- **Context:** what was done, why this path was chosen
- **Decision:** final decision / ADR / commit
- **Constraints:** what does NOT work, what to watch out for
- **Next step:** specific action for the receiving agent

## To: [Agent] ([role])
- [ ] Step 1
- [ ] Step 2
```

## Git trailer (required for cross-agent commits)

```bash
git commit -m "feat: ..." \
  --trailer "Co-Authored-By: Claude <noreply@anthropic.com>" \
  --trailer "Co-Authored-By: Kimi <noreply@moonshot.ai>"
```

## Default Workflow

```
Claude (assessment / archgate / think)
  → git commit --trailer "Co-Authored-By: Claude ..."
  → Kimi reads git log / .handoff.md
  → Kimi (implementation / coding / tests)
  → git commit --trailer "Co-Authored-By: Kimi ..."
  → Claude reads diff → verify
```

## Constraints

- **Lock collision:** both agents via MCP gateway → `acquire_file_lock` is required
- **Context window:** `.handoff.md` ≤150 lines (Sawtooth compression — WP-207 P3)
- **Freshness:** handoff becomes stale within hours → mandatory probe before start

</body>