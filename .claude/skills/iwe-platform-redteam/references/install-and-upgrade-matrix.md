# Install and Upgrade Matrix

Use for setup, update, migration, runtime rebuild, interpreter resolution, and portability claims.

## Fixture Rules

- Use only synthetic content. Never seed from a real consumer workspace.
- Create random sentinel bytes in every documented user-owned class such as `extensions/`, existing `params.yaml`, local settings, secrets placeholders, and governance repositories.
- Record pre-run hashes, modes, Git status, and ownership classification.
- Isolate environment routing and network caches. Pin the candidate by immutable SHA or tag.
- Capture stdout, stderr, exit status, installed manifest identity, transaction markers, and postconditions.

## Minimum Matrix

Test independently:

1. documented fresh install;
2. previous release -> candidate;
3. oldest explicitly supported release -> candidate;
4. every release boundary that changed updater, manifest, ownership, generator, runtime, or layout semantics;
5. candidate -> candidate second run;
6. supported macOS and Linux shells/runtimes;
7. serial and parallel paths when both are production behavior.

If the project promises upgrades from every historical supported version, test every promised edge or narrow the documented support range before release.

## Assertions

For each cell require:

- preview and apply resolve the same immutable release;
- updater bootstrap, manifest, and payloads use that identity;
- manifest verification succeeds before live replacement;
- platform-owned files match expected hashes and modes;
- user-owned sentinels remain byte-identical;
- deprecated platform-owned files are removed only when provenance proves ownership;
- unknown or modified files are preserved or require explicit resolution;
- runtime rebuild succeeds with no unresolved placeholders;
- transaction marker closes only after all required postprocessing;
- failures produce a nonzero exit and accurate diagnostic;
- no unexpected dirty state or orphan staging files remain;
- second run downloads nothing unnecessary, changes nothing, and returns success.

## Failure Injection

Inject failures at these boundaries:

- manifest unavailable, truncated, malformed, stale, or wrong hash;
- payload missing, wrong hash, wrong mode, or served from another revision;
- one parallel download fails while others succeed;
- disk write, rename, runtime build, migration, or postprocessing fails;
- process interruption before and after transaction marker creation;
- interpreter exists but required module is absent;
- resolver finds a non-default valid interpreter;
- generator or fixture is excluded from delivery;
- stale incomplete marker or owner token remains from a crashed run;
- updater encounters a user modification or merge conflict;
- rerun follows every failure.

The updater must either finish the complete contract or leave an explicit recoverable incomplete state. It must never mark the version current while required files or migrations remain old.

## Shell and Python Portability

- Execute with the actual declared shell binary. `bash` on a modern runner does not prove macOS Bash 3.2 compatibility.
- Scan every production entry point, sourced helper, role installer, cron/launchd branch, and generated script for unsupported features.
- Use one shared Python resolver contract for all `.py` consumers.
- Test system Python without PyYAML and an alternate Homebrew/Nix interpreter with it.
- Missing dependencies must name the dependency and corrective path; suppressed parse errors must not become false configuration diagnostics.
- Declare dependencies and ensure documented setup installs or verifies them for the actual consumer interpreter.

## Installed Projection

Create a tree from manifest-delivered files only, then run every delivered validator, generator, role, hook, and runtime consumer. Fail when a delivered file relies on an excluded test fixture, source-only default, undeclared Python module, or developer checkout path.
