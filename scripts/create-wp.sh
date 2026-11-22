#!/usr/bin/env bash
# routing: helper  called-by=wp-gate  deterministic=true
# see DP.SC.159, DP.ROLE.059
# create-wp.sh — atomic WP creation in local locations (inbox, REGISTRY, WeekPlan);
# external tracker (Linear) — conditional post-step, only when connected MCP (issue #321)
# see WP-297 Phase6.2 (<governance-repo>/inbox/WP-297-wp-lifecycle-architecture.md)
# see DP.M.010, DP.ROLE.037
#
# Usage:
#   bash create-wp.sh --artifactor-result result.json --budget 5h --priority P3 --verification-class closed-loop [--slug slug] [--repo "repo"] [--related "WP-150:dependency,WP-167:product"]
#   bash create-wp.sh --artifactor-result result.json --budget 5h --priority P3 --verification-class open-loop --state "belonging (Readiness): from → to" --hypothesis "H-101 | —:infra|techdebt|order|spinoff" [--hypothesis-relation tests]
#   bash create-wp.sh --artifactor-result result.json --budget 5h --priority P3 --verification-class trivial --no-consent-check
#
# --verification-class (WP structural-hole fix): REQUIRED, always — trivial|closed-loop|open-loop|problem-framing.
#   Determines whether the WP needs a staged plan (/decompose): open-loop/problem-framing
#   with budget ≥3h get an extra checklist item in the generated context file's «Remaining»
#   section reminding the pilot to run /decompose. Unlike --state/--hypothesis this gate is
#   NOT conditional on a governance-repo file existing — every WP declares its class.
# --artifactor-result (WP-7 Phase142, 2026-09-11): path to JSON-call result
#   Artifactor (scripts/artifactor.py or LLM-fallback skill /artifactor,
#   field is required: "artifact"). TITLE is taken from the field "artifact" this
#   file -- --title is no longer the name source on its own, only verification/explicit
#   pilot revision: if BOTH are provided (--title and --artifactor-result) and they
#   differ, requires --pilot-revision "reason" (otherwise rejected -- name was created
#   bypassing the Artifactor result). Required for ANY task class (no
#   exception for trivial/closed-loop, go-ahead pilot 2026-09-11) --
#   emergency bypass: --no-artifactor-check.
# --state (WP-505): target state transition (WP-457 State-Transition Gate).
#   REQUIRED when <governance>/docs/state-axes-registry.yaml exists (author install);
#   optional otherwise (typical user install — gate inactive per template contract).
#   Must mention at least one gate_ready axis code from the registry file.
# --hypothesis (WP-496 Phase8): REQUIRED when <governance>/current/hypotheses-log.md exists —
#   H-NNN anchored in the log, or explicit dash with reason code (—:infra|techdebt|order|spinoff).
# --hypothesis-relation: tests|enables|responds|researches|operational|unclassified.
# New work must resolve unclassified before it is started; the default preserves
# older callers while making the missing strategic basis visible in frontmatter.
#
# Precondition: consent state file must exist:
#   touch ${IWE_ROOT:-$HOME/IWE}/.claude/state/wp-consent-{N}
#
# Compatibility: bash 3.2+ (macOS), bash 4+ (Linux)

set -uo pipefail

IWE="${IWE_ROOT:-$HOME/IWE}"

# --- Determine governance-repo ---
# Priority: (1) explicit variable IWE_GOVERNANCE_REPO → (2) DS-strategy (default convention)
GOV_REPO="${IWE_GOVERNANCE_REPO:-DS-strategy}"
if [[ -z "${IWE_GOVERNANCE_REPO:-}" ]] && [[ ! -d "$IWE/$GOV_REPO" ]]; then
  echo "ERROR: IWE_GOVERNANCE_REPO not set and $GOV_REPO not found in $IWE" >&2
  exit 1
fi

STRATEGY="$IWE/$GOV_REPO"
REGISTRY="$STRATEGY/docs/WP-REGISTRY.md"
INBOX="$STRATEGY/inbox"
STATE_DIR="$IWE/.claude/state"

# --- Parameters ---
TITLE=""
BUDGET=""
PRIORITY="P3"
SLUG=""
REPO=""
RELATED=""
RESULT=""
VERIFICATION_CLASS=""
STATE=""
HYPOTHESIS=""
HYPOTHESIS_RELATION="unclassified"
SKIP_CONSENT=0
ARTIFACTOR_RESULT_FILE=""
PILOT_REVISION=""
SKIP_ARTIFACTOR=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title)    TITLE="$2";    shift 2 ;;
    --budget)   BUDGET="$2";   shift 2 ;;
    --priority) PRIORITY="$2"; shift 2 ;;
    --slug)     SLUG="$2";     shift 2 ;;
    --repo)     REPO="$2";     shift 2 ;;
    --related)  RELATED="$2";  shift 2 ;;
    --result)   RESULT="$2";   shift 2 ;;
    --verification-class) VERIFICATION_CLASS="$2"; shift 2 ;;
    --state)    STATE="$2";    shift 2 ;;
    --hypothesis) HYPOTHESIS="$2"; shift 2 ;;
    --hypothesis-relation) HYPOTHESIS_RELATION="$2"; shift 2 ;;
    --no-consent-check) SKIP_CONSENT=1; shift ;;
    --artifactor-result) ARTIFACTOR_RESULT_FILE="$2"; shift 2 ;;
    --pilot-revision) PILOT_REVISION="$2"; shift 2 ;;
    --no-artifactor-check) SKIP_ARTIFACTOR=1; shift ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

# --- Artefactor Gate (WP-7 Phase142, 2026-09-11) ---
# Title must come from the Artifactor result, must not be invented by the agent
# bypassing it — go-ahead pilot: no exceptions for trivial/closed-loop.
# Divergent --title without --pilot-revision — rejection (agent inserted its own name,
# although the Artifactor result was different); emergency bypass — --no-artifactor-check.
ARTF_RESOLUTION_PATH="bypassed"
ARTF_SHA256=""
if [[ -n "$ARTIFACTOR_RESULT_FILE" ]]; then
  if [[ ! -f "$ARTIFACTOR_RESULT_FILE" ]]; then
    echo "❌ --artifactor-result: file not found: $ARTIFACTOR_RESULT_FILE" >&2
    exit 1
  fi
  ARTF_PARSED=$(python3 - "$ARTIFACTOR_RESULT_FILE" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        data = json.load(f)
except (OSError, json.JSONDecodeError) as exc:
    print(f"INVALID:cannot be read or is not JSON ({exc})")
    sys.exit(0)
if not isinstance(data, dict):
    print("INVALID:top level JSON is not an object (expected {...})")
    sys.exit(0)
artifact = data.get("artifact")
if not artifact or not isinstance(artifact, str):
    print("INVALID:field 'artifact' is empty or not a string")
    sys.exit(0)
if "\n" in artifact or "\r" in artifact:
    print("INVALID:field 'artifact' contains a newline character — the WP name must be a single line")
    sys.exit(0)
resolution_path = data.get("resolution_path") or "unknown"
print(f"OK:{resolution_path}\t{artifact}")
PYEOF
)
  if [[ "$ARTF_PARSED" != OK:* ]]; then
    echo "❌ --artifactor-result: ${ARTF_PARSED#INVALID:}" >&2
    exit 1
  fi
  ARTF_RESOLUTION_PATH="${ARTF_PARSED#OK:}"
  ARTF_RESOLUTION_PATH="${ARTF_RESOLUTION_PATH%%$'\t'*}"
  ARTF_ARTIFACT="${ARTF_PARSED#*$'\t'}"
  ARTF_SHA256=$({ shasum -a 256 "$ARTIFACTOR_RESULT_FILE" 2>/dev/null || sha256sum "$ARTIFACTOR_RESULT_FILE" 2>/dev/null; } | cut -d' ' -f1)
  if [[ -z "$TITLE" ]]; then
    TITLE="$ARTF_ARTIFACT"
  elif [[ "$TITLE" != "$ARTF_ARTIFACT" && -z "$PILOT_REVISION" ]]; then
    echo "❌ --title (\"$TITLE\") does not match the Artifactor result (\"$ARTF_ARTIFACT\")." >&2
    echo "   Either use the Artifactor wording as-is, or, if the pilot intentionally" >&2
    echo "   revised it themselves, add --pilot-revision \"reason for revision\"." >&2
    exit 1
  fi
