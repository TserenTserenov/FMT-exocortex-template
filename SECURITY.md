# Security Policy

## Supported Versions

IWE is distributed as a rolling release (`update.sh` pulls the latest template version). Separate LTS branches are not supported — vulnerabilities are fixed in `main` and delivered to all users via the next `update.sh`.

## Reporting a Vulnerability

The primary channel is private: use the **Security → Report a vulnerability** tab in this Repository ([GitHub Private Vulnerability Reporting](https://github.com/TserenTserenov/FMT-exocortex-template/security/advisories/new)). Do not create a public Issue for vulnerabilities that have not yet been fixed.

If the private form is unavailable, email **aisystant@gmail.com**.

When reporting, include: the IWE version (`bash update.sh --check`), a reproduction scenario, expected and actual behavior, and potential impact. Response time is within 1 week. After confirmation, coordinated disclosure follows the release of the fix.

## Threat Model: Honest About Trade-offs

IWE is not an isolated service. It is a set of Scripts and agent instructions that run with your local user's permissions. The following describes the real design trade-offs — not a list of guarantees.

- **The trust boundary is your machine.** Claude Code and other agents run with your account's permissions. `.claude/hooks/` and `.claude/scripts/` can execute arbitrary shell commands — treat changes to these directories as code that requires Review (see `CLAUDE.md` §2 p.6, Hooks/Scripts Bypass Gate).
- **Secrets stay local only.** IWE does not store or transmit secrets on your behalf: `.env` is in `.gitignore`, and keys belong in a password manager. A secret leak from your local Environment is outside the scope of this Repository's responsibility.
- **`update.sh` trusts upstream.** Template updates perform a 3-way merge from this Repository. If you operate in an Environment with elevated security requirements, review commits before running `update.sh` rather than trusting it automatically.
- **The publication Pipeline history was rewritten.** On 2026-07-09, the RU→EN publication Pipeline (`translate-sync.yml`) detected and fixed a bug: a force-push was pulling 1,037 commits from a private personal Repository into the public EN-facing store (`iwesys`). The bug is closed (publication now takes only the file tree, not the history), but this is an example of how the publication Pipeline is not merely a "mirror" — it is a separate failure point that we monitor separately.
- **External LLM calls.** Requests to the Anthropic API and (for the translation Pipeline) to OpenRouter carry prompt content. See [docs/DATA-POLICY.md](docs/DATA-POLICY.md) §3 for details.

## Dependencies

Report vulnerabilities in dependencies (Python packages in CI, GitHub Actions) through the same channel. `dependabot`/`secret-scanning` are not yet enabled in this Repository (see the open item in the public store benchmark).
