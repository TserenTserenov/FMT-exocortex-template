---
description: IWE operational memory file
domains:
- reference
horizon: warm
name: dry-run-contract
owner: platform
related:
- VR.SC.005
- DP.ARCH.001
schema_version: 1
status: active
type: protocol
valid_from: 2026-04-26
---
# Dry-Run Contract for Skills With Side Effects

> **Purpose.** Guarantee read-only mode for ritual skills (`/day-open`, `/day-close`, `/week-close`, `/month-close`), so that `/audit-installation` can smoke-test them without creating drift.
>
> **Implementation principle (variant F3).** Skills do NOT know about dry-run. Protection works via a **PreToolUse Hook + sentinel file** — an external mechanism independent of skill logic. This covers the author (inline skills), Pilots (FMT delegation), and Pilots' custom skills.

## State machine (issue #549 stage 2, 2026-08-31 — superset of sentinel)

> **Problem not closed by stage 1:** the branch "sentinel removed, owner file still present" was a permanent fail-closed with no standard unblocking path from within (session died between `rm sentinel` and the Stop hook, or the id did not match).

**Invariants (design confirmed by Codex peer review, 2 rounds):**

1. **Single canonical record** — `/tmp/iwe-dry-run-<uid>/gate-<gate_id>.state` (JSON v2: `gate_id`, `owner_session_id`, `owner_pid`/`owner_pgid`/`owner_pid_start`, `state: active|completed`, `created_at`, `completed_at`, `completion_reason`, `owner_token_sha256`). The capability token is stored only as sha256 — a rehearsal reading the state via an allowed read-only command receives only the hash and cannot complete the gate itself (completion requires the preimage; the runtime's Stop hook completes inline — no trusted flag exists; Codex r2: the flag was bypassed via shell-quoting of the argument). Sentinel `/tmp/iwe-dry-run.flag` is only a marker of active mode with a `gate_id` reference to this record; the gate decision is made from the state table (sentinel × state), not from the sentinel alone.
2. **Exclusivity:** one active rehearsal per installation; a second attempt fails with the current `gate_id`. Multiple active states = corruption → fail-closed.
3. **Atomic transitions and creation:** only `active→completed`, monotonically, via tmp+mv inside a short transactional lock (`transaction.lock/` via `mkdir`, lock owner is pid+nonce — a provably orphaned lock is removed under a unique name; release only by its own nonce). Creation also happens under the lock and only through the helper (`scripts/dry-run-begin.sh`: re-scan, reject if a rehearsal is active, exclusive sentinel creation after the state file). Completion is performed by the **completion command** (`scripts/dry-run-complete.sh`, capability token); the Stop hook is an idempotent fallback inline via `gate_id`+`owner_session_id` (entire scan under one lock, transition only when there is exactly one valid v2 active record for the current session, sentinel removed only after a successful transition). Repeated completion does not overwrite metadata.
4. **Provable orphan detection** (instead of permanent blocking): `owner_pid` is dead OR its `lstart` does not match (pid reuse) **AND** no live process with `owner_pgid` → `completed(reason=orphan-sweep)` → allow. Any ambiguity (ps error, corrupt state, unknown `gate_id`, live pgid) → the original permanent fail-closed, with recovery command `dry-run-complete.sh <gate_id> manual-recovery`.
5. **Known residual issues (accepted consciously):** (a) if the runtime places the gate itself in the owner's process group, the pgid scan always sees "live" → permanent fail-closed (safe direction); (b) `lstart` is a text platform format: a live pid with a DIFFERENT start = pid reuse (original owner is provably dead), while UNREADABLE ps/empty output = "unproven" → fail-closed; (c) same-uid attacks are outside the threat model (protection via 0700 directory + lstat checks against symlinks/foreign owner); (d) PGID reuse produces only a false fail-closed; (e) path env overrides (`IWE_DRY_RUN_DIR`/`IWE_DRY_RUN_SENTINEL`) are active only when the `.iwe-dry-run-test-mode` marker is present in the override directory — ambient variables from launch configuration do not disable the protection.
6. **Legacy:** old-format `owner-*.token` files (without a state file) follow the original permanent branch with `rm -f` recovery. `sentinel+completed` → self-healing: stale sentinel is removed after a `gate_id` check.

## Sentinel mechanics

### File

```
/tmp/iwe-dry-run.flag
```

- **Name:** single file, not session-bound (v2, WP-7/BUGTRIAGE2, issue #237). `CLAUDE_SESSION_ID` is not forwarded to sub-agent environments — a session-bound name caused desync: the main agent created `iwe-dry-run-${SID}.flag` using its own SID, while the Stop hook of the sub-agent cleaned up using its own (empty/different) SID, missing the actual file. A single name eliminates the create/cleanup desync.
- **Content:** one JSON line: `{"created_at": "<ISO8601>", "session_id": "<initiator-id>", "initiator": "<skill-name>"}` — `session_id` is stored for diagnostics only and does not participate in file lookup or cleanup.
- **TTL:** 40 minutes (2400 s) from mtime (issue #460 path 3; was 10 min — measured `close day` takes ~26 min, the old TTL expired mid-rehearsal). A file with mtime older than TTL is **fail-CLOSED**: the hook blocks and leaves the sentinel in place for manual inspection; it no longer deletes it automatically (the old `rm -f` + allow was the same class of fail-open as paths 1/2).
- **Cleanup:** (a) explicit — final step of `/audit-installation`; (b) TTL expiry requires manual `rm -f`, no automatic cleanup. The owner's Stop (even with matching `session_id` and capability token) **no longer removes the sentinel** (issue #460 path 6 — the parent and its background sub-agent share the same `session_id`, so the parent work-turn's Stop could tear down the protection while the sub-agent is still writing); Stop only cleans up the current session's residue owner file, and only when the sentinel is already absent. A foreign Stop still does not remove the protection (issue #460 path 7, regression covered by a test).

### Lifecycle

```
[start]  /audit-installation smoke-test step
         → echo "$payload" > /tmp/iwe-dry-run.flag
         → launch subagent: /run-protocol close day (via Agent tool)
         → ...
[end]    rm -f /tmp/iwe-dry-run.flag
         → analyze subagent result
```

## PreToolUse Hook `dry-run-gate.sh`

### Contract

When a valid sentinel file is present (single name, mtime ≤ 40 min), the hook blocks **any tool call with side effects** and returns exit 2 with diagnostics:

```
[dry-run-gate] BLOCKED: <tool> on <path/cmd>
Reason: dry-run mode active (sentinel created at <iso>, by <initiator>)
Expected: tool blocked by contract, this is rehearsal failure point
```

### Blocked tool matchers

| Tool | Matcher | What | Why |
|---|---|---|---|
| `Write` | any | File write | Obvious side effect |
| `Edit` | any | Edit | Obvious side effect |
| `MultiEdit` | any | Multi-edit | Obvious side effect |
| `NotebookEdit` | any | Jupyter | Side effect |
| `Bash` | `command` regex | See below | Indirect side effects |
| MCP-write | tool name whitelist | See below | Write via MCP |

### Bash matchers

v2 (WP-7/BUGTRIAGE2, issue #237): not a full-line regex but three passes —
(1) strip quoted spans (`'...'`/`"..."` → `QSTR`, except psql — SQL is matched against
the original), (2) split the normalised string into simple commands on `; & | && || ( ) { } $( `` `,
(3) classify each fragment by its first word (after skipping `VAR=val`/
`command`/`env`/`nohup`/`time`/`sudo`). This simultaneously closes the subshell bypass
(`(git commit)`) and false positives on text inside quotes (`echo "git commit"`).
Implementation — `.claude/hooks/dry-run-gate.sh`, "Bash matchers" section.

Classified commands (by first word of fragment):

```
git (add|commit|push|pull|reset|merge|rebase|mv|rm), git checkout -*
rm | mv                     # except cleanup of own sentinel
tee (not /dev/null)
sed -i*
curl -X (POST|PUT|DELETE|PATCH) | curl --data | curl -d
psql ... (INSERT|UPDATE|DELETE|TRUNCATE|DROP|ALTER)   # matched against original (SQL in quotes)
bash|sh|zsh <script>              # indirect execution — block, EXCEPT whitelist below (issue #264)
python|python3 <script>           # indirect execution — block, EXCEPT whitelist below (issue #460 path 5)
python|python3 -c "..."           # inline snippet — outside contract per threat model (see below), allow
eval|source|.|xargs               # indirect execution — payload is uninspectable after quote-strip

Whitelist read-only helpers (issue #264) — allowed under dry-run because
the script code contains no write paths (verified at time of addition, see rule below):

```
.claude/scripts/load-extensions.sh                    # relative, from workspace root
$HOME/IWE/.claude/scripts/load-extensions.sh          # absolute, hardcoded
scripts/day-close-prepare.sh                          # relative (issue #315) — valid
                                                        # only when CWD is inside IWE
${IWE_SCRIPTS:-$HOME/IWE/scripts}/day-close-prepare.sh # absolute (non-static — actual nested
                                                        # path resolved via $IWE_SCRIPTS, issue #315)
"$IWE_SCRIPTS/day-close-prepare.sh"                    # the real documented form (day-close call
                                                        # from day-close/SKILL.md) — marker __WL_DAY_CLOSE_PREPARE__
```

Python whitelist (issue #460 path 5, added after code review caught that an
unconditional block broke `close day` at the very first step):

```
${IWE_TEMPLATE:-<HOME_DIR>/IWE/IWE}/.claude/scripts/memory-drift-scan.py
${IWE_TEMPLATE:-<HOME_DIR>/IWE/IWE}/.claude/scripts/check-index-health.py
```

Both are read-only diagnostics (day-close/SKILL.md steps 1–2), with no write paths in the code
(verified). Markers `__WL_PY_MDS__`/`__WL_PY_CIH__`, same targeted
sed-replacement technique used before split as for `day-close-prepare.sh` above — `${IWE_TEMPLATE:-...}`
contains `{`/`}` that would otherwise split the path into segments (see code comments).
The pattern matches the **exact** `$HOME` path, not a wildcard default — round-2 review
reproduced live that `[^}]*` allowed `${IWE_TEMPLATE:-$(cmd)}/...` as
allow, swallowing command substitution as a marker before step 2 could
segment it. `rule-classifier.py` (day-close/SKILL.md step "Rule-engine")
is intentionally NOT in the whitelist — the SKILL.md itself documents that the script makes edits.
`{{HOME_DIR}}` in the SKILL.md source is a repository-template placeholder
(setup.sh renders only CLAUDE.md, not `.claude/skills/`); the executing agent is expected to
substitute the real path when forming the Bash call — the same principle as the
existing `WL_ABS`/`WL_ABS2` (bash whitelist).

The absolute pattern is hardcoded to `$HOME/IWE`, not a glob `*/.claude/...` or
`$IWE_ROOT` — otherwise a planted `/tmp/.claude/scripts/load-extensions.sh` or
env injection `IWE_ROOT=/tmp/evil` would pass the gate (review-01 High, review-02 H1).
Users with a non-standard workspace location call the helper via a relative path
from the workspace root.

The real (and only documented) call to `day-close-prepare.sh` is
`bash "$IWE_SCRIPTS/day-close-prepare.sh"` (day-close/SKILL.md, day-close-details.md).
`$IWE_SCRIPTS` defaults to `$WORKSPACE_DIR/IWE/scripts`
(`scripts/` is not copied to the workspace root, unlike `.claude/` — see
`.claude/lib/iwe-env-bootstrap.sh:86`), so neither of the two paths above by itself
matches the real call: the quoted variable `"$IWE_SCRIPTS/..."` is consumed
by the general quote-collapse (step 1 of Bash matchers) before the whitelist
case is reached, and becomes an indistinguishable `QSTR` token. The targeted
sed-replacement of the literal (unexpanded at PreToolUse time) pattern
`"$IWE_SCRIPTS/day-close-prepare.sh"` → marker `__WL_DAY_CLOSE_PREPARE__`
runs BEFORE the general quote-collapse and restores the match specifically for
this hardwired call, without opening a quote-bypass for anything else
(independent verification — review caught both this and the incorrect absolute path above
in the first version of the fix; corrected in the second iteration, live reproduction
of the exact documented command confirmed allow).

`day-close-prepare.sh` (issue #315) — read-only digest orchestrator for Day Close step 0b
(see code: only `git log`/`grep`/`ls`/`wc`/`python3 <script>`/
`wakatime-cli --today`, no write paths — redirect to file, `tee`, `sed -i`,
`git add|commit|push`, `rm`/`mv` are absent from the code). Before the fix, the narrow whitelist
(only `load-extensions.sh`) blocked it as "indirect execution", even though
the gate triggers on actual writes — the ritual smoke-test lost accuracy,
failing on harmless reads before the first real write.

Whitelist rule: additions require (1) a line here + (2) a branch in the `bash|sh|zsh` case
in dry-run-gate.sh + (3) code review confirming the absence of write paths
(redirect/tee/sed -i/mv/rm in the script code).
> file / >> file             # redirect to a real file (not /dev/null)
```

`.iwe-paths` whitelist for `source|.` (issues #784/#785) — only two exact documented
forms of source/dot calls are allowed:

```
. "$HOME/.iwe-paths"
IWE_PATHS="${IWE_PATHS_FILE:-}"; if [ -z "$IWE_PATHS" ]; then for _c in "$PWD/.iwe-paths" "${IWE_WORKSPACE:-$HOME/IWE}/.iwe-paths" "$HOME/.iwe-paths"; do [ -r "$_c" ] && { IWE_PATHS="$_c"; break; }; done; fi; [ -n "$IWE_PATHS" ] && . "$IWE_PATHS"
```

(and the same forms with `source` instead of `.`). The `.iwe-paths` file is a read-only
path config (used by day scripts, contains no write logic);
before the fix, the unconditional block of the `eval|source|.|xargs` branch broke
the legitimate day start on the very first access to it.

Technique: `eval|source|.|xargs` are split into two independent cases — `eval|xargs`
remains an unconditional block (payload is uninspectable after quote-strip, no other
legitimate calls exist), while `source|.` receives a targeted sed-replacement before split
(same technique as `day-close-prepare.sh`/python whitelist above) with two
vulnerabilities found by live code review, both fixed before merge:

1. **Static marker spoofing** (Codex, cold review) — the first version replaced the
   literal with a static token `__WL_IWE_PATHS__`; an attacker prints this token
   literally as an argument (`source __WL_IWE_PATHS__` + a planted file of the same name)
   — NORM cannot distinguish "marker from substitution" from "marker from input".
   Fix — `GATE_NONCE` (random value from `/dev/urandom`, computed once per hook
   process — PreToolUse creates a new process per call): the marker
   `__WL_IWE_PATHS_${GATE_NONCE}__` is unpredictable to the attacker within a single call.
2. **HOME/IWE_PATHS_FILE override in a preceding segment of the same command**
   (Fable, independent post-merge review) — the whitelist matches the
   UNEXPANDED text `"$HOME/.iwe-paths"`, not the resolved value; the classifier
   processes each segment independently and does not remember assignments from previous
   segments of the same compound command. `HOME=/tmp/evil; . "$HOME/.iwe-paths"`
   passes textually as allow, but at actual execution bash substitutes
   the already-poisoned `$HOME` and sources `/tmp/evil/.iwe-paths`. Fix — pre-scan
   of the entire `$SPLIT` (before case dispatch) for an assignment to `HOME`/`IWE_PATHS_FILE`
   anywhere in the command; a triggered `HOME_OR_IWE_PATHS_TAMPERED` flag blocks
   the `source|.` branch entirely for that command, regardless of what follows `.`/`source`.
3. **Incomplete coverage of assignment forms + missing argc check** (Codex,
   round-2 cold review of the same Fable finding) — the first version of the pre-scan
   caught only `^(export )?(HOME|IWE_PATHS_FILE)=` (anchor at segment start) — it missed
   `readonly`/`declare`/`typeset`/`local`/`builtin export`/
   `command export`, `printf -v HOME ...`/`read HOME ...` (assignment via
   builtin, without the `HOME=` token) and prefix assignment not as the first word of the
   segment (`x=1 HOME=evil cmd`, without `;`). Separately: NORM inserts spaces
   around the marker during replacement — without an argc check, concatenation without a space
   in the original command (`. "$HOME/.iwe-paths"suffix`) would resolve to
   `W0=. $1=marker $2=suffix` and pass as allow. Fix — regex without anchor at segment start,
   covering all listed assignment forms (see code), plus `[ $# -gt 0 ] && block ...`
   immediately after the marker in the `source|.` case.

Both checks are in the `sed -E` pipeline of NORM; an invalid `-e` expression kills
the entire pipeline (exit≠0, empty stdout) and without an explicit check would cause
allow-all (SPLIT is empty → the while loop does not iterate → `exit 0` by default) —
after `NORM=$(...)`, a check for `NORM_RC`/`fail_closed` on failure is mandatory.

**Accepted boundary (not a bug, documented scope decision):**
Codex (round-2, after confirming the fix is "reasonable for deployment within this
boundary") identified a residual class — INDIRECT variable name construction
(`v=HOME; declare "$v"=/tmp/evil; ...`, `declare -n h=HOME;
h=/tmp/evil; ...`) — changes `$HOME` without any `HOME=`/`IWE_PATHS_FILE=` token
in the command, so NO regex on the two variable name literals can catch this
in principle (this is not a missed specific form, but the general undecidability
of static assignment analysis in a Turing-complete language without actual
execution/AST parsing). Consciously out of scope for this fix: (a) it is exotic —
`declare -n`/dynamic variable name construction via intermediate `v=...` looks
suspicious even in a quick code review, and does not resemble natural legitimate
command text; (b) it requires an architecturally different level of solution (a real
bash parser/AST or sandboxed dry-run execution), not a targeted regex patch.
If a live incident with this vector ever occurs — escalate to the Pilot, do not apply
a silent patch by analogy.

### MCP-write whitelist

Exact tool names (full list — everything that is NOT read-only):

```
mcp__claude_ai_IWE__personal_write
mcp__claude_ai_IWE__personal_delete
mcp__claude_ai_IWE__personal_create_pack
mcp__claude_ai_IWE__personal_propose_capture
mcp__claude_ai_IWE__personal_reindex_source
mcp__claude_ai_IWE__personal_scaffold_notes
mcp__claude_ai_IWE__dt_write_digital_twin
mcp__claude_ai_IWE__create_repository
mcp__claude_ai_IWE__github_connect
mcp__claude_ai_IWE__github_disconnect
mcp__claude_ai_IWE__knowledge_feedback
mcp__claude_ai_Gmail__create_draft
mcp__claude_ai_Gmail__create_label
mcp__claude_ai_Gmail__label_message
mcp__claude_ai_Gmail__label_thread
mcp__claude_ai_Gmail__unlabel_message
mcp__claude_ai_Gmail__unlabel_thread
mcp__claude_ai_Google_Calendar__create_event
mcp__claude_ai_Google_Calendar__delete_event
mcp__claude_ai_Google_Calendar__update_event
mcp__claude_ai_Google_Calendar__respond_to_event
mcp__claude_ai_Google_Drive__create_file
mcp__ext-google-calendar__create-event
mcp__ext-google-calendar__create-events
mcp__ext-google-calendar__delete-event
mcp__ext-google-calendar__update-event
mcp__ext-google-calendar__respond-to-event
mcp__ext-google-drive__copy_file
mcp__ext-google-drive__create_file
mcp__ext-google-drive__create_folder
mcp__ext-google-drive__delete_file
mcp__ext-google-drive__move_file
mcp__ext-google-drive__update_file
mcp__ext-google-drive__share_file
mcp__ext-linear__create_issue
mcp__ext-linear__update_issue
mcp__ext-railway__create-environment
mcp__ext-railway__create-project-and-link
mcp__ext-railway__deploy
mcp__ext-railway__deploy-template
mcp__ext-railway__generate-domain
mcp__ext-railway__link-environment
mcp__ext-railway__link-service
mcp__ext-railway__set-variables
```

Read-only tools (`*_search`, `*_get_*`, `*_list_*`, `*_status`, `dt_read_*`, etc.) — **allowed**.

### Fail-safe (hook failure)

If the hook **itself fails** (syntax error, missing jq) → **fail-CLOSED** (exit 2 with `hook-error` label). Principle: a false block is preferable to a missed contract violation.

```bash
if ! command -v jq >/dev/null 2>&1; then
    echo "[dry-run-gate] FAIL-CLOSED: jq missing, blocking by default" >&2
    exit 2
fi
```

## Extension obligations

Pilot extensions (`extensions/*.md`) may run their own bash. To avoid breaking dry-run:

```bash
# At the start of the extension script, BEFORE any write action:
if [ -f "/tmp/iwe-dry-run.flag" ]; then
    echo "[extension] dry-run active, skipping write steps"
    exit 0
fi
```

**Alternative path:** the extension performs writes through standard tools (Write/Edit/Bash) — the hook intercepts them automatically. An explicit sentinel check in the extension is only needed if the extension wants to produce a "meaningful rehearsal" (rather than a plain block), or if it uses exotic tools (binary APIs) that the hook does not cover.

## Smoke-test analysis in `/audit-installation`

The sub-agent analyses the transcript after running the ritual:

| Signal | Interpretation |
|---|---|
| **All steps completed without a block** | `/run-protocol close day` has NO write steps (suspicious — it should have some). Verdict: ⚠️ |
| **Block at step 1–2** | The ritual fails early (missing source file, MCP down). Verdict: ❌ |
| **Block at a write step (commit/Write)** after successful read steps | Read logic works. This is the **expected behavior** of the smoke-test. Verdict: ✅ |
| **Hook-error** (jq missing, etc.) | Infrastructure is broken. Verdict: ❌ |

## Outside the contract

- **Guarantee that the ritual works correctly in terms of content** (pass/fail logic). This is open-loop verification, not closed-loop. The smoke-test checks initiability, not correctness.
- **Coverage of subtle side effects** — for example, a skill may read a `/tmp` file that contains a `mktemp` call (creates a temporary file, formally a write). The hook does not block these. Principle: block what changes user data, not temp state.
- **Protection against malicious extensions.** The contract operates under the assumption of good-faith Pilots. If an extension intentionally bypasses the hook (e.g., via `python -c 'open(...,"w")'`) — this is outside the threat model.

## History

- **v1 (rejected):** dry-run flag in each skill (variant A from ArchGate v1). Declarative contract; the LLM could miss the flag.
- **v2 (rejected):** dry-run flag in `/run-protocol` (F2 from ArchGate v2). Does not cover author inline skills.
- **v3 (rejected):** sentinel + hook, session-bound file name (F3 from ArchGate v3). Covered all skills regardless of structure, but the session-bound sentinel did not survive sub-agents — issue #237.
- **v4 (WP-7/BUGTRIAGE2):** single sentinel file (not session-bound) + bash command parsing into simple segments instead of full-line regex. Closes 4 holes found and confirmed by live hook execution: sticky block in sub-agents, self-blocking cleanup, subshell bypass, false positives on text inside quotes.
- **v5 (current, issue #460):** a live installation caught 7 fail-open paths at once — `/audit-installation` actually wrote to a file during rehearsal. Fail-closed instead of fail-open on jq-missing (path 1) and sentinel-missing-with-owner (path 2); TTL 600 s → 2400 s + fail-closed instead of `rm+allow` on expiry (path 3); `python`/`python3` added to the indirect-execution matcher (path 5); Stop hook no longer removes a live sentinel at all, not even its own — only the residue owner file when the sentinel is already explicitly removed (path 6); path 7 (foreign session) was already closed, covered by a regression test.
