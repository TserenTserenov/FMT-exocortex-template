#!/usr/bin/env bash
# routing: utility  deterministic=true
# see DP.SC.159, DP.ROLE.059
# setup-extractor-feeders.sh — Onboarding onboarding script for activating feeder-system
# (WP-247 Phase-MULTI-SOURCE).
#
# What it does:
#  1. Checks the platform (macOS/Linux)
#  2. Creates launchd plist (macOS) or systemd timer (Linux) for git-diff-feed
#  3. Enables git-templates for post-commit hook (one command)
#  4. Creates an empty fleeting-notes.md if it does not exist
#  5. Reports what is enabled
#
# Usage:
#   bash {{IWE_TEMPLATE}}/scripts/setup-extractor-feeders.sh
#   bash {{IWE_TEMPLATE}}/scripts/setup-extractor-feeders.sh --check  # check only
#   bash {{IWE_TEMPLATE}}/scripts/setup-extractor-feeders.sh --uninstall

set -euo pipefail

# issue #768: this script hardcoded $HOME/IWE everywhere below, ignoring
# IWE_WORKSPACE entirely -- update.sh's caller comment used to say "the
# feeders script never reads it" as if that were a fact of nature, when it
# was really just this script never having been written to read it. A
# workspace copy running update.sh got its real launchd job silently
# re-pointed at $HOME/IWE regardless of where it actually lived.
IWE_WORKSPACE="${IWE_WORKSPACE:-$HOME/IWE}"
IWE_RUNTIME="${IWE_RUNTIME:-$IWE_WORKSPACE/.iwe-runtime}"
GOVERNANCE_REPO="${IWE_GOVERNANCE_REPO:-DS-strategy}"
EXTRACTOR_SH="$IWE_RUNTIME/roles/extractor/scripts/extractor.sh"
FLEETING="$IWE_WORKSPACE/$GOVERNANCE_REPO/inbox/fleeting-notes.md"

MODE="${1:-install}"

# --schedule-only (WP-5 F55): install just the periodic job. update.sh runs this
# script on EVERY update now, and the two steps below it -- taking over
# ~/.git-templates/hooks/post-commit and the global init.templateDir -- are
# install-time decisions, not something an update may redo behind the user's
# back on a machine where either already points somewhere of their own.
SCHEDULE_ONLY=false
if [ "$MODE" = "--schedule-only" ]; then
    SCHEDULE_ONLY=true
    MODE="install"
fi

log() { echo "[setup-extractor] $*"; }
ok() { echo "  ✅ $*"; }
warn() { echo "  ⚠️  $*"; }
fail() { echo "  ❌ $*"; }

# === 1. Checks ===

log "1/4 Dependency check"

if [ ! -x "$EXTRACTOR_SH" ]; then
    fail "extractor.sh not found in $EXTRACTOR_SH — run update.sh"
    exit 1
fi
ok "extractor.sh found"

# AR.293: the gate inspects the effective program (AI_CLI override of
# extractor.sh), not the literal claude — otherwise override of the call itself
# remains decorative, the schedule is not created under any configuration.
AI_CLI="${AI_CLI:-claude}"
if ! command -v "$AI_CLI" >/dev/null 2>&1; then
    fail "$AI_CLI CLI CLI is not installed (https://docs.anthropic.com/en/docs/claude-code)"
    exit 1
fi
ok "$AI_CLI CLI: $(command -v "$AI_CLI")"

PLATFORM=$(uname -s)
case "$PLATFORM" in
    Darwin)  log "Platform: macOS (using launchd)";;
    Linux)   log "Platform: Linux (using systemd --user)";;
    *)       fail "Unsupported platform: $PLATFORM"; exit 1;;
esac

# === 2. Git-templates (post-commit hook) ===

if $SCHEDULE_ONLY; then
    log "2/4 Git-templates — skipped (schedule-only mode)"
else
# Body deliberately left at its original indentation: it contains a quoted
# heredoc (HOOK) whose leading whitespace would end up inside the generated
# git hook. The block ends at `fi  # SCHEDULE_ONLY` below.
log "2/4 Git-templates for post-commit hook"

