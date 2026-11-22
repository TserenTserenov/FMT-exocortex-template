#!/usr/bin/env python3
# routing: helper skill=extend called-by=manual
# see DP.SC.159, DP.ROLE.059
"""
generate-catalogs.py — unified generator of public catalogs IWE.

Builds three markdown-catalogs in docs/ from real repository files:
  - docs/skills-catalog.md   — all skills (.claude/skills/*/SKILL.md)
  - docs/scripts-catalog.md  — scripts-helpers (scripts/*.sh, .claude/scripts/*.{sh,py})
  - docs/roles-catalog.md    — roles (memory/roles.md, tables | R<N> | ... |)

Catalogs — derived-artifacts: DO NOT edit manually, regenerate with the script.
By default root = repository, containing the script (parent of scripts/).
A user IWE can run from their own repo: the catalog will be built from their files.

Usage:
  python3 scripts/generate-catalogs.py            # build all three
  python3 scripts/generate-catalogs.py --root ~/IWE
  python3 scripts/generate-catalogs.py --dry-run  # print without writing
"""
import argparse
import re
from pathlib import Path
from datetime import datetime, timezone

FM_RE = re.compile(r"^---\s*\n(.*?)\n---\s*\n", re.DOTALL)


def parse_frontmatter(text: str) -> dict:
    m = FM_RE.match(text)
    if not m:
        return {}
    data = {}
    for line in m.group(1).splitlines():
        if ":" in line and not line.strip().startswith("#"):
            k, v = line.split(":", 1)
            data[k.strip()] = v.strip().strip('"').strip("'")
    return data


def short(s: str, n: int = 110) -> str:
    s = " ".join(s.split())
    return s if len(s) <= n else s[: n - 1].rstrip() + "…"


def stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


# ---------- skills ----------
def collect_skills(root: Path) -> list[dict]:
    skills = []
    skills_dir = root / ".claude" / "skills"
    for skill_md in sorted(skills_dir.glob("*/SKILL.md")):
        sid = skill_md.parent.name
        if sid == "_template":
            continue
        fm = parse_frontmatter(skill_md.read_text(encoding="utf-8", errors="replace"))
        skills.append({
            "id": sid,
            "desc": short(fm.get("description", "—")),
        })
    return skills


def render_skills(skills: list[dict], root: Path) -> str:
    lines = [
        "# IWE Skills Catalog IWE",
        "",
        f"> Auto-generated `scripts/generate-catalogs.py` · {stamp()} · DO NOT edit manually.",
        f"> Source: `.claude/skills/*/SKILL.md`. A skill is invoked with the command `/<id>`.",
        "",
        "| Skill | What it does |",
        "|-------|------------|",
    ]
    for s in skills:
        lines.append(f"| `/{s['id']}` | {s['desc']} |")
    lines += ["", f"_Total skills: {len(skills)}_", ""]
    return "\n".join(lines)


# ---------- scripts ----------
def script_desc(path: Path) -> str:
    text = path.read_text(encoding="utf-8", errors="replace")
    name = path.name
    # 1) "# name.sh — description" / "name.py — description"
    m = re.search(rf"^#\s*{re.escape(name)}\s*[—-]\s*(.+)$", text, re.MULTILINE)
    if m:
        return short(m.group(1))
    # 2) python docstring — first meaningful line
    if path.suffix == ".py":
        dm = re.search(r'"""(.*?)"""', text, re.DOTALL)
        if dm:
            for ln in dm.group(1).splitlines():
                ln = ln.strip()
                if ln and not ln.endswith(".py") and "routing:" not in ln:
                    return short(ln)
    # 3) first meaningful comment after shebang (not routing/see/shellcheck)
    for ln in text.splitlines():
        s = ln.strip()
        if not s.startswith("#"):
            continue
        body = s.lstrip("#").strip()
        if not body or s.startswith("#!"):
            continue
        low = body.lower()
        if low.startswith(("routing:", "see ", "shellcheck", "-*-")):
            continue
        return short(body)
    return "—"


