# Protection Against Irreversible Commands (destructive-guard)

The Hook `.claude/hooks/destructive-guard.sh` inspects every command the agent is about to run in Bash and blocks irreversible ones: `git add -A`, `git push --force`, `git reset --hard`, `git clean -fdx`, `git rm -r -f`, `DROP`/`TRUNCATE` via `psql`, repository deletion on GitHub, and recursive forced `rm`. Exit code 2 means the command is blocked; the agent receives the reason.

## How to Delete Directories

Plain `rm` with recursion and force flags (`-rf`, `-r -f`, `-Rf`, `--recursive --force`, `/bin/rm`, `find -exec rm`, `xargs rm`, `bash -c "rm -rf …"`) is always blocked, including inside `/tmp`. The reason: the deletion target depends on variables, `cd`, symlinks, and substitutions that are only known at execution time, so safety cannot be proven from the command text alone (a `/tmp/` path in an adjacent command once triggered deletion of entirely different directories — issue #940).

Instead, run the same command with the same flags and targets through the wrapper:

```bash
.claude/bin/guarded-rm -rf "$TMPDIR/build"
```

At execution time, the wrapper resolves the real path of each target (symlinks and `..` are expanded) and deletes only within the roots listed in the Registry `.claude/config/guarded-rm-roots.txt` (defaults: `/tmp`, `$TMPDIR`, `.claude/worktrees` of the workspace). The root itself is never deleted. A path outside the roots, an empty target, a Registry failure, or a normalization failure all result in refusal without deletion.

Add a custom directory for permitted deletion by appending a line to the Registry (data only, not shell). The Registry lives in the workspace and is not protected from agent edits, so it is a convenience feature, not a security boundary against a hostile agent.

## Fail Closed

Claude Code blocks a command only on exit code 2. Therefore, any other exit from the Hook (missing `jq` or `perl`, a `grep` failure, an unexpected error under `set -e`) also results in a block, marked as "verification error" rather than a pass-through.

## Human Override

For a one-time exception: set `CC_ALLOW_DESTRUCTIVE_INPUT=1` from the pilot's real shell. The Hook reads its own process environment; the agent cannot set this variable for itself.

## Outside the Guarantee

The Hook sees only the command text. It does not catch: deletion via Python or other languages, `find -delete`, intentional bypass, incorrect target selection within a permitted tree, a race between the check and deletion inside `guarded-rm`, a series of `xargs` calls (this is not a transaction), or edits to the roots Registry via a file-write tool.

## Verification

```bash
python3 .claude/hooks/tests/destructive-guard/hook_cases.py                 # 168 hook cases
python3 .claude/hooks/tests/destructive-guard/long_cases.py                 # long commands (70 KB)
python3 .claude/hooks/tests/destructive-guard/guarded_rm_cases.py .claude/bin/guarded-rm
bash .claude/hooks/tests/test-destructive-guard-executed-command-scope.sh
```

The test suites can be run after a Platform update. They read the Hook alongside them and execute nothing — commands are passed to the Hook as data.