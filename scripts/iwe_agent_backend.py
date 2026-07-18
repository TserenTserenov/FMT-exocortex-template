"""Provider-neutral, safe headless CLI execution for IWE."""
from __future__ import annotations
import os
import subprocess
import tempfile
from pathlib import Path

MODEL_ALIASES = {
    "low": {"claude": "haiku", "codex": ""},
    "medium": {"claude": "sonnet", "codex": ""},
    "high": {"claude": "opus", "codex": ""},
    "haiku": {"claude": "haiku", "codex": ""},
    "sonnet": {"claude": "sonnet", "codex": ""},
    "opus": {"claude": "opus", "codex": ""},
}

def provider_model(model: str | None, provider: str) -> str:
    value = (model or os.environ.get("IWE_AGENT_MODEL", "medium")).strip()
    if provider == "codex" and value.startswith("claude-"):
        return ""
    return MODEL_ALIASES.get(value, {}).get(provider, value)

def invoke(prompt: str, model: str | None = None, cwd: Path | None = None,
           timeout: int = 1800, provider: str | None = None) -> tuple[bool, str]:
    provider = (provider or os.environ.get("IWE_AGENT_PROVIDER", "claude")).lower()
    workdir = Path(cwd or os.getcwd()).resolve()
    resolved_model = provider_model(model, provider)
    try:
        if provider == "claude":
            cmd = [os.environ.get("IWE_CLAUDE_BIN", "claude"), "-p", prompt,
                   "--output-format", "text"]
            if resolved_model:
                cmd += ["--model", resolved_model]
            result = subprocess.run(cmd, cwd=workdir, capture_output=True, text=True,
                                    timeout=timeout)
            output = result.stdout.strip() or result.stderr.strip()
            return result.returncode == 0, output
        if provider == "codex":
            with tempfile.TemporaryDirectory(prefix="iwe-codex-") as tmp:
                last = Path(tmp) / "last-message.txt"
                cmd = [os.environ.get("IWE_CODEX_BIN", "codex"), "exec", "--cd",
                       str(workdir), "--sandbox", "workspace-write", "--json",
                       "--output-last-message", str(last)]
                if resolved_model:
                    cmd += ["--model", resolved_model]
                cmd.append("-")
                result = subprocess.run(cmd, input=prompt, cwd=workdir,
                                        capture_output=True, text=True, timeout=timeout)
                output = last.read_text(encoding="utf-8").strip() if last.exists() else ""
                output = output or result.stdout.strip() or result.stderr.strip()
                return result.returncode == 0, output
        return False, f"unsupported IWE_AGENT_PROVIDER: {provider}"
    except subprocess.TimeoutExpired:
        return False, f"{provider} CLI timed out after {timeout}s"
    except FileNotFoundError:
        return False, f"{provider} CLI not found in PATH"
