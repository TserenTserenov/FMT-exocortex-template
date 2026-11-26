#!/usr/bin/env python3
"""Fallback for the close-protocol check by a helper with a clean context (WP-592 Ф7).

The close protocols (run-protocol step 4, day-close step 11) ask for a helper
(sub-agent "R23") that checks the closing against the checklist without the
closing agent's context. Agents that cannot start a sub-agent (Codex, Kimi Code)
use this program instead: it builds a text projection of the same inputs,
passes it through the peer-adapter filter, and asks ANOTHER agent's peer adapter
(`<verifier>-peer-adapter.sh`, text only, no tools) for a strict JSON verdict.

Design: MC-sessions 2026-11-26-07-wp592-f7-fallback-close (agreed with Kimi).
No text of the diff is sent: only the checklist, the list of changed file names,
the summary and, when given, the card's remaining-work text.

Usage:
  python3 close_verify_fallback.py --verifier kimi|codex|claude|grok \\
      --checklist FILE --files FILE --summary FILE [--remaining FILE] \\
      [--closer claude|kimi|codex|grok] [--timeout SECONDS]

Exit codes (every non-zero code is an honest refusal, never a pass):
  0   pass
  10  fail on substance (the JSON lists the failed items)
  20  verifier unavailable (no adapter or binary, unknown failure of the adapter)
  21  filter refused (PII, secret pattern) — nothing was sent
  22  the reply is not valid verdict JSON (or contradicts itself)
  23  access denied by the environment (network off in the sandbox, auth, timeout)
  2   bad arguments or unreadable input
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

EXIT_PASS = 0
EXIT_FAIL = 10
EXIT_UNAVAILABLE = 20
EXIT_FILTER = 21
EXIT_BAD_REPLY = 22
EXIT_ACCESS_DENIED = 23
EXIT_USAGE = 2

VERIFIERS = ("kimi", "codex", "claude", "grok")
MAX_PROJECTION_BYTES = 60 * 1024
DEFAULT_TIMEOUT_SEC = 300

# Adapter stderr markers that mean "the environment forbids the call", not "broken adapter".
ACCESS_DENIED_RE = re.compile(
    r"network is disabled|CODEX_SANDBOX_NETWORK_DISABLED|network/auth/quota|"
    r"authentication|unauthorized|not logged in|login required|quota",
    re.IGNORECASE,
)

PROMPT_HEAD = (
    "You are the independent verifier of a close protocol (role R23). You see only the "
    "inputs below, not the closing agent's context. Do not use tools.\n"
    "Check every checklist line against the inputs. A line you cannot confirm from the "
    "inputs is a fail with a short note saying what evidence is missing.\n"
    "Reply with ONE JSON object and nothing else (no prose, no markdown):\n"
    '{"verdict":"pass|fail","items":[{"check":"<checklist line, short>",'
    '"status":"pass|fail","note":"<one sentence>"}]}\n'
    'Rule: "verdict" is "pass" only if every item has status "pass".\n'
)


class FallbackError(Exception):
    """A refusal with the exit code the caller must see."""

    def __init__(self, code: int, message: str) -> None:
        super().__init__(message)
        self.code = code


def read_text(path: str, label: str) -> str:
    try:
        return Path(path).read_text(encoding="utf-8").strip()
    except OSError as exc:
        raise FallbackError(EXIT_USAGE, f"cannot read {label} file {path}: {exc}") from exc


def build_projection(checklist: str, files: str, summary: str, remaining: str) -> str:
    parts = [PROMPT_HEAD, "## Checklist\n" + checklist, "## Changed files (names only)\n" + files,
             "## Summary of the session\n" + summary]
    if remaining:
        parts.append("## Remaining-work text of the work-product card\n" + remaining)
    text = "\n\n".join(parts) + "\n"
    size = len(text.encode("utf-8"))
    if size > MAX_PROJECTION_BYTES:
        raise FallbackError(EXIT_USAGE, f"projection is {size} bytes, limit {MAX_PROJECTION_BYTES}: shorten the inputs")
    return text


def resolve_adapter(verifier: str) -> Path:
    base = Path(os.environ.get("IWE_CLOSE_VERIFY_ADAPTER_DIR") or Path(__file__).resolve().parent)
    adapter = base / f"{verifier}-peer-adapter.sh"
    if not adapter.is_file():
        raise FallbackError(EXIT_UNAVAILABLE, f"adapter not found: {adapter}")
    return adapter


def run_filter(projection: str) -> str:
    """Pass the projection through the same PII/secret filter the peer adapters use."""
    filter_script = Path(__file__).resolve().parent / "peer-adapter-filter.py"
    if not filter_script.is_file():
        raise FallbackError(EXIT_FILTER, f"filter missing: {filter_script}; nothing sent")
    with tempfile.TemporaryDirectory(prefix="close-verify-") as tmp:
        src, dst = Path(tmp, "src"), Path(tmp, "dst")
        src.mkdir()
        dst.mkdir()
        Path(tmp, "agentigore").write_text("", encoding="utf-8")
        (src / "projection.txt").write_text(projection, encoding="utf-8")
        env = dict(os.environ, SRC_DIR=str(src), DST_DIR=str(dst), AGENTIGORE_FILE=str(Path(tmp, "agentigore")))
        proc = subprocess.run([sys.executable, str(filter_script)], env=env, capture_output=True, text=True)
        cleaned = dst / "projection.txt"
        if proc.returncode != 0 or not cleaned.is_file():
            raise FallbackError(EXIT_FILTER, f"filter refused (code {proc.returncode}): {proc.stderr.strip()[-300:]}")
        return cleaned.read_text(encoding="utf-8")


def call_adapter(adapter: Path, prompt: str, timeout: int) -> str:
    env = dict(os.environ, IWE_PEER_PLAIN="1")
    try:
        proc = subprocess.run(["bash", str(adapter)], input=prompt, env=env, capture_output=True,
                              text=True, timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        raise FallbackError(EXIT_ACCESS_DENIED, f"adapter timed out after {timeout}s") from exc
    tail = proc.stderr.strip()[-300:]
    if proc.returncode == 0:
        return proc.stdout
    if proc.returncode in (2, 3):
        raise FallbackError(EXIT_FILTER, f"adapter filter refused (code {proc.returncode}): {tail}")
    if proc.returncode == 6 or ACCESS_DENIED_RE.search(proc.stderr):
        raise FallbackError(EXIT_ACCESS_DENIED, f"environment denied the call (adapter code {proc.returncode}): {tail}")
    if proc.returncode == 7:
        raise FallbackError(EXIT_BAD_REPLY, "adapter returned an empty reply")
    raise FallbackError(EXIT_UNAVAILABLE, f"adapter failed (code {proc.returncode}): {tail}")


def parse_verdict(reply: str) -> dict:
    text = reply.strip()
    fenced = re.fullmatch(r"```(?:json)?\s*(.*?)\s*```", text, re.DOTALL)
    if fenced:
        text = fenced.group(1)
    try:
        data = json.loads(text)
    except json.JSONDecodeError as exc:
        raise FallbackError(EXIT_BAD_REPLY, f"reply is not JSON: {exc}") from exc
    if not isinstance(data, dict) or data.get("verdict") not in ("pass", "fail"):
        raise FallbackError(EXIT_BAD_REPLY, 'reply lacks "verdict": "pass|fail"')
    items = data.get("items")
    if not isinstance(items, list) or not items:
        raise FallbackError(EXIT_BAD_REPLY, 'reply lacks a non-empty "items" list')
    for item in items:
        if not isinstance(item, dict) or not isinstance(item.get("check"), str) or item.get("status") not in ("pass", "fail"):
            raise FallbackError(EXIT_BAD_REPLY, 'each item needs "check" (text) and "status" (pass|fail)')
    any_failed = any(item["status"] == "fail" for item in items)
    if data["verdict"] == "pass" and any_failed:
        raise FallbackError(EXIT_BAD_REPLY, 'verdict "pass" contradicts a failed item')
    if data["verdict"] == "fail" and not any_failed:
        raise FallbackError(EXIT_BAD_REPLY, 'verdict "fail" without a failed item')
    return data


def independence(verifier: str, closer: str | None) -> str:
    if closer is None:
        return "unknown"
    return "weak" if closer == verifier else "independent"


def run(args: argparse.Namespace) -> int:
    checklist = read_text(args.checklist, "checklist")
    files = read_text(args.files, "files")
    summary = read_text(args.summary, "summary")
    remaining = read_text(args.remaining, "remaining") if args.remaining else ""
    for label, value in (("checklist", checklist), ("files", files), ("summary", summary)):
        if not value:
            raise FallbackError(EXIT_USAGE, f"{label} file is empty")
    adapter = resolve_adapter(args.verifier)
    filtered = run_filter(build_projection(checklist, files, summary, remaining))
    verdict = parse_verdict(call_adapter(adapter, filtered, args.timeout))
    verdict["verifier"] = args.verifier
    verdict["independence"] = independence(args.verifier, args.closer)
    print(json.dumps(verdict, ensure_ascii=False))
    return EXIT_PASS if verdict["verdict"] == "pass" else EXIT_FAIL


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--verifier", required=True, choices=VERIFIERS)
    parser.add_argument("--checklist", required=True)
    parser.add_argument("--files", required=True)
    parser.add_argument("--summary", required=True)
    parser.add_argument("--remaining")
    parser.add_argument("--closer", choices=VERIFIERS + ("hermes",), help="the agent that did the closing")
    parser.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT_SEC)
    args = parser.parse_args(argv)
    try:
        return run(args)
    except FallbackError as err:
        print(f"close-verify-fallback: {err}", file=sys.stderr)
        return err.code


if __name__ == "__main__":
    sys.exit(main())
