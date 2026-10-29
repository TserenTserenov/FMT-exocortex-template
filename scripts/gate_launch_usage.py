"""Bounded, in-memory observation of a dispatcher-owned CLI launch.

Only native assistant message identities count as observed calls. Neither a
process launch nor a final result establishes a model call. No prompt, response,
tool content or error text is sent to the Gate journal.
"""

from __future__ import annotations

import hashlib
import json
import os
import selectors
import signal
import sys
import time
import uuid

try:
    import iwe_gate
except ImportError:
    iwe_gate = None

TOKEN_FIELDS = (
    "input_tokens",
    "output_tokens",
    "cache_read_input_tokens",
    "cache_creation_input_tokens",
)
MAX_LINE_BYTES = 8 * 1024 * 1024
MAX_TEXT_BYTES = 8 * 1024 * 1024
MAX_OBSERVATIONS = 20000


def _warn(reason: str) -> None:
    # Do not include exception messages: they can contain caller data.
    print(f"[gate_launch_usage] WARN: {reason}", file=sys.stderr)


class LaunchUsage:
    """Observe one CLI invocation; an inherited launch ID is always replaced."""

    def __init__(self, provider: str, gate_context: dict | None = None):
        self.provider = provider
        self.scope_id = str(uuid.uuid4())
        self.started_at = time.monotonic()
        self.context = {"source": "dispatcher", "workload": "process"}
        if iwe_gate is not None:
            try:
                self.context = iwe_gate.execution_context(**self.context)
            except Exception as exc:
                _warn(f"telemetry context unavailable ({type(exc).__name__})")
        self.parent = dict(gate_context or {})
        self.seen: set[bytes] = set()
        self.call_count = 0
        self.complete_count = 0
        self.issues: set[str] = set()
        self.result: str | None = None
        self.result_error = False
        self.output_limited = False
        self.finished = False
        self.telemetry_failed = False

    def child_env(self) -> dict:
        return {**os.environ, "IWE_GATE_MODEL_SCOPE_ID": self.scope_id}

    def _emit(self, event: str, *, context=None, **fields) -> None:
        try:
            if iwe_gate is None:
                raise RuntimeError("gate unavailable")
            written = iwe_gate.log_execution(
                context if context is not None else self.context,
                event,
                scope_id=self.scope_id,
                scope_kind="launch",
                provider=self.provider,
                **fields,
            )
            if not written:
                raise RuntimeError("gate write failed")
        except Exception as exc:  # telemetry must not change execution results
            if not self.telemetry_failed:
                _warn(f"telemetry unavailable ({type(exc).__name__})")
            self.telemetry_failed = True

    def started(self) -> None:
        self._emit("model_scope_started", executor_kind=self.provider)
        if self.parent.get("decision_id"):
            self._emit("model_scope_linked", context={**self.context, **self.parent})

    def observe_line(self, line: bytes) -> None:
        if not line.strip():
            return
        try:
            event = json.loads(line)
        except (ValueError, UnicodeError, RecursionError):
            self.issues.add("malformed_stream")
            return
        if not isinstance(event, dict):
            self.issues.add("malformed_stream")
            return
        kind = event.get("type")
        if kind == "result":
            # Subagent results cannot replace the dispatcher's final text.
            if event.get("parent_tool_use_id") is None:
                value = event.get("result")
                self.result = value if isinstance(value, str) else None
                self.result_error = event.get("is_error") is True or str(
                    event.get("subtype", "")
                ).startswith("error")
        elif kind == "assistant":
            self._observe_assistant(event)
        elif kind == "stream_event":
            # Partial deltas are not complete per-call usage observations.
            self.issues.add("partial_usage")

    def _observe_assistant(self, event: dict) -> None:
        message = event.get("message")
        if not isinstance(message, dict):
            self.issues.add("malformed_stream")
            return
        call_id = message.get("id")
        if not isinstance(call_id, str) or not call_id.strip():
            self.issues.add("missing_usage")
            return
        usage = message.get("usage")
        tokens = {
            key: usage[key]
            for key in TOKEN_FIELDS
            if isinstance(usage, dict)
            and type(usage.get(key)) is int
            and usage[key] >= 0
        }
        fields = {
            "call_id": call_id,
            "tokens": tokens,
            "call_kind": "subagent"
            if event.get("parent_tool_use_id") is not None
            else "root",
        }
        model = message.get("model")
        if isinstance(model, str) and model.strip():
            fields["model"] = model
        native_session = event.get("session_id")
        if isinstance(native_session, str) and native_session.strip():
            fields["native_session_id"] = native_session
        fingerprint = hashlib.sha256(
            json.dumps(fields, sort_keys=True).encode()
        ).digest()
        if fingerprint in self.seen:
            return
        if len(self.seen) >= MAX_OBSERVATIONS:
            self.issues.add("observation_limit")
            return
        self.seen.add(fingerprint)
        self.call_count += 1
        if len(tokens) == len(TOKEN_FIELDS) and "model" in fields:
            self.complete_count += 1
        else:
            self.issues.add("partial_usage" if tokens else "missing_usage")
        self._emit("model_call_observed", **fields)

    def finish(self, status: str, reason: str | None = None, exit_code=None) -> None:
        if self.finished:
            return
        self.finished = True
        if self.provider != "claude":
            coverage, reason = "unknown", "unsupported_provider"
        elif self.issues:
            coverage = (
                "partial"
                if self.complete_count or "partial_usage" in self.issues
                else "unknown"
            )
            reason = reason or sorted(self.issues)[0]
        elif self.complete_count:
            coverage = "observed_calls" if status == "complete" else "partial"
            reason = reason or "observed"
        else:
            coverage, reason = "unknown", reason or "missing_usage"
        self._emit(
            "model_scope_finished",
            status=status,
            coverage=coverage,
            reason=reason,
            duration_ms=int((time.monotonic() - self.started_at) * 1000),
            exit_code=exit_code,
        )


