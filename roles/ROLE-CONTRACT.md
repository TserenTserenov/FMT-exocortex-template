# Role Contract

> Formal specification: what a role directory under `roles/` must contain.
> Theory: [DP.D.033](https://github.com/TserenTserenov/PACK-digital-platform/blob/main/pack/digital-platform/01-domain-contract/DP.D.033-role-centric-architecture.md) (Role-Centric Architecture).
> Role catalog: [DP.ROLE.001 §3.2](https://github.com/TserenTserenov/PACK-digital-platform/blob/main/pack/digital-platform/02-domain-entities/DP.ROLE.001-platform-roles.md).

---

## Required Files

| File | Purpose |
|------|---------|
| `role.yaml` | Machine-readable Manifest: identity, type, installation |
| `README.md` | Human-readable description: purpose, scenarios, when to install |
| `install.sh` | Installation entry point (launchd/cron/no-op) |

## Optional Structure

| Path | When needed |
|------|-------------|
| `prompts/*.md` | Role uses an AI agent (agential role — method selection) |
| `scripts/{role}.sh` | Role has a runner script |
| `scripts/launchd/*.plist` | Role uses macOS scheduling (independent of synchronizer) |
| `config/` | Role-specific Configuration |

## Full Structure

```
roles/{name}/
├── role.yaml              # REQUIRED — manifest
├── README.md              # REQUIRED — documentation
├── install.sh             # REQUIRED — installer
├── prompts/               # For AI agents
│   └── {scenario}.md      # One file = one scenario
├── scripts/
│   ├── {name}.sh          # Runner (invokes AI CLI with prompt)
│   └── launchd/           # macOS scheduling (opt.)
│       └── com.exocortex.{name}.plist
└── config/                # Role-specific configuration
```

---

## role.yaml Schema

```yaml
# === Required fields ===
name: string              # Directory name (lowercase, no spaces)
id: string                # Role ID from DP.ROLE.001 (R1, R2, R8, ...)
type: agential|functional # agential = role description allows method selection (AI), functional = role description prescribes execution (bash); holder grade is not part of the criterion (CC-A13.4, RP-595 F13)
display_name: string      # Human-readable name ("Strategist", "Extractor")

# === Runner (opt. — roles without scripts may omit) ===
runner: string            # Path to runner script (relative to role directory)
# OR for multi-script roles:
scripts:
  - string                # List of scripts

# === Installation ===
install:
  auto: boolean           # true = setup.sh installs automatically
  priority: integer       # Installation order (lower = earlier)

# === Notifications (opt.) ===
notify_template: string   # Filename in synchronizer/scripts/templates/
```

### Example (Strategist)

```yaml
name: strategist
id: R1
type: agential
display_name: "Strategist"
runner: scripts/strategist.sh
install:
  auto: true
  priority: 1
notify_template: strategist.sh
```

---

## How setup.sh Uses role.yaml

1. Scans `roles/*/role.yaml`
2. `install.auto: true` → installs automatically (in `priority` order)
3. `install.auto: false` → prints instructions for manual installation
4. No `role.yaml` → skips the directory (not a role, but a utility directory)

## How scheduler.sh Uses role.yaml

1. Reads `runner:` → resolves the path to the launch script
2. Fallback: `scripts/{name}.sh` (if role.yaml is absent)
3. Schedule: `synchronizer/config.yaml` (single source of schedule truth)

---

## How to Add a New Role

1. Create `roles/<name>/`
2. Create `role.yaml` following the schema above
3. Add `README.md` (description Template: [DP.D.033 §3](https://github.com/TserenTserenov/PACK-digital-platform/blob/main/pack/digital-platform/01-domain-contract/DP.D.033-role-centric-architecture.md))
4. Add `install.sh` (copy from an existing role and adapt)
5. If an AI agent: add `prompts/` with scenarios
6. If scheduling is needed: add a section to `synchronizer/config.yaml`
7. For notifications: add a Template at `synchronizer/scripts/templates/<name>.sh`
8. `setup.sh` will detect the role automatically

---

*Last updated: 2026-03-01*