elif [[ "$SKIP_ARTIFACTOR" -eq 0 ]]; then
  echo "🚫 WP Gate: no Artifactor result for the new WP" >&2
  echo "   Invoke Skill artifactor (or its keyword-keyword classifier directly), save JSON-response to a file:" >&2
  echo "   --artifactor-result /path/to/artifactor-result.json" >&2
  echo "   Required for any task class, no exceptions (go-ahead pilot 2026-09-11)." >&2
  echo "   Emergency bypass (not for routine WP creation): --no-artifactor-check" >&2
  exit 1
fi

# --- Validation ---
if [[ -z "$TITLE" || -z "$BUDGET" ]]; then
  echo "Usage: $0 --artifactor-result result.json --budget 5h --verification-class <trivial|closed-loop|open-loop|problem-framing> [--priority P3] [--slug slug] [--repo repo] [--related \"WP-NNN:type\"] [--result R3] [--state \"axis: from → to\"] [--hypothesis H-NNN] [--hypothesis-relation tests]" >&2
  exit 1
fi

# --- Verification-Class Gate (structural-hole fix) ---
# Unlike --state/--hypothesis, this is unconditionally required: every WP
# declares its verification class regardless of which governance-repo files
# exist. The class feeds the decompose-reminder checklist item below.
case "$VERIFICATION_CLASS" in
  trivial|closed-loop|open-loop|problem-framing) ;;
  *)
    echo "❌ --verification-class is required: trivial|closed-loop|open-loop|problem-framing" >&2
    echo "   Provided: ${VERIFICATION_CLASS:-<empty>}" >&2
    exit 1
    ;;
esac

case "$HYPOTHESIS_RELATION" in
  tests|enables|responds)
    [[ "${HYPOTHESIS:-—}" =~ ^H-[0-9]{3}$ ]] || {
      echo "❌ For the relation '$HYPOTHESIS_RELATION' required --hypothesis H-NNN" >&2
      exit 1
    }
    ;;
  researches|operational)
    [[ -z "$HYPOTHESIS" || "$HYPOTHESIS" == "—" || "$HYPOTHESIS" =~ ^—:(infra|techdebt|order|spinoff)$ ]] || {
      echo "❌ For relation '$HYPOTHESIS_RELATION' specify --hypothesis — or reason code —:<infra|techdebt|order|spinoff>" >&2
      exit 1
    }
    ;;
  unclassified) ;;
  *)
    echo "❌ Unknown hypothesis relation: $HYPOTHESIS_RELATION" >&2
    exit 1
    ;;
esac

# --- State-Transition Gate (WP-457 / WP-505) ---
# When the axes registry exists, --state is mandatory and must reference a
# gate_ready axis; without the registry (typical user install) the gate is off.
AXES_FILE="$STRATEGY/docs/state-axes-registry.yaml"
GATE_READY_AXES=""
if [[ -f "$AXES_FILE" ]]; then
  GATE_READY_AXES=$(python3 - "$AXES_FILE" <<'PYEOF'
import sys, re
codes, code = [], None
for line in open(sys.argv[1], encoding="utf-8"):
    m = re.match(r"\s*-\s*code:\s*(\S+)", line)
    if m:
        code = m.group(1)
    elif re.match(r"\s*gate_ready:\s*true\b", line) and code:
        codes.append(code)
        code = None
print(" ".join(codes))
PYEOF
)
  if [[ -z "$STATE" ]]; then
    echo "🚫 State-Transition Gate (WP-457): --state is required — axis registry found:" >&2
    echo "   $AXES_FILE" >&2
    echo "   Format: --state \"<axis> (<axis name>): <from> → <to>\"" >&2
    echo "   Allowed axes (gate_ready): $GATE_READY_AXES" >&2
    exit 1
  fi
  STATE_AXES=""
  for ax in $GATE_READY_AXES; do
    if [[ "$STATE" == *"$ax"* ]]; then
      STATE_AXES="$STATE_AXES $ax"
    fi
  done
  if [[ -z "$STATE_AXES" ]]; then
    echo "🚫 State-Transition Gate: in --state no matching gate_ready axis code" >&2
    echo "   Allowed: $GATE_READY_AXES" >&2
    echo "   Provided: $STATE" >&2
    exit 1
  fi
fi

# --- Hypothesis Gate (WP-496 Phase8) ---
# Mirror of the State-Transition Gate: when the hypotheses log exists (author
# install), --hypothesis is mandatory — either an H-NNN recorded in the log or
# an explicit dash with a reason code. A WP references an EXISTING bet
# (many WPs per hypothesis); new hypotheses enter only via the pilot's entry
# filter, never as a side effect of creating a WP. Installs without the log
# keep the gate off.
HYP_LOG="$STRATEGY/current/hypotheses-log.md"
if [[ -f "$HYP_LOG" ]]; then
  HYP_USAGE="H-NNN (from current/hypotheses-log.md) or —:infra | —:techdebt | —:order | —:spinoff"
  if [[ -z "$HYPOTHESIS" ]]; then
    echo "🚫 Hypothesis Gate (WP-496): --hypothesis is required — hypothesis log found:" >&2
    echo "   $HYP_LOG" >&2
    echo "   Format: $HYP_USAGE" >&2
    exit 1
  fi
  case "$HYPOTHESIS" in
    "—:infra"|"—:techdebt"|"—:order"|"—:spinoff") : ;;
    *)
      HYP_IDS=$(grep -oE '\bH-[0-9]{3}\b' <<<"$HYPOTHESIS" | sort -u)
      if [[ -z "$HYP_IDS" ]]; then
        echo "🚫 Hypothesis Gate: neither H-NNN nor H-NNN, nor reason code was recognized" >&2
        echo "   Provided: $HYPOTHESIS" >&2
        echo "   Format: $HYP_USAGE" >&2
        exit 1
      fi
      for HID in $HYP_IDS; do
        if ! grep -q "id=$HID " "$HYP_LOG"; then
          echo "🚫 Hypothesis Gate: $HID not found among log anchors ($HYP_LOG)" >&2
          echo "   A new hypothesis is registered through the log intake filter, not through create-wp" >&2
          exit 1
        fi
      done
      ;;
  esac
fi

# --- Decompose-reminder derivation (structural-hole fix) ---
# Budget formats seen in the wild: "5h", "2h", "3-4h" (range), "0.5h" / "0,5h"
# (fractional). For a range we want the upper bound — the more conservative
# read when deciding whether the WP is big enough to need a staged plan.
# Plain `sed 's/[^0-9]//g'` (used elsewhere in this script for a different,
# looser purpose) would mangle "3-4h" into "34"; this instead takes the max
# of all digit groups found. issue #1088: a plain `[0-9]+` group split "0.5h"
# into separate "0" and "5" groups, reading it as 5h instead of 0 (rounded
# down); matching an optional fractional part first and then truncating to
# its whole-number prefix keeps "3-4h" and ranges like "2.5-3.5h" correct too.
budget_upper_bound_hours() {
  local budget="$1" n max=0
  for n in $(grep -oE '[0-9]+([.,][0-9]+)?' <<<"$budget"); do
    n="${n%%[.,]*}"
    [[ "$n" -gt "$max" ]] && max="$n"
  done
  printf '%s\n' "$max"
}