GIT_TEMPLATES="$HOME/.git-templates"
TEMPLATE_HOOK="$GIT_TEMPLATES/hooks/post-commit"

# issue #809: v1's SCRIPT_DIR-relative `source` only ever resolved correctly
# inside .git-templates itself — once `git init`/`git clone` copies this hook
# into ANY new repo's .git/hooks/post-commit (that's the whole point of
# init.templateDir), SCRIPT_DIR becomes <that-repo>/.git/hooks, and the
# relative path resolves to a location that never exists. `|| exit 1` then
# silently killed the hook on every commit in every non-IWE repo on the
# machine. Marker bumped to v2 so an already-installed v1 hook (present on
# any machine that ran this script before the fix) gets regenerated the next
# time setup.sh/update.sh calls this script, instead of the grep below
# treating a known-broken hook as "already installed".
HOOK_MARKER="WP-247 Phase-TRIGGER-BASED v2"

if [ "$MODE" = "--check" ]; then
    if [ -f "$TEMPLATE_HOOK" ] && grep -q "$HOOK_MARKER" "$TEMPLATE_HOOK"; then
        ok "post-commit hook in git-templates is installed"
    else
        warn "post-commit hook is not installed — run without --check"
    fi
elif [ "$MODE" = "--uninstall" ]; then
    if [ -f "$TEMPLATE_HOOK" ]; then
        # Remove only our block
        sed -i.bak "/$HOOK_MARKER/,/^fi\$/d" "$TEMPLATE_HOOK"
        ok "post-commit hook (our block) removed"
    fi
else
    mkdir -p "$GIT_TEMPLATES/hooks"
    if [ ! -f "$TEMPLATE_HOOK" ] || ! grep -q "$HOOK_MARKER" "$TEMPLATE_HOOK"; then
        cat > "$TEMPLATE_HOOK" <<HOOK
#!/bin/bash
# post-commit hook — $HOOK_MARKER
# When inbox/captures.md (or its monthly chunks inbox/captures/YYYY-MM.md) or fleeting-notes.md → runs extractor inbox-check
set -uo pipefail

# issue #809: this hook is installed globally and copied into EVERY new repo
# on this machine, not just IWE ones — baked-in absolute root, checked before
# touching anything that only exists inside the IWE workspace, so a foreign
# repo exits immediately instead of failing on a path that was never there.
IWE_ROOT_BAKED="$IWE_WORKSPACE"
REPO_DIR=\$(git rev-parse --show-toplevel 2>/dev/null || echo "")
[[ "\$REPO_DIR" != "\$IWE_ROOT_BAKED"* ]] && exit 0

# Absolute, not \$SCRIPT_DIR-relative (issue #809 — see above).
source "\$IWE_ROOT_BAKED/.claude/lib/iwe-env-bootstrap.sh" || exit 1
REPO_NAME=\$(basename "\$REPO_DIR")
GOVERNANCE_REPO="\${IWE_GOVERNANCE_REPO:-DS-strategy}"
if [ "\$REPO_NAME" = "\$GOVERNANCE_REPO" ]; then
    CHANGED=\$(git diff-tree --no-commit-id -r --name-only HEAD 2>/dev/null | grep -E '^inbox/(captures(/[0-9]{4}-[0-9]{2})?|fleeting-notes)\.md\$' || true)
    if [ -n "\$CHANGED" ]; then
        EXTRACTOR_SH="\$IWE_ROOT/.iwe-runtime/roles/extractor/scripts/extractor.sh"
        [ -x "\$EXTRACTOR_SH" ] && (nohup "\$EXTRACTOR_SH" inbox-check >/dev/null 2>&1 &) 2>/dev/null
    fi
fi
exit 0
HOOK
        chmod +x "$TEMPLATE_HOOK"
        ok "post-commit hook installed in $TEMPLATE_HOOK"
        log "  Apply to existing repos: cd <repo> && git init"
    else
        ok "post-commit hook already installed"
    fi
    git config --global init.templateDir "$GIT_TEMPLATES" || warn "failed to set init.templateDir"
fi
fi  # SCHEDULE_ONLY

