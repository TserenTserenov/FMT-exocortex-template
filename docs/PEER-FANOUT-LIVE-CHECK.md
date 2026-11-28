# Live Verification of Subtask Distribution to Multiple Agents

Distributing independent subtasks to multiple agents (the `/peer-fanout` skill) is included in release 0.43 only after a person who is **not** the template author verifies it on their own installation. If no such verification is completed before the release, the feature moves to 0.44.

The verification takes about five minutes and uses three standard Claude calls against your subscription.

## Prerequisites

- A clean IWE installation at version 0.43 (release candidate) on macOS or Linux.
- Claude Code installed and authorized: running the `claude` command in the terminal opens Claude without prompting you to sign in.
- Kimi, Codex, and other agents are **not** required.

## Step 1. Open a Terminal

On macOS: press Cmd+Space, type `Terminal`, press Enter. A window with a blinking cursor opens.

On Linux: open the Terminal application from the application menu.

You can also use VS Code: go to the Terminal menu → New Terminal; the terminal panel opens at the bottom of the window.

## Step 2. Create a Verification Directory

Paste this command into the terminal and press Enter:

```bash
export FANOUT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fanout-check.XXXXXX"); echo "$FANOUT_DIR"
```

The terminal prints the path to a new empty directory (for example, `/tmp/fanout-check.Ab12Cd`). Do not close this terminal window until the verification is complete: the following commands use this directory.

## Step 3. Write Three Subtasks

Paste this command into the same terminal and press Enter:

```bash
printf '%s\t%s\t%s\n' a claude "Name one capital city in Europe and one of its landmarks." b claude "Name one river in Asia and the country it flows through." c claude "Name one animal from Australia and what it eats." > "$FANOUT_DIR/t.tsv"; cat "$FANOUT_DIR/t.tsv"
```

The terminal shows three lines: each line begins with the letter `a`, `b`, or `c`, followed by the word `claude` and the question text.

## Step 4. Locate the Distribution Script

Paste this command into the same terminal and press Enter:

```bash
FANOUT="${IWE_SCRIPTS:-${IWE_WORKSPACE:-$HOME/IWE}/scripts}/peer-fanout.sh"; [ -f "$FANOUT" ] || FANOUT="${IWE_TEMPLATE:-${IWE_WORKSPACE:-$HOME/IWE}/IWE}/scripts/peer-fanout.sh"; ls -l "$FANOUT"
```

The terminal shows one line containing a path that ends with `peer-fanout.sh`. If instead the terminal prints `No such file or directory`, the installation is not version 0.43: stop and report this in the merge request.

## Step 5. Run the Distribution

Paste this command into the same terminal and press Enter:

```bash
bash "$FANOUT" --tasks "$FANOUT_DIR/t.tsv" --out-dir "$FANOUT_DIR/out"; echo "exit=$?"
```

Wait between a few seconds and a couple of minutes: the three agents respond concurrently and the script asks no questions. When finished, the terminal prints a three-row table (columns `id`, `vendor`, `status`, `bytes`, `elapsed_s`), a summary line in the form `ok=3 total=3 out_dir=... wall_s=...`, and a final line `exit=0`.

If the line `PREFLIGHT FAIL: CLI 'claude' not found in PATH` appears, the terminal cannot find Claude Code: return to the Prerequisites section.

## Step 6. View the Answers

Paste this command into the same terminal and press Enter:

```bash
for f in a b c; do echo "== $f"; cat "$FANOUT_DIR/out/$f.md"; done
```

Below each `== a`, `== b`, and `== c` line, the answer to that question appears: a capital city, a river, and an animal.

## Verification Passes When All Four Conditions Are Met

1. The last line of Step 5 is `exit=0`.
2. The summary line begins with `ok=3 total=3`.
3. All three answers from Step 6 are non-empty and address their respective questions.
4. The number after `wall_s=` is less than the sum of the three numbers in the `elapsed_s` column: the subtasks ran concurrently, not sequentially.

## Where to Report the Result

Copy the table and the summary line from Step 5 out of the terminal and add them as a comment on the merge request for this feature (or in the release 0.43 discussion thread). State the IWE version, the operating system (macOS or Linux), and whether the verification passed all four conditions.

