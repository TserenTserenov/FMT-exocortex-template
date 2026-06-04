---
name: platform-bottleneck
description: "Alias для /bottleneck-pick --layer platform. Deprecated — используйте /bottleneck-pick напрямую."
version: 1.0.0
layer: L3
status: active
sunset: "FMT v2.0 (semver-major)"
type: alias
redirects_to: bottleneck-pick
triggers:
  slash: [/platform-bottleneck]
  phrases: []
routing:
  executor: sonnet
  deterministic: false
---

# /platform-bottleneck — Alias (Deprecated)

> ⚠️ **Deprecated.** Этот skill является alias для `/bottleneck-pick --layer platform`.
> Прямой вызов `/bottleneck-pick` предпочтителен.
>
> **Sunset:** удалится при FMT v2.0 (semver-major).

## Поведение

При вызове `/platform-bottleneck [--horizon <h>] [--subsystem <s>]` — выполнить:

```
/bottleneck-pick --target c2:platform --layer platform [--horizon <h>]
```

Если `--subsystem` указан:

```
/bottleneck-pick --target c2:platform --layer platform --subsystem <s> [--horizon <h>]
```

## Полная документация

→ `/bottleneck-pick` SKILL.md (секция `--layer=platform`)
→ DP.SC.152 (обещание платформо-специфичного анализа)
