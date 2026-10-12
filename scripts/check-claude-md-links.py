#!/usr/bin/env python3
"""check-claude-md-links.py — path references in shipped CLAUDE.md,
.claude/skills/**/*.md and memory/*.md must resolve.

issue #291: platform section (start .. SYNC-CORE-END) of CLAUDE.md is what
update.sh delivers to every user via §1-7 + Agent Core — a path in backticks
that doesn't exist in this repo (and isn't in update-manifest.json's files[])
is a dead reference on 100% of installs, not just this one. {{PLACEHOLDER}}
tokens are substituted by setup.sh/update.sh at delivery time, so they're
skipped here, not resolved.

issue #1110: the same class of dead reference was found independently by two
post-release audits inside delivered skills (.claude/skills/**/*.md) and
memory (memory/*.md) — trees the CLAUDE.md-only check above never looked at.
check_claude_md() below is untouched (same regex, same rules, same output) —
the new check_tree() is a separate, deliberately more conservative pass:

- Skills/memory files spell out paths three ways CLAUDE.md barely uses:
  inline `single-backtick spans` (sometimes "command arg/path.sh", not just
  a bare path), fenced ```bash blocks (a shell command naming a script, no
  backticks around the path at all), and markdown links ([text](path)).
  All three are scanned here.
- A first pass matched path-shaped substrings anywhere in fenced-code text
  and was unusable: ~600 hits, almost all shell parameter expansions like
  "${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/x.yaml" (the "DS-strategy}/
  scripts/x.yaml" tail alone looks path-shaped) or bare sibling filenames
  ("routing.yaml") that are meaningful relative to some OTHER repo the skill
  talks about, not this one. Fixed by requiring a *whole* whitespace token to
  fullmatch the path pattern (one disallowed character like "$" or ":"
  anywhere in the token voids the whole token, not just the part after it)
  and by requiring a "/" in it — bare filenames are ambiguous relative-to-
  what and out of scope here, same as they'd be for a human reader.

Usage: python3 check-claude-md-links.py [--strict]  (--strict: exit 1 on any dead link)
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CLAUDE_MD = ROOT / "CLAUDE.md"
END_MARKER = "<!-- SYNC-CORE-END -->"

PATH_RE = re.compile(r"`([\w./{}-]+\.[a-zA-Z]{2,5}(?:\s+§?[\w.]*)?)`")

# Explicitly documented as author-only / not shipped right at the point of
# reference (see the surrounding sentence) — flagging them again here would
# just be noise, not a new finding.
ALLOWLIST = {
    "PACK-agent-rules/rules/AR.NNN.md",
    ".claude/rules-registry.yaml",
    "archive/wp-contexts/WP-457/CONCEPT-user-states.md",
    # FPF is cloned into the user's workspace by setup.sh, it is not part of the
    # template; the Obsidian rule (#522, #883) names its big spec file as the reason.
    "FPF/FPF-Spec.md",
}

manifest_files = set()
manifest_path = ROOT / "update-manifest.json"
if manifest_path.exists():
    manifest_files = {f["path"] for f in json.loads(manifest_path.read_text()).get("files", [])}


def check_claude_md():
    """issue #291, unchanged by #1110: backtick spans inside CLAUDE.md's
    platform section (start .. SYNC-CORE-END) only."""
    text = CLAUDE_MD.read_text(encoding="utf-8")
    platform_text = text.split(END_MARKER, 1)[0]

    dead = []
    for m in PATH_RE.finditer(platform_text):
        candidate = m.group(1).split()[0]  # strip trailing "§5" etc.
        if "{{" in candidate or "NNN" in candidate or candidate in ALLOWLIST:
            continue
        if "/" not in candidate and "." not in candidate:
            continue
        rel = candidate.lstrip("/")
        if (ROOT / rel).exists() or rel in manifest_files or f"scripts/{Path(rel).name}" in manifest_files:
            continue
        dead.append(candidate)
    return dead


# ---------------------------------------------------------------------------
# issue #1110: .claude/skills/**/*.md and memory/*.md
# ---------------------------------------------------------------------------

# A backtick span's raw inner text — may be a bare path ("memory/x.md"), a
# path with a trailing section ref ("file.md §3"), or a shell snippet with a
# leading command word ("bash scripts/fix-strikethrough.sh"); all three are
# handled uniformly by tokenizing the inner text below, not by this regex.
BACKTICK_RE = re.compile(r"`([^`\n]+)`")
# ```lang\n...\n``` fenced code block body. Backreference on the opening
# backtick run so a 4-backtick outer fence used to quote an example that
# itself contains a ```yaml block (apply-captures/SKILL.md) matches its own
# closer and doesn't stop early at the nested 3-backtick one.
FENCE_RE = re.compile(r"(`{3,})[\w-]*\n(.*?)\n\1", re.DOTALL)
# [text](path) markdown link — path group only.
MDLINK_RE = re.compile(r"\[[^\]\n]*\]\(([^)\s]+)\)")
# A whitespace-delimited token, tested with fullmatch (see module docstring
# for why fullmatch instead of search-anywhere).
TOKEN_FULLMATCH_RE = re.compile(r"[\w./{}-]+\.[a-zA-Z]{2,5}")
WHITESPACE_RE = re.compile(r"\S+")

# issue #1110 follow-up (adversarial review, 2026-10-06): "$IWE_SCRIPTS/x.sh"
# is the dominant way this exact codebase's own skills name a script path
# (check-secret/SKILL.md:38 has a real, correct "$IWE_SCRIPTS/route-task.sh"
# right in the file this fix touches) -- but the bare "$" voided the whole
# token above, so a genuinely dead "$IWE_SCRIPTS/<typo>.sh" was never even
# tested. These two vars are a deliberately narrow, explicit exception, not
# a shell-expansion parser: update.sh/setup.sh deliver .claude/, memory/ and
# scripts/ directly under $IWE_ROOT, and $IWE_SCRIPTS is specifically
# $IWE_ROOT/<this repo>/scripts -- both map unambiguously onto the exact
# three prefixes is_dead() already restricts itself to. Other vars seen in
# this text (IWE_GOVERNANCE_REPO, IWE_HOME, IWE_TEMPLATE, a ":-default"
# branch) name a path in some OTHER repo or carry a fallback value a regex
# can't safely resolve -- left alone, same as before this fix.
KNOWN_VAR_PREFIX_RE = re.compile(r"^\$\{?(IWE_SCRIPTS|IWE_ROOT)\}?(/.*)?$")
KNOWN_VAR_PREFIX_SUBSTITUTION = {"IWE_SCRIPTS": "scripts", "IWE_ROOT": ""}


def _known_var_candidate(tok):
    """`tok` with a recognized $IWE_SCRIPTS/$IWE_ROOT prefix substituted for
    the real repo-relative path it names, or None if `tok` doesn't start
    with one of those two (see the module-level comment above)."""
    m = KNOWN_VAR_PREFIX_RE.match(tok)
    if not m:
        return None
    return (KNOWN_VAR_PREFIX_SUBSTITUTION[m.group(1)] + (m.group(2) or "")).lstrip("/")


def _candidate_from_token(tok):
    """The token itself if it already fullmatches the safe path pattern,
    else its known-var-substituted form if THAT fullmatches, else None."""
    if TOKEN_FULLMATCH_RE.fullmatch(tok):
        return tok
    substituted = _known_var_candidate(tok)
    if substituted and TOKEN_FULLMATCH_RE.fullmatch(substituted):
        return substituted
    return None

LEAD_STRIP = "\"'(["
TRAIL_STRIP = "\"')],;:"

# Same spirit as CLAUDE.md's ALLOWLIST: a reference that's a known, already
# -understood gap rather than something #1110 should fix. See the report for
# issue #1110 for the full reasoning.
TREE_ALLOWLIST = {
    # check-secret/{SKILL.md,check.sh} name this runbook, but it does not
    # live in this template's own tree at all — it lives in whichever
    # separate, personal repo each installation keeps its rotation runbooks
    # in, if any. check-claude-md-links.py can never confirm that path
    # locally, so it is allowlisted rather than treated as a dead link.
    "DP.RUNBOOK.003-cascade-secret-rotation.md",
    # Governance-repo-relative, not template-repo-relative — "scripts/" is
    # also the directory name in the user's deployed governance repo, and
    # these three are tooling that lives (or gets placed by update.sh) there,
    # not here. Confirmed by investigation, not assumed:
    #   - scripts/ds-publish.sh: strategy-session/SKILL.md documents in
    #     detail that update.sh places this in the governance repo's
    #     "канон" without committing it; the template's own copy ships at
    #     seed/strategy/scripts/ds-publish.sh, a different path on purpose.
    #   - scripts/process-runner.py and scripts/processes/quick-close.yaml:
    #     protocol-close.md's own prose says "в репозитории управления"
    #     right next to these two, and the one fenced-shell occurrence is
    #     reached through an explicit `cd` into the governance repo first.
    "scripts/ds-publish.sh",
    "scripts/process-runner.py",
    "scripts/processes/quick-close.yaml",
    # author-mode/SKILL.md's "$IWE_SCRIPTS/template-sync.sh" line is inside a
    # paragraph explicitly gated "Автор (author_mode: true)" -- the author's
    # own delivery tooling, which root CLAUDE.md says lives in a separate
    # setup repo, not in this template. Only reachable since the
    # $IWE_SCRIPTS-prefix substitution above was added; the original #1110
    # checker's charset never looked at this token at all (it contains "$"),
    # so this isn't something that fix missed -- it's a new case this later
    # widening surfaces for the first time, same shape as the three entries
    # right above it.
    "scripts/template-sync.sh",
    # bottleneck-pick/SKILL.md's own parameter table already says this map
    # "не доставляется публичным шаблоном" (not delivered by the public
    # template) right at the point of reference — a documented default
    # value for a user-supplied path, not a dead shipped reference.
    "memory/project_iwe_systems_map.md",
    # .gitignore'd runtime checkpoint (PreCompact writes it); never present
    # in a fresh checkout by design, not something that ships.
    ".claude/checkpoint.md",
    # .gitignore'd, author-local config for sync-communication-style.py
    # (confirmed: scripts/.gitignore lists it); communication-style-
    # downstream-template.md names the .example template to copy it from
    # right next to this reference, same "documented, not shipped by
    # design" shape as the two entries above.
    "scripts/sync-communication-style.yaml",
}


def strip_token(tok):
    tok = tok.strip()
    while tok and tok[0] in LEAD_STRIP:
        tok = tok[1:]
    while tok and tok[-1] in TRAIL_STRIP:
        tok = tok[:-1]
    return tok


def normalize_candidate(candidate):
    """Treat a markdown-relative path as relative to the repo root,
    regardless of how many '../' hops it actually spells out (issue #1110:
    this is also what rescues distinctions-warm.md's own '../../memory/x.md'
    — one hop short of where it sits — since the *intent* is clearly
    'memory/x.md' at repo root, not a path above the repo)."""
    candidate = candidate.split("#", 1)[0]  # drop a markdown anchor fragment
    rel = candidate.lstrip("/")
    while rel.startswith("../"):
        rel = rel[3:]
    while rel.startswith("./"):
        rel = rel[2:]
    return rel


def is_dead(candidate, referencing_dir=None):
    if not candidate or "/" not in candidate:
        return False
    if "{{" in candidate or "NNN" in candidate or candidate in TREE_ALLOWLIST:
        return False
    if candidate.startswith(("http://", "https://", "mailto:", "~")):
        return False
    rel = normalize_candidate(candidate)
    if not rel:
        return False
    # issue #1110: skills/memory text routinely names paths in a repo OTHER
    # than this one — the user's governance repo (bare "docs/WP-REGISTRY.md",
    # "inbox/...", "current/...", or a "{{GOVERNANCE_REPO}}/..." placeholder
    # resolved at delivery time), a Pack repo ("PACK-.../...", "SPF/...",
    # "FPF/..."), or a documented, optional extension point under
    # "extensions/" that's absent until a user creates it by design (see the
    # `extend` skill). None of that is checkable against THIS repo's tree
    # without per-reference judgment a regex can't make, and scanning it
    # anyway was ~90% noise in practice (measured: 614, then 283 hits before
    # this filter, nearly all paths that are real in some OTHER repo).
    # Restrict to the prefixes where skills/memory text unambiguously means
    # "this repo's own tree" — proven sufficient for all 7 items issue #1110
    # itself lists.
    if not rel.startswith((".claude/", "memory/", "scripts/")):
        return False
    if (ROOT / rel).exists() or rel in manifest_files or f"scripts/{Path(rel).name}" in manifest_files:
        return False
    # "## Bundled resources" sections (e.g. skill-creator/SKILL.md) commonly
    # name a skill's own files as a bare "scripts/x.sh" — sibling-relative to
    # the skill's own directory, not to the repo root. Give the referencing
    # file's own directory a second chance before calling it dead.
    if referencing_dir is not None and (referencing_dir / rel).exists():
        return False
    return True


def line_of(text, offset):
    return text.count("\n", 0, offset) + 1


def find_candidates(text):
    """Yield (offset, candidate) for every path-shaped reference in `text`."""
    for m in BACKTICK_RE.finditer(text):
        inner = m.group(1)
        base = m.start(1)
        for wm in WHITESPACE_RE.finditer(inner):
            candidate = _candidate_from_token(strip_token(wm.group(0)))
            if candidate:
                yield base + wm.start(), candidate
    for m in MDLINK_RE.finditer(text):
        tok = strip_token(m.group(1))
        if not tok.startswith(("http://", "https://", "mailto:", "#")):
            yield m.start(1), tok
    for fence in FENCE_RE.finditer(text):
        body = fence.group(2)
        base = fence.start(2)
        for wm in WHITESPACE_RE.finditer(body):
            candidate = _candidate_from_token(strip_token(wm.group(0)))
            if candidate:
                yield base + wm.start(), candidate


def check_tree(glob_root, pattern):
    """Scan every file matching `pattern` under `glob_root`. Returns a list
    of (relative_file_path, line_number, candidate)."""
    dead = []
    for path in sorted(glob_root.glob(pattern)):
        if not path.is_file():
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        rel_file = path.relative_to(ROOT)
        seen = set()
        for offset, candidate in find_candidates(text):
            if not is_dead(candidate, referencing_dir=path.parent):
                continue
            key = (candidate, line_of(text, offset))
            if key in seen:
                continue
            seen.add(key)
            dead.append((str(rel_file), line_of(text, offset), candidate))
    return dead


def main():
    strict = "--strict" in sys.argv

    claude_md_dead = check_claude_md()
    tree_dead = check_tree(ROOT / ".claude" / "skills", "**/*.md") + check_tree(ROOT / "memory", "*.md")

    if claude_md_dead:
        print(f"❌ {len(claude_md_dead)} dead link(s) in CLAUDE.md platform section (start..SYNC-CORE-END):")
        for candidate in claude_md_dead:
            print(f"   {candidate}")
    else:
        print("✅ check-claude-md-links: no dead links in CLAUDE.md platform section")

    if tree_dead:
        print(f"❌ {len(tree_dead)} dead link(s) in .claude/skills/**/*.md and memory/*.md:")
        for rel_file, lineno, candidate in tree_dead:
            print(f"   {rel_file}:{lineno}  {candidate}")
    else:
        print("✅ check-claude-md-links: no dead links in .claude/skills/**/*.md or memory/*.md")

    if strict and (claude_md_dead or tree_dead):
        sys.exit(1)


if __name__ == "__main__":
    main()
