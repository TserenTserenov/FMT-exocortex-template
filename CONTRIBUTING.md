# Contributing to IWE

Thank you for your interest in contributing to IWE! This document explains how to contribute effectively.

**Language:** Issues and PRs in English or Russian are both welcome.

---

## Ways to Contribute

### Report Issues

- **Bugs:** Something broke during `setup.sh`, `update.sh`, or a protocol didn't work as expected
- **Documentation:** Unclear instructions, broken links, missing explanations
- **Ideas:** Feature requests, workflow improvements, new use cases

Use [GitHub Issues](https://github.com/TserenTserenov/FMT-exocortex-template/issues) with the appropriate template.

### Share Your Setup

Show how you use IWE in [GitHub Discussions](https://github.com/TserenTserenov/FMT-exocortex-template/discussions):
- Custom extensions you've built
- Workflows that work well for your domain
- Integration with other tools

### Submit Pull Requests

We welcome PRs for:
- Bug fixes in `setup.sh`, `update.sh`, and scripts
- Documentation improvements
- New extensions (in `extensions/` or `seed/`)
- Platform compatibility fixes (Linux, WSL)
- Translations

---

## Architecture: Three Layers

Before contributing, understand how IWE is structured:

| Layer | What | Who edits | Location |
|-------|------|-----------|----------|
| **L1 (Platform)** | Core protocols, skills, hooks, scripts | Maintainers only | Delivered via `update.sh` |
| **L2 (Staging)** | Rules being tested before promotion to L1 | Maintainers | `STAGING.md` |
| **L3 (User)** | Your personal customizations | You | `extensions/`, `params.yaml`, CLAUDE.md §9 |

**Key rule:** User customizations go in `extensions/` and `params.yaml`, never in platform files. This ensures `update.sh` works cleanly.

---

## Pull Request Guidelines

### Before You Start

1. Check existing [Issues](https://github.com/TserenTserenov/FMT-exocortex-template/issues) and [PRs](https://github.com/TserenTserenov/FMT-exocortex-template/pulls) to avoid duplicates
2. For non-trivial changes, open an issue first to discuss the approach
3. Fork the repository and create a branch from `main`

### Code Style

- **Shell scripts:** Follow existing style. Use `shellcheck` if available
- **Markdown:** Russian for user-facing docs (with English translations where needed). Technical comments in English are fine
- **Commit messages:** `feat:`, `fix:`, `docs:`, `chore:` prefixes. Brief, in English or Russian

### What Makes a Good PR

- **One concern per PR** — don't mix bug fixes with new features
- **Test your changes** — run `bash setup.sh --validate` before submitting
- **Update docs** — if your change affects user-facing behavior, update the relevant docs
- **Respect the layers** — platform changes (L1) require discussion; extension examples (L3) are welcome directly

### Review Process

1. Maintainer reviews within 1 week
2. CI runs `setup.sh --validate` automatically
3. Changes to L1 files require maintainer approval
4. Extensions and docs usually merge faster

---

## Development Setup

```bash
# Fork and clone
gh repo fork TserenTserenov/FMT-exocortex-template --clone
cd FMT-exocortex-template

# Validate the template
bash setup.sh --validate

# Run setup in dry-run mode to test changes
bash setup.sh --dry-run
```

---

## Extension Development

The easiest way to contribute is by creating extensions:

```bash
# Extensions hook into protocol stages
extensions/day-open.before.md    # Runs before Day Open
extensions/day-close.after.md    # Runs after Day Close
extensions/session-open.after.md # Runs after Session Open
```

See [extensions/README.md](extensions/README.md) for the full extension API, naming conventions, and sharing guidelines.

---

## Code of Conduct

- Be respectful and constructive
- Focus on the work, not the person
- Help others learn — IWE is about amplifying thinking, including in collaboration

---

## Questions?

- [GitHub Discussions](https://github.com/TserenTserenov/FMT-exocortex-template/discussions) — general questions and ideas
- [GitHub Issues](https://github.com/TserenTserenov/FMT-exocortex-template/issues) — specific bugs and feature requests
