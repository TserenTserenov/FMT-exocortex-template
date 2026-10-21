# Template: soak-verify

> Verifies service stability over N hours after deploy (pattern WP-277).

## Parameters

| Parameter | Type | Example |
|-----------|------|---------|
| `service_name` | str | `multi-domain-projection-worker` |
| `deploy_commit` | str | `b0558ce` |
| `since` | datetime | 2026-04-28T11:37:00+03:00 |
| `metrics` | list | [throughput, error_rate, lag] |
| `notify_via` | str | `gmail` / `telegram` |
| `recipient` | str | `pilot@example.invalid` (example; specify the actual recipient address) |

## Prompt

```
You are a one-time soak-verify agent for service {{service_name}} (deploy commit {{deploy_commit}} at {{since}}).

## Context

24h after deploy. Verify stability against metrics {{metrics}}.

## Steps

1. Run `git log --oneline -10` in the {{service_name}} repo: check for commits after {{deploy_commit}} containing `revert` / `hotfix` / `fix({{wp}})` → ⚠️ regression.

2. Build an email checklist with specific commands for the pilot (Railway logs, SQL queries, TG alerter check) — the pilot will close the verify locally within 30 min.

3. Send via {{notify_via}} to {{recipient}}:
   - subject: `[{{wp}}] {{n}}h soak verify — checklist ready`
   - body: markdown checklist with verdict ✅ STABLE / ⚠️ NEW COMMIT / 🚨 ROLLBACK

## Checklist (template for email body)

See the full WP-277 prompt as a reference — it contains sections:
- Git status (auto-checked)
- Railway deployment status (what to check)
- Logs for {{n}}h (what to grep)
- Throughput sample (how to calculate)
- SQL lag for {{n}}h (psql query)
- TG alerter channel (what to look for)
- Verdict logic (when to close the Work milestone vs. not close)

## Acceptance

- Email sent to {{recipient}} within 5 min of start.
- Git verdict ✅/⚠️/🚨 included in the body.
- Specific Railway/SQL/TG commands are specified.
```