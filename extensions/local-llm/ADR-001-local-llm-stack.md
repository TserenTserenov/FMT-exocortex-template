# ADR-001 — Local LLM Stack on Mac (RP404)

> Decision record (lightweight, not ArchGate). Source: peer session 2026-06-10-26-local-llm-stack-mac (Claude + Kimi).
> Date: 2026-06-10. Status: accepted.

## Context

The entire IWE runs on cloud models (Claude, Kimi). A local LLM on the pilot's Mac is a new role in the system. Before selecting a model, define its JOB.

## JOB (purpose of the local model)

**Primary (co-primary, compatible at the Deployment level — both local, no cloud):**
1. **Privacy** — tasks involving PII (secret scrubbing, personal data) that cannot be sent to the cloud. Cloud providers do not cover this without an enterprise contract.
2. **Fallback** — operation without internet access, or when cloud token quotas are exhausted. Degraded mode: substituting the cloud for simple tasks.

**Secondary (bonus, if hardware allows):** cheap bulk processing. NOT a selection driver — covered by cloud tiers (Haiku, Flash).

**Spun off from RP404 (spin-off):** a free model on the platform server for high-volume tasks (homework checker) — different target (server, not Mac), different JOB (bulk for platform users), triggers IntegrationGate plus hosting cost questions. → quick-feasibility spike (1–2h) within WP-337 → then a separate RP through WP Gate.

## Hardware (detected 2026-06-10)

| Parameter | Value |
|-----------|-------|
| Chip | Apple M4 (Mac16,13) |
| Unified memory | 32 GB |
| macOS | 26.3.1 |
| CPU cores | 10 |
| Disk free | 93 GB |
| Python (system) | 3.14.3 (homebrew) |
| Runtimes | none (no MLX, Ollama, LM Studio) |

> The stack Environment (venv) is built on **Python 3.12** (`IWE_LLM_PYVER`, installer default) — MLX wheels are guaranteed for this version. The system Python 3.14.3 is too recent and unreliable for MLX. These are distinct things: 3.14.3 is what was found on the system; 3.12 is what the venv is built on.

## Decisions

### 1. Runtime: MLX primary, Ollama fallback
- **MLX** (native Apple Silicon) — fastest on M-series hardware; **offline by design, sends no telemetry** (critical for the privacy JOB — B7.3 satisfied out of the box).
- Ollama — fallback (simpler, more ready-made models), but has telemetry → requires explicit blocking. On the fallback path, the installer must hard-set the env variable that disables telemetry.

### 2. Model: one general ~7–8B model, on-demand without keep-alive
- **Trade-off (explicit):** we sacrifice an optimally lightweight PII model and instant fallback response in exchange for the simplicity of "one model, one install." Fallback is a degraded mode; a one-time load time of 15–30 seconds is acceptable.
- **Branch by RAM (detection decides, no guessing):**
  - RAM ≤ 16 GB → one general ~7–8B model, on-demand. No second model.
  - **RAM ≥ 32 GB (our case) → one general ~7–8B as MVP; optionally a second lightweight model (3–4B) for instant privacy — NOT mandatory, at the pilot's discretion later.**
- **MVP model:** `mlx-community/Qwen2.5-7B-Instruct-4bit` (~4.3 GB, fits comfortably within 32 GB RAM and 93 GB disk). A strong general model with solid mlx-community support.

### 3. Integration: OpenAI-compatible API shim (required)
- Without a compatible endpoint, the local model is a standalone toy. Existing IWE tools must switch to the local model using the same client they use for the cloud.
- Implementation: `mlx_lm.server` (OpenAI-compatible `/v1/chat/completions`) on localhost. This makes the local model a real tier in Model Tiering (WP-337).

### 5. Model lifecycle (four states)

Every model in the catalog has a status: `analysis` (under consideration, found by monitor) → `testing` (downloaded for comparison) → `active` (in use, exactly one) → `archived` (retired). The source of truth is `model-catalog.yaml` (edited with comment preservation via `model-lifecycle.py`). Download status is verified against the HuggingFace cache (actual reality, not a flag). The "exactly one active" invariant is enforced on the `use`/`set active`/`add` paths (the previous active model is demoted to `testing`).

### 4. Mini security check B7.3 (privacy JOB involves PII)
- [ ] Runtime does not send telemetry externally (MLX — confirmed; Ollama fallback — env blocking).
- [ ] `mlx_lm.server` / wrapper does not write prompts or PII to disk (explicit log Audit, not "probably does not write by default").
- [ ] Server binds only to localhost (127.0.0.1), not 0.0.0.0.

## RP404 Phases (revised)

| Phase | Content | Estimate |
|-------|---------|----------|
| P0 | ADR + hardware detection + mini B7.3 check | ~1h |
| P1 | MLX install + MVP model + API shim + smoke test on PII task | ~2h |
| P2 | Biweekly SOTA monitoring via process-catalog.yaml (sources: LMArena + HF trending + MLX-community) | ~1h |
| P3 | Hardware-aware FMT installer + selection criteria + Ollama telemetry blocking | ~2.5h |
| P4 | Documentation + Verification | ~1h |

## Rejected

- **Full ArchGate** — disproportionate for a personal tool on a single machine (the standard checklist would have passed trivially). A lightweight ADR is sufficient.
- **Fixed "golden" model in FMT** — unworkable across pilots with different hardware ("Suit ≠ Equipment", DP.D.131). We distribute the selection process and installer instead.
- **llama-2 / claude.ai as candidates** (original RP criterion) — llama-2 is three generations behind; claude.ai is categorically not a local model.
- **Weekly monitoring** — excessive; biweekly matches the MLX-quantized release cycle (2–3 weeks).