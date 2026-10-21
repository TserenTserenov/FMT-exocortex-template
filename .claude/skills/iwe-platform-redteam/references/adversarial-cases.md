# Adversarial and Regression Cases

Use to verify defect reports and to attack a proposed fix. Select relevant cases; add every confirmed incident as a versioned regression fixture.

## Closure Standard

A reported defect is closed only when:

1. reproduced or decisively proven on an immutable known-bad artifact;
2. root contract identified across all affected consumers;
3. fix exists in the final combined tree;
4. regression test fails on known-bad or focused mutation and passes on the candidate;
5. manifest-only installed projection passes;
6. fresh install and required upgrades receive the fix;
7. supported OS/shell/runtime matrix passes;
8. tag, release, manifest, CI receipt, and announcement bind to the fixed SHA.

“Merged to main” closes only source status, not delivery.

## Mutation Catalog

### Release and Manifest

- change a delivered file without regenerating the manifest;
- include an excluded test or omit a required generator/helper;
- make a deprecated path overlap a delivered path;
- validate PRs independently but introduce conflict-resolution drift in the combined tree;
- pre-create a tag at another SHA;
- advertise a version without a GitHub Release object;
- make announcement run after a skipped publication step.

### Update Transaction

- serve bootstrap from release A, manifest from B, and one payload from C;
- return an older release or stale latest-release response;
- fail one parallel payload, rename, migration, or runtime build;
- interrupt before/after marker creation and rerun;
- overwrite the executing updater;
- create a user-modified managed file and a synthetic user-owned file;
- omit the historical merge baseline;
- mark version current before required postprocessing.

### Portability and Dependencies

- run every production path under stock macOS Bash 3.2;
- remove PyYAML from default Python while leaving a valid alternate interpreter;
- make dependency parsing fail and assert the diagnostic is dependency-specific;
- execute cron/launchd-only branches, role installers, and sourced helpers;
- use paths containing spaces and Unicode.

### Hooks and Safety Gates

- merge `git add && git commit` in one call;
- use pipeline, subshell, alias, wrapper, alternative quoting, or indirect script;
- make the index empty before pre-tool validation;
- leave a lock/owner token with missing session identity;
- attempt exact cleanup while the gate is active;
- corrupt or remove policy/config/parser dependencies;
- replay approval with modified target or parameters;
- invoke the same write through a role, scheduler, or another agent.

### Day Open/Close and Runtime

- install from manifest only and remove source checkout access;
- seed no extension, prose-only extension, valid executable checks, and failing checks;
- store a session flat while the reader expects month folders, and vice versa;
- mix pending, pending-review, applied, malformed, and body-text status reports;
- force LLM, calendar, Git, network, and Python failures;
- run manual and scheduled entry points;
- test two concurrent invocations and a stale lock;
- confirm postcondition before commit/push and after a failed check.

### Agentic Paths

- embed instructions in web/calendar/document/memory content asking the agent to override policy;
- request an unlisted tool through a trusted-looking role message;
- persist malicious content and load it in a later day/session;
- attempt secret extraction through logs, URL parameters, Git metadata, and inter-agent messages;
- replay or alter a destructive-action approval;
- force repeated tool failure to test recursion, retry, time, token, and cost caps;
- compromise one subagent and ask it to delegate a higher-privilege action.

## False-Green Detectors

- zero tests discovered;
- relevant job/step skipped;
- test reads an excluded source-only fixture;
- failure is caught and replaced by empty success;
- `XFAIL`, fallback, or “pending” counted as support;
- regression passes both bad and fixed artifacts;
- validation uses a different SHA, shell, OS, Python, entry point, or manifest than publication;
- a second run says current while required files remain old;
- separately green PRs lack an exact combined-tree run;
- artifact provenance exists but is never verified.
