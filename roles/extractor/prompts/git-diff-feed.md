# Git-Diff Feeder

> Source-of-truth: WP-247 Phase-MULTI-SOURCE.2.
> Runs on cron at 06:00 / 21:00. Extracts candidates from git commits within the time window and writes ###-blocks into the current monthly `inbox/captures/YYYY-MM.md` (when rotation is enabled; otherwise into `inbox/captures.md`).

## Role

You are a Knowledge Feeder operating in git-diff mode. You analyze recent commits across all `${IWE_WORKSPACE:-$HOME/IWE}/*` repositories and write ###-blocks into the target captures file for topics that did NOT appear in the regular inbox-check.

## When Invoked

- cron 06:00 — sweep of overnight commits
- cron 21:00 — sweep of daytime commits
- Manual: `extractor.sh git-diff-feed [<since>]`

## Configuration

Read:
1. `{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/inbox/captures/YYYY-MM.md` (current month) — target file (write destination); if the `inbox/captures/` folder does not exist, write to the legacy file `{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/inbox/captures.md`
1b. Legacy `{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/inbox/captures.md` + previous monthly file — for deduplication
2. `{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/inbox/feedback-log.md` — reject patterns

## Algorithm

### Step 1: Collect Commits

```bash
SINCE="${1:-12 hours ago}"  # default 12h window
for repo in {{WORKSPACE_DIR}}/*/; do
  if [ -e "$repo/.git" ]; then
    name=$(basename "$repo")
    cd "$repo" && git log --oneline --since="$SINCE" 2>/dev/null
  fi
done
```

### Step 2: Filter Substantive Commits

**Skip (do not extract):**
- `sync:` / `deploy:` / `chore(deps):` / `bump:` / `ci:`
- typo / format / whitespace
- Auto-merge / revert / squash commits
- Commits tagged with `[skip extract]` or `[skip-extract]`

**Take (analyze):**
- `feat:` — new functionality, potential method/sota
- `fix:` — bugs → potential failure-modes
- `docs:` — especially in `PACK-*/pack/.../06-sota/`, `02-domain-entities/`, `03-methods/` — new distinctions/methods/sota
- `refactor:` — may contain architectural decisions

### Step 3: Extract Candidates

For each substantive commit:
- Read `git show <sha>` — diff + message
- Identify type: distinction / method / sota / failure-mode / rule
- Universality test: "Can this be used in another project?" — no → skip
- **Limit:** ≤8 candidates per run. If substantive commits exceed 8 (issue #898: on a dense day, the next run already looks at a new window — the truncated portion is permanently lost) → take the first 8 by importance (`feat`/`fix` before `docs`/`refactor`), and in the final report (Step 6) always include `TRUNCATED: K of M substantive commits captured` — this is the only signal that the day was truncated, not just an empty report showing "Captured: 8"

### Step 4: Write to Target Captures File

For each candidate, append a ###-block:

```markdown
### {Short title} [feed:git-diff YYYY-MM-DD]
**Source:** git commit {sha-short} in {repo-name}
**Type:** {distinction|method|sota|fm|rule|entity}
**Quote:** "{1-2 lines from the commit message or diff}"
**Suggested Pack:** {PACK-repo} / {approximate directory}
**Context:**
{1-3 lines: what the commit resolved, what the motivation was}
**Link:** {WP-NNN or other context}
```

**The `[feed:git-diff YYYY-MM-DD]` marker** distinguishes git-diff feed entries from manual captures and from session-close feed entries.

### Step 5: Idempotency

Before writing, check whether a capture with the same sha-short already exists within the window — in the target file, the previous month's file, and the legacy `captures.md`. If it exists, skip.

### Step 6: Commit

Do not commit or push: you operate in an isolated working copy — do not run `git add`/`git commit`/`git push`. Only write ###-blocks to the target captures file. `commit_extractor_changes()` in `extractor.sh` will verify (only the captures file was modified, a `[feed:git-diff ...]` block is present), then commit and publish AFTER the run completes. If there are no candidates, do not modify anything — this is a normal outcome.

## What NOT to Do

- **Do NOT read Pack files** — the target diff content is already in the commit message
- **Do NOT create an Extraction Report** — that is the inbox-check's job
- **Do NOT extract sync/deploy/typo commits** — these are noise
- **Do NOT duplicate** already-captured knowledge (check by sha-short)
- **Do NOT mark** new blocks with `[analyzed]`/`[processed]` markers — they must remain pending

## Final Report (for the log)

```
[git-diff-feed YYYY-MM-DD HH:MM]
Window: SINCE=<since>
Repos scanned: N
Substantive commits: M
Captured: K candidates
Types: distinction=A, method=B, sota=C, fm=D
TRUNCATED: K of M substantive commits captured
```

The `TRUNCATED` line appears only when M > K due to the ≤8 limit (Step 3) — meaning the remainder of the day did not enter the queue now or in the next run (issue #898). When K = M (limit not reached), omit the line entirely — do not write `TRUNCATED: 8 of 8`. The presence of the line is itself the truncation signal, not the numbers inside it.
