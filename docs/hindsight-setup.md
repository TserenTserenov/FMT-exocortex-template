# Hindsight Setup Guide

Quick start for IWE pilots who want semantic fault memory (L2 layer).

## Prerequisites

- Docker Desktop installed and running
- OpenAI API key (or compatible endpoint)
- macOS (this guide; Linux is similar)

## 1. Start Hindsight (3 commands)

```bash
cd exocortex/hindsight
export OPENAI_API_KEY=sk-...
bash start.sh
```

Expected output:
```
Starting Hindsight (localhost:8888)...
Hindsight is ready.
```

## 2. Auto-start on login (optional)

```bash
bash install-launchd.sh
```

## 3. Verify

```bash
curl http://localhost:8888/health
```

Should return `{"status":"ok"}`.

## 4. How agents use it

Once running, IWE agents automatically:
- **Recall** relevant faults before opening a work product or skill
- **Retain** new faults in background (never blocks)
- **Reflect** on weekly patterns during Week Close

No manual action required.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `OPENAI_API_KEY is not set` | Export the key before running `start.sh` |
| `Connection refused` | Run `docker ps` — is `iwe-hindsight` running? |
| `Hindsight did not become healthy` | Check `docker logs iwe-hindsight` |
| Retain not appearing in log | Check `~/.iwe/hindsight.log`; Hindsight may be unavailable |

## Token Budget

| Scenario | Estimate |
|----------|----------|
| One-time ingest (334 facts) | ~$0.60 |
| New faults (5–10/week) | ~$0.03–0.06/week |
| Weekly reflect | ~$0.14 |
| **Monthly total** | **~$5–10** |

## Architecture Note

- **L1 (SQLite)**: Primary source of truth, sync, <10ms. Always works.
- **L2 (Hindsight)**: Semantic memory, async background, ~2.5s retain. Graceful degradation if down.

Hindsight = optional enhancement. IWE works fully without it.
