# Runtime and Integration Contracts

Use for Day Open/Close, extension graphs, roles, launchd/systemd/cron, calendar, Git operations, Python helpers, and generated runtime.

## Delivery Closure

A feature is operationally delivered only when all layers agree:

1. canonical source and generator input;
2. generated artifact;
3. manifest ownership, hash, mode, exclusions, and deprecations;
4. fresh-install destination;
5. existing-install update or migration destination;
6. consumer lookup path;
7. transitive scripts, defaults, fixtures, schemas, imports, and resolvers;
8. runtime or scheduled invocation;
9. exit propagation and truthful diagnostics;
10. observable user-facing postcondition.

Source-tree CI, repository presence, or manifest presence proves only one layer.

## Ownership Model

The repository must explicitly classify each installed path:

- platform-managed: replaced only by verified platform release logic;
- generated/derived: reproducibly rebuilt, never hand-patched as the durable fix;
- user-owned: never overwritten or deleted by default;
- merge-managed: changed only through an explicit previewable merge/migration;
- deprecated platform-owned: removable only with ownership/provenance evidence.

Use synthetic sentinels to test user-owned preservation. Do not use real customizations.

## Day Open

Test manual and scheduled paths separately. Require one canonical entry point and trace the actual Strategist/headless invocation.

Verify:

- `before -> core -> after -> checks` ordering and nonzero propagation;
- extension discovery at the installed path;
- platform defaults installed without overwriting user extensions;
- root/template/runtime/governance paths resolve from documented configuration;
- calendar and knowledge inputs distinguish missing, empty, stale, applied, pending, and parse failure;
- carry-over writer and all readers use the same session/report layout;
- LLM failure, dependency failure, or failed checks cannot return success;
- dated DayPlan is structurally valid and contains no unresolved state beyond explicit policy;
- commit/push occurs only after checks pass;
- status, heartbeat, counters, and diagnostics describe the actual result.

An `XFAIL`, fallback-only result, zero discovered checks, or source-only dependency means Day Open is not end-to-end complete.

## Day Close and Git

Verify:

- checkpoint checks run before commit or push;
- validation cannot be bypassed by combined command shape;
- dirty, untracked, partially staged, detached, no-remote, non-fast-forward, offline, and authentication cases are truthful;
- an optional remote sync failure does not corrupt local work, while a required sync failure does not report completion;
- session/archive paths written by Day Close are the paths Day Open reads;
- close is idempotent or detects a duplicate explicitly;
- secrets and temporary runtime directories never enter commits or cloud backup.

## Roles and Scheduled Automation

Check without activating a real user service:

- generated plist/unit/cron content in a disposable destination;
- executable path, working directory, label, environment, and log paths;
- setup ordering: prerequisites exist before activation;
- actual production shell and interpreter resolver;
- update/incomplete marker blocks mutating roles;
- overlapping invocations, stale lock, crash recovery, timeout, and retry cap;
- headless authority is narrower than interactive authority;
- failure propagates to service status and observable diagnostics.

CI stubs such as `SETUP_CI` do not prove real launchd/systemd semantics. Include a real supported-platform smoke job when the platform contract claims it.

## Runtime Build

- Build only from pinned platform inputs and explicit configuration.
- Fail closed on missing generator, placeholder, dependency, or required artifact.
- Record source/manifest/config identities in the runtime receipt without secrets.
- Verify runtime completeness from the installed projection, not the source checkout.
- Rebuild failure must not silently retain a misleading “current” version marker.
- Patch the source or generator, never the derived runtime, for durable fixes.