# Step 4.5 protocol-open.md (/decompose): open-loop/problem-framing + budget
# ≥3h needs a staged plan. create-wp.sh is deterministic=true and cannot call
# the (non-deterministic) /decompose skill itself — instead it plants a
# checklist reminder directly in the generated «Remaining» section, so the
# nudge survives even when the console output scrolls away.
DECOMPOSE_CHECKLIST_ITEM=""
if [[ "$VERIFICATION_CLASS" == "open-loop" || "$VERIFICATION_CLASS" == "problem-framing" ]]; then
  if [[ "$(budget_upper_bound_hours "$BUDGET")" -ge 3 ]]; then
    DECOMPOSE_CHECKLIST_ITEM="- [ ] Run /decompose /decompose — stage-by-stage plan (verification class requires it) (verification class requires it)
"
  fi
fi

# YAML double-quoted scalar escape (WP-7 Phase142, found in cold-review 2026-09-11):
# title now always comes from external JSON (including.incl.. LLM-fallback
# Artifactor), not only from agent keyboard input -- a quote or newline character
# in a value used to silently corrupt frontmatter card (title: "${TITLE}" without
# escaping). Applied to any free-form text, going into YAML
# double-quoted scalar: title, --state, --hypothesis, --pilot-revision.
yaml_dq_escape() {  # yaml_dq_escape <string>
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

# Registry cell «Stake»: Russian axis names + hypothesis id (WP-505).
axis_ru() {
  case "$1" in
    permission) echo "Trust" ;;
    belonging)  echo "Resourcefulness" ;;
    engagement) echo "Engagement" ;;
    mastery)    echo "Competence" ;;
    community)  echo "Inclusion" ;;
    mentorship) echo "Care" ;;
    *)          echo "$1" ;;
  esac
}
STAKE_CELL="—"
if [[ -n "$STATE" && -n "${STATE_AXES:-}" ]]; then
  STAKE_CELL=""
  for ax in $STATE_AXES; do
    [[ -n "$STAKE_CELL" ]] && STAKE_CELL="${STAKE_CELL}+"
    STAKE_CELL="${STAKE_CELL}$(axis_ru "$ax")"
  done
  if [[ -n "$HYPOTHESIS" && "$HYPOTHESIS" != "—" ]]; then
    STAKE_CELL="${STAKE_CELL} · ${HYPOTHESIS}"
  fi
fi

# --- Find and atomically reserve the next number WP ---
# issue #743: max(REGISTRY)+1 without reservation returns the same number
# to two parallel agents (Claude/Kimi/Codex — standard platform mode,
# see. AGENTS.md § Git Staging), and again — any reduction of the active
# registry (archiving, splitting). The same race condition class has already been resolved for numbers
# peer-sessions (session-dir-reserve.sh, WP-530): marker-directory + `mkdir` without
# -p as the sole atomic arbiter on POSIX-file system, retry on
# EEXIST. Markers are never deleted during WP archiving WP — a number is never reissued.
WP_NUMBERS_DIR="$STATE_DIR/wp-numbers"
mkdir -p "$WP_NUMBERS_DIR"
# Fail fast on a real filesystem problem (permissions, read-only, disk full)
# instead of burning all 50 retry attempts and reporting a misleading
# "couldn't reserve after 50 tries" — that message is meant for a genuine
# reservation race, not a broken filesystem (cold-review finding, PR #746).
[[ -w "$WP_NUMBERS_DIR" ]] || { echo "❌ No write permission to $WP_NUMBERS_DIR — number reservation is not possible" >&2; exit 1; }

registry_max() {
  python3 - "$REGISTRY" <<'PYEOF' 2>/dev/null
import sys, re
registry = sys.argv[1]
max_num = 0
try:
    with open(registry, "r", encoding="utf-8") as f:
        for line in f:
            # Looking for lines of the form | 297 |, | ~~297~~ | or legacy-format | WP-297 |
            m = re.match(r"^\|\s*[*~]*(?:WP-)?(\d+)[*~]*\s*\|", line)
            if m:
                n = int(m.group(1))
                if n > max_num:
                    max_num = n
except Exception:
    pass
print(max_num)
PYEOF
}

