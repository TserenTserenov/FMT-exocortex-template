# Protection Against Irreversible Commands (destructive-guard)

The hook `.claude/hooks/destructive-guard.sh` inspects every command the agent is about to run in Bash and blocks irreversible ones: `git add -A`, `git push --force`, `git reset --hard`, `git clean -fdx`, `git rm -r -f`, `DROP`/`TRUNCATE` via `psql`, repository deletion on GitHub, and recursive forced `rm`. Exit code 2 means the command is blocked; the agent receives the reason.

## How to Delete Directories

Plain `rm` with recursion and force flags (`-rf`, `-r -f`, `-Rf`, `--recursive --force`, `/bin/rm`, `find -exec rm`, `xargs rm`, `bash -c "rm -rf …"`) is always blocked, including inside `/tmp`. The reason: the deletion target depends on variables, `cd`, symlinks, and substitutions that are only known at execution time, so safety cannot be proven from the command text alone. (A `/tmp/` path in an adjacent command once allowed deletion of entirely different directories — issue #940.)

Use the wrapper instead, with the same flags and targets:

```bash
.claude/bin/guarded-rm -rf "$TMPDIR/build"
```

At execution time, the wrapper resolves the real path of each target (symlinks and `..` are expanded) and deletes only within the roots listed in `.claude/config/guarded-rm-roots.txt` (defaults: `/tmp`, `$TMPDIR`, `.claude/worktrees` of the workspace). The root itself is never deleted. A path outside the allowed roots, an empty target, a Registry failure, or a normalization failure all result in refusal without deletion.

To allow deletion of a custom directory, add it as a line in the Registry (plain data, not shell). The Registry lives in the workspace and is not protected from agent modification, so it is a convenience feature, not a security boundary against a hostile agent.

## Fail Closed

Claude Code blocks a command only on exit code 2. Therefore any other hook exit (missing `jq` or `perl`, a failed `grep`, an unexpected error under `set -e`) also becomes a block, marked as a "verification error" rather than a pass-through.

## Human Bypass

Set `CC_ALLOW_DESTRUCTIVE_INPUT=1` in the real shell of the Pilot from which Claude Code is launched. The hook reads its own process environment; the agent cannot set this variable for itself. This is not a one-time skip for a single command: as long as the variable is present in the environment, the hook skips all commands in that process — meaning the entire agent Session — without inspection. Set it only for the duration of the required operation, then restart Claude Code without the variable.

## Outside the Guarantee

The hook sees only the command text. It does not catch: deletion via Python or other languages, `find -delete`, deliberate bypasses, incorrect target selection within an allowed tree, a race between the check and the deletion inside `guarded-rm`, a series of `xargs` calls (this is not a transaction), or edits to the roots Registry via a file-write tool.

The hook also passes through:

- `rm -r`, `rm -R`, and `rm --recursive` without a force flag (`-f`, `--force`). In an agent call, such deletion is equally irreversible: without a terminal, `rm` does not prompt for confirmation and removes the entire tree, including read-only files (for example, `.git` objects).
- A string executed by `git submodule foreach '…'`: the hook treats words after `git` as git arguments and does not parse them as commands, so `git submodule foreach 'rm -rf build'` passes through.
- Any commands in a process whose environment contains `CC_ALLOW_DESTRUCTIVE_INPUT=1` (see "Human Bypass").

## Verification

```bash
python3 .claude/hooks/tests/destructive-guard/hook_cases.py                 # 173 hook and description checks
python3 .claude/hooks/tests/destructive-guard/long_cases.py                 # long commands (70 KB)
python3 .claude/hooks/tests/destructive-guard/guarded_rm_cases.py .claude/bin/guarded-rm
bash .claude/hooks/tests/test-destructive-guard-executed-command-scope.sh
```

The test suites can be run after a Platform update. They read the hook located alongside them and execute nothing — commands are passed to the hook as data.