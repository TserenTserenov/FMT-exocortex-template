# Skill Support in FMT

## Adding a New Skill

1. Create the directory `.claude/skills/<name>/`
2. Write `SKILL.md` with frontmatter:
   ```yaml
   ---
   name: <name>
   description: "..."
   version: 1.0.0
   layer: L1 | L2 | L3
   status: active | experimental | deprecated
   triggers:
     slash: [/<name>]
     phrases: ["..."]
   ---
   ```
3. Add the Skill to `docs/skills-catalog.md`
4. Run `python3 scripts/iwe-catalog-list.py` to verify

## Modifying diagnose Rubrics

SoT: `shared/rubrics/form-089.yaml`

```bash
# 1. Edit the YAML
vim shared/rubrics/form-089.yaml

# 2. Check synchronization (drift detection)
python3 scripts/generate-diagnose-skill.py --check
# If an error occurs — update SKILL.md manually so that the questions match the YAML

# 3. Commit both files together
git add shared/rubrics/form-089.yaml .claude/skills/diagnose/SKILL.md
git commit -m "feat(diagnose): update rubrics"
```

The pre-commit Hook checks synchronization automatically.

## Removing a Skill

1. Set `status: deprecated` in SKILL.md
2. Specify `sunset: "FMT vX.Y"` or `sunset_condition: "..."`
3. Add an entry to CHANGELOG
4. Delete the files in the next major release