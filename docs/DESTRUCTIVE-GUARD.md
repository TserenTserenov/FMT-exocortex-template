# Destructive Command Guard (destructive-guard)

The `.claude/hooks/destructive-guard.sh` hook inspects the text of every Bash invocation before execution and blocks recognized dangerous forms: `git add -A`, `git push --force`, `git reset --hard`, destructive `git clean`, `git rm -r -f`, `DROP`/`TRUNCATE` via `psql`/`mysql`/`sqlite3`, GitHub repository deletion, and recursive forced `rm`. For `git clean`, a pass is allowed only when a recognized active `-n`/`--dry-run` flag is present: the absence of `-f` alone does not prove safety when `clean.requireForce=false`. Exit code 2 means the command is blocked; the agent sees the reason. The recognition boundaries are listed below. The hook does not prove the safety of arbitrary shell code.

## How to delete directories

A recognized `rm` invocation with recursion and force flags (`-rf`, `-r -f`, `-Rf`, `--recursive --force`, `/bin/rm`, `find -exec rm`, `xargs rm`, `bash -c "rm -rf …"`) is blocked even inside `/tmp`. Also blocked: deletion of everything found via `find -delete`, `find` with `-exec`/`-execdir`/`-ok`/`-okdir` and `rm`, `unlink`, `shred`, and `xargs rm` — with or without flags, on any path, including through the wrappers `env`, `command`, `nice`, `sudo`, `busybox` (WP-529 F270, attacks on candidates 0.42-rc.1 and rc.2). Also blocked are commands that write to a file from their own argument and are allowed without a prompt: `git diff/log/show --output=<file>` and `find -fprint`/`-fprint0`/`-fprintf`/`-fls` — this attack overwrote the checks themselves; use redirect `>` instead. `find -exec`/`-execdir`/`-ok`/`-okdir` only runs read-only commands (`grep`, `cat`, `head`, `tail`, `wc`, `ls`, `stat`, `file`, `sha256sum`, `diff`, and similar); `rg --pre` is forbidden: both programs are allowed without a prompt, and no list of forbidden commands is ever complete (the attack on candidate rc.3 deleted and overwrote via `sh -c`, `truncate`, `cp /dev/null`, `mv`, `sed -i`). `git branch` and `git remote` are allowed without a prompt only for viewing: `git branch -d/-D/-f/-m/-M/-C` (including long forms and their abbreviations) and `git remote add/rename/remove/rm/set-url/set-head/set-branches/prune` are blocked; branch creation and viewing pass through (attack on candidate rc.4). Also blocked: `git branch -u`/`--unset-upstream`/`--set-upstream-to` and `git remote update --prune` (attack on candidate rc.5). Rules for `find` apply to the entire expression: a read-only action at the front (`-exec cat {} \; -delete`, `… \; -exec rm`, `… \; -fprint file`) does not bypass them (attack on candidate rc.6). An escaped character (`\(`, `\)`, `\;`, `\&`, `\|`) is read by the check as bash would read it — as part of the command, so parentheses in a `find` expression do not hide the tail (candidate rc.7 check). Zeroing a file with a read command (`cat /dev/null > file`, `>| file`, `1> file`, `/dev/null>file`, `head -c0 … > file`) is blocked when the target is outside a temp directory (`/tmp`, `/var/folders`, `$TMPDIR`). `RIPGREP_CONFIG_PATH` is blocked (an `rg` config file can enable `--pre`), and writes via redirect or `tee` to `.claude/hooks/`, `.claude/bin/`, `settings.json` are blocked; a path in a variable is not visible to this check. The hook also recognizes `bash -o pipefail -c`, `bash -O extglob -c`, `bash -c --`, a literal shell name before a heredoc (`bash<<EOF`, `/bin/bash<<-EOF`, `'bash'<<'EOF'`), and the name `RM` on a case-insensitive filesystem. For verified forms of a single literal command, the hook associates the heredoc body with the recipient, including prefix forms `<<EOF bash` and `0<<SQL psql`: text for a plain `cat` remains data; code for a shell or SQL client is checked. Verified non-nested `if`, `for`, `while`, `until`, `select`, `case` are also recognized; this is not a full Bash syntax parser. When an assignment, redirect, or wrapper precedes `<<`, the body is retained for checking if a literal shell or SQL client appears on the right and no data command is recognized on the left. For a literal shell or SQL client, the heredoc body is retained for checking on any FD: `/dev/fd/N` or a redirect chain can deliver it to the interpreter. Therefore `bash 2<<EOF` with dangerous content may be rejected, even though that redirection does not itself feed the body to stdin; the hook does not prove the final FD graph. An ambiguous header may produce a false rejection. Branches are checked conservatively: an unreachable branch containing a shell may produce a rejection. A dynamic command name or a construct assembled by substitution remains outside the guarantee. The reason: the deletion target depends on variables, `cd`, symlinks, and substitutions that are known only at runtime, so safety cannot be proved from the command text alone (a `/tmp/` path in an adjacent command once freed deletion of entirely different directories, issue #940).

Instead, the same command with the same flags and targets runs through a wrapper:

```bash
.claude/bin/guarded-rm -rf "$TMPDIR/build"
```

At execution time the wrapper resolves the real path of each target (symlinks and `..` are expanded) and deletes only within the roots listed in the registry `.claude/config/guarded-rm-roots.txt` (defaults: `/tmp`, `$TMPDIR`, the workspace's `.claude/worktrees`). `$TMPDIR` is accepted only if it is a system temp directory (`/tmp`, `/var/tmp`, `/var/folders/…`, `/run/user/…`, a Windows user temp directory): otherwise an invocation with a substituted `TMPDIR=$HOME` could delete any directory (WP-529 F270). The root itself is not deleted; a path outside the roots, an empty target, a registry failure, or a normalization failure produce a rejection without deletion.

Add a directory for allowed deletion by appending a line to the registry (data, not shell). The registry lives in the workspace and is not protected from agent edits, so this is a convenience mechanism, not a security boundary against a hostile agent.

The checked text accounts for simple sequential assignments of a literal command name: `x=rm; $x -rf build`, `${x}`, and `"$x"`. Value overwrites and `unset` are accounted for; an ambiguous value in command position produces a rejection. Single quotes and an escaped dollar sign remain literal text. This is not evaluation of arbitrary shell variables.

For adjacent `echo/printf | sh/bash`, the text fed to the shell as a program is checked. For `printf`, `%s`, `%%`, `\n`, `\t`, `\r`, `\\` are supported; any other format or escape in such a pair produces a rejection. For `echo`, `-n`, `-e`, `-E` are allowed, but escape sequences are not evaluated and produce a rejection. Data without an executing shell is not checked as a program; `bash -c ...` and `bash script.sh` do not treat stdin as a program. A forced refspec `git push origin +main` is blocked; a plain push and `--force-with-lease` without a leading `+` remain allowed.

## Fail closed

Claude Code blocks a command only on exit code 2. Therefore any other hook exit (missing `jq` or `perl`, a `grep` failure, an unexpected error under `set -e`) also becomes a block marked "check error", not a pass. This rule applies to check failure; an unrecognized dangerous command may complete the check with code 0.

## Human bypass

`CC_ALLOW_DESTRUCTIVE_INPUT=1` is set in the real shell of the pilot from which Claude Code is launched (the hook reads its own process environment; the agent cannot set the variable for itself). This is not a one-time skip for a single command: while the variable is present in the environment, the hook skips all commands of that process — that is, the entire agent session — without checking. Set it only for the duration of the required operation, then restart Claude Code without the variable.

## Outside the guarantee

The hook sees only the command text. It does not catch: deletion via Python or other languages, a dynamic command name through an alias/function/unknown variable, deliberate bypass, an incorrect target selection within an allowed tree, a race between the check and deletion inside `guarded-rm`, a series of `xargs` calls (this is not a transaction), or edits to the roots registry via a file-writing tool.

Compound shell commands outside the verified non-nested forms may pass a heredoc to an inner interpreter without recognition: for example, `if true; then if true; then bash; fi; fi<<EOF`, a nested `case`, or `{ case x in x) bash;; esac; }<<EOF`. Conservative false rejections are also possible: in `{ printf bash; cat; }<<EOF` the word `bash` is data for `printf`, but the hook may treat it as an executable command name; `&>/dev/null cat <<EOF bash` may also be rejected even though the body goes to `cat`. Do not treat the absence of a rejection as proof that a nested construct is safe.

In addition, the hook passes through:

- `rm -r`, `rm -R`, and `rm --recursive` without a force flag (`-f`, `--force`). In an agent invocation such deletion is equally irreversible: without a terminal, `rm` does not ask for confirmation and deletes the entire tree, including read-only files (for example, `.git` objects).
- a line executed by `git submodule foreach '…'`: the hook treats words after `git` as git arguments and does not parse them as commands, so `git submodule foreach 'rm -rf build'` passes through.
- script text from a here-string (`bash <<<`, `sh -s <<<`) or an arbitrary source in a `| sh` pipeline (for example, `curl ... | sh`). Literal `echo/printf | sh/bash` and `cat <<EOF | bash` are checked; this is not binding of any data source to a shell.
- command substitution inside double quotes, for example `echo "$(rm -rf …)"`, or in backticks. The text `$(...)` is executed by the shell even though it remains part of an argument for the current parser.
- substitution inside an unquoted heredoc for a write command, for example `cat <<EOF` with `$(rm -rf …)` in the body: the shell executes the substitution before passing the text to `cat`, and the hook discards the body as data.
- passing a heredoc body to a shell via process substitution, for example `cat <<EOF > >(bash)`: the hook does not yet associate this path with the executing shell.
- all commands of a process whose environment contains `CC_ALLOW_DESTRUCTIVE_INPUT=1` (see "Human bypass").

These are known limitations #1002, not permission to delete data in those ways. Use `guarded-rm` for deletion; for all other forms, follow the general rule for confirming irreversible actions.

## Verification

```bash
python3 .claude/hooks/tests/destructive-guard/hook_cases.py                 # hook and description checks
python3 .claude/hooks/tests/destructive-guard/long_cases.py                 # long commands (70 KB)
python3 .claude/hooks/tests/destructive-guard/guarded_rm_cases.py .claude/bin/guarded-rm
bash .claude/hooks/tests/test-destructive-guard-executed-command-scope.sh
```

The test suites can be run after a platform update: `hook_cases.py` passes commands to the hook as data, and `guarded_rm_cases.py` checks deletion only in temp directories.