# === 3. Cron for git-diff-feed (06:00 / 21:00) ===

log "3/4 Cron for git-diff-feed"

if [ "$PLATFORM" = "Darwin" ]; then
    PLIST="$HOME/Library/LaunchAgents/com.extractor.git-diff-feed.plist"
    if [ "$MODE" = "--check" ]; then
        if [ -f "$PLIST" ]; then ok "launchd plist installed"; else warn "launchd plist not installed"; fi
    elif [ "$MODE" = "--uninstall" ]; then
        if [ -f "$PLIST" ]; then launchctl unload "$PLIST" 2>/dev/null || true; rm "$PLIST"; ok "launchd plist removed"; fi
    else
        # launchd does not create the directory for StandardOutPath on its own and without it does not
        # start. Previously the directory was created only in the. Previously the directory was created only in the Linux-branch
        # roles/extractor/install.sh, meaning on a clean Mac the job was registered
        # and silently failed to launch (WP-5 F55, found during cold review).
        mkdir -p "$HOME/logs/extractor"
        # launchd does not inherit login-shell PATH (WP-5, discovered 03.09 — job was failing
        # exit 127 "claude CLI not found"), therefore PATH must be set explicitly, and
        # do not rely on the launchd default environment launchd by default (/usr/bin:/bin:/usr/sbin:/sbin).
        CLAUDE_BIN_DIR="$(dirname "$(command -v "$AI_CLI")")"
        PLIST_PATH="$CLAUDE_BIN_DIR:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
        IWE_TEMPLATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
        # issue #984: extractor.sh resolves session-guard.sh as ${IWE_SCRIPTS:-$HOME/IWE/scripts};
        # without this key launchd runs it with the fallback, which does not exist,
        # and the feed is verified but never saved.
        IWE_SCRIPTS="${IWE_SCRIPTS:-$IWE_TEMPLATE_DIR/scripts}"
        NEW_PLIST_CONTENT=$(cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>Label</key><string>com.extractor.git-diff-feed</string>
    <key>ProgramArguments</key>
    <array>
        <string>$EXTRACTOR_SH</string>
        <string>git-diff-feed</string>
        <string>12 hours ago</string>
    </array>
    <key>StartCalendarInterval</key>
    <array>
        <dict><key>Hour</key><integer>6</integer><key>Minute</key><integer>0</integer></dict>
        <dict><key>Hour</key><integer>21</integer><key>Minute</key><integer>0</integer></dict>
    </array>
    <key>StandardOutPath</key><string>$HOME/logs/extractor/launchd-git-diff-feed.log</string>
    <key>StandardErrorPath</key><string>$HOME/logs/extractor/launchd-git-diff-feed-error.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key><string>$PLIST_PATH</string>
        <key>HOME</key><string>$HOME</string>
        <key>USER</key><string>${USER:-$(whoami)}</string>
        <key>LOGNAME</key><string>${USER:-$(whoami)}</string>
        <key>IWE_TEMPLATE</key><string>$IWE_TEMPLATE_DIR</string>
        <key>IWE_WORKSPACE</key><string>$IWE_WORKSPACE</string>
        <key>IWE_GOVERNANCE_REPO</key><string>$GOVERNANCE_REPO</string>
        <key>IWE_RUNTIME</key><string>$IWE_RUNTIME</string>
        <key>IWE_SCRIPTS</key><string>$IWE_SCRIPTS</string>
    </dict>
</dict></plist>
PLIST
)
        # Idempotency (WP-5, found 03.09 — setup.sh now calls this on every
        # run, not just a one-off manual invocation): re-installing an
        # unchanged, already-loaded job would still unload/reload it, which
        # could kill a run in flight at exactly 06:00/21:00. Skip only when
        # content is unchanged AND the job is actually loaded -- content
        # unchanged but not loaded (e.g. a prior `launchctl unload` left it
        # stopped) must still fall through to `load`.
        if [ -n "${SETUP_CI:-}" ]; then
            # Issue #1006 (#1010 F6): CI and smoke runs must never touch the real launchd session.
            printf '%s\n' "$NEW_PLIST_CONTENT" > "$PLIST"
            ok "SETUP_CI: plist written to $PLIST, activation launchctl skipped"
        elif [ -f "$PLIST" ] && [ "$(cat "$PLIST")" = "$NEW_PLIST_CONTENT" ] \
            && launchctl list "com.extractor.git-diff-feed" >/dev/null 2>&1; then
            ok "launchd plist already installed and active, no changes"
        else
            # Unload BEFORE overwriting the file: unload reads Label from the CURRENT
            # content on disk. If Label ever-changes in
            # heredoc above, unload after overwriting would remove the job by the NEW
            # Label (which is not yet in the launchd registry launchd), and the old job
            # would remain dangling as an orphan.
            launchctl unload "$PLIST" 2>/dev/null || warn "launchctl unload: job was not loaded (normal on first install)"
            printf '%s\n' "$NEW_PLIST_CONTENT" > "$PLIST"
            launchctl load "$PLIST" 2>/dev/null || warn "launchctl load failed (retry manually)"
            ok "launchd plist installed to $PLIST"
        fi
    fi
