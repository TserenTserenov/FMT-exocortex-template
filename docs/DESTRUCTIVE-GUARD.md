# Protection Against Irreversible Commands (destructive-guard)

The hook `.claude/hooks/destructive-guard.sh` checks the text of every Bash invocation before execution and blocks recognized dangerous forms: `git add -A`, `git push --force`, `git reset --hard`, destructive `git clean`, `git rm -r -f`, `DROP`/`TRUNCATE` via `psql`/`mysql`/`sqlite3`, repository deletion on GitHub, and recursive forced `rm`. For `git clean`, a pass is allowed only when a recognized active `-n`/`--dry-run` flag is present: the absence of `-f` alone does not prove safety when `clean.requireForce=false`. Exit code 2 = command blocked; the agent sees the reason. Recognition boundaries are listed below; the hook does not prove the safety of arbitrary shell code.

## How to delete directories

A recognized `rm` invocation with recursion and force flags (`-rf`, `-r -f`, `-Rf`, `--recursive --force`, `/bin/rm`, `find -exec rm`, `xargs rm`, `bash -c "rm -rf …"`) is blocked even inside `/tmp`. Also blocked: deletion of everything found via `find -delete`, `find` with `-exec`/`-execdir`/`-ok`/`-okdir` and `rm`, `unlink`, `shred`, and `xargs rm` — with or without flags, on any path, including through wrappers `env`, `command`, `nice`, `sudo`, `busybox` (WP-529 F270, attacks on candidates 0.42-rc.1 and rc.2). Also blocked are commands that write to a file from their own argument and are allowed without a prompt: `git diff/log/show --output=<file>` and `find -fprint`/`-fprint0`/`-fprintf`/`-fls` — this is how an attack overwrote the checks themselves; use redirect `>` instead. `find -exec`/`-execdir`/`-ok`/`-okdir` runs only reading commands (`grep`, `cat`, `head`, `tail`, `wc`, `ls`, `stat`, `file`, `sha256sum`, `diff`, and similar); `rg --pre` is forbidden: both programs are allowed without a prompt, and a list of forbidden commands is never complete (the attack on candidate rc.3 deleted and overwrote via `sh -c`, `truncate`, `cp /dev/null`, `mv`, `sed -i`). `git branch` and `git remote` are allowed without a prompt only for viewing: `git branch -d/-D/-f/-m/-M/-C` (with long forms and their abbreviations) and `git remote add/rename/remove/rm/set-url/set-head/set-branches/prune` are blocked; branch creation and viewing pass through (attack on candidate rc.4). Also in this group: `git branch -u`/`--unset-upstream`/`--set-upstream-to` and `git remote update --prune` (attack on candidate rc.5). Rules for `find` apply to the entire expression: a reading action placed first (`-exec cat {} \; -delete`, `… \; -exec rm`, `… \; -fprint file`) does not bypass them (attack on candidate rc.6). An escaped character (`\(`, `\)`, `\;`, `\&`, `\|`) is read by the check as bash would — as part of the command, so parentheses in a `find` expression do not hide the tail (candidate rc.7 check). Zeroing a file with a reading command (`cat /dev/null > file`, `>| file`, `1> file`, `/dev/null>file`, `head -c0 … > file`) is blocked when the target is outside a temporary directory (`/tmp`, `/var/folders`, `$TMPDIR`). `RIPGREP_CONFIG_PATH` is blocked (an `rg` config file can enable `--pre`), and writes via redirect or `tee` to `.claude/hooks/`, `.claude/bin/`, `settings.json` are blocked; the path is normalized before comparison (`.claude//hooks`, `./.claude/./hooks`, `.claude/x/../hooks`, patterns `hook?`, `h*`, `[h]ooks`, and brace expansion `{hooks,x}` are treated as the same path, issue #1567), but a path stored in a variable is not seen by this check. Overwriting a file via redirect `>` (also `>|`, `2>`, `&>`) after a command that is allowed without a prompt (`ls`, `cat`, `head`, `tail`, `wc`, `grep`, `rg`, `find`, `diff`, `git status/log/diff/show/branch/remote`) goes through a permission prompt (`ask`) when the target is outside a temporary directory and is not `/dev/null`: empty output from any such command erases the file, and a list of forbidden forms is never complete (issue #1568). Appending with `>>` passes without a prompt, as does a command whose content is supplied in the invocation itself via heredoc or here-string (`cat > file <<'EOF'`, `cat <<< "x" > file`): its output is not empty; the write-protection rule for guarded files still applies. The hook also recognizes `bash -o pipefail -c`, `bash -O extglob -c`, `bash -c --`, a literal shell name before a heredoc (`bash<<EOF`, `/bin/bash<<-EOF`, `'bash'<<'EOF'`), and the name `RM` on a case-insensitive file system. For verified forms of a single literal command, the hook associates the heredoc body with the recipient, including prefix forms `<<EOF bash` and `0<<SQL psql`: text for a plain `cat` remains data, while code for a shell or SQL client is checked. Verified non-nested `if`, `for`, `while`, `until`, `select`, and `case` are also recognized; this is not a full Bash syntax parser. When an assignment, redirect, or wrapper precedes `<<`, the body is retained for checking if a literal shell or SQL client appears on the right and no data command is recognized on the left. For a literal shell or SQL client, the heredoc body is retained for checking on any FD: `/dev/fd/N` or a chain of redirects may deliver it to the interpreter. Therefore `bash 2<<EOF` with dangerous content may be rejected, even though that redirect does not itself feed the body to stdin; the hook does not prove the final FD graph. An ambiguous header may produce a false rejection. Branches are checked conservatively: an unreachable branch containing a shell may cause a rejection. A dynamic command name or a construct assembled by substitution remains outside the guarantee. Reason: the deletion target depends on variables, `cd`, symlinks, and substitutions that are known only at execution time, so safety cannot be proved from the command text alone (a `/tmp/` path in a neighboring command once freed deletion of entirely different directories, issue #940).

Instead, run the same command with the same flags and targets through the wrapper:

```bash
.claude/bin/guarded-rm -rf "$TMPDIR/build"
```

At execution time the wrapper resolves the real path of each target (symlinks and `..` are expanded) and deletes only within roots listed in the registry `.claude/config/guarded-rm-roots.txt` (defaults: `/tmp`, `$TMPDIR`, `.claude/worktrees` of the workspace). `$TMPDIR` is accepted only if it is a system temporary directory (`/tmp`, `/var/tmp`, `/var/folders/…`, `/run/user/…`, or the Windows user temp directory): otherwise an invocation with a substituted `TMPDIR=$HOME` could delete any directory (WP-529 F270). The root itself is not deleted; a path outside the roots, an empty target, a registry failure, or a normalization failure causes a rejection without deletion.

Add a directory for allowed deletion by appending a line to the registry (data, not shell). The registry lives in the workspace and is not protected from agent edits, so this is a convenience, not a security boundary against a hostile agent.

Simple sequential assignments of a literal command name are recognized in checked text: `x=rm; $x -rf build`, `${x}`, and `"$x"`. Value overwriting and `unset` are tracked; an ambiguous value in command position causes a rejection. Single quotes and an escaped dollar sign remain literal text. This is not evaluation of arbitrary shell variables.

For adjacent `echo/printf | sh/bash`, the text fed to the shell as a program is checked. For `printf`, `%s`, `%%`, `\n`, `\t`, `\r`, and `\\` are supported; any other format or escape in such a pair causes a rejection. For `echo`, `-n`, `-e`, and `-E` are accepted, but escape sequences are not evaluated and cause a rejection. Data without an executing shell is not checked as a program; `bash -c ...` and `bash script.sh` do not treat stdin as a program. A forced refspec `git push origin +main` is blocked; a normal push and `--force-with-lease` without a leading `+` remain allowed.

## Fail closed

Claude Code blocks a command only on exit code 2. Therefore any other hook exit (missing `jq` or `perl`, a `grep` failure, an unexpected error under `set -e`) also becomes a block marked "check error", not a pass-through. This rule applies to check failure; an unrecognized dangerous command may complete the check with code 0.

## Human bypass

`CC_ALLOW_DESTRUCTIVE_INPUT=1` is set in the pilot's real shell from which Claude Code is launched (the hook reads its process environment; the agent cannot set the variable for itself). This is not a one-time skip for a single command: as long as the variable exists in the environment, the hook passes all commands of that process — that is, the entire agent session — without checking. Set it only for the duration of the required operation, then restart Claude Code without the variable.

## Outside the guarantee

The hook sees only the command text. It does not catch: deletion via Python or other languages, a dynamic command name through an alias/function/unknown variable, deliberate bypass, an incorrect target choice within an allowed tree, a race between the check and deletion inside `guarded-rm`, a series of `xargs` calls (this is not a transaction), or edits to the roots registry via a file-writing tool.

Composite shell commands outside the verified non-nested forms may pass a heredoc to an inner interpreter without recognition: for example, `if true; then if true; then bash; fi; fi<<EOF`, a nested `case`, or `{ case x in x) bash;; esac; }<<EOF`. Conservative false rejections are also possible: in `{ printf bash; cat; }<<EOF` the word `bash` is data for `printf`, but the hook may treat it as an executable command name; `&>/dev/null cat <<EOF bash` may also be rejected even though the body goes to `cat`. Do not treat the absence of a rejection as proof of safety for a nested construct.

The hook also passes through:

- `rm -r`, `rm -R`, and `rm --recursive` without a force flag (`-f`, `--force`). In an agent invocation such deletion is equally irreversible: without a terminal, `rm` asks for no confirmation and deletes the entire tree, including read-only files (for example, `.git` objects).
- The string executed by `git submodule foreach '…'`: words after `git` are treated by the hook as git arguments and are not parsed as commands, so `git submodule foreach 'rm -rf build'` passes through.
- Script text from a here-string (`bash <<<`, `sh -s <<<`) or an arbitrary source in a pipeline `| sh` (for example, `curl ... | sh`). Literal `echo/printf | sh/bash` and `cat <<EOF | bash` are checked; this is not a binding of any data source to a shell.
- Command substitution inside double quotes, for example `echo "$(rm -rf …)"`, or in backticks. The text `$(...)` is executed by the shell, even though it remains part of an argument for the current parser.
- Substitution inside an unquoted heredoc for a write command, for example `cat <<EOF` with `$(rm -rf …)` in the body: the shell performs the substitution before passing the text to `cat`, and the hook discards the body as data.
- Passing a heredoc body to a shell via process substitution, for example `cat <<EOF > >(bash)`: the hook does not yet associate this path with an executing shell.
- Any commands of a process whose environment contains `CC_ALLOW_DESTRUCTIVE_INPUT=1` (see "Human bypass").

These are known limitations #1002, not permission to delete data in those ways. Use `guarded-rm` for deletion; for all other forms, follow the general rule for confirming irreversible actions.

## Verification

```bash
python3 .claude/hooks/tests/destructive-guard/hook_cases.py                 # hook and description checks
python3 .claude/hooks/tests/destructive-guard/long_cases.py                 # long commands (70 KB)
python3 .claude/hooks/tests/destructive-guard/guarded_rm_cases.py .claude/bin/guarded-rm
bash .claude/hooks/tests/test-destructive-guard-executed-command-scope.sh
bash .claude/hooks/tests/test-destructive-guard-path-spellings.sh           # path spellings for guarded files
bash .claude/hooks/tests/test-destructive-guard-reader-overwrite.sh         # prompt on overwrite after a reading command
```

The test suites can be run after a platform update: `hook_cases.py` passes commands to the hook as data, and `guarded_rm_cases.py` checks deletion only in temporary directories.