def collect_scripts(root: Path) -> list[dict]:
    seen, scripts = set(), []
    search = [
        (root / "scripts", "*.sh"),
        (root / ".claude" / "scripts", "*.sh"),
        (root / ".claude" / "scripts", "*.py"),
    ]
    for d, pat in search:
        if not d.is_dir():
            continue
        for f in sorted(d.glob(pat)):
            if f.name in seen:
                continue
            seen.add(f.name)
            scripts.append({
                "name": f.name,
                "rel": str(f.relative_to(root)),
                "desc": script_desc(f),
            })
    return sorted(scripts, key=lambda x: x["name"])


def render_scripts(scripts: list[dict]) -> str:
    lines = [
        "# IWE Scripts Catalog IWE",
        "",
        f"> Auto-generated `scripts/generate-catalogs.py` · {stamp()} · DO NOT edit manually.",
        "> Source: `scripts/*.sh`, `.claude/scripts/*.{sh,py}`. These are helper scripts (helpers, utilities, servers), not skills.",
        "",
        "| Script | Path | What it does |",
        "|--------|------|------------|",
    ]
    for s in scripts:
        lines.append(f"| `{s['name']}` | `{s['rel']}` | {s['desc']} |")
    lines += ["", f"_Total scripts: {len(scripts)}_", ""]
    return "\n".join(lines)


# ---------- roles ----------
def collect_roles(root: Path) -> list[dict]:
    roles_md = root / "memory" / "roles.md"
    if not roles_md.is_file():
        return []
    seen, roles = set(), []
    row_re = re.compile(r"^\|\s*(R\d+)\s*\|(.+)\|\s*$")
    for line in roles_md.read_text(encoding="utf-8", errors="replace").splitlines():
        m = row_re.match(line)
        if not m:
            continue
        rid = m.group(1)
        if rid in seen:
            continue
        cells = [c.strip() for c in m.group(2).split("|")]
        cells = [c for c in cells if c]
        if not cells:
            continue
        name = re.sub(r"\*\*", "", cells[0]).strip()
        desc = cells[-1] if len(cells) > 1 else "—"
        desc = re.sub(r"`", "", desc)
        seen.add(rid)
        roles.append({"id": rid, "name": name, "desc": short(desc, 120)})
    roles.sort(key=lambda r: int(r["id"][1:]))
    return roles


def render_roles(roles: list[dict]) -> str:
    lines = [
        "# IWE Roles Catalog IWE",
        "",
        f"> Auto-generated `scripts/generate-catalogs.py` · {stamp()} · DO NOT edit manually.",
        "> Source: `memory/roles.md`. Role = functional position (responsibilities, permissions, I/O).",
        "> Full passports for platform roles (DP.ROLE.*) reside in PACK-digital-platform.",
        "",
        "| ID | Role | What it does |",
        "|----|------|------------|",
    ]
    for r in roles:
        lines.append(f"| {r['id']} | **{r['name']}** | {r['desc']} |")
    lines += ["", f"_Total roles: {len(roles)}_", ""]
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=None, help="repo root (default — the script repo)")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    root = Path(args.root).expanduser() if args.root else Path(__file__).resolve().parent.parent
    docs = root / "docs"

    outputs = {
        docs / "skills-catalog.md": render_skills(collect_skills(root), root),
        docs / "scripts-catalog.md": render_scripts(collect_scripts(root)),
        docs / "roles-catalog.md": render_roles(collect_roles(root)),
    }

    for path, content in outputs.items():
        if args.dry_run:
            print(f"--- {path} ---\n{content}\n")
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content + "\n", encoding="utf-8")
            n = content.count("\n|") - 1  # rows minus header sep
            print(f"✅ {path.relative_to(root)} ({max(n,0)} data rows)")


if __name__ == "__main__":
    main()
