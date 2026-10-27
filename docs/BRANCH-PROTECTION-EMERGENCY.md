# Removing and Restoring `main` Branch Protection (Emergency Procedure)

> WP-529 F21. Write this on a calm day — not during an incident.
> Toggling the normal mode (`required_approving_review_count` /
> `require_code_owner_reviews`) uses a separate script:
> `setup/wp529-f21-toggle-required-review.sh` — see its `--help` comment at
> the top of the file. This document covers only the case where branch
> protection itself blocks a required action (for example, an emergency
> rollback that `enforce_admins` prevents) and the normal toggle is not
> sufficient.

## Why This Is a Separate Procedure and Not Part of the Script

The GitHub API cannot selectively "disable one protection rule and re-enable
it" — `DELETE .../protection` removes all protection at once: review
requirements, required status checks (`release-receipt`, `changelog-entry`),
the force-push ban, the branch-deletion ban, and everything else are all
removed together. Restoring protection via `PUT` is possible, but only if
you know in advance *exactly what to restore* — after `DELETE`, those
settings are stored nowhere and cannot be read back from GitHub.

## Current Base Profile (recorded 22.10.2026)

```json
{
  "required_status_checks": {
    "strict": false,
    "contexts": ["release-receipt", "changelog-entry"]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": false,
    "require_last_push_approval": false,
    "required_approving_review_count": 0
  },
  "restrictions": null,
  "required_linear_history": false,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "block_creations": false,
  "required_conversation_resolution": false,
  "lock_branch": false,
  "allow_fork_syncing": false
}
```

**These are the live current settings, not a template.** If the protection
profile changes through a normal operation — for example,
`setup/wp529-f21-toggle-required-review.sh on --apply` enables required
reviews — update this block in the same commit that changes the protection.
Otherwise, the procedure below will restore an outdated profile. Before any
planned protection change, verify that the block above matches the output of
`gh api repos/iwesys/IWE/branches/main/protection`.
A discrepancy means someone changed the protection directly via the UI or API,
bypassing this document.

## Procedure

**1. Remove protection:**
```bash
gh api -X DELETE repos/iwesys/IWE/branches/main/protection
```

**2. Perform the single action that required removing protection.**
Do not use the open window for anything else — proceed immediately to step 3.

**3. Restore protection** — copy the JSON block from "Current Base Profile"
above into a file and apply it:
```bash
cat > /tmp/branch-protection-restore.json <<'EOF'
{
  "required_status_checks": {
    "strict": false,
    "contexts": ["release-receipt", "changelog-entry"]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": false,
    "require_last_push_approval": false,
    "required_approving_review_count": 0
  },
  "restrictions": null,
  "required_linear_history": false,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "block_creations": false,
  "required_conversation_resolution": false,
  "lock_branch": false,
  "allow_fork_syncing": false
}
EOF
gh api -X PUT repos/iwesys/IWE/branches/main/protection \
  --input /tmp/branch-protection-restore.json
rm -f /tmp/branch-protection-restore.json
```

**4. Verify that exactly this configuration was restored:**
```bash
gh api repos/iwesys/IWE/branches/main/protection | python3 -m json.tool
```
Compare the output against the "Current Base Profile" block line by line — do not skim.

## Known Open Issues

**Parallel peer-session identity deadlock (F21, open).** If
`required_approving_review_count` is ever enabled (`on --apply`) and two
peer sessions are simultaneously waiting for each other to approve their
respective PRs, neither can proceed. Either both are waiting, or neither is
allowed to approve its own PR under the same GitHub account — when both
sessions push from the same `gh auth` identity. This document addresses only
"remove and restore full protection"; it does not resolve this specific
deadlock. That remains an open F21 item for a separate discussion.

**`enforce_admins: true` in the current profile.** This means that even the
repository owner cannot bypass protection through the UI without explicitly
following this removal procedure. That is intentional — otherwise protection
does not protect against anything. It also means that step 1 above is the
only path even for the owner when normal protection has blocked a required
action.