elif [ "$PLATFORM" = "Linux" ]; then
    UNIT_DIR="$HOME/.config/systemd/user"
    mkdir -p "$UNIT_DIR"
    if [ "$MODE" = "--uninstall" ]; then
        rm -f "$UNIT_DIR/extractor-git-diff-feed.service" "$UNIT_DIR/extractor-git-diff-feed.timer"
        systemctl --user daemon-reload
        ok "systemd units removed"
    elif [ "$MODE" != "--check" ]; then
        cat > "$UNIT_DIR/extractor-git-diff-feed.service" <<UNIT
[Unit]
Description=IWE Extractor: git-diff-feed (WP-247 Phase-MULTI-SOURCE.2)
[Service]
Type=oneshot
ExecStart=$EXTRACTOR_SH git-diff-feed "12 hours ago"
UNIT
        cat > "$UNIT_DIR/extractor-git-diff-feed.timer" <<TIMER
[Unit]
Description=IWE Extractor git-diff-feed schedule (06:00 + 21:00)
[Timer]
OnCalendar=*-*-* 06:00:00
OnCalendar=*-*-* 21:00:00
Persistent=true
[Install]
WantedBy=timers.target
TIMER
        if [ -n "${SETUP_CI:-}" ]; then
            ok "SETUP_CI: units written to $UNIT_DIR, activation systemd skipped"
        else
            systemctl --user daemon-reload
            systemctl --user enable --now extractor-git-diff-feed.timer
            ok "systemd timer installed and activated"
        fi
    fi
fi

# === 4. Fleeting-notes.md ===

log "4/4 Fleeting-notes inbox"

if [ "$MODE" != "--check" ] && [ "$MODE" != "--uninstall" ] && ! $SCHEDULE_ONLY; then
    if [ ! -f "$FLEETING" ]; then
        mkdir -p "$(dirname "$FLEETING")"
        cat > "$FLEETING" <<'FN'
# Fleeting Notes (quick inbox)

> Quick thoughts land here throughout the day. R2 (extractor) reads both files:
> `captures.md` (formalized) and `fleeting-notes.md` (draft).
> Markers `[analyzed]`/`[processed]`/`[duplicate]`/`[defer]` are applied during processing.

FN
        ok "Created $FLEETING"
    else
        ok "fleeting-notes.md already exists"
    fi
fi

# === Summary ===

echo ""
log "Done."
log "What is included (based on results):"
log " - post-commit hook on changes to captures/fleeting-notes (for a new clone — git init)"
log " - cron 06:00 + 21:00 for git-diff-feed (on this machine)"
log " - fleeting-notes.md inbox created"
log ""
log "What does NOT require configuration (works automatically after update.sh):"
log " - regex fix in pending counter (WP-7 Phase-EXTRACTOR-FP)"
log " - inbox-check reads fleeting-notes as 2-nd inbox (Phase-MULTI-SOURCE.3)"
log " - session-close-feed is called from Quick Close step 2.6 (Phase-MULTI-SOURCE.1)"
log ""
log "Check: $0 --check"
log "Uninstall:  $0 --uninstall"
