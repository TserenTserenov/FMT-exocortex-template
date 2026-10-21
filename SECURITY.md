# Security Policy

## Supported Versions

IWE is distributed as a rolling release (`update.sh` pulls the latest template version). Separate LTS branches are not supported — vulnerabilities are fixed in `main` and delivered to all users via the next `update.sh` run.

## Reporting a Vulnerability

The primary channel is private: use the **Security → Report a vulnerability** tab in this Repository ([GitHub Private Vulnerability Reporting](https://github.com/iwesys/IWE/security/advisories/new)). Do not open a public Issue for vulnerabilities that have not yet been fixed.

If the private form is unavailable, contact **aisystant@gmail.com**.

Include the following in your report: IWE version (`bash update.sh --check`), reproduction steps, expected and actual behavior, and potential impact. You will receive a response within 1 week. After confirmation, coordinated disclosure follows the release of a fix.

## Threat Model: Honest About Trade-offs

IWE is not an isolated service. It is a set of scripts and agent instructions that run with your local user's permissions. The following describes real design trade-offs, not a list of guarantees.

- **The trust boundary is your machine.** Claude Code and other agents run under your user account. `.claude/hooks/` and `.claude/scripts/` can execute arbitrary shell commands — treat changes to these directories as code that requires Review (see `CLAUDE.md` §2 p.6, Hooks/Scripts Bypass Gate).
- **Secrets stay local.** IWE does not store or transmit secrets on your behalf: `.env` is in `.gitignore`, and keys belong in a password manager. A secret leaking from your local Environment is outside the scope of this Repository.
- **`update.sh` trusts upstream.** Template updates perform a 3-way merge from this Repository. If you operate in a high-security Environment, review commits before running `update.sh` rather than trusting it automatically.
- **The publication Pipeline history was rewritten.** On 2026-07-09, a bug was found and fixed in the publication Pipeline: a force-push was pulling unrelated commit history into the public distribution. The bug is closed (publication now takes only the file tree, not the history), but this is an example of the publication Pipeline being not just a "mirror" but a separate failure point that we monitor independently.
- **External LLM calls.** Requests to the Anthropic API and (for the publication Pipeline) to OpenRouter include prompt content. See [docs/DATA-POLICY.md](docs/DATA-POLICY.md) §3 for details.

## Dependencies

Report vulnerabilities in dependencies (Python packages in CI, GitHub Actions) through the same channel. `dependabot` and `secret-scanning` are not yet enabled in this Repository (see the open item in the public showcase benchmark).
