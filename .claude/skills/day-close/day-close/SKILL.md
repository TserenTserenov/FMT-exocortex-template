---
argument-hint: ''
description: Day Close protocol. Alias for /run-protocol close day -- symmetry with
  /day-open.
name: day-close
version: 1.0.0
---
<frontmatter_values>
description: Day Close protocol. Alias for /run-protocol close day -- symmetry with /day-open.
name: day-close
</frontmatter_values>

# Day Close (alias)

> **Symmetry:** `/day-open` opens the day; `/day-close` closes it.
> **Implementation:** delegates to `/run-protocol close day`.

Run `/run-protocol close day` using the full algorithm from `memory/protocol-close.md § Day`.

### T-checklist

> See [memory/t-checklist.md](../../../../memory/t-checklist.md) section Day Close (T6-T14). All items must be completed before close.