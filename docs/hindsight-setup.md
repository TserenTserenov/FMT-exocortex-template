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

## 4. Manual integration

Hindsight is an optional L2 extension. A standard IWE installation does not
automatically invoke Recall, Retain, or Reflect.

After starting the container, the pilot explicitly connects the calls needed
by their local workflow and decides which data may be sent. The supplied
`scripts/hindsight_trigger.py` is a low-level JSON interface for that local
integration; it is not registered as a default hook.

The peer adapters have one narrow opt-in: setting `IWE_HINDSIGHT_RETAIN=1`
allows them to retain peer responses. Without this setting, those adapters do
not send their responses to Hindsight. Recall and Reflect require a separately
configured local integration.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `OPENAI_API_KEY is not set` | Export the key before running `start.sh` |
| `Connection refused` | Run `docker ps` — is `iwe-hindsight` running? |
| `Hindsight did not become healthy` | Check `docker logs iwe-hindsight` |
| Explicit peer retain not appearing in log | Check `~/.iwe/hindsight.log`; Hindsight may be unavailable |

## Token Budget

| Scenario | Estimate |
|----------|----------|
| One-time ingest (334 facts) | ~$0.60 |
| Optional retain (5–10 explicit events/week) | ~$0.03–0.06/week |
| Optional reflect (one explicit run/week) | ~$0.14 |
| **Monthly total** | **~$5–10** |

## Architecture Note

- **L1 (SQLite)**: Primary source of truth, sync, <10ms. Always works.
- **L2 (Hindsight)**: Semantic memory. An explicitly configured retain call is async (~2.5s); local integration degrades gracefully if it is down.

Hindsight = optional enhancement. IWE works fully without it.
