# Platform Compatibility Checklist

> The Template must work on macOS and Linux. Check this checklist before committing.

## Windows

| Launch method | Status | Comment |
|---|---|---|
| WSL2 | Full support | This is Linux — same path as the standard Linux checklist below |
| Git Bash | Best-effort, no guarantees | Hybrid environment: `bash`/GNU utilities from MSYS, but `python3` typically resolves to the native Windows interpreter, which does not understand MSYS paths (e.g., `/c/Users/.../IWE`) — known limitation (issue #799), will not be fixed individually |
| Native Windows (cmd/PowerShell without Git Bash) | Not supported | Scripts are bash; no alternative exists |

**Commits in Git Bash (issue #1281).** The `session-open-gate.sh` hook requires an open session with a Work Product number, and that cannot be done in Git Bash, so `git commit` and `git push` are blocked. A user can temporarily disable the check with the key `session_open_gate_skip_until: YYYY-MM-DD` in `params.yaml` (no more than 30 days ahead; format and rules are in `params.yaml.example`). On Linux, macOS, and WSL2, the key has no effect. Each skipped commit prints a warning and writes a line to `.iwe-runtime/session-open-gate-skip.log`. Residual risks accepted knowingly: (1) an agent with write access to `params.yaml` can set or extend the key itself; (2) setting `OSTYPE` in the `env` block of `.claude/settings.local.json` can set `msys` or `cygwin` for agent sessions in that directory, causing the key to take effect on Linux/macOS as well. There is no protection against intentional misuse by an agent with write access: the primary control for this risk class is visibility (a warning on every skip and the log). The format, calendar date, and 30-day limit are checked in code; "the key is set by a human" is a policy rule, not a technical constraint. The log is written on a best-effort basis: its absence does not prove that no skips occurred. Each log line includes `uname_s=` alongside `ostype=` — the output of `uname -s` from the default system PATH (`command -p`), which is independent of both `OSTYPE` and the user's `PATH`; in Git for Windows it starts with `MINGW64_NT`, `MINGW32_NT`, or `MSYS_NT`, and in Cygwin with `CYGWIN_NT` (the platform family is compared, not the exact string). `ostype=msys` or `ostype=cygwin` alongside `uname_s=Linux` or `uname_s=Darwin` indicates substitution.

Weekly review while the key is in use: check whether `params.yaml` contains a key you did not set; check the log for entries on days when you did not work in Git Bash, or entries where `ostype=` and `uname_s=` disagree; check whether `OSTYPE` appears in the `env` block of `.claude/settings.local.json`. On anomaly: remove the key from `params.yaml`, remove `OSTYPE` from `env`, and notify the installation owner.

A permanent fix (a block that works inside Git Bash) has not been implemented. Recommended trigger condition: two or more distinct agents, or five or more skips within 7 days (numbers can be changed).

**Sessions without a Work Product are read-only (WP-7 F274, pilot decision 29.10.2026).** An agent session not opened on a Work Product may read, explore, and perform reversible local checks; `git commit` and `git push` are permitted by `session-open-gate.sh` only when a session is open on a Work Product (`session-guard.sh open --wp WP-N`), when the protocol is from the closed list (`day-open`, `day-close`, `week-close`, `month-close`, `update-delivery`), or — for non-Claude agents only — on a scheduled run. There is no separate "read-only" mode: a session without a Work Product binding already is read-only. The umbrella tech-debt Work Product is only for work that is actually tech debt; the hook does not verify this — it is a convention. The rule applies equally to Claude and to other agents (Kimi and others, for which the hook searches for any open agent semaphore): the previous behavior of passing such agents through without an open session has been removed. A semaphore is considered owned when it contains exactly one `agent:` line and that line matches the agent name: a name-prefix match (`kimi` and `kimi-peer`) does not find each other's semaphores. An agent name (`IWE_AGENT`) containing characters outside the set `A-Z a-z 0-9 . _ -` blocks the commit; otherwise search-pattern characters could match other agents' semaphores. The names `claude` and `claude-code` refer to a single agent, as in the session guard: `IWE_AGENT=claude` is treated as `claude-code`, and a semaphore `claude-<id>.open` with the line `agent: claude` is counted for a Claude conversation (WP-7 F275). Claude without a valid session identifier (`session_id` in the hook request is empty or contains characters outside `A-Za-z0-9._-`, and `CLAUDE_CODE_SESSION_ID` is also absent when `session_id` is empty) cannot commit: this is an environment failure; previously such a commit was passed through. The Git Bash skip key also applies here. The cost in Git Bash without a skip key: a Work Product session cannot be opened there, so commits must be made from WSL2 or another environment. Scheduled non-Claude agent runs without a Work Product (`housekeeping: sched-<id>`, Kimi queue; this reason is not a binding for Claude) are passed through when the reason exactly matches `sched-[A-Za-z0-9._-]+`, with no whitespace trimming and case-sensitive matching; each such pass writes a line to `.iwe-runtime/session-open-gate-sched.log`. This is a deliberately left loophole that an agent can confirm itself: the hook does not distinguish a real queue identifier from a fabricated one (`sched-research`). Using `sched-` outside a scheduled run is a policy violation; the control is the log and the weekly review (entries with a reason not present in the scheduler queue are a reason to investigate). Second residual risk: for non-Claude agents the hook does not distinguish a live session from an abandoned one, so a semaphore on a Work Product or a scheduled-run semaphore left over after a failure keeps commits open until the session guard removes it.

Known issue: `update.sh` fails in Git Bash at the step where `python3` receives a MSYS path (issue #799). Workaround: use WSL2 to run `update.sh` and other Template scripts, even if you edit files through Git Bash/VS Code on Windows.

## Forbidden Constructs (without a wrapper)

| Construct | Problem | Replacement |
|-------------|----------|--------|
| `sed -i '' ...` | GNU sed does not accept `''` | `sed_inplace` (defined in setup.sh, update.sh) |
| `date -v-Nd` | BSD-only (macOS) | `portable_date_offset N` (defined in role scripts) |
| `osascript` | macOS-only | `osascript \|\| notify-send \|\| true` |
| `launchctl` | macOS-only | Wrap in a `command -v launchctl` guard |
| `readlink -f` | BSD readlink does not support `-f` | `cd "$(dirname "$0")" && pwd` |
| `grep -P` | GNU-only (Perl regex) | `grep -E` (Extended regex) |
| `stat -c` / `stat -f` | GNU vs BSD | Avoid; use `wc`, `ls -l`, `find` |
| `mktemp -d -t` | Inconsistent behavior | `mktemp -d` (no template) |
| `timeout N cmd` | GNU coreutils/Homebrew-only — `command not found` on stock macOS without Homebrew (issue #1108) | `iwe_timeout` (`lib/common.sh`) — delegates to real `timeout`, otherwise uses a perl polyfill |
| `md5sum` | GNU-only, no macOS equivalent (issue #1108) | `iwe_md5` (`lib/common.sh`) — delegates to `md5sum`, otherwise BSD `md5` |
| `sha256sum` | GNU-only; present in `/sbin` only on macOS 26+, absent on older versions (issue #1108) | `iwe_sha256` (`lib/common.sh`) — delegates to `sha256sum`, otherwise `shasum -a 256` |
| `flock -n/-x/-s ...` | util-linux/Homebrew-only, absent on stock macOS — a bare call fails with `command not found`, which code was incorrectly treating as "lock already held" (issue #1108) | `command -v flock` guard + mkdir-fallback lock (reference: `scripts/ledger-append.sh`, `scripts/wp-pool-cascade.sh`) |
| `${var,,}` / `${var^^}` | bash 4+ (lowercase/uppercase expansion) — `bad substitution` on bash 3.2, the default `/bin/bash` on stock macOS (issue #1108) | `$(printf '%s' "$var" \| tr '[:upper:]' '[:lower:]')` |

## Wrappers (copy-paste to the top of a script)

### sed_inplace

```bash
if sed --version >/dev/null 2>&1; then
    sed_inplace() { sed -i "$@"; }
else
    sed_inplace() { sed -i '' "$@"; }
fi
```

### portable_date_offset

```bash
# portable_date_offset <days_back> [format]
portable_date_offset() {
    local days="$1"
    local fmt="${2:-%Y-%m-%d}"
    date -v-${days}d +"$fmt" 2>/dev/null || date -d "$days days ago" +"$fmt" 2>/dev/null
}
```

### notify (desktop)

```bash
notify() {
    local title="$1" message="$2"
    printf 'display notification "%s" with title "%s"' "$message" "$title" | osascript 2>/dev/null \
        || notify-send "$title" "$message" 2>/dev/null \
        || true
}
```

### portable_lowercase (replacement for `${var,,}`)

```bash
# not a copy-paste function — an inline one-liner at the point of use
lower=$(printf '%s' "$var" | tr '[:upper:]' '[:lower:]')
```

### timeout / md5 / sha256 — via lib/common.sh, not copy-paste

Unlike the wrappers above (local, no external dependencies), these three are
sufficiently complex (perl polyfill for `timeout`, GNU/BSD branching) and are
already centralized in `scripts/lib/common.sh` — do not duplicate inline:

```bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
iwe_timeout 30 some_cmd   # instead of bare `timeout 30 some_cmd`
iwe_sha256 < "$FILE"      # instead of bare `sha256sum`
echo -n "$x" | iwe_md5    # instead of bare `md5sum`
```

Path to `lib/common.sh` relative to the calling script (`scripts/*.sh` →
`lib/common.sh`; outside `scripts/` — see `.claude/lib/capture_writer.sh` for
an example of a relative path from a different directory).

### flock — guard + mkdir-fallback, not copy-paste

`flock(1)` is absent on stock macOS, and a bare `command not found` is easy to
mistake for "lock already held" (issue #1108). No `iwe_*` helper exists — the
lock is tied to a specific `$LOCK_FILE` and the blocking/non-blocking wait
semantics of the calling script, so the pattern is not parameterized in
`lib/common.sh`. Reference implementations (copy and adapt, do not reinvent):
`scripts/ledger-append.sh` (blocking `-w 10`, with dead-lock reclaim by
PID+hostname) and `scripts/wp-pool-cascade.sh` (non-blocking `-n`, same
reclaim logic, no retry loop).

## Architectural Constraints

- **launchd / .plist** — macOS-only. Linux requires cron or a systemd timer. Setup.sh skips step 5 on Linux.
- **~/Library/LaunchAgents** — macOS path. Role install scripts are currently macOS-only.
- **/opt/homebrew/bin** — Apple Silicon macOS. Substituted by the Template in the plist PATH, but not universal.
- **Sleep prevention** — scripts detect the OS automatically: `caffeinate -diu` (macOS) / `systemd-inhibit` (Linux). On macOS the `-s` flag is **not used** — it is ignored when Optimized Battery Charging switches the power profile to battery.
- **Laptop wake** — macOS: `pmset repeat wakeorpoweron`, Linux: `rtcwake` / systemd timer `WakeSystem=true`, Windows: Task Scheduler. For macOS laptops, `pmset -b sleep 0` is recommended (disables idle sleep on the battery power profile).
- **`scripts/kimi-whisper-safe.sh`** — optional dependencies `ffmpeg` + `openai-whisper` (Python package), not included in the base Template installation. The script checks for `ffprobe`/`whisper` in PATH itself and exits with a clear error if they are absent — install as needed.

## How to Check

```bash
# Find all potential issues:
grep -rn "sed -i ''" --include="*.sh" .
grep -rn "date -v" --include="*.sh" .
grep -rn "osascript" --include="*.sh" .
grep -rn "launchctl" --include="*.sh" .
grep -rn "readlink -f" --include="*.sh" .
grep -rn "grep -P" --include="*.sh" .
grep -rn "\btimeout [\"\$0-9]" --include="*.sh" .
grep -rn "\bsha256sum\b\|\bmd5sum\b" --include="*.sh" .
grep -rnE '\bflock -[a-zA-Z]' --include="*.sh" .
grep -rnE '\$\{[A-Za-z_][A-Za-z0-9_]*(,,?|\^\^?)\}' --include="*.sh" .
```

Or run directly: `bash scripts/check-platform-compat.sh` — the same checklist as a CI gate (`check_guarded`/`check_forbidden` for each row in the table above), not just a list for manual review.

---

*Last updated: 2026-10-05 (issue #1108: timeout/md5sum/sha256sum/flock/bash4-isms)*