highest_taken() {
  local max
  max=$(registry_max)
  [[ "$max" =~ ^[0-9]+$ ]] || max=0
  local d n
  for d in "$WP_NUMBERS_DIR"/*/; do
    [[ -d "$d" ]] || continue
    n="$(basename "$d")"
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    if [ "$n" -gt "$max" ]; then max=$n; fi
  done
  printf '%s\n' "$max"
}

WP_NUM=""
for ((_attempt = 1; _attempt <= 50; _attempt++)); do
  next=$(( $(highest_taken) + 1 ))
  # Without -p: EEXIST — signal, meaning another session claimed the number, retry with
  # fresh highest_taken (the REGISTRY portion of the maximum may also have grown REGISTRY-portion of the maximum).
  if mkdir "$WP_NUMBERS_DIR/$next" 2>/dev/null; then
    WP_NUM="$next"
    break
  fi
done

if [[ -z "$WP_NUM" ]]; then
  echo "❌ Failed to reserve WP number WP in 50 attempts" >&2
  exit 1
fi

echo "📋 Next WP number WP: $WP_NUM (reserved: $WP_NUMBERS_DIR/$WP_NUM)"

# issue #338 item.4: without padding "WP-9" sorts after in a directory listing "WP-10".
# WP_ID — only for lines with the prefix "WP-" (paths, headings); frontmatter
# wp:, consent-file and columns "#" REGISTRY/WeekPlan remain bare-number.
WP_ID=$(printf '%03d' "$WP_NUM")

# --- Validation consent ---
# Rejection here is the standard first round — standard first round WP Gate (the real user has not yet
# confirmed creation), not a race for the number: nothing for WP_NUM has not been created,
# therefore the reservation marker is removed before exit — otherwise a repeated run
# after `touch` reserves the NEXT number, and not the one, that the user just
# confirmed, and WP Gate never passes (a live test caught this before
# release: touch consent-2 → the second run requires consent-3 → infinite
# chase). Difference from "failed to create WP-N" below (rollback_wp_creation):
# there may already be partial file traces, here — guaranteed none.
CONSENT_FILE="$STATE_DIR/wp-consent-${WP_NUM}"
if [[ "$SKIP_CONSENT" -eq 0 ]]; then
  if [[ ! -f "$CONSENT_FILE" ]]; then
    rmdir "$WP_NUMBERS_DIR/$WP_NUM" 2>/dev/null
    echo "🚫 WP Gate: no user consent to create WP-${WP_NUM}" >&2
    echo "   Create consent file and retry:" >&2
    echo "   touch $CONSENT_FILE" >&2
    exit 1
  fi
  echo "✅ Consent: $CONSENT_FILE"
fi

# --- Date ---
TODAY=$(date +%Y-%m-%d)

# --- Slug from title (if not set) ---
if [[ -z "$SLUG" ]]; then
  SLUG=$(echo "$TITLE" | python3 -c "
import sys, re
# issue #851: reading via sys.stdin.read() left the decoding to Python's
# default (locale-dependent) stdin codec, which on Windows Git Bash is not
# guaranteed to be UTF-8 even though the pipe itself carries UTF-8 bytes --
# a Cyrillic title decoded as mojibake, transliterated to nothing the table
# recognizes, and collapsed to dashes. Reading raw bytes and decoding as
# UTF-8 explicitly removes that platform dependency; errors='replace' keeps
# this a slug generator, not a strict validator.
data = sys.stdin.buffer.read().decode('utf-8', errors='replace')
s = data.strip().lower()
# Cyrillic transliteration
tr = {
  'a':'a','b':'b','v':'v','g':'g','d':'d','e':'e','yo':'yo','zh':'zh',
  'z':'z','i':'i','j':'j','k':'k','l':'l','m':'m','n':'n','o':'o',
  'p':'p','r':'r','s':'s','t':'t','u':'u','f':'f','kh':'kh','ts':'ts',
  'ch':'ch','sh':'sh','shch':'shch','hard sign':'','y':'y','soft sign':'','e':'e','yu':'yu','ya':'ya'
}
result = ''
for c in s:
    result += tr.get(c, c)
result = re.sub(r'[^a-z0-9]+', '-', result)
result = result[:40].strip('-')
print(result)
" 2>/dev/null)
  # issue #851: the pre-existing bash fallback below only ran on a non-zero
  # python3 exit -- a *successful* run that decoded to an empty/dash-only
  # slug (e.g. an undetected encoding mismatch) slipped through silently and
  # went on to create files with a degenerate name. Treat an empty result
  # the same as a failed one.
  if [[ -z "$SLUG" ]]; then
    SLUG="wp-$(echo "$TITLE" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-' | cut -c1-30)"
  fi
fi

# Inbox convention (WP-434): every WP is a folder inbox/WP-N/ with main file WP-N.md.
# Slug lives in the title/frontmatter.  Archive is created only on closure:
# preliminary stub conflicted with close-wp.sh and could overwrite the context.
WP_DIR="$INBOX/WP-${WP_ID}"
WP_FILE="$WP_DIR/WP-${WP_ID}.md"
mkdir -p "$WP_DIR"

echo "🚀 Creating WP-${WP_ID}: $TITLE"
echo "   Folder: inbox/WP-${WP_ID}/WP-${WP_ID}.md"
echo "   Budget: $BUDGET | Priority: $PRIORITY"

# --- Atomicity (Phase-script-contract-gate, Stage 2): steps 1-4 write to 3 different
# locations (inbox, REGISTRY, WeekPlan) without a shared transaction. Previously a failure at step
# 3/4 left a partially created WP and was not treated as an error — failure of WeekPlan
# was simply printed to stderr and the script continued to «✅ WP created». Snapshot +
# rollback below guarantees: either all 4 steps succeeded, or no trace was left behind.
#
# Snapshots are file copies, not — file copies, not `$(cat file)`: command substitution truncates
# trailing newline, while `printf '%s' "$snapshot" > "$file"` on rollback
# does not restore it — silently corrupts the formatting of REGISTRY/WeekPlan on EVERY
# rollback trigger (found in code-review 03.08, both seed files seed today
# end with \n). `cp` preserves content byte-for-byte, including the case of
# a missing file (then there is no snapshot — rollback simply removes the file, rather than
# creates an empty one where, there was none before).
SNAPSHOT_DIR=$(mktemp -d)
trap 'rm -rf "$SNAPSHOT_DIR"' EXIT
REGISTRY_SNAPSHOT="$SNAPSHOT_DIR/registry.snapshot"
[[ -f "$REGISTRY" ]] && cp "$REGISTRY" "$REGISTRY_SNAPSHOT"
WEEKPLAN=$(find "$STRATEGY/current" -maxdepth 1 -name "WeekPlan*.md" 2>/dev/null | sort -r | head -1)
WEEKPLAN_SNAPSHOT="$SNAPSHOT_DIR/weekplan.snapshot"
[[ -n "$WEEKPLAN" ]] && cp "$WEEKPLAN" "$WEEKPLAN_SNAPSHOT"

rollback_wp_creation() {
  echo "↩️  Rollback: WP-${WP_ID} was not created in full, reverting partial writes" >&2
  rm -rf "$WP_DIR"
  if [[ -f "$REGISTRY_SNAPSHOT" ]]; then
    cp "$REGISTRY_SNAPSHOT" "$REGISTRY"
  else
    rm -f "$REGISTRY"
  fi
  if [[ -n "$WEEKPLAN" ]]; then
    if [[ -f "$WEEKPLAN_SNAPSHOT" ]]; then
      cp "$WEEKPLAN_SNAPSHOT" "$WEEKPLAN"
    else
      rm -f "$WEEKPLAN"
    fi
  fi
}

# --- Build link table rows ---
RELATED_ROWS="| — | — | — | no links |"
if [[ -n "$RELATED" ]]; then
  RELATED_ROWS=""
  IFS=',' read -ra REL_ITEMS <<< "$RELATED"
  for rel_item in "${REL_ITEMS[@]}"; do
    rel_item="${rel_item# }"
    rel_wp="${rel_item%%:*}"
    rel_type="${rel_item#*:}"
    [[ "$rel_wp" == "$rel_type" ]] && rel_type="—"
    RELATED_ROWS+="| ${rel_wp} | 🟡 | ${rel_type} | — |
"
  done
fi

# --- Step 1: context file ---
echo ""
echo "1/5 context file..."

# state_transition goes into frontmatter only when provided (gate off on
# installs without the axes registry); hypothesis always present, "—" = no bet.
FM_STAKE=""
if [[ -n "$STATE" ]]; then
  FM_STAKE="state_transition: \"$(yaml_dq_escape "$STATE")\"
"
fi
FM_STAKE="${FM_STAKE}hypothesis: \"$(yaml_dq_escape "${HYPOTHESIS:-—}")\"
hypothesis_relation: \"${HYPOTHESIS_RELATION}\"
artifactor_resolution_path: \"${ARTF_RESOLUTION_PATH}\""
if [[ -n "$ARTF_SHA256" ]]; then
  FM_STAKE="${FM_STAKE}
artifactor_result_sha256: \"${ARTF_SHA256}\""
fi
if [[ -n "$PILOT_REVISION" ]]; then
  FM_STAKE="${FM_STAKE}
pilot_revision: \"$(yaml_dq_escape "$PILOT_REVISION")\""
fi

if ! cat > "$WP_FILE" <<WPEOF
---
wp: ${WP_NUM}
title: "$(yaml_dq_escape "$TITLE")"
status: pending
priority: ${PRIORITY}
budget: ${BUDGET}
created: ${TODAY}
last_session: ${TODAY}
related: []
verification_class: ${VERIFICATION_CLASS}
${FM_STAKE}
activation: on-demand
---

# WP-${WP_ID}: ${TITLE}

## Problem

[Describe the dissatisfaction / problem, that this WP addresses]

## Artifact

[Concrete outcome — noun-artifact with acceptance criteria]

## WP Links

| WP | Strength | Type | What is transferred |
|----|------|-----|----------------|
${RELATED_ROWS}

## Implementation Phases

### Phase1 — [Phase name] (~?h)

- [ ] ...

## Learnings

[Filled in during sessions]

## Remaining

**What was tried:** not started
**What was learned:** —
  → memory: not needed
**What is next:**
${DECOMPOSE_CHECKLIST_ITEM}- [ ] Open session, read the task, make a plan
**Next step:** Open session — read the task, make a plan
**Context for next session:** WP just created, no context
WPEOF
then
  echo "❌ Failed to write context file: $WP_FILE" >&2
  rollback_wp_creation
  exit 1
fi

echo "   ✅ $WP_FILE"
if [[ "$HYPOTHESIS_RELATION" == "unclassified" ]]; then
  echo "   ⚠️  Hypothesis link is not defined: before starting the WP choose tests/enables/responds/researches/operational" >&2
fi

# --- Step 2: WP-REGISTRY.md ---
echo "2/5 WP-REGISTRY.md..."

if ! python3 - "$REGISTRY" "$WP_NUM" "$PRIORITY" "$TITLE" "$REPO" "$BUDGET" "$GOV_REPO" "$STAKE_CELL" "$WP_ID" <<'PYEOF'
import re
import sys
registry_path, wp_num, priority, title, repo, budget, gov_repo, stake, wp_id = sys.argv[1:10]

with open(registry_path, "r", encoding="utf-8") as f:
    lines = f.readlines()

# Markdown table separator row: `|---|---|`, `| --- | --- |`, `|:---|---:|`, or without
# outer pipes — a line made only of `|`, `-`, `:` and whitespace with at least two cells.
# Same pattern as the Strategy.md writer below (issue #901); the literal `|---` lookup
# this replaces missed every spaced separator, and the missing table failed the whole
# creation with a rollback (issue #979).
TABLE_SEP_RE = re.compile(r"^[ \t]*\|?[ \t:-]*-[ \t:-]*(?:\|[ \t:-]*-[ \t:-]*)+\|?[ \t]*$")

# Find the separator row under the header row (`| # | ...`)
insert_at = None
header_line = None
for i, line in enumerate(lines):
    if TABLE_SEP_RE.match(line.rstrip("\r\n")) and i > 0 and lines[i-1].strip().startswith("| #"):
        insert_at = i + 1
        header_line = lines[i-1]
        break

if insert_at is None:
    print("❌ Table header not found REGISTRY", file=sys.stderr)
    sys.exit(1)

# Schema-guard (issue #263, extended in issue #276): previously the writer required exactly
# 6 columns in the header — REGISTRY with a legitimately different number/and order of columns
# (same semantics, extra. column on top) was blocked entirely, even though the reader
# (check-wp-format.py::find_column_indices) is already tolerant of such variation.
# Instead of counting columns — we build {name: index} from the actual header and
# we check for the presence of 6 canonical names, not their order/or count.
header_cols = [c.strip() for c in header_line.strip().strip("|").split("|")]
CANONICAL_NAMES = ["#", "P", "Title", "St", "Repo", "Budget"]
# issue #297: vendor skeleton (templates/strategy-skeleton/docs/WP-REGISTRY.md)
# writes full names such as Priority Status Repositories rather than short ones («Priority», «Status», «Repositories»), not the short ones
# canonical («P», «St», «Repo») — same semantics, different spelling. Previously
# the check required a literal match and failed even on a freshly created
# from the vendor skeleton registry. Synonyms are resolved to the canonical column before
# validation — the same lines find_column_indices() in check-wp-format.py already read
# both variants via positional fallback'here the same tolerance via an explicit list, here the same tolerance via an explicit list.
COLUMN_SYNONYMS = {
    "Priority": "P",
    "Status": "St",
    "Repositories": "Repo",
    "Repository": "Repo",
}
col_index = {}
for i, name in enumerate(header_cols):
    canonical = COLUMN_SYNONYMS.get(name, name)
    col_index.setdefault(canonical, i)
missing_names = [name for name in CANONICAL_NAMES if name not in col_index]
if missing_names:
    # issue #364: old installs cannot receive seed/template changes through
    # update.sh, so migrate the first writable registry table in place. Existing
    # columns (including the useful legacy «Activation») remain untouched; missing
    # canonical columns are appended and old rows receive an explicit em dash.
    def append_cell(line, value):
        newline = "\n" if line.endswith("\n") else ""
        body = line.rstrip("\n").rstrip()
        if not body.endswith("|"):
            raise ValueError("not a markdown table row")
        return body[:-1].rstrip() + " | " + value + " |" + newline

    header_idx = insert_at - 2
    separator_idx = insert_at - 1
    for name in missing_names:
        lines[header_idx] = append_cell(lines[header_idx], name)
        lines[separator_idx] = append_cell(lines[separator_idx], "---")

    row_idx = insert_at
    while row_idx < len(lines) and lines[row_idx].lstrip().startswith("|"):
        for _ in missing_names:
            lines[row_idx] = append_cell(lines[row_idx], "—")
        row_idx += 1

    header_line = lines[header_idx]
    header_cols = [c.strip() for c in header_line.strip().strip("|").split("|")]
    col_index = {}
    for i, name in enumerate(header_cols):
        canonical = COLUMN_SYNONYMS.get(name, name)
        col_index.setdefault(canonical, i)
    print(
        "   ⚠ REGISTRY: missing columns added {} (legacy-legacy columns preserved)".format(
            ", ".join(missing_names)
        )
    )

repo_cell = repo if repo else "{}/inbox/WP-{}/".format(gov_repo, wp_id)
values_by_name = {
    "#": wp_num,
    "P": priority,
    "Title": "**{}**".format(title),
    "St": "⏳",
    "Repo": repo_cell,
    "Budget": budget,
    # WP-505: optional column; silently skipped when the header lacks it
    "Rate": stake,
}
row_cells = ["—"] * len(header_cols)
for name, idx in col_index.items():
    if name in values_by_name:
        row_cells[idx] = values_by_name[name]
new_row = "| " + " | ".join(row_cells) + " |\n"
lines.insert(insert_at, new_row)

with open(registry_path, "w", encoding="utf-8") as f:
    f.writelines(lines)

print("   ✅ REGISTRY: row {} added".format(wp_num))
PYEOF
then
  rollback_wp_creation
  exit 1
fi

# Post-write verification (issue #256): create-wp.sh once reported success here
# without the row actually landing in REGISTRY — the writer above has no retry/lock,
# so confirm the row is really there before moving on.
# issue #263: some repos historically write the WP number with a prefix (| WP-N |),
# not a bare number (| N |) — grep must accept both formats.
if ! grep -qE "\| \*?\*?(WP-)?${WP_NUM}\*?\*? \|" "$REGISTRY"; then
  echo "❌ REGISTRY write verification FAILED: row WP-${WP_NUM} not found after writing" >&2
  rollback_wp_creation
  exit 1
fi

# --- Step 3: WeekPlan ---
echo "3/5 WeekPlan..."

# WEEKPLAN already located above (snapshot for rollback, issue WP-507 regarding the file name format
# applied there as well) — the same path is used here, do not search again.
if [[ -n "$WEEKPLAN" ]]; then
  if ! python3 - "$WEEKPLAN" "$WP_NUM" "$TITLE" "$PRIORITY" "$BUDGET" "$REPO" "$STAKE_CELL" <<'PYEOF'
import sys, re
weekplan_path, wp_num, title, priority, budget = sys.argv[1:6]
# Optional (issue #1152): the writer tests invoke this block with the first five only.
repo = sys.argv[6] if len(sys.argv) > 6 else ""
stake = sys.argv[7] if len(sys.argv) > 7 else "—"

# Priority mapping → traffic light
flag_map = {"P1": "🔴", "P2": "🟡", "P3": "🟢", "P4": "⚪", "P5": "⚪"}
flag = flag_map.get(priority, "⚪")
# issue #1088: `re.sub(r"[^0-9\-]", "", budget)` dropped the decimal
# separator along with the "h" suffix, turning "0.5h" into "05" (read as
# five hours at a glance, not half an hour). Find the number(s) anywhere in
# the string instead of anchoring to its start -- a start-anchored version
# of this fix (cold review, Fable) returned "?" for "~2h" or a leading-space
# budget, and disagreed with the bash threshold parser on "2h-3h". Take the
# first two numbers found, normalizing a locale comma to a dot; "h" is still
# dropped, same as the old regex did for "3-4h" -> "3-4".
_nums = re.findall(r"\d+(?:[.,]\d+)?", budget)
h_val = "-".join(n.replace(",", ".") for n in _nums[:2]) or "?"

with open(weekplan_path, "r", encoding="utf-8") as f:
    lines = f.readlines()

# issue (2026-07-27, WP-507 registration): the old writer matched a text anchor
# ("**Weekly budget:**"/"**Total budget:**") and a fixed 7-field column order —
# neither exists in the current WeekPlan format (summary line is now "**Budget:**",
# table header is "🚦 | # | WP | h | Source | P | Status | Result"). Locate the table by
# its actual header instead, same name-based technique as the REGISTRY writer, so
# column order/extra columns don't silently corrupt the row.
#
# issue #979: the first WP/Status table is not necessarily the plan. After a day close
# the WeekPlan may start with an «Day summary» block holding `| WP | What was done | Status |`
# and the new row landed there. So every table gets its chain of ancestors — the
# <summary> of each enclosing <details> plus the markdown headings in scope — and the
# writer skips a table when ANY ancestor is a facts section («Summary», «Overview», «Summary»:
# WeekPlan = plan, WeekReport = facts), prefers the table whose «Plan» ancestor is the nearest
# one (its own section beats a plan title that only a general heading above it carries; the
# first one on a tie), falls back to the only remaining candidate and otherwise refuses to
# guess. A <details> block is a section of its own: headings from before it do not apply
# inside, headings met inside it are dropped when it closes. A <summary> may span several
# lines and belongs to the block that opened it: one that is never closed swallows its block
# (nested blocks included), so no table inside it is a candidate, and a nested <details> or
# <summary> cannot take the open state over. The first <summary> names the block; a second one
# in the same block makes the name untrustworthy, and every table of that block, those above
# the second <summary> included, is left to the pilot. Code is decided BEFORE anything else
# (the stage table below): nothing inside a fenced block (``` or ~~~), an indented one (4+
# columns beyond the list item it sits in, a tab counts to 4) or an inline code span is a
# comment or a tag, and nothing inside a fenced or an indented block is a heading or a table.
# An indented line is code only after a blank line, a heading, a closing fence or another code
# line (it cannot interrupt a paragraph, an HTML block or a list item), and a nested list is
# not code. Only an unindented heading is trusted as a section title. A heading with anything
# in front of its hashes (indentation, a list marker, a quote mark) sits in a container whose
# end the line-based reading cannot tell for sure (lazy continuation, tabs, numbering), so it
# changes no section, neither pushes nor pops: it opens an AMBIGUITY ZONE, and no table after
# it, up to the next unindented heading, is a candidate. A heading is told from a table row by
# its shape, not by a pipe in its text: `#`..`######` and a space make an ATX heading (it wins
# over a table row in CommonMark and GFM), so `### Summary | actual` is the heading «Summary | actual»
# and `# | WP | Status` is a heading, not a table header. A quote (`>` after up to three
# spaces) is a container of its own: its tags change nothing outside it. The content of an HTML
# comment (`<!--` .. `-->`, one line or many) is not read at all: no heading, tag, table or zone
# comes out of it, and what is left of a line around a comment (`| WP | <!-- x --> |`) is read as
# the line it is; an unclosed comment swallows the rest of the file. Code comes before comments:
# a `<!--` in fenced, indented or inline code is text and opens nothing. The rows are written
# into the file as it is.
# A table is a candidate only when its header has the exact cell «WP» and a cell
# starting with the word «Status» («Status (as of 3 July)» counts, and gets «pending» like the
# plain «Status» column): «Related WPs» (the «Strategic review» table) is not a plan
# and would receive a nameless row.
# Separator rows are matched by pattern, not by the literal `|---` (same as #901).
#
# STAGE ORDER. The document is read in five stages and an earlier stage takes its lines first: a
# later stage reads only what the earlier ones leave, and no stage hands the next one a line an
# earlier stage has taken (a comment never opens in a line of code, a line inside a comment is no
# code, fence, tag or heading, a heading line is no table row). Two stages that decide on the same
# lines in two places can disagree, so stages 1 and 2 are ONE pass (`read_layout`) with one mask.
#
#   stage | takes                                | what it leaves to the later stages
#   ------+--------------------------------------+---------------------------------------------
#     1   | code: fenced (``` ~~~), indented (4+ | nothing of such a line: no comment, tag,
#         | columns beyond the list item, a tab  | heading or table row comes out of it (`deep`
#         | counts to 4), inline `code spans`    | marks the lines that can be no table row)
#         | (a span is looked for on one line)   |
#     2   | HTML comments, `<!--` .. `-->`       | the text around a comment on its line; a
#         |                                      | line with nothing left is blank
#     3   | tags <details>, <summary>            | the block stack and the titles; the lines of
#         |                                      | an open <summary> title are text
#     4   | ATX headings                         | the headings in scope; one in a container
#         |                                      | opens the ambiguity zone instead
#     5   | table rows: separator and header     | the candidates
#
# Stages 1 and 2 are `read_layout`, stage 3 is `scan_tags`, stages 4 and 5 are the loop below.
TABLE_SEP_RE = re.compile(r"^[ \t]*\|?[ \t:-]*-[ \t:-]*(?:\|[ \t:-]*-[ \t:-]*)+\|?[ \t]*$")
TAG_RE = re.compile(r"</details>|<details\b|<summary\b[^>]*>|</summary>", re.IGNORECASE)
HEADING_RE = re.compile(r"^ {0,3}(#{1,6})[ \t]+(.*)$")
FENCE_RE = re.compile(r"^[ \t]*(`{3,}|~{3,})(.*)$")
LIST_ITEM_RE = re.compile(r"^( *)(?:[-*+]|\d{1,9}[.)])( +|$)")
QUOTE_RE = re.compile(r"^ {0,3}>")
# A heading with something in front of the hashes: indentation, quote marks, list markers.
LOOSE_HEADING_RE = re.compile(r"^[ \t>]*(?:(?:[-*+]|\d{1,9}[.)])[ \t]+)*#{1,6}[ \t]+\S")
# Whole words only: «Weekly summary table (planned WPs)» is a plan, not a facts section.
FACTS_RE = re.compile(r"\b(?:Summar(?:y|ies)?|Overvie[w]|Summary)\b", re.IGNORECASE)
# The word must START with «Plan»/«Plan»: «Unplanned WPs» is not a plan section.
PLAN_RE = re.compile(r"\b(?:Plan|Plan)", re.IGNORECASE)


def strip_tags(text):
    return " ".join(re.sub(r"<[^>]+>", "", text).split())


def table_cells(row):
    return [c.strip() for c in row.strip().strip("|").split("|")]


def column_key(cell):
    """Column name without its qualifier: «Status (as of 3 July)» and «Status W13» are «Status»."""
    return "Status" if re.match(r"Status\b", cell) else cell


def is_plan_header(cells):
    keys = [column_key(c) for c in cells]
    return "WP" in keys and "Status" in keys


def plan_distance(ancestors):
    """Ancestors below the nearest «Plan» one: 0 = the table's own section, None = no «Plan» above."""
    for below, title in enumerate(reversed(ancestors)):
        if PLAN_RE.search(title):
            return below
    return None


def next_fence(fence, text):
    """Fence tracker after one line: (marker, length) inside a fenced code block, else None."""
    found = FENCE_RE.match(text)
    if fence:
        # Only a fence of the same kind, at least as long and without an info string closes it.
        closes = (
            found
            and found.group(1)[0] == fence[0]
            and len(found.group(1)) >= fence[1]
            and not found.group(2).strip()
        )
        return None if closes else fence
    # An info string with a backtick means inline code, not a fence (CommonMark).
    if found and not (found.group(1)[0] == "`" and "`" in found.group(2)):
        return (found.group(1)[0], len(found.group(1)))
    return None


def heading_of(line):
    # An ATX heading wins over a table row (CommonMark, GFM): `### Totals | actual` is a heading
    # whatever its text holds, and so is `# | WP | Status`, which therefore is no table header.
    # A row of a table starts with a pipe or does not look like this at all.
    return HEADING_RE.match(line)


def mask_code_spans(text):
    """The text with every inline code span, backticks included, blanked out; same length."""
    masked = []
    i = 0
    while i < len(text):
        if text[i] != "`":
            masked.append(text[i])
            i += 1
            continue
        run = re.match(r"`+", text[i:]).group()
        closing = re.search(r"(?<!`)" + re.escape(run) + r"(?!`)", text[i + len(run):])
        if closing:  # a span ends at as many backticks as it began with
            end = i + len(run) + closing.end()
            masked.append(" " * (end - i))
            i = end
        else:  # no closing run: the backticks are plain text
            masked.append(run)
            i += len(run)
    return "".join(masked)


def comment_start(text, pos):
    """Index of the first `<!--` at or after pos that is not inside an inline code span, else -1."""
    found = mask_code_spans(text[pos:]).find("<!--")
    return pos + found if found >= 0 else -1


def strip_comments(text, in_comment, block):
    """Stage 2 on one line: (what is left of it, still inside a comment, the open comment began a line).

    A comment opens at `<!--` and closes at the next `-->`, on the same line or on a later one; a
    line with nothing left is blank. A comment that starts a line is an HTML block: its closing line
    goes with it, whatever follows the `-->`. A `<!--` inside an inline code span is text.
    """
    visible, pos = [], 0
    while pos < len(text):
        if in_comment:
            end = text.find("-->", pos)
            if end < 0:
                break
            pos, in_comment = (len(text) if block else end + 3), False
        else:
            start = comment_start(text, pos)
            if start < 0:
                visible.append(text[pos:])
                break
            visible.append(text[pos:start])
            block = not "".join(visible).strip()
            pos, in_comment = start + 4, True
    return "".join(visible), in_comment, block


def read_line(text, items, code_ok):
    """Stage 1 on one line that is not fenced code: (is_code, deep, base, items, code_ok).

    The first three are the facts about the line, the last two the state after it. is_code: a line of
    an indented code block (4+ columns beyond the list item it sits in, a tab counts to 4); it starts
    only after a blank line, a heading, a closing fence or another code line, as right after any other
    line it continues that line's block. deep: indented that far whatever block it belongs to, so never
    a table row. base: the column where the markup of the line starts, i.e. the content offset of its
    container (of the item it opens, for a list item line); a quote or a tag is looked for after it,
    not after the margin. items: content offsets of the open list items, outermost first.
    """
    text = text.expandtabs(4)
    if not text.strip():
        return False, False, 0, items, True
    indent = len(text) - len(text.lstrip(" "))
    items = [offset for offset in items if offset <= indent]
    container = items[-1] if items else 0
    deep = indent - container >= 4
    item = LIST_ITEM_RE.match(text)
    if item and not deep:
        return False, False, item.end(), items + [item.end()], heading_of(text[item.end():]) is not None
    if deep and code_ok:
        return True, True, 0, items, True
    return False, deep, container, items, heading_of(text[container:]) is not None


def read_layout(lines):
    """Stages 1 and 2 in ONE pass: (view, is_code, deep, base), one entry per line.

    view: the lines as markdown reads them, whatever sits inside an HTML comment gone. The code mask
    (is_code, deep, base) is made from the same pass and the same state, so that code and comments
    cannot disagree: a line the code stage takes (fenced, or a line of an indented code block) is
    never looked at for a comment, a `<!--` in it is text, and a line inside a comment is neither
    code nor a fence. Same number of lines, so an index means the same line before and after.
    """
    view, is_code, deep, base = [], [], [], []
    fence = None  # (marker, length) while inside a fenced code block
    in_comment = False
    block = False  # the open comment started its line: the line it closes on is hidden whole
    items, code_ok = [], True
    for line in lines:
        text = line.rstrip("\r\n")
        seen = None  # what stage 1 leaves of the line to the later stages
        if not in_comment:
            was_open = fence is not None
            fence = next_fence(fence, text)
            if was_open or fence:  # fenced code
                view.append(line)
                is_code.append(True)
                deep.append(False)
                base.append(0)
                code_ok = was_open and not fence  # only the closing fence line frees the next one
                continue
            if read_line(text, items, code_ok)[0]:  # indented code: its `<!--` is text
                seen = text
        if seen is None:
            seen, in_comment, block = strip_comments(text, in_comment, block)
        code, is_deep, offset, items, code_ok = read_line(seen, items, code_ok)
        view.append(seen)
        is_code.append(code)
        deep.append(is_deep)
        base.append(offset)
    return view, is_code, deep, base


class Block:
    """An open <details>: the title of its <summary> and what the writer needs to scope headings."""

    def __init__(self, outer_headings):
        self.title = ""
        self.outer_headings = outer_headings  # headings in scope before it opened (rebound, never mutated)
        self.pieces = None  # text of the <summary> being read, None while none is open
        self.summaries = 0  # <summary> tags met in this block; a second one makes its name untrustworthy


def collect_title(blocks, text):
    """Add text to the innermost <summary> that is still open."""
    for block in reversed(blocks):
        if block.pieces is not None:
            block.pieces.append(text)
            return


def scan_tags(line, blocks, headings):
    """Apply the <details>/<summary> tags of one line to the block stack; return the headings in scope.

    A tag inside an inline code span is text: stage 1 (code) comes before stage 3 (tags).
    """
    position = 0
    for tag in TAG_RE.finditer(mask_code_spans(line)):
        collect_title(blocks, line[position:tag.start()])
        position = tag.end()
        kind = tag.group(0).lower()
        top = blocks[-1] if blocks else None
        if kind == "</summary>":
            if top and top.pieces is not None:  # only the block that opened it can close it
                if top.summaries == 1:  # the first <summary> names the block, a later one never renames it
                    top.title = strip_tags(" ".join(top.pieces))
                top.pieces = None
        elif kind == "</details>":
            if top:
                headings = blocks.pop().outer_headings  # an unclosed <summary> ends with its block
        elif kind.startswith("<details"):
            blocks.append(Block(headings))
            headings = []
        elif top:
            top.summaries += 1
            if top.pieces is None:  # a repeated tag inside an open title keeps the text read so far
                top.pieces = []
    collect_title(blocks, line[position:])
    return headings


view, is_code, deep, base = read_layout(lines)  # stages 1 and 2; `lines` stays as it is, the row goes into it
candidates = []  # (header line, insert position, ancestor titles, open blocks)
headings = []  # (level, title) of the markdown headings in scope
blocks = []  # the open <details> blocks, outermost first
zone = False  # a heading we cannot place was met and no unindented heading has closed its zone yet
for i, line in enumerate(view):
    if is_code[i]:
        continue
    text = line.expandtabs(4)[base[i]:]  # the line without the indentation of its container
    in_summary = any(b.pieces is not None for b in blocks)  # the line starts inside a <summary> title
    if not in_summary and not line.startswith("#") and LOOSE_HEADING_RE.match(line):
        zone = True  # a heading in a list item, in a quote or indented: it changes no section, see above
    if QUOTE_RE.match(text):
        continue  # a quote is a container of its own: its tags leave the sections outside alone
    headings = scan_tags(text, blocks, headings)
    if in_summary:
        continue  # the lines of a <summary> title are text, not headings or tables
    heading = heading_of(line) if line.startswith("#") else None  # only an unindented heading is trusted
    if heading:
        level = len(heading.group(1))
        headings = [h for h in headings if h[0] < level] + [(level, strip_tags(heading.group(2)))]
        zone = False
    if i > 0 and TABLE_SEP_RE.match(line.rstrip("\r\n")):
        header = view[i - 1]
        ancestors = [b.title for b in blocks] + [h[1] for h in headings]
        if (
            not zone
            and heading_of(header) is None  # a heading is no table header, a pipe in its text or not
            and is_plan_header(table_cells(header))
            and not deep[i - 1]
            and not deep[i]
            and not any(FACTS_RE.search(t) for t in ancestors)
        ):
            candidates.append((header, i + 1, ancestors, list(blocks)))

# A block with a second <summary> is not told by its name: its tables, those above the second
# <summary> included, are left to the pilot.
candidates = [c for c in candidates if all(b.summaries < 2 for b in c[3])]
# The table whose «Plan» ancestor is the nearest wins; equal distance keeps document order.
ranked = [(plan_distance(c[2]), n) for n, c in enumerate(candidates)]
ranked = [r for r in ranked if r[0] is not None]
if ranked:
    chosen = candidates[min(ranked)[1]]
elif len(candidates) == 1:
    chosen = candidates[0]
else:
    chosen = None
header_line, insert_at = (chosen[0], chosen[1]) if chosen else (None, None)

if insert_at is None:
    if candidates:
        titles = ", ".join("«{}»".format(" › ".join(t for t in c[2] if t) or "no title") for c in candidates)
        print("   ⚠️  WeekPlan: multiple WP tables/Status, none is named «Plan» ({}) — not picking one at random, add manually".format(titles), file=sys.stderr)
    else:
        print("   ⚠️  WeekPlan: week table (WP header/Status outside blocks «Totals») not found — add manually", file=sys.stderr)
else:
    header_cols = table_cells(header_line)
    header_keys = [column_key(c) for c in header_cols]
    values_by_name = {
        "🚦": flag,
        "#": wp_num,
        "WP": "**{}** — [description]".format(title),
        "h": h_val,
        "Source": "—",
        "P": priority,
        "Status": "pending",
        "Result": "[fill in]",
    }
    # issue #1152 / #1170: a layout `🚦 | WP | Work | Hours (ceiling) | Source | Rate |
    # Status | Repo` keeps the NUMBER in «WP» and the title in «Work»; there is no «#»
    # column. Without this the title landed in «WP» and the other columns stayed empty.
    if "#" not in header_keys and "Work" in header_keys:
        values_by_name["WP"] = "WP-{}".format(wp_num)
        values_by_name["Work"] = "**{}** — [description]".format(title)
        values_by_name["Hours (ceiling)"] = h_val
        values_by_name["Rate"] = stake
        values_by_name["Repo"] = repo if repo else "—"
    row_cells = ["—"] * len(header_cols)
    for idx, name in enumerate(header_cols):
        key = column_key(name)  # the same normalization the header detection used
        if key in values_by_name:
            row_cells[idx] = values_by_name[key]
    # The new row keeps the indentation of the table (a table inside a list item stays one).
    indent = re.match(r"[ \t]*", lines[insert_at - 1]).group()
    new_row = indent + "| " + " | ".join(row_cells) + " |\n"
    lines.insert(insert_at, new_row)
    with open(weekplan_path, "w", encoding="utf-8") as f:
        f.writelines(lines)
    print("   ✅ WeekPlan: row WP-{} added".format(wp_num))
PYEOF
  then
    echo "❌ WeekPlan write FAILED — WP-${WP_NUM} not created" >&2
    rollback_wp_creation
    exit 1
  fi
else
  echo "   ⚠️  WeekPlan not found in current/ — add manually" >&2
fi

# --- Step 4: Strategy.md (only if --result is set and budget ≥3h) ---
echo "4/5 Strategy.md..."

# issue #1088: this used to be its own `sed 's/[^0-9]//g'`, which read a
# fractional budget like "0.5h" as "05" (five hours) -- the same bug as
# budget_upper_bound_hours() above, duplicated with a different regex.
# Reuse that function instead of a second copy of the same threshold logic.
BUDGET_H=$(budget_upper_bound_hours "$BUDGET")
if [[ -n "$RESULT" && "${BUDGET_H:-0}" -ge 3 ]]; then
  STRATEGY_FILE="$STRATEGY/docs/Strategy.md"
  python3 - "$STRATEGY_FILE" "$WP_ID" "$REPO" "$RESULT" <<'PYEOF'
import re
import sys

strategy_path, wp_id, repo, result = sys.argv[1:5]

section_anchor = "### WP → Results"
# A markdown table separator row (`|---|---|`, `|----|----|`, `| --- | --- |`,
# `|:---|---:|`, or without outer pipes) — any line made only of `|`, `-`, `:`
# and whitespace, requiring at least two `|`-separated cells (this table is
# always 4 columns; a bare single-cell "|---|" does not match, unlike the old
# literal search issue #901 reported — not a concern here). The old literal
# "|---|" also missed every width other than exactly three dashes per cell.
TABLE_SEP_RE = re.compile(
    r"^[ \t]*\|?[ \t:-]*-[ \t:-]*(?:\|[ \t:-]*-[ \t:-]*)+\|?[ \t]*$", re.MULTILINE
)

with open(strategy_path, "r", encoding="utf-8") as f:
    content = f.read()

if section_anchor not in content:
    print("   ⚠️  Strategy.md: section «{}» not found — add manually".format(section_anchor))
    sys.exit(0)

section_start = content.index(section_anchor)
next_heading = re.search(r"\n#{2,3} ", content[section_start + len(section_anchor):])
section_end = (
    section_start + len(section_anchor) + next_heading.start()
    if next_heading
    else len(content)
)

sep_match = TABLE_SEP_RE.search(content, section_start, section_end)
if not sep_match:
    print("   ⚠️  Strategy.md: table separator not found in section — add manually")
    sys.exit(0)

insert_at = content.index("\n", sep_match.end()) + 1
repo_cell = repo if repo else "—"
new_row = "| WP-{} | {} | {} | pending |\n".format(wp_id, repo_cell, result)
content = content[:insert_at] + new_row + content[insert_at:]

with open(strategy_path, "w", encoding="utf-8") as f:
    f.write(content)
print("   ✅ Strategy.md: WP-{} → {} added".format(wp_id, result))
PYEOF
elif [[ "${BUDGET_H:-0}" -ge 3 ]]; then
  echo "   ℹ️  WP ≥3h, but --result not set — add mapping to Strategy.md manually"
else
  echo "   ℹ️  WP <3h — mapping to Strategy.md not required"
fi

# --- Step 5: active-wp.md ---
echo "5/5 active-wp.md..."

BUILD_ACTIVE_WP=""
if [[ -f "$STRATEGY/scripts/build-active-wp.py" ]]; then
  BUILD_ACTIVE_WP="$STRATEGY/scripts/build-active-wp.py"
elif [[ -f "$IWE/IWE/scripts/build-active-wp.py" ]]; then
  BUILD_ACTIVE_WP="$IWE/IWE/scripts/build-active-wp.py"
fi

if [[ -n "$BUILD_ACTIVE_WP" ]]; then
  python3 "$BUILD_ACTIVE_WP" \
    && echo "   ✅ active-wp.md rebuilt" \
    || echo "   ⚠️  build-active-wp.py finished with an error — rebuild manually" >&2
else
  echo "   ⚠️  scripts/build-active-wp.py not found (searched in \`$STRATEGY/scripts/\` and \`$IWE/IWE/scripts/\`) — rebuild manually" >&2
fi

# --- External tracker (conditional post-step, #432) ---
# The local transaction above is already complete.  The adapter is deliberately
# best-effort: its UNAVAILABLE/INVALID_CONFIG result is visible but never rolls
# back a valid local WP.
echo ""
TRACKER_ADAPTER=""
if [[ -x "$IWE/scripts/external-tracker.py" ]]; then
  TRACKER_ADAPTER="$IWE/scripts/external-tracker.py"
elif [[ -x "$IWE/IWE/scripts/external-tracker.py" ]]; then
  TRACKER_ADAPTER="$IWE/IWE/scripts/external-tracker.py"
fi

if [[ -n "$TRACKER_ADAPTER" && "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  TRACKER_OUTPUT=$(python3 "$TRACKER_ADAPTER" create --context "$WP_FILE" --repository "$REPO" 2>&1 || true)
  echo "ℹ️  External tracker: $TRACKER_OUTPUT"
elif [[ -n "$TRACKER_ADAPTER" ]]; then
  echo "ℹ️  External tracker was not invoked: --repo must have the format owner/repository"
else
  echo "ℹ️  External tracker is not installed; local WP registration complete"
fi

# --- Consent file stays in the WP folder WP for the audit-trail ---
# Previously consent file was deleted here; this broke subsequent wp-gate-check
# edits in the same session. The file is kept; cleanup at the discretion of the pilot.
if [[ "$SKIP_CONSENT" -eq 0 && -f "$CONSENT_FILE" ]]; then
  echo ""
  echo "ℹ️  Consent file saved: $CONSENT_FILE"
fi

echo ""
echo "✅ WP-${WP_ID} created: $TITLE"
echo "   context: inbox/WP-${WP_ID}/WP-${WP_ID}.md"
echo "   archive: will be created close-wp.sh when the WP is closed"
echo "   Next step: fill in «Problem», «Artifact», «Phases» in context file"
echo "   Do not forget: issue in the external tracker (if connected)"
