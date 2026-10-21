---
scope: IWE
status: active
title: Connect the public FPF Library to ChatGPT or Codex
updated: 2026-10-21
---

# Connect the public FPF Library to ChatGPT or Codex

Aisystant Open provides read-only access to the public FPF Library through `https://open.aisystant.com/mcp`. It does not connect private IWE files or a personal profile.

For current ChatGPT connection steps, use the [Aisystant connection guide](https://aisystant.com/connect#chatgpt). Availability of custom MCP connections depends on your ChatGPT workspace settings.

For Codex CLI, add the server in your terminal:

```bash
codex mcp add aisystant-open --url https://open.aisystant.com/mcp
codex mcp list
```

Restart Codex after adding the server. Ask it to list public FPF publications to verify the connection. No Aisystant account is required for this public server.

To install a local English IWE workspace in VS Code, follow the [separate setup steps](https://aisystant.com/connect#vscode).
