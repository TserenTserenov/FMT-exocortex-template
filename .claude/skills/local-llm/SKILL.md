---
agents: single
browser_safe: false
description: Local LLM stack on Mac (Apple Silicon, MLX) for privacy and fallback
  mode. Natural-language entry point for installing, running, and switching models,
  plus a judgment layer for monitoring new models. Thin wrapper over the WP404 scripts
  — not a replacement.
gates_enforced: []
gates_rationale: operational skill; WP Gate applicable only when creating a new WP,
  not for operational calls
gates_required: []
interaction: multi-step
layer: L1
name: local-llm
routing:
  deterministic: false
  executor: script+judgment
  optimization_priority: 2
status: active
triggers:
  phrases:
  - install a local model
  - set up a local model
  - run a local model
  - show models
  - what models are available
  - switch model
  - switch to 14B
  - what new models have been released
  - check for new models
  slash:
  - /local-llm
user_invocable: true
version: 1.0.0
---

# Local LLM Stack (local-llm)

> **Scope:** Natural-language entry point for the local LLM stack (install / start / status / switch model) plus a judgment layer for evaluating new model monitor findings.
> **Not in scope:** mechanics (installation, states, switching, archive) — those live in deterministic scripts (Distinction: Script ≠ Agent). The Skill **calls** them; it does not duplicate their logic. The source of truth for model statuses is the catalog and `model-lifecycle.py`.
> **Stack JOB:** privacy (tasks with personal data that cannot be sent to the cloud) and fallback mode (no network / cloud tokens exhausted). See `ADR-001-local-llm-stack.md`.

## Bundle location

The control scripts are a self-contained bundle (each runs from its own directory).
The path is resolved via an env variable; the default is `extensions/local-llm/` inside the IWE installation:

```bash
BUNDLE="${IWE_LOCAL_LLM_DIR:-$HOME/IWE/extensions/local-llm}"
```

- Stack venv: `~/.iwe-local-llm/.venv` (installed by the installer).
- Active model and server state: `~/.iwe-local-llm/` (`active-model`, `server.pid`, `server.log`).

## When to use

- "install local model" → hardware-matched installation (Step 1).
- "show models" / "what models are available" → list by state (Step 2).
- "start / stop" / "status" → server management (Step 2).
- "switch model" / "switch to 14B" → change active model (Step 3).
- "what new models are out" / "check new models" → monitor and judgment on adopt (Step 4).

## Algorithm

### Step 1 — installation (mechanics → script)

```bash
bash "$BUNDLE/install-local-llm.sh"          # recommended model for the hardware
bash "$BUNDLE/install-local-llm.sh" --max    # heaviest model that fits
```

The installer is idempotent: detect hardware → select model from catalog by memory → venv + mlx-lm → download → smoke test. Show the user the result (model name, confirmation that the server started).

### Step 2 — start / status / list (mechanics → script)

```bash
bash "$BUNDLE/iwe-local-llm.sh" start    # start server (OpenAI-compatible, localhost:8080)
bash "$BUNDLE/iwe-local-llm.sh" status   # active model + server state
bash "$BUNDLE/iwe-local-llm.sh" models   # all models across four states + download status
bash "$BUNDLE/iwe-local-llm.sh" stop     # stop server
bash "$BUNDLE/iwe-local-llm.sh" test     # check compatible interface (SHIM_OK)
```

IWE tools connect to `http://127.0.0.1:8080/v1/chat/completions` using the same client as for the cloud.

### Step 3 — switching models (mechanics → script)

```bash
bash "$BUNDLE/iwe-local-llm.sh" use <model-id>    # download + activate + restart
bash "$BUNDLE/iwe-local-llm.sh" pull <model-id>   # download only for testing (→ testing)
bash "$BUNDLE/iwe-local-llm.sh" archive <model-id># move to archive
```

`use` moves the previous active model to `testing` (it remains downloaded). Exactly one model is active at a time. Do not edit `model-catalog.yaml` by hand — use only `iwe-local-llm.sh` / `model-lifecycle.py` (preserves comments, maintains the single-active invariant).

### Step 4 — monitoring new models (judgment → LLM work)

```bash
BUNDLE="${IWE_LOCAL_LLM_DIR:-$HOME/IWE/extensions/local-llm}"
PY3="$(bash "${IWE_SCRIPTS:-$HOME/IWE/scripts}/lib/find-python3.sh")" && "$PY3" "$BUNDLE/model-monitor.py"    # digest of trending models not yet in the catalog
```

The monitor only **finds** candidates. The adopt decision is the agent's judgment (this is the LLM work the Skill exists to support):

1. Compare the candidate against the current active model on **quality** (LMArena / benchmarks, if the user provides a link or asks for a comparison).
2. Verify **JOB fit**: privacy (offline, no telemetry) and fits Mac memory (`min_ram_gb` ≤ hardware).
3. Give a recommendation: add to the catalog (`model-lifecycle.py add`) and `pull` for comparison, or skip with a reason.
4. The decision to change the active model belongs to the user. The Skill recommends; it does not switch silently.

## Anti-patterns

- **Duplicating mechanics in the Skill.** States, switching, and archiving belong in the scripts. The Skill calls them; it does not rewrite them (OwnerIntegrity: catalog = source of truth).
- **Silently switching the active model** based on a monitor finding. Adopt is the user's decision after a quality comparison.
- **Sending prompt contents to the cloud** when the local stack is chosen for privacy — the stack exists precisely to prevent this.
- **Editing `model-catalog.yaml` by hand** — breaks comments and the single-active invariant; use lifecycle commands only.

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
