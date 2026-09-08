# Methodology Sources

Checked 2026-08-26. These are primary or project-maintained sources. Recheck mutable guidance before a security-sensitive revision.

## Skill Design

- [Agent Skills specification](https://agentskills.io/specification): portable `SKILL.md` structure, concise discovery metadata, progressive disclosure, focused references, and validation.
- [Agent Skills best practices](https://agentskills.io/skill-creation/best-practices): ground skills in real incident/runbook evidence, use moderate detail, route references explicitly, and refine through execution traces and evaluation cases.
- [Anthropic Claude Code skills](https://docs.anthropic.com/en/docs/claude-code/skills): skill discovery, supporting files, invocation behavior, and testing in Claude Code.

## Agentic Red Team

- [OWASP AI Agent Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/AI_Agent_Security_Cheat_Sheet.html): least-privilege tools, untrusted-input boundaries, memory isolation, action-bound approvals, fail-closed enforcement, monitoring, multi-agent containment, and adversarial CI cases.
- [OWASP GenAI Red Teaming Guide](https://genai.owasp.org/resource/genai-red-teaming-guide/): threat-model-driven testing across model, implementation, infrastructure, and runtime layers.
- [OWASP Top 10 for Agentic Applications 2026](https://genai.owasp.org/resource/owasp-top-10-for-agentic-applications-for-2026/): current agentic risk categories and mitigations.
- [MITRE ATLAS](https://atlas.mitre.org/): threat-informed adversarial techniques and case studies for AI-enabled systems.
- [NIST AI RMF Generative AI Profile, AI 600-1](https://nvlpubs.nist.gov/nistpubs/ai/NIST.AI.600-1.pdf): pre-deployment and ongoing evaluation, go/no-go thresholds, independent assessment, incident evidence retention, and value-chain risk.

## Secure Development and Release Supply Chain

- [NIST Secure Software Development Framework, SP 800-218](https://csrc.nist.gov/pubs/sp/800/218/final): prepare, protect, produce well-secured software, and respond to vulnerabilities through repeatable development practices.
- [SLSA v1.2 specification](https://slsa.dev/spec/v1.2/): build/source integrity and verifiable artifact provenance.
- [SLSA v1.2 artifact verification](https://slsa.dev/spec/v1.2/verifying-artifacts): verify artifact digests and provenance against an explicit policy and trusted builder/source identity.
- [The Update Framework security model](https://theupdateframework.io/security/): rollback, freeze, mix-and-match, arbitrary-package, and key-compromise threat classes for software update systems.
- [The Update Framework specification](https://theupdateframework.github.io/specification/latest/): consistent snapshots, expiration, version monotonicity, threshold trust, and target verification.
- [GitHub Actions secure use](https://docs.github.com/en/actions/reference/security/secure-use): least-privilege tokens, full-SHA action pinning, untrusted workflow boundaries, secret handling, and runner isolation.
- [GitHub artifact attestations](https://docs.github.com/en/actions/concepts/security/artifact-attestations): cryptographically signed provenance binding artifacts to workflow, repository, environment, event, and commit SHA; verification is required and does not itself prove safety.
- [OpenSSF Open Source Project Security Baseline](https://baseline.openssf.org/versions/2025-10-10.html): minimum repository, workflow, access, vulnerability, and release controls.

## Adaptation to IWE/FMT

The skill translates these sources into platform-specific acceptance tests:

- SLSA/GitHub -> exact SHA/tag/release/manifest/CI receipt and optional attestation verification;
- TUF -> updater rollback, freeze, mixed-revision, stale-cache, and partial-publication tests;
- OWASP/NIST/MITRE -> prompt, memory, tool, approval, scheduling, multi-agent, exfiltration, and loop abuse cases;
- NIST SSDF/OpenSSF -> protected release workflows, least privilege, negative controls, vulnerability regression, and retained evidence;
- prior IWE/FMT defect classes -> installed projection, Bash 3.2, shared Python resolver, self-update transaction, Day Open graph, session-layout consistency, and truthful fail-closed postconditions.

The adaptation intentionally excludes any real consumer installation, personal path, private DS content, or user-specific integration policy.
