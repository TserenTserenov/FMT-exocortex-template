---
browser_safe: false
description: Set up WakaTime time-tracking for Claude Code and VS Code.
name: setup-wakatime
routing:
  deterministic: false
  executor: sonnet
user_invocable: true
---

# Setup WakaTime Time Tracking

Automated WakaTime setup for tracking working time.

## What Gets Installed

1. **wakatime-cli** — CLI for sending heartbeats
2. **Claude Code Hook** — automatic tracking during Claude sessions (category "AI Coding")
3. **WakaTime Desktop App** (optional) — window focus tracking (reading, browser)

## Instructions for Claude

Complete each step in order. Before each step, check whether it is already done.

### Step 1: wakatime-cli

```bash
# Check for presence (wildcard, not exact name — issue #1151: the VS Code
# extension on Windows downloads the binary as wakatime-cli-windows-amd64.exe)
ls ~/.wakatime/wakatime-cli* 2>/dev/null || wakatime-cli --version 2>/dev/null
```

If not installed — the path depends on the OS:

**macOS:**
```bash
brew install wakatime-cli
mkdir -p ~/.wakatime
ln -sf $(which wakatime-cli) ~/.wakatime/wakatime-cli
```

**Windows (issue #1151):** no package manager is available for direct CLI installation.
Install the WakaTime extension for VS Code (Extensions → WakaTime) — it automatically
downloads the binary to `~/.wakatime/wakatime-cli-windows-amd64.exe` on first launch.
Steps 2–4 then work as-is: the template scripts search for the file using the
`wakatime-cli*` wildcard, not an exact name. Alternative without WakaTime:
ActivityWatch via `extensions/day-close.before.*.md` (see extension README).

**Linux:** see https://wakatime.com/plugins — use the distribution package or
download the binary manually to `~/.wakatime/wakatime-cli`.

### Step 2: API Key

```bash
cat ~/.wakatime.cfg 2>/dev/null
```

If the file does not exist or `api_key` is missing:
1. Tell the user: "A WakaTime API key is required. Get it at https://wakatime.com/settings/api-key (registration required). Paste the key here."
2. Wait for a response.
3. Write the configuration:
```bash
# ~/.wakatime.cfg
[settings]
api_key = <key from user>
```

### Step 3: Hook Script

This hook is not included in the template distribution (removed from the platform in v0.34 — user-installed hook only, issue #215): create the file directly with the content below; do not copy it from the repository.
```bash
mkdir -p ~/.claude/hooks
cat > ~/.claude/hooks/wakatime-heartbeat.sh << 'EOF'
#!/bin/bash
# Claude Code → WakaTime heartbeat hook
# Sends heartbeats to track AI coding time per project.
# Events: UserPromptSubmit, PostToolUse, Stop

INPUT=$(cat)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty')
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')

# Detect project from git or folder name
if [ -n "$CWD" ] && [ -d "$CWD" ]; then
  PROJECT=$(cd "$CWD" && git config --local remote.origin.url 2>/dev/null | sed 's#.*/\([^.]*\)#\1#;s#\.git$##')
  PROJECT=${PROJECT:-$(basename "$CWD")}
else
  PROJECT="Unknown"
fi

# Category based on event/tool
CATEGORY="ai coding"
if [ "$EVENT" = "PostToolUse" ]; then
  case "$TOOL" in
    WebSearch|WebFetch) CATEGORY="researching" ;;
    Read|Grep|Glob)    CATEGORY="code reviewing" ;;
    Edit|Write)        CATEGORY="coding" ;;
  esac
fi

# Resolve the CLI binary by mask, not exact name — issue #1151: the VS Code
# WakaTime extension on Windows downloads it as wakatime-cli-windows-amd64.exe.
WAKATIME_CLI=$(ls -d "$HOME"/.wakatime/wakatime-cli* 2>/dev/null | head -1)
[ -z "$WAKATIME_CLI" ] && exit 0

# Send heartbeat in background (non-blocking, silent)
("$WAKATIME_CLI" \
  --entity-type app \
  --entity "Claude Code" \
  --category "$CATEGORY" \
  --project "$PROJECT" \
  --plugin "claude-code-wakatime/0.1.0" \
  --write \
  >/dev/null 2>&1 &)

exit 0
EOF
chmod +x ~/.claude/hooks/wakatime-heartbeat.sh
```

### Step 4: Hook Configuration in settings.json

Read `~/.claude/settings.json`. Add the following entries to the `hooks` section without removing any existing hooks:

- **UserPromptSubmit** — add a hook group:
  ```json
  {"hooks": [{"type": "command", "command": "~/.claude/hooks/wakatime-heartbeat.sh"}]}
  ```
- **PostToolUse** — add:
  ```json
  {"hooks": [{"type": "command", "command": "~/.claude/hooks/wakatime-heartbeat.sh", "async": true}]}
  ```
- **Stop** — add:
  ```json
  {"hooks": [{"type": "command", "command": "~/.claude/hooks/wakatime-heartbeat.sh", "async": true}]}
  ```

### Step 5: WakaTime Desktop App (macOS only — ask the user)

On Windows/Linux there is no `brew` equivalent for this step — skip it silently
(ActivityWatch from Step 1 already covers window focus tracking where needed).

Ask: "Install WakaTime Desktop App? It tracks window focus time (when you are reading responses or working in a browser). Requires Accessibility permission on macOS."

If yes:
```bash
brew install --cask wakatime
open -a WakaTime
```
Say: "Grant Accessibility access in System Settings → Privacy & Security → Accessibility."

### Step 6: Test

```bash
echo '{"cwd": "'$(pwd)'", "hook_event_name": "UserPromptSubmit", "prompt": "test"}' | ~/.claude/hooks/wakatime-heartbeat.sh
sleep 3
WAKA_CLI=$(ls -d ~/.wakatime/wakatime-cli* 2>/dev/null | head -1)
"$WAKA_CLI" --today
```

Show the result to the user. Say: "Hooks will be picked up on the next Claude Code launch (hooks are loaded at session start)."

### Step 7: Summary

Show a table:

| Component | Status |
|-----------|--------|
| wakatime-cli | ✅/❌ |
| API key | ✅/❌ |
| Hook script | ✅/❌ |
| Hooks in settings.json | ✅/❌ |
| Desktop App | ✅/❌/skipped |
| Heartbeat test | ✅/❌ |

Say: "Dashboard: https://wakatime.com/dashboard. Data will appear within 5–15 minutes."
