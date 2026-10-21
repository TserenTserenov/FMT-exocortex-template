# IWE Local LLM Stack (WP404)

A local language model on Mac (Apple Silicon, MLX engine) for two purposes: **privacy** (tasks involving personal data that cannot be sent to the cloud) and **fallback mode** (no network, or cloud tokens exhausted). The decision and rationale are in `ADR-001-local-llm-stack.md`.

## Installation (single command)

```bash
bash install-local-llm.sh          # recommended model for your hardware
bash install-local-llm.sh --max    # heaviest model that fits in memory
```

The installer is idempotent: hardware detection → model selection from catalog based on available memory → environment + mlx-lm → model download → verification. Re-running does not break anything.

## Stack Operations

```bash
bash iwe-local-llm.sh start          # start server (OpenAI-compatible, localhost:8080)
bash iwe-local-llm.sh status         # active model + server state
bash iwe-local-llm.sh test           # verify compatible interface
bash iwe-local-llm.sh models         # all models across four states + download status
bash iwe-local-llm.sh pull <model>   # download model for testing (status -> testing)
bash iwe-local-llm.sh use <model>    # put model into service (download + activate + restart)
bash iwe-local-llm.sh archive <model># move model to archive
bash iwe-local-llm.sh stop           # stop server
```

IWE tools connect to `http://127.0.0.1:8080/v1/chat/completions` using the same client as for the cloud.

## Model Lifecycle (four states)

Each model in the catalog has a status. A model progresses through the following path:

| State | Meaning |
|-------|---------|
| **under analysis** (`analysis`) | discovered by the monitor, under consideration; not yet downloaded |
| **for testing** (`testing`) | downloaded, being compared against the active model |
| **active** (`active`) | in service; the server loads exactly this model; exactly one at a time |
| **archived** (`archived`) | retired from use (obsolete or lost comparison) |

The source of truth is `model-catalog.yaml` (edited with comment preservation via `model-lifecycle.py`). The `models` command shows all four buckets and the actual download status (from cache). When running `use <model>`, the previous active model automatically moves to `testing` (and remains downloaded).

## Discovering New Models (every two weeks)

```bash
python3 model-monitor.py            # digest of trending models not yet in the catalog
```

The monitor compares the catalog against Apple Silicon model trends (HuggingFace). The decision to add a candidate to the catalog belongs to the pilot (manual quality check via LMArena). If you find a model better than the current one — add it to `model-catalog.yaml` and run `use <model>`.

## Files

| File | Purpose |
|------|---------|
| `ADR-001-local-llm-stack.md` | Decision: purpose, engine/model selection, mini security check |
| `model-catalog.yaml` | Model catalog by memory size + lifecycle status + sources (single source of truth) |
| `detect-hardware.sh` | Mac hardware detection → model ceiling |
| `install-local-llm.sh` | Hardware-aware installer |
| `iwe-local-llm.sh` | Stack wrapper (start/test/stop/status/models/pull/use/archive) |
| `model-lifecycle.py` | Model lifecycle management (analysis/testing/active/archived) |
| `model-monitor.py` | Pipeline for discovering new models |

## Security (mini check B7.3)

- The server listens on `127.0.0.1` only — not exposed externally.
- The MLX engine runs offline and does not send telemetry.
- The server log records token counters and request address, not prompt content.
- The fallback engine Ollama includes telemetry — the installer must disable it (on the fallback path).

## Requirements

macOS on Apple Silicon, `uv` (or `python3.12`), approximately 5–10 GB of disk space for the model.