# State-Transition Gate — Full Contract

> Hot trigger: `CLAUDE.md`, Agent Core. This file is required in full when
> `docs/state-axes-registry.yaml` (WP-457) exists in the governance repository.

Before any non-trivial action or Work turn, name the target user state transition
in the form `{state type, from→to}`.

## Valid Transition

1. Take the state type only from the same `docs/state-axes-registry.yaml` of the
   governance repository whose presence activated the hot trigger.
2. Use only an axis with `gate_ready: true`.
3. Provide a reference to the declared FSM-owner of that axis.
4. Free text in place of a registered state type is not accepted.

If the type is not registered, the axis does not have `gate_ready: true`, or the
owner reference is missing, only fact collection (`inventory`) is permitted →
STOP and defer the non-trivial action or Work turn.

For transitions across multiple axes, apply the cross-axis rules from
`memory/reference/agent-core.md`. The author's conceptual model may be available
at `archive/wp-contexts/WP-457/CONCEPT-user-states.md §5`, but is not required
for understanding or executing this delivered contract.