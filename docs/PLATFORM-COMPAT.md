# Platform Compatibility Checklist

> The Template must work on macOS and Linux. Check this list before committing.

## Windows

| Launch method | Status | Comment |
|---|---|---|
| WSL2 | Full support | This is Linux — follows the same path as the standard Linux checklist below |
| Git Bash | Best-effort, no guarantees | Hybrid environment: `bash`/GNU utilities from MSYS, but `python3` typically resolves to the native Windows interpreter, which does not understand MSYS paths (e.g., `/c/Users/.../IWE`) — known limitation (issue #799), will not be fixed on a case-by-case basis |
| Native Windows (cmd/PowerShell without Git Bash) | Not supported | Scripts are bash; no alternative exists |

**Commits in Git Bash (issue #1281).** The hook `session-open-gate.sh` requires an open session with a Work Product number, which cannot be opened in Git Bash, so `git commit` and `git push` are blocked. A user can temporarily disable the check with the key `session_open_gate_skip_until: YYYY-MM-DD` in `params.yaml` (no more than 30 days ahead; format and rules are in `params.yaml.example`). The key has no effect on Linux, macOS, or WSL2. Each skipped commit prints a warning and writes a line to `.iwe-runtime/session-open-gate-skip.log`. Residual risk: an agent with write access to `params.yaml` can set or extend the key itself, so the key must be set by a human, and `params.yaml` and the log should be reviewed periodically. A permanent fix (a block that works in Git Bash) has not been implemented.

Known issue: `update.sh` fails in Git Bash at the step where `python3` receives an MSYS path (issue #799). Workaround: use WSL2 to run `update.sh` and other Template scripts, even if you edit files through Git Bash/VS Code on Windows.

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
| `mktemp -d -t` | Behavior differs across platforms | `mktemp -d` (no template) |
| `timeout N cmd` | GNU coreutils/Homebrew-only — `command not found` on stock macOS without Homebrew (issue #1108) | `iwe_timeout` (`lib/common.sh`) — delegates to real `timeout`, otherwise uses a Perl polyfill |
| `md5sum` | GNU-only, no macOS equivalent (issue #1108) | `iwe_md5` (`lib/common.sh`) — delegates to `md5sum`, otherwise BSD `md5` |
| `sha256sum` | GNU-only; present in `/sbin` only on macOS 26+, absent on older versions (issue #1108) | `iwe_sha256` (`lib/common.sh`) — delegates to `sha256sum`, otherwise `shasum -a 256` |
| `flock -n/-x/-s ...` | util-linux/Homebrew-only, absent on stock macOS — a bare call fails with `command not found`, which code incorrectly treated as "lock already held" (issue #1108) | `command -v flock` guard + mkdir-fallback lock (reference: `scripts/ledger-append.sh`, `scripts/wp-pool-cascade.sh`) |
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

Unlike the wrappers above (local, no external dependencies), these three are sufficiently complex (Perl polyfill for `timeout`, GNU/BSD branching) and are already centralized in `scripts/lib/common.sh` — do not duplicate them inline:

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

`flock(1)` is absent on stock macOS, and a bare `command not found` is easy to misinterpret as "lock already held" (issue #1108). There is no ready-made `iwe_*` helper — the lock is tied to a specific `$LOCK_FILE` and the blocking/non-blocking wait semantics of the calling script, so the pattern is not parameterized in `lib/common.sh`. Reference implementations (copy and adapt, do not reinvent): `scripts/ledger-append.sh` (blocking `-w 10`, with dead-lock reclaim by PID+hostname) and `scripts/wp-pool-cascade.sh` (non-blocking `-n`, same reclaim logic, no retry loop).

## Architectural Constraints

- **launchd / .plist** — macOS-only. Linux requires cron or a systemd timer. Setup.sh skips step 5 on Linux.
- **~/Library/LaunchAgents** — macOS path. Role install scripts are currently macOS-only.
- **/opt/homebrew/bin** — Apple Silicon macOS. Substituted into the plist PATH by the Template, but not universal.
- **Sleep prevention** — scripts detect the OS automatically: `caffeinate -diu` (macOS) / `systemd-inhibit` (Linux). On macOS the `-s` flag is **not used** — it is ignored when Optimized Battery Charging switches the power profile to battery.
- **Laptop wake** — macOS: `pmset repeat wakeorpoweron`, Linux: `rtcwake` / systemd timer `WakeSystem=true`, Windows: Task Scheduler. For macOS laptops, `pmset -b sleep 0` is recommended (disables idle sleep on the battery profile).
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

Alternatively, run directly: `bash scripts/check-platform-compat.sh` — this is the same checklist as a CI gate (`check_guarded`/`check_forbidden` per each row in the table above), not just a list for manual review.

---

*Last updated: 2026-10-05 (issue #1108: timeout/md5sum/sha256sum/flock/bash4-isms)*