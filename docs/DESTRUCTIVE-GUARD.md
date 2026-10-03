# Protection Against Irreversible Commands (destructive-guard)

The hook `.claude/hooks/destructive-guard.sh` checks the text of every Bash invocation before execution and blocks recognized dangerous forms: `git add -A`, `git push --force`, `git reset --hard`, destructive `git clean`, `git rm -r -f`, `DROP`/`TRUNCATE` via `psql`/`mysql`/`sqlite3`, repository deletion on GitHub, and recursive forced `rm`. For `git clean`, a pass is allowed only when a valid `-n`/`--dry-run` flag is recognized: the absence of `-f` alone does not prove safety when `clean.requireForce=false`. Exit code 2 = command blocked; the agent sees the reason. Recognition boundaries are listed below. The hook does not prove the safety of arbitrary shell code.

## How to Delete Directories

A recognized `rm` invocation with recursion and force flags (`-rf`, `-r -f`, `-Rf`, `--recursive --force`, `/bin/rm`, `find -exec rm`, `xargs rm`, `bash -c "rm -rf …"`) is blocked even inside `/tmp`. The hook also recognizes `bash -o pipefail -c`, `bash -O extglob -c`, `bash -c --`, a literal shell name before a heredoc (`bash<<EOF`, `/bin/bash<<-EOF`, `'bash'<<'EOF'`), and the name `RM` on the filesystem regardless of case. For verified forms of a single literal command, the hook binds the heredoc body to its recipient, including prefix forms `<<EOF bash` and `0<<SQL psql`: text destined for a plain `cat` remains data; code destined for a shell or SQL client is checked. Verified non-nested `if`, `for`, `while`, `until`, `select`, and `case` constructs are also recognized; this is not a full Bash syntax parser. When an assignment, redirection, or wrapper precedes `<<`, the body is retained for checking if a literal shell or SQL client appears on the right side and no data command is recognized on the left. For a literal shell or SQL client, the heredoc body is retained for checking on any file descriptor: `/dev/fd/N` or a redirection chain may pass it to an interpreter. Therefore, `bash 2<<EOF` with dangerous content may be rejected, even though that redirection does not itself feed the body to stdin; the hook does not prove the final file-descriptor graph. An ambiguous header may produce a false rejection. Branches are checked conservatively: an unreachable branch containing a shell name may cause a rejection. A dynamic command name or a construct assembled by substitution remains outside the guarantee. The reason: the deletion target depends on variables, `cd`, symlinks, and substitutions that are known only at runtime, so safety cannot be proven from the command text alone (a `/tmp/` path in a neighboring command once allowed deletion of entirely different directories, issue #940).

Instead, run the same command with the same flags and targets through the wrapper:

```bash
.claude/bin/guarded-rm -rf "$TMPDIR/build"
```

At runtime, the wrapper resolves the real path of each target (symlinks and `..` are expanded) and deletes only within the roots registered in `.claude/config/guarded-rm-roots.txt` (defaults: `/tmp`, `$TMPDIR`, `.claude/worktrees` of the workspace). The root itself is not deleted. A path outside the registered roots, an empty target, a Registry failure, or a normalization failure all cause rejection without deletion.

Add your own directory for permitted deletion by appending a line to the Registry (data, not shell). The Registry resides in the workspace and is not protected from modification by the agent, so it is a convenience mechanism, not a security boundary against a hostile agent.

## Fail Closed

Claude Code blocks a command only on exit code 2. Therefore, any other exit from the hook (missing `jq` or `perl`, a `grep` failure, an unexpected error under `set -e`) also becomes a block, marked as "verification error," rather than a pass. This rule applies to a verification failure; an unrecognized dangerous command may complete verification with exit code 0.

## Human Bypass

Set `CC_ALLOW_DESTRUCTIVE_INPUT=1` in the real shell of the pilot from which Claude Code is launched (the hook reads its own process environment; the agent cannot set the variable for itself). This is not a one-time skip for a single command: as long as the variable is present in the environment, the hook skips all commands in that process — meaning the entire agent Session — without checking. Set it only for the duration of the required operation, then restart Claude Code without the variable.

## Outside the Guarantee

The hook sees only the command text. It does not catch: deletion via Python or other languages, `find -delete`, a dynamic command name via alias/function/variable, deliberate bypass, incorrect target selection within an allowed tree, a race between the check and the deletion inside `guarded-rm`, a sequence of `xargs` invocations (this is not a transaction), or modification of the root Registry via a file-write tool.

Compound shell commands outside the verified non-nested forms may pass a heredoc to an inner interpreter without recognition — for example, `if true; then if true; then bash; fi; fi<<EOF`, a nested `case`, or `{ case x in x) bash;; esac; }<<EOF`. Conservative false rejections are also possible: in `{ printf bash; cat; }<<EOF` the word `bash` is data for `printf`, but the hook may treat it as an executable command name; `&>/dev/null cat <<EOF bash` may also be rejected even though the body goes to `cat`. Do not treat the absence of a rejection as proof that a nested construct is safe.

In addition, the hook passes through:

- `rm -r`, `rm -R`, and `rm --recursive` without a force flag (`-f`, `--force`). In an agent invocation, such deletion is equally irreversible: without a terminal, `rm` does not prompt for confirmation and removes the entire tree, including read-only files (for example, `.git` objects).
- The string executed by `git submodule foreach '…'`: the hook treats words after `git` as git arguments and does not parse them as commands, so `git submodule foreach 'rm -rf build'` passes through.
- Script text that a shell receives via standard input from a here-string (`bash <<<`, `sh -s <<<`) or from a pipeline whose source is outside a literal heredoc in the same command (for example, `printf '%s\n' 'rm -rf …' | sh`). A literal `cat <<EOF | bash` is checked, but the hook does not yet link an arbitrary `| sh` source to the executing shell.
- Command substitution inside double quotes, for example `echo "$(rm -rf …)"`, or inside backticks. The text `$(...)` is executed by the shell, but it remains part of an argument to the current analyzer.
- Substitution inside an unquoted heredoc for a write command, for example `cat <<EOF` with `$(rm -rf …)` in the body: the shell performs the substitution before passing the text to `cat`, and the hook discards the body as data.
- Passing a heredoc body to a shell via process substitution, for example `cat <<EOF > >(bash)`: the hook does not yet link this path to the executing shell.
- Any commands in a process whose environment contains `CC_ALLOW_DESTRUCTIVE_INPUT=1` (see "Human Bypass").

These are known limitations #1002, not permission to delete data by those means. Use `guarded-rm` for deletion; for all other forms, follow the general rule for coordinating irreversible actions.

## Verification

```bash
python3 .claude/hooks/tests/destructive-guard/hook_cases.py                 # hook checks and this description
python3 .claude/hooks/tests/destructive-guard/long_cases.py                 # long commands (70 KB)
python3 .claude/hooks/tests/destructive-guard/guarded_rm_cases.py .claude/bin/guarded-rm
bash .claude/hooks/tests/test-destructive-guard-executed-command-scope.sh
```

The test suites can be run after a Platform update: `hook_cases.py` passes commands to the hook as data, and `guarded_rm_cases.py` checks deletion only in temporary directories.