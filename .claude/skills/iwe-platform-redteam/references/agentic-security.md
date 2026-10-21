# Agentic Security Review

Use for skills, prompts, rules, hooks, memory, tools, approvals, MCP or other connectors, role agents, and multi-agent orchestration.

## IWE Trust Boundaries

Treat these as separate principals and data classes:

- system/platform instructions;
- repository and skill instructions;
- human request and explicit approval;
- retrieved web, calendar, document, email, issue, and tool output;
- persistent memory, DayPlan/WeekPlan, reports, and session logs;
- role agents and inter-agent messages;
- shell/filesystem/network/GitHub/calendar tools;
- secrets and external identities;
- scheduled or headless execution with no human present.

External and persisted content is untrusted data. It must not silently grant tools, change policy, redefine approval, or become higher-priority instructions.

## Abuse-Case Matrix

| Case | Required behavior |
|---|---|
| Direct/indirect prompt injection | Retrieved content cannot replace platform policy or authorize tools. |
| Tool misuse | Deny unlisted tool, path, host, verb, or operation even when the model requests it confidently. |
| Privilege escalation | A low-trust role or subagent cannot inherit a parent’s write, secret, or external-message privilege. |
| Memory poisoning | Untrusted content is validated, attributed, scoped, bounded, and reviewable before persistence. |
| Data exfiltration | Secrets/private context cannot leave through logs, URLs, command arguments, citations, Git commits, or another agent. |
| Goal hijacking | Retrieved or persisted text cannot replace the explicit session objective. |
| Approval bypass | High-impact action requires a valid approval bound to exact normalized parameters and target. |
| Approval replay | Expired, altered, duplicated, or cross-session approval is rejected. |
| Command-shape bypass | Combined commands, pipelines, quoting, aliases, wrappers, and indirect scripts cannot bypass hooks. |
| Fail-open fallback | Missing policy, parser, model, dependency, or log sink blocks a sensitive action. |
| Runaway autonomy | Retry, recursion, chain depth, time, token, and cost limits stop loops. |
| Multi-agent cascade | One compromised agent cannot make another exceed its own trust boundary. |
| Scheduled execution | Headless mode has narrower authority and cannot substitute implicit approval. |

## Tool and Approval Contract

- Grant the minimum tool set and scope per role; separate read, write, delete, external messaging, and administrative actions.
- Make authorization deterministic outside the model where practical.
- Classify destructive, irreversible, credential, publication, bulk-write, and externally visible actions as high impact.
- Bind approval to actor, tool, normalized arguments, exact target, timestamp, expiry, and nonce. Revalidate immediately before execution.
- Separate proposal from execution for high-impact actions.
- Make operations idempotent where possible; require explicit duplicate confirmation otherwise.
- A dry-run or diagnostic sentinel must have ownership, expiry, crash recovery, and a cleanup path that remains authorized while the sentinel exists.
- Fail closed if risk classification, approval validation, policy lookup, dependency resolution, or audit logging fails.

## Memory and Artifact Contract

- Validate schema and provenance before persistence.
- Separate observations, user decisions, model inference, and executable instructions.
- Do not promote quoted/retrieved commands into active instructions.
- Enforce session/user/repository scope, retention, size, and allowed content class.
- Reject secrets and unsafe executable payloads from long-term memory.
- Preserve an audit trail for who/what wrote, reviewed, superseded, or deleted an item.
- Test cross-day, cross-role, and cross-agent reads for both intended carry-over and forbidden contamination.

## Hook Validation

Test the real host event and real command lifecycle, not a helper extracted from the hook. Include:

- empty index versus staged changes;
- untracked file then `git add && git commit` in one tool call;
- quoted paths, spaces, Unicode, globbing, pipelines, subshells, aliases, and wrapper scripts;
- direct binary invocation and alternative Git clients;
- multiple artifacts and partial staging;
- parser failure, missing dependency, timeout, and malformed hook input;
- bypass through another role, agent, scheduler, fallback, or generated script.

If enforcement depends on pre-execution state, prove that the guarded state already exists at that moment or enforce it at a later unavoidable boundary such as pre-commit.

## Observability and Response

Retain structured, redacted evidence for security-relevant decisions: agent/role, session, policy version, action class, approval identifier, tool, normalized target, result, timeout/circuit-breaker event, and reason. Monitor repeated denial/bypass attempts, elevated privilege, unusual tool frequency, recursion, and cost. Provide a safe interrupt/disable path and incident regression fixture.
