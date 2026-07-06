<body>
# Testing as Specification

> For developers writing tests for IWE code (MCP services, bot handlers, Scripts). Referenced from [developer-guide.md](developer-guide.md) at the transition between Station 3 (Design) and Station 4 (Work).

## Principle

A test describes system behavior at its **boundary** — what it accepts and what it returns, not how it works internally.

**Order:** write the test (specification) first, then write the code that passes it.

**Contract:** any implementation that passes all boundary tests is acceptable — regardless of internal structure.

## Working With Claude

- Ask Claude to describe the tests first, then write the code.
- If Claude does not understand the boundary — it should ask, not guess.
- Stop signal: if a test breaks when the implementation is replaced with an equivalent one (same input/output, different computation method) — the test is checking an implementation detail, not the contract. Rewrite the test in boundary terms.

## What to Test at the Boundary (Example — MCP Service)

- The list of tools matches what is expected — no extras, no omissions.
- Authorization accepts and rejects correctly.
- Response format matches the declared contract.
- Each tool returns exactly the declared data, nothing more.

## Source

This methodology emerged from a meeting with an external development expert (the Protocol is stored in your governance repo, `{{GOVERNANCE_REPO}}/inbox/`).

</body>