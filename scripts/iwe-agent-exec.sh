#!/usr/bin/env bash
# Provider-neutral headless runner. Prompt is read from stdin.
set -euo pipefail

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  cat <<'EOF'
Usage: prompt | scripts/iwe-agent-exec.sh

Provider-neutral headless execution for IWE.
Environment: IWE_AGENT_PROVIDER=claude|codex, IWE_AGENT_WORKDIR,
IWE_AGENT_MODEL, IWE_CLAUDE_BIN, IWE_CODEX_BIN.
EOF
  exit 0
fi

provider="${IWE_AGENT_PROVIDER:-claude}"
workdir="${IWE_AGENT_WORKDIR:-$PWD}"
model="${IWE_AGENT_MODEL:-}"

case "$provider" in
  claude)
    cli="${IWE_CLAUDE_BIN:-${CLAUDE_CLI_PATH:-claude}}"
    args=(-p --output-format text)
    case "$model" in low) model=haiku;; medium) model=sonnet;; high) model=opus;; esac
    [ -n "$model" ] && args+=(--model "$model")
    if [ -n "${IWE_CLAUDE_EXTRA_FLAGS:-}" ]; then
      read -r -a extra <<< "$IWE_CLAUDE_EXTRA_FLAGS"
      args+=("${extra[@]}")
    fi
    prompt="$(cat)"
    exec "$cli" "${args[@]}" "$prompt"
    ;;
  codex)
    cli="${IWE_CODEX_BIN:-codex}"
    output="$(mktemp "${TMPDIR:-/tmp}/iwe-codex-last.XXXXXX")"
    trap 'rm -f "$output"' EXIT
    case "$model" in low|medium|high|claude-*) model="";; esac
    args=(exec --cd "$workdir" --sandbox workspace-write --json --output-last-message "$output")
    [ -n "$model" ] && args+=(--model "$model")
    "$cli" "${args[@]}" -
    rc=$?
    [ -s "$output" ] && cat "$output"
    exit "$rc"
    ;;
  *) echo "Unsupported IWE_AGENT_PROVIDER: $provider" >&2; exit 2 ;;
esac
