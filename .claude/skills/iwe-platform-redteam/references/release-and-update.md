# Release and Update Security

Use for release candidates, updater changes, manifest changes, announcements, tags, and publication decisions.

## Immutable Release Receipt

Bind these to one intended revision:

1. final source SHA, including conflict resolution;
2. validation run and its actual checkout SHA;
3. generated manifest version, digest, file set, exclusions, and deprecated paths;
4. tag and peeled tag SHA;
5. GitHub Release object and published assets;
6. release workflow run and artifact digest or provenance attestation;
7. updater-resolved ref for bootstrap, manifest, and every payload;
8. announcement emitted only after the release object and required gates exist.

Fail if any identity differs. A tag-exists skip, version bump, changelog entry, or release announcement is not publication evidence.

## Integrated-Tree Gate

- For overlapping PRs, inspect the combined merge tree, not the individual green heads.
- Regenerate the manifest after the final merge/conflict resolution.
- Require all release gates on the exact final SHA.
- Treat any post-validation change as invalidating the previous receipt.
- Block branch or release publication when required status checks are missing, skipped, stale, or red.

## Manifest Contract

Verify independently:

- completeness: every platform-owned delivered file appears exactly once;
- accuracy: path, hash, mode, version, and classification match the final tree;
- exclusions: excluded tests or developer files cannot be required by an installed consumer;
- deprecations: no path is simultaneously delivered and deleted;
- transitive closure: scripts, generators, defaults, schemas, fixtures, imports, and resolvers needed at runtime are delivered;
- deterministic regeneration: two generations from the same tree are identical;
- clean tree: regeneration leaves no unexplained diff.

Build an installed projection from the manifest alone and run delivered consumers there.

## Updater Threat Cases

Adapt The Update Framework threat model even if IWE does not implement TUF metadata:

- **rollback**: server or cache offers an older release than the client has seen;
- **freeze**: the client is kept on known but stale release metadata;
- **mix-and-match**: bootstrap, manifest, scripts, or payloads come from different revisions;
- **moving-ref drift**: `main`, a mutable tag, or latest-release changes during one transaction;
- **partial publication**: metadata is visible before every target file is available;
- **arbitrary payload**: a file does not match authenticated release metadata;
- **fast-forward/version poisoning**: implausible metadata version strands future updates;
- **cache poisoning**: stale or attacker-controlled cache wins over pinned content.

Expected boundary:

- resolve one immutable release identity once;
- verify every downloaded target against trusted metadata from that same snapshot;
- reject older-than-trusted versions unless an explicit, separately authorized rollback mode exists;
- never combine files from different release identities;
- stage, verify, then atomically commit the transaction;
- retain a recoverable prior state until postprocessing succeeds;
- report an incomplete or unverifiable update as failure, never as current.

## Self-Update Contract

The updater may replace its managed copy only through an explicit bootstrap protocol:

1. current updater resolves and verifies the release;
2. new updater is staged under a separate path;
3. digest and executable mode are verified;
4. control transfers once to the staged version with the pinned release identity;
5. a loop/re-exec guard prevents recursion;
6. failure preserves a runnable recovery path;
7. second invocation is a clean no-op.

Generic in-place overwrite of the executing script is a release blocker.

## Release Decision

`GO` requires one immutable receipt, manifest-only projection, supported upgrade matrix, negative controls, and non-skipped exact-SHA CI. Artifact attestations strengthen provenance but do not prove correctness; the verified artifact must still pass IWE policy and behavior tests.
