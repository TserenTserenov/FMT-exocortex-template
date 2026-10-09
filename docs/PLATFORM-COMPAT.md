# Platform Compatibility Checklist

> This Template must work on macOS and Linux. Check this checklist before committing.

## Windows

| Launch method | Status | Comment |
|---|---|---|
| WSL2 | Full support | This is Linux — follow the standard Linux checklist below |
| Git Bash | Best-effort, no guarantees | Hybrid environment: `bash`/GNU utilities from MSYS, but `python3` typically resolves to the native Windows interpreter, which does not understand MSYS paths (e.g., `/c/Users/.../IWE`) — known limitation (issue #799), will not be fixed |
| Native Windows (cmd/PowerShell without Git Bash) | Not supported | Scripts are bash; no alternative exists |

Known issue: `update.sh` fails in Git Bash at the step where `python3` receives an MSYS path (issue #799). Workaround: use WSL2 to run `update.sh` and other Template scripts, even if you edit files via Git Bash/VS Code on Windows.

## Forbidden Constructs (without a wrapper)

| Construct | Problem | Replacement |
|-----------|---------|-------------|
| `sed -i '' ...` | GNU sed does not accept `''` | `sed_inplace` (defined in setup.sh, update.sh) |
| `date -v-Nd` | BSD-only (macOS) | `portable_date_offset N` (defined in role scripts) |
| `osascript` | macOS-only | `osascript \|\| notify-send \|\| true` |
| `launchctl` | macOS-only | Wrap in a `command -v launchctl` guard |
| `readlink -f` | BSD readlink does not support `-f` | `cd "$(dirname "$0")" && pwd` |
| `grep -P` | GNU-only (Perl regex) | `grep -E` (Extended regex) |
| `stat -c` / `stat -f` | GNU vs BSD | Avoid; use `wc`, `ls -l`, `find` |
| `mktemp -d -t` | Inconsistent behavior | `mktemp -d` (no template) |
| `timeout N cmd` | GNU coreutils/Homebrew-only — `command not found` on stock macOS without Homebrew (issue #1108) | `iwe_timeout` (`lib/common.sh`) — delegates to real `timeout`, otherwise uses a Perl polyfill |
| `md5sum` | GNU-only, no macOS equivalent (issue #1108) | `iwe_md5` (`lib/common.sh`) — delegates to `md5sum`, otherwise uses BSD `md5` |
| `sha256sum` | GNU-only; available in `/sbin` only on macOS 26+, absent on older versions (issue #1108) | `iwe_sha256` (`lib/common.sh`) — delegates to `sha256sum`, otherwise uses `shasum -a 256` |
| `flock -n/-x/-s ...` | util-linux/Homebrew-only, absent on stock macOS — a bare call fails with `command not found`, which code incorrectly treated as "lock already held" (issue #1108) | `command -v flock` guard + mkdir-fallback lock (reference: `scripts/ledger-append.sh`, `scripts/wp-pool-cascade.sh`) |
| `${var,,}` / `${var^^}` | bash 4+ (lowercase/uppercase expansion) — `bad substitution` on bash 3.2, the default `/bin/bash` on stock macOS (issue #1108) | `$(printf '%s' "$var" \| tr '[:upper:]' '[:lower:]')` |

## Wrappers (copy-paste at the top of a script)

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
# not a copy-paste function — inline one-liner replacement at point of use
lower=$(printf '%s' "$var" | tr '[:upper:]' '[:lower:]')
```

### timeout / md5 / sha256 — via lib/common.sh, not copy-paste

Unlike the wrappers above (local, no external dependencies), these three are
sufficiently complex (Perl polyfill `timeout`, GNU/BSD branching) and are
already centralized in `scripts/lib/common.sh` — do not duplicate them inline:

```bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
iwe_timeout 30 some_cmd   # instead of bare `timeout 30 some_cmd`
iwe_sha256 < "$FILE"      # instead of bare `sha256sum`
echo -n "$x" | iwe_md5    # instead of bare `md5sum`
```

Path to `lib/common.sh` is relative to the calling script (`scripts/*.sh` →
`lib/common.sh`; outside `scripts/` — see `.claude/lib/capture_writer.sh` for
an example of a relative path from a different directory).

### flock — guard + mkdir-fallback, not copy-paste

`flock(1)` is absent on stock macOS, and a bare `command not found` is easy to
mistake for "lock already held" (issue #1108). No ready-made `iwe_*` helper
exists — the lock is tied to a specific `$LOCK_FILE` and the blocking/non-blocking
wait semantics of the calling script, so the pattern is not parameterized in
`lib/common.sh`. Reference implementations (copy and adapt, do not reinvent):
`scripts/ledger-append.sh` (blocking `-w 10`, with dead-lock reclaim by PID+hostname)
and `scripts/wp-pool-cascade.sh` (non-blocking `-n`, same reclaim logic, no retry loop).

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

Alternatively, run directly: `bash scripts/check-platform-compat.sh` — the same checklist as a CI gate (`check_guarded`/`check_forbidden` for each row in the table above), not just a list for manual review.

---

*Last updated: 2026-10-05 (issue #1108: timeout/md5sum/sha256sum/flock/bash4-isms)*