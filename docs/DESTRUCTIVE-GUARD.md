# Protection Against Irreversible Commands (destructive-guard)

The hook `.claude/hooks/hooks/destructive-guard.sh` checks the text of every Bash invocation before execution and blocks recognized dangerous forms: `git add -A`, `git push --force`, `git reset --hard`, destructive `git clean`, `git rm -r -f`, `DROP`/`TRUNCATE` via `psql`/`mysql`/`sqlite3`, repository deletion on GitHub, and recursive forced `rm`. For `git clean`, the hook permits a pass-through only when a valid `-n`/`--dry-run` is recognized: the absence of `-f` alone does not prove safety when `clean.requireForce=false`. Exit code 2 = command blocked; the agent sees the reason. Recognition boundaries are listed below. The hook does not prove the safety of arbitrary shell code.

## How to Delete Directories

Any recognized `rm` invocation with recursion and force flags (`-rf`, `-r -f`, `-Rf`, `--recursive --force`, `/bin/rm`, `find -exec rm`, `xargs rm`, `bash -c "rm -rf …"`) is blocked, including paths inside `/tmp`. The hook also recognizes `bash -o pipefail -c`, `bash -O extglob -c`, `bash -c --`, a literal shell name before a heredoc (`bash<<EOF`, `/bin/bash<<-EOF`, `'bash'<<'EOF'`), and the name `RM` on case-insensitive file systems. For verified forms of a single literal command, the hook associates the heredoc body with its recipient, including prefix forms `<<EOF bash` and `0<<SQL psql`: text destined for a plain `cat` remains data; code destined for a shell or SQL client is checked. Verified non-nested `if`, `for`, `while`, `until`, `select`, and `case` constructs are also recognized; this is not a full Bash syntax parse. When an assignment, redirection, or wrapper precedes `<<`, the body is retained for checking if a literal shell or SQL client appears on the right and no data command is recognized on the left. For a literal shell or SQL client, the heredoc body is retained for checking on any FD: `/dev/fd/N` or a redirection chain may deliver it to an interpreter. Therefore `bash 2<<EOF` containing dangerous text may be rejected, even though that redirection does not feed the body to stdin; the hook does not prove the final FD graph. An ambiguous header may produce a false rejection. Branches are checked conservatively: an unreachable branch containing a shell may trigger a rejection. A dynamic command name or a construct assembled by substitution remains outside the guarantee. The reason: the deletion target depends on variables, `cd`, symlinks, and substitutions that are only known at execution time, so safety cannot be proved from the command text alone (a `/tmp/` path in a neighboring command once permitted deletion of entirely different directories, issue #940).

Instead, use the wrapper to run the same command with the same flags and targets:

```bash
.claude/bin/guarded-rm -rf "$TMPDIR/build"
```

At execution time the wrapper resolves the real path of each target (symlinks and `..` are expanded) and deletes only within roots listed in the registry `.claude/config/guarded-rm-roots.txt` (defaults: `/tmp`, `$TMPDIR`, `.claude/worktrees` of the workspace). The root itself is never deleted. A path outside the roots, an empty target, or a registry or normalization failure causes rejection without deletion.

Add a directory for permitted deletion by appending a line to the registry (data, not shell). The registry lives in the workspace and is not protected from agent modification, so it is a convenience, not a security boundary against a hostile agent.

The checked text accounts for simple sequential assignments of a literal command name: `x=rm; $x -rf build`, `${x}`, and `"$x"`. Value reassignment and `unset` are tracked; an ambiguous value in command position causes rejection. Single quotes and an escaped dollar sign remain literal text. This is not evaluation of arbitrary shell variables.

For adjacent `echo/printf | sh/bash` patterns, the hook checks the text delivered to the shell as a program. For `printf`, the sequences `%s`, `%%`, `\n`, `\t`, `\r`, and `\\` are supported; any other format specifier or escape in such a pair causes rejection. For `echo`, the flags `-n`, `-e`, and `-E` are permitted, but escape sequences are not evaluated and cause rejection. Data not passed to an executing shell is not checked as a program; `bash -c ...` and `bash script.sh` do not treat stdin as a program. A forced refspec `git push origin +main` is blocked; a plain push and `--force-with-lease` without a leading `+` remain permitted.

## Fail Closed

Claude Code blocks a command only on exit code 2. Therefore any other hook exit (missing `jq` or `perl`, a `grep` failure, an unexpected error under `set -e`) also becomes a block, marked as "verification error" rather than a pass-through. This rule applies to a check failure; an unrecognized dangerous command may complete the check with code 0.

## Human Bypass

Set `CC_ALLOW_DESTRUCTIVE_INPUT=1` in the pilot's real shell from which Claude Code is launched (the hook reads its process environment; the agent cannot set the variable for itself). This is not a one-time skip for a single command: while the variable is present in the environment, the hook skips all commands in that process — meaning the entire agent Session — without checking. Set it only for the duration of the required operation, then restart Claude Code without the variable.

## Outside the Guarantee

The hook sees only the command text. It does not catch: deletion via Python or other languages, `find -delete`, a dynamic command name via alias/function/unknown variable, intentional bypass, an incorrect target selection within a permitted tree, a race between the check and deletion inside `guarded-rm`, a sequence of `xargs` invocations (this is not a transaction), or edits to the root registry via a file-write tool.

Compound shell commands outside the verified non-nested forms may deliver a heredoc to an inner interpreter without recognition — for example, `if true; then if true; then bash; fi; fi<<EOF`, a nested `case`, or `{ case x in x) bash;; esac; }<<EOF`. Conservative false rejections are also possible: in `{ printf bash; cat; }<<EOF` the word `bash` is data for `printf`, but the hook may treat it as an executable command name; `&>/dev/null cat <<EOF bash` may also be rejected even though the body goes to `cat`. Do not treat the absence of a rejection as proof that a nested construct is safe.

The hook also passes through:

- `rm -r`, `rm -R`, and `rm --recursive` without a force flag (`-f`, `--force`). In an agent invocation, such deletion is equally irreversible: without a terminal, `rm` does not prompt for confirmation and removes the entire tree, including read-only files (for example, `.git` objects).
- The string executed by `git submodule foreach '…'`: the hook treats words after `git` as git arguments and does not parse them as commands, so `git submodule foreach 'rm -rf build'` passes through.
- Script text from a here-string (`bash <<<`, `sh -s <<<`) or an arbitrary source in a `| sh` pipeline (for example, `curl ... | sh`). Literal `echo/printf | sh/bash` and `cat <<EOF | bash` are checked; this does not cover binding of any data source to a shell.
- Command substitution inside double quotes, for example `echo "$(rm -rf …)"`, or in backticks. The text `$(...)` is executed by the shell, even though it remains part of an argument from the current parser's perspective.
- Substitution inside an unquoted heredoc for a write command, for example `cat <<EOF` with `$(rm -rf …)` in the body: the shell performs substitution before passing the text to `cat`, and the hook discards the body as data.
- Delivery of a heredoc body to a shell via process substitution, for example `cat <<EOF > >(bash)`: the hook does not yet associate this path with an executing shell.
- All commands of any process whose environment contains `CC_ALLOW_DESTRUCTIVE_INPUT=1` (see "Human Bypass").

These are known limitations #1002, not permission to delete data using such methods. Use `guarded-rm` for deletion; for other forms, follow the general rule for coordinating irreversible actions.

## Verification

```bash
python3 .claude/hooks/tests/destructive-guard/hook_cases.py                 # hook and description checks
python3 .claude/hooks/tests/destructive-guard/long_cases.py                 # long commands (70 KB)
python3 .claude/hooks/tests/destructive-guard/guarded_rm_cases.py .claude/bin/guarded-rm
bash .claude/hooks/tests/test-destructive-guard-executed-command-scope.sh
```

The test suites can be run after a Platform update: `hook_cases.py` passes commands to the hook as data, and `guarded_rm_cases.py` checks deletion only within temporary directories.