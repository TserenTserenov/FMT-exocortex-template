# Capture Detectors

> **Dispatcher:** [../hooks/capture-bus.sh](../hooks/capture-bus.sh)
> **Registry:** [../config/capture-detectors.sh](../config/capture-detectors.sh)

## Interface Contract

A detector is an executable script (shell by default) that:

1. **Input** — reads JSON from stdin (harness hook input): `tool_name`, `tool_input`, `tool_response`, `cwd`, `session_id`, `hook_event_name`.
2. **Output** — either empty stdout (no event detected), or exactly one JSON line:
  ```json
  {
    "event_type": "agent_incident",
    "payload": { ... },
    "repo_ctx": { "target_repo_hint": "/abs/path" }
  }
  ```
3. **Exit** — `0` always (regardless of whether an event was detected). A non-zero exit is an error; the dispatcher logs `detector_error` and continues.

## Rules

- **One detector = one event per invocation.** If you need more, use two detectors, or emit the second event on the next tool call.
- **`repo_ctx.target_repo_hint` is required.** The detector itself determines the target repo (via `tool_input.file_path`, `cwd`, or session context). If it cannot determine the target unambiguously, it emits empty stdout — it does not guess. The writer rejects writes without a hint (no fallback).
- **Rule-based by default.** `cost_class: free` — regex, string match, explicit conditions. `cost_class: llm` — LLM-as-judge calls, disabled by default.
- **Latency ≤30ms per invocation.** The detector runs on every PostToolUse. Bus budget is ≤150ms for 4–5 active detectors.

## Add a New Detector

1. Copy `detector_incident.sh` as a template.
2. Replace the logic in the body — keep the structure (input parse → detection → emit/skip).
3. Register it in `config/capture-detectors.sh`:
  ```bash
  "NAME|.claude/detectors/detector_NAME.sh|EVENT_TYPE|free|true|PostToolUse,Stop"
  ```
4. Run `chmod +x` on the new detector.
5. If `event_type` is new — add routing in `lib/capture_writer.sh` (case statement) and in spec §4.3.
6. Run a dry-run (see below) before setting enable=true.

## Dry-Run

Test a detector without writing to the incident log:

```bash
echo '{
  "hook_event_name": "PostToolUse",
  "tool_name": "Write",
  "tool_input": {"file_path": "/Users/.../IWE/<governance-repo>/random-file.md"},
  "cwd": "/Users/.../IWE/<governance-repo>"
}' | .claude/detectors/detector_incident.sh
```

Expected result: stdout contains a JSON event (if matched) or is empty.

## Debugging

All activations and errors are written to `.claude/logs/capture_log.jsonl`:

```bash
tail -f ~/IWE/.claude/logs/capture_log.jsonl | jq .
```

Statuses:
- `fired` — event written to the target repo
- `skip` — detector ran, no event detected
- `detector_error` — detector failed (exit != 0 or stderr)
- `writer_reject` — writer rejected the write (target_repo_unresolved, unknown_event_type, …)