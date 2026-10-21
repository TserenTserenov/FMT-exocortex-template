# Synchronizer (R8)

> Central dispatcher for exocortex agents: scheduling, notifications, monitoring.

## What It Does

The Synchronizer is a bash tool (not an AI agent) that:
1. **Dispatcher:** Launches the Strategist and Extractor on a schedule
2. **Code Scan:** Nightly scans downstream repositories for activity
3. **Notify:** Sends results to Telegram
4. **Report:** Generates a daily system health report

## Components

| Script | What It Does | Trigger |
|--------|-------------|---------|
| `scheduler.sh` | Central dispatcher: checks the schedule, launches agents | launchd (11×/day) |
| `code-scan.sh` | Scans DS-* repositories for commits in the last 24h | scheduler (00:00) |
| `daily-report.sh` | Health report: traffic-light status, errors, recommendations | scheduler (after morning) |
| `sync-files.sh` | Targeted file sync from remote | scheduler (every 2 min) |
| `notify.sh` | Sends to Telegram using agent templates | After each process |

## Installation

```bash
cd {{WORKSPACE_DIR}}/IWE/roles/synchronizer
bash install.sh
```

### Telegram Notifications (Optional)

Create the file `~/.config/aist/env`:

```bash
export TELEGRAM_BOT_TOKEN="your-bot-token"
export TELEGRAM_CHAT_ID="your-chat-id"
```

Without this file, notifications are simply not sent (scripts do not fail).

### Author-Only Scripts (NOT for End Users)

The following scripts require direct access to the platform's Neon production database
(template author secrets) and **are not intended to run in IWE user environments**:

- `dt-collect.sh` — collects activity and writes to the digital twin via `NEON_URL` + `DT_USER_ID`
- `dt-collect-neon.py` — writer for `dt-collect.sh`

`scheduler.sh` automatically skips `dt-collect.sh` when `NEON_URL` and `DT_USER_ID` are absent from
`~/.config/aist/env`. Users without these secrets will not execute the script — the code included in the
template remains as a marker for a future feature.

**The user-facing path** for writing activity to Memory/digital twin is the MCP tool
`dt_write_digital_twin` in IWE Gateway (the subscription JWT identifies the user; no direct database connection is required).

**The system transition** `dt-collect` → event-gateway (REST endpoint with a service token, without direct psycopg2) is planned as a separate phase in the migration Roadmap WP-253 (`DP.ROADMAP.001-neon-migration.md`) and activates after Phase 3 of creator #2 journal creation. Until then, `dt-collect.sh` remains a transitional Artifact owned by the template author.

## Schedule

| Time (UTC) | Agent | Scenario | Catch-up |
|------------|-------|----------|----------|
| 00:00 | Synchronizer | code-scan | all day |
| 04:00 | Strategist | morning (Mon=session-prep, Tue–Sun=day-plan) | until 22:00 |
| Mon 00:00 | Strategist | week-review | all Monday |
| Every 3h (07–23) | Extractor | inbox-check | interval-based |
| After morning | Synchronizer | daily-report | after 06:00 |

> **Catch-up:** If the computer was asleep and missed a scheduled time, it will run the missed tasks on wake (within the catch-up window).
>
> **Note review (note-review) is not scheduled** — neither in the evening nor as a catch-up run (template owner decision, July 2026). Notes are reviewed manually: during a live session with the pilot (for example, in the "Note Review" section of Day Open), all steps are performed; archiving happens only on the pilot's explicit instruction. Running `strategist.sh note-review` from the terminal proceeds without chat: the runner prepends the following line to the prompt — "MODE: script launch without chat; do not execute step 10 or archiving, only annotations and suggestions" — and the model only classifies notes, adds `✅suggested` annotations, and writes suggestions. This is an instruction to the model, not a technical restriction: the runner only guarantees that the line is included in the prompt. After the run, a safety script executes: it removes notes that have no bold text, no `🔄`, and no `✅suggested` annotation; no archiving on the pilot's instruction and no cleanup occur during the run itself.
>
> **Sleep prevention:** `scheduler.sh` and `strategist.sh` automatically block sleep while running (macOS: `caffeinate -diu`, Linux: `systemd-inhibit`). For laptops, it is also recommended to disable idle sleep at the OS level — see [SETUP-GUIDE.md](../../docs/SETUP-GUIDE.md).

## Files

```
roles/synchronizer/
├── README.md
├── install.sh
├── config.yaml                    # Schedule (reference)
├── scripts/
│   ├── scheduler.sh               # Central dispatcher
│   ├── code-scan.sh               # Nightly scan
│   ├── daily-report.sh            # Health report
│   ├── sync-files.sh              # Targeted sync
│   ├── notify.sh                  # Telegram dispatch
│   ├── templates/
│   │   ├── strategist.sh          # TG template for Strategist
│   │   ├── extractor.sh           # TG template for Extractor
│   │   └── synchronizer.sh        # TG template for Synchronizer
│   └── launchd/
│       └── com.exocortex.scheduler.plist
└── configs/
    └── systems/
        └── .gitkeep               # Future system configurations
```

## State

Launch markers: `~/.local/state/exocortex/`
- `{agent}-{YYYY-MM-DD}` — daily
- `{agent}-W{NN}` — weekly
- `{agent}-last` — interval-based (timestamp)

Logs: `~/logs/synchronizer/`

---

*Source-of-truth: DP.SYS.016 (PACK-digital-platform)*