class PipeCapture:
    """Drain both pipes while the child is running, with bounded memory.

    Oversized JSON lines are discarded up to their newline; later complete
    observations are still read. Text truncation is a failed output contract,
    never a successful truncated answer. Raw data never reaches the filesystem.
    """

    def __init__(self, proc, usage: LaunchUsage):
        self.usage = usage
        self.selector = selectors.DefaultSelector()
        self.pending = bytearray()
        self.dropping_line = False
        self.text = bytearray()
        self.errors = bytearray()
        for name, stream in (("stdout", proc.stdout), ("stderr", proc.stderr)):
            os.set_blocking(stream.fileno(), False)
            self.selector.register(stream, selectors.EVENT_READ, name)

    @property
    def open(self) -> bool:
        return bool(self.selector.get_map())

    def drain(self, timeout=0.1) -> None:
        for key, _ in self.selector.select(timeout):
            try:
                chunk = os.read(key.fd, 65536)
            except BlockingIOError:
                continue
            if not chunk:
                self.selector.unregister(key.fileobj)
                key.fileobj.close()
                if key.data == "stdout":
                    self._flush_line()
            elif key.data == "stderr":
                # Error output remains bounded and is returned only to the caller.
                self.errors.extend(chunk)
                del self.errors[:-MAX_TEXT_BYTES]
            elif self.usage.provider == "claude":
                self._consume_json(chunk)
            else:
                remaining = MAX_TEXT_BYTES - len(self.text)
                self.text.extend(chunk[:remaining])
                if len(chunk) > remaining:
                    self.usage.output_limited = True

    def _consume_json(self, chunk: bytes) -> None:
        fragments = chunk.split(b"\n")
        for index, fragment in enumerate(fragments):
            if not self.dropping_line:
                if len(self.pending) + len(fragment) <= MAX_LINE_BYTES:
                    self.pending.extend(fragment)
                else:
                    self.pending.clear()
                    self.dropping_line = True
                    if "output_limit_exceeded" not in self.usage.issues:
                        _warn("stream line exceeded the observation limit")
                    self.usage.issues.add("output_limit_exceeded")
                    # We cannot tell whether the discarded line was the final
                    # result. Never reuse an earlier result after a lost line;
                    # a later intact result can still complete the work.
                    self.usage.result = None
            if index < len(fragments) - 1:
                self._flush_line()

    def _flush_line(self) -> None:
        if self.pending and not self.dropping_line:
            self.usage.observe_line(bytes(self.pending))
        self.pending.clear()
        self.dropping_line = False

    def output(self) -> tuple[str, str]:
        text = (
            self.usage.result
            if self.usage.provider == "claude"
            else self.text.decode("utf-8", "replace")
        )
        return text or "", self.errors.decode("utf-8", "replace")

    def close(self) -> None:
        for key in list(self.selector.get_map().values()):
            self.selector.unregister(key.fileobj)
            key.fileobj.close()
        self.selector.close()


def kill_owned_process(proc) -> None:
    """The dispatcher creates a new session, so only its own descendants die."""
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        return
    except OSError as exc:
        _warn(f"process group termination failed ({type(exc).__name__})")
        proc.kill()


def drain_after_exit(proc, capture: PipeCapture) -> None:
    """Reap the child and drain pending observations even after timeout/stop."""
    deadline = time.monotonic() + 5
    while capture.open and time.monotonic() < deadline:
        capture.drain()
    if capture.open:
        # A descendant retained a pipe after the direct child exited.
        kill_owned_process(proc)
        capture.usage.issues.add("incomplete_stream")
        deadline = time.monotonic() + 1
        while capture.open and time.monotonic() < deadline:
            capture.drain()
    proc.wait(timeout=5)
