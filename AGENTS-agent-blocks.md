<!-- AGENT-SPECIFIC-START -->
<!--
  Агент-специфичные блоки AGENTS.md (WP-394 Ф4.2).
  НЕ синхронизируется из CLAUDE.md — у каждого агента своё.
  Врезается скриптом scripts/sync-agent-instructions.sh после SYNC-CORE.
-->

## Commit Attribution

Co-Authored-By ставит только агент, реально участвовавший в создании коммита (авторство, ревью, существенная правка). Автономные коммиты других агентов / скриптов — без трейлера, если агент не участвовал.

Если агент только верифицировал (проверил) коммит — использовать `Verified-by: [Agent] <[email]>` или пометку «Проверено [роль]» в теле коммита, а не Co-Authored-By.

### Для коммитов с участием Kimi

**Method 1 (preferred — template):**
```bash
git commit -t ~/.git-commit-template-kimi -m "feat: description"
```

**Method 2 (manual — if template unavailable):**
```bash
git commit -m "feat: description" --trailer "Co-Authored-By: Kimi <noreply@moonshot.ai>"
```

**Never** commit without the trailer. If you forget — amend immediately:
```bash
git commit --amend --trailer "Co-Authored-By: Kimi <noreply@moonshot.ai>"
```

### Для коммитов с участием Hermes (Nous Research)

```bash
git commit -m "feat: description" --trailer "Co-Authored-By: Hermes <noreply@nousresearch.com>"
```

**Hermes Agent** — оркестратор в экосистеме IWE (РП392). Подключён к Aisystant MCP, работает через CLI/Telegram. Hermes НЕ заменяет Claude Code или Kimi Code в кодинге — он координирует, запоминает и даёт мобильный доступ.

## IWE Instructions Level (Kimi headless)

# IWE workspace with 5000+ docs and multiple Packs — use experienced level.
# Revisit if a new small repo (< 1000 docs) is added to {{HOME_DIR}}/IWE/.
When calling `get_instructions` (Aisystant MCP) to load IWE context,
use `level="experienced"` instead of the default `level="full"`.
This reduces token load by ~89% (~10K → ~1.1K) on every headless turn.

Example:
```
get_instructions(level="experienced")
```

This applies to all Kimi sessions: peer (via kimi-peer-adapter.sh) and standalone.
Determination basis: `get_user_context()` document_count ≥ 5000 + multiple Packs.

## Coordination Protocol (MCP Gateway)

> Для агентов с доступом к Local Gateway (Claude Code, Kimi). Hermes НЕ имеет MCP Gateway
> (`acquire_file_lock` / `release_file_lock`) — он использует `terminal` + `patch` напрямую,
> а при конфликте на push сообщает пилоту.

Before starting any edit task:

1. **Declare intention** (no lock needed):
   ```
   Tool: update_peer_status
   params: { "status": "working", "current_task": "<brief>", "files": ["relative/path/file.md"] }
   ```

2. **Acquire lock** before first Edit:
   ```
   Tool: acquire_file_lock
   param: canonical_file = relative path from IWE root
   ```

3. **Release lock** after commit:
   ```
   Tool: release_file_lock
   ```

4. On `lock_collision`: wait 30s and retry, or switch to another file.

## Hermes Agent — координация

Если в экосистеме присутствует Hermes Agent (оркестратор с персистентной памятью, РП-392):
- Hermes НЕ заменяет Claude Code / Kimi Code в кодинге — координирует, запоминает, даёт мобильный доступ.
- Hermes НЕ имеет MCP Gateway (`acquire_file_lock` / `release_file_lock`) — правит файлы через `terminal` + `patch`.
- При правках критичных файлов: сначала `git pull`, проверить `git status`, потом править; конфликт на push — сообщить пилоту.

## Prompt Cache Pattern

- Паттерн PREFIX/BODY/TAIL для headless-агентов → см. `memory/sota-prompt-cache.md`.
- Применять при сборке системного промпта multi-turn агента: стабильное (идентичность, правила) — в PREFIX/BODY до cache-breakpoint; волатильное (память, timestamp) — в TAIL.

<!-- AGENT-SPECIFIC-END -->
