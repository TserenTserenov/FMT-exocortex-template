# Default Day Open Checks (Template)

> Executed by `scripts/day-open-checks-runner.sh` at step 5 of the Day Open Pipeline,
> BEFORE the DayPlan commit. Each ```bash``` block = one check; a non-zero exit
> blocks the commit. The variable `$FILE` is the path to today's DayPlan.
>
> This is the DEFAULT template set (WP-529 F7: without it, the Checks step on a fresh
> installation honestly reported "nothing to check" and degraded). It verifies only
> universal invariants that hold for any installation. Add your own checks as separate
> `day-open.checks.<name>.md` files in the same directory — the runner will pick them all up.
>
> A check file addressed to the AGENT (prose, no bash blocks) declares this
> with the line `<!-- executor: agent -->` in the first 15 lines — the runner treats
> such a file as "not applicable" rather than failing it as a markup error (issue #546).
> A file with no declaration and no bash blocks remains an error: it may be a typo
> in the ```bash fence or a corrupted file.

### 🔴 CHECK: DayPlan exists and looks like a plan

> The file must be a non-empty markdown document with a first-level heading.
> An empty or truncated file indicates a failed generation; there is nothing to commit.

```bash
[ -s "$FILE" ] || { echo "  ❌ DayPlan is empty or missing: $FILE"; exit 1; }
FIRST_H1=$(grep -m1 '^# ' "$FILE" || true)
[ -n "$FIRST_H1" ] || { echo "  ❌ DayPlan has no '# ' first-level heading"; exit 1; }
LINES=$(wc -l < "$FILE" | tr -d ' ')
[ "$LINES" -ge 5 ] || { echo "  ❌ DayPlan is suspiciously short ($LINES lines) — looks like a truncated generation"; exit 1; }
echo "  ✅ DayPlan exists, heading is present, $LINES lines"
```

### 🔴 CHECK: date in the filename matches the heading

> The filename (`DayPlan YYYY-MM-DD.md`) and the date in the H1 heading (if present)
> must match — a mismatch means the wrong plan is being checked
> (head-1/tail-1 bug class from the author's checks file, 2026-07-11).

```bash
FNAME_DATE=$(basename "$FILE" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)
[ -n "$FNAME_DATE" ] || { echo "  ✅ Filename has no date — check not applicable"; exit 0; }
FIRST_H1=$(grep -m1 '^# ' "$FILE" || true)
H1_DATE=$(printf '%s\n' "$FIRST_H1" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1 || true)
if [ -n "$H1_DATE" ] && [ "$H1_DATE" != "$FNAME_DATE" ]; then
  echo "  ❌ Date in heading ($H1_DATE) does not match filename ($FNAME_DATE) — wrong plan being checked?"
  exit 1
fi
echo "  ✅ Date is consistent: $FNAME_DATE"
```

### 🟡 CHECK: "Requires Attention" section is present

> Warning, not a block: deterministic Pipeline steps (4.55–4.57)
> write their findings into this section — without it, findings are silently lost.

```bash
if grep -q "Requires Attention" "$FILE"; then
  echo "  ✅ \"Requires Attention\" section is present"
else
  echo "  🟡 DayPlan has no \"Requires Attention\" section — findings from deterministic steps (priorities, closing errors, version) will not be recorded"
fi